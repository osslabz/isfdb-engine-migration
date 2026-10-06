#!/bin/bash
# =====================================================
# MySQL InnoDB Migration - Common Functions Library
# =====================================================
#
# This library provides reusable functions for MySQL
# table management, optimization, and configuration.
#
# Usage:
#   source ./mysql_innodb_lib.sh
#
# Scripts accept: [--yes] [--user NAME] [--defaults-extra-file FILE] [login-path]
# plus their own options in OPTION_VARIABLES (see parse_connection_args).
# ISFDB_ASSUME_YES=1 is the same as --yes.
#
# =====================================================

# =====================================================
# COLOR DEFINITIONS
# =====================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# =====================================================
# FORMATTED PRINTING FUNCTIONS
# =====================================================

print_header() {
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
}

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

print_separator() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# =====================================================
# MYSQL CONNECTION MANAGEMENT
# =====================================================

ASSUME_YES=0
[ "${ISFDB_ASSUME_YES:-}" = "1" ] && ASSUME_YES=1
LOGIN_PATH="isfdb_local"
DB_USER=""
DEFAULTS_EXTRA_FILE=""
# Options that take a value, mapped to the variable they set; a script adds its own before parsing
declare -A OPTION_VARIABLES=(["--user"]=DB_USER ["--defaults-extra-file"]=DEFAULTS_EXTRA_FILE)
# Usage text for the options a script adds, e.g. "[--database DB]"
SCRIPT_USAGE_OPTIONS=""

print_usage() {
    echo "Usage: $(basename "$0") [--yes] [--user NAME] [--defaults-extra-file FILE]${SCRIPT_USAGE_OPTIONS:+ ${SCRIPT_USAGE_OPTIONS}} [login-path]"
}

# Fail unless the name is a plain identifier, so the scripts can put it into SQL
# Args: $1 = option the name came from, $2 = database name
validate_database_name() {
    if [[ ! "$2" =~ ^[A-Za-z0-9_]+$ ]]; then
        print_error "$1 must match [A-Za-z0-9_]+, got '$2'"
        return 1
    fi
}

# Parse the options shared by all scripts
# Args: the script's command line
# Sets: ASSUME_YES, LOGIN_PATH and the variables in OPTION_VARIABLES
parse_connection_args() {
    local login_path_given=0
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes)
                ASSUME_YES=1
                ;;
            -*)
                if [ -z "${OPTION_VARIABLES[$1]+set}" ]; then
                    print_error "Unknown option: $1"
                    print_usage
                    return 1
                fi
                if [ $# -lt 2 ]; then
                    print_error "Option $1 needs a value"
                    return 1
                fi
                printf -v "${OPTION_VARIABLES[$1]}" '%s' "$2"
                shift
                ;;
            "")
                ;;
            *)
                LOGIN_PATH="$1"
                login_path_given=1
                ;;
        esac
        shift
    done

    if [ "$login_path_given" = "1" ] && { [ -n "$DB_USER" ] || [ -n "$DEFAULTS_EXTRA_FILE" ]; }; then
        print_error "A login-path cannot be combined with --user or --defaults-extra-file"
        print_usage
        return 1
    fi
}

# Ask a yes/no question; always yes when --yes is set
# Args: $1 = question
# Returns: 0 on yes
confirm() {
    if [ "$ASSUME_YES" = "1" ]; then
        return 0
    fi
    local answer
    read -r -p "$1 (yes/no): " answer
    [ "$answer" = "yes" ]
}

# Check if mysql_config_editor is installed
check_mysql_tools() {
    if ! command -v mysql_config_editor &> /dev/null; then
        print_error "mysql_config_editor not found!"
        echo ""
        echo "Install MySQL client tools:"
        echo "apt-get install mysql-client  # Debian/Ubuntu"
        echo "yum install mysql             # RHEL/CentOS"
        echo "brew install mysql-client     # macOS"
        return 1
    fi
    return 0
}

# Setup or verify MySQL login-path
# Args: $1 = login-path name
setup_login_path() {
    local login_path="$1"

    if ! mysql_config_editor print --login-path="${login_path}" &> /dev/null; then
        print_error "Login-path '${login_path}' not found!"
        echo ""
        echo "Setup: mysql_config_editor set --login-path=${login_path} --user=root --password"
        echo ""
        if [ "$ASSUME_YES" = "1" ]; then
            print_error "Non-interactive mode cannot set up a login-path; create it first or use --user / --defaults-extra-file"
            return 1
        fi

        if confirm "Set it up now?"; then
            local setup_user
            read -p "MySQL username [root]: " setup_user
            setup_user=${setup_user:-root}
            mysql_config_editor set --login-path="${login_path}" --user="${setup_user}" --password
            if ! mysql_config_editor print --login-path="${login_path}" &> /dev/null; then
                print_error "Setup failed"
                return 1
            fi
            print_info "✓ Login-path created"
        else
            return 1
        fi
    fi

    print_info "Using login-path: ${CYAN}${login_path}${NC}"
    mysql_config_editor print --login-path="${login_path}" 2>/dev/null | grep -E "user|host" | sed 's/^/  /'
    echo ""
    return 0
}

# Build MYSQL_CMD from the parsed options and test the connection
# --user / --defaults-extra-file replace the login-path; the mysql client
# still reads MYSQL_PWD, MYSQL_HOST and MYSQL_TCP_PORT from the environment.
# Sets: MYSQL_CMD, MYSQL_VERSION, CONNECTION_LABEL
connect_mysql() {
    print_header "MySQL Authentication Setup"

    if [ -n "$DB_USER" ] || [ -n "$DEFAULTS_EXTRA_FILE" ]; then
        if ! command -v mysql &> /dev/null; then
            print_error "mysql client not found!"
            return 1
        fi
        if [ -n "$DEFAULTS_EXTRA_FILE" ] && [ ! -r "$DEFAULTS_EXTRA_FILE" ]; then
            print_error "Cannot read defaults file: ${DEFAULTS_EXTRA_FILE}"
            return 1
        fi
        # --defaults-extra-file must be the first mysql option
        MYSQL_CMD="mysql"
        CONNECTION_LABEL="credentials from options/environment"
        [ -n "$DEFAULTS_EXTRA_FILE" ] && MYSQL_CMD="${MYSQL_CMD} --defaults-extra-file=${DEFAULTS_EXTRA_FILE}"
        [ -n "$DB_USER" ] && MYSQL_CMD="${MYSQL_CMD} --user=${DB_USER}"
        print_info "Using ${CONNECTION_LABEL}"
        echo ""
    else
        check_mysql_tools || return 1
        setup_login_path "${LOGIN_PATH}" || return 1
        MYSQL_CMD="mysql --login-path=${LOGIN_PATH}"
        CONNECTION_LABEL="login-path ${LOGIN_PATH}"
    fi

    test_mysql_connection "${MYSQL_CMD}"
}

# Test MySQL connection and get version
# Args: $1 = mysql command
# Returns: version string in MYSQL_VERSION variable
test_mysql_connection() {
    local mysql_cmd="$1"

    print_step "Testing MySQL connection..."
    if ! MYSQL_VERSION=$(${mysql_cmd} -s -N -e "SELECT VERSION();" 2>&1); then
        print_error "Cannot connect: $MYSQL_VERSION"
        return 1
    fi
    print_info "✓ Connected successfully"
    print_info "MySQL version: ${MYSQL_VERSION}"
    echo ""
    return 0
}

# =====================================================
# TABLE DISCOVERY FUNCTIONS
# =====================================================

# Condition that limits an information_schema.TABLES query to one engine
# Args: $1 = engine, empty for all engines
engine_condition() {
    if [ -n "$1" ]; then
        echo "AND ENGINE = '$1'"
    fi
}

# Get tables by engine type
# Args: $1 = mysql command, $2 = database name, $3 = engine (InnoDB/MyISAM), empty for all engines
# Returns: table list (one per line)
get_tables_by_engine() {
    local mysql_cmd="$1"
    local db_name="$2"
    local engine="$3"

    ${mysql_cmd} -D "${db_name}" -s -N -e "
        SELECT TABLE_NAME
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = '${db_name}'
        $(engine_condition "${engine}")
        AND TABLE_TYPE = 'BASE TABLE'
        ORDER BY (DATA_LENGTH + INDEX_LENGTH) ASC;
    " 2>&1
}

# Display table details with formatted output
# Args: $1 = mysql command, $2 = database name, $3 = engine (InnoDB/MyISAM), empty for all engines
display_table_details() {
    local mysql_cmd="$1"
    local db_name="$2"
    local engine="$3"

    ${mysql_cmd} -D "${db_name}" -t -e "
        SELECT
            TABLE_NAME,
            ENGINE,
            LPAD(FORMAT(TABLE_ROWS, 0), 15, ' ') AS TABLE_ROWS,
            LPAD(ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2), 10, ' ') AS SIZE_MB
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = '${db_name}'
        $(engine_condition "${engine}")
        ORDER BY SIZE_MB DESC
        LIMIT 20;
    "
}

# Get total size of tables
# Args: $1 = mysql command, $2 = database name, $3 = engine (InnoDB/MyISAM), empty for all engines
get_total_size() {
    local mysql_cmd="$1"
    local db_name="$2"
    local engine="$3"

    ${mysql_cmd} -D "${db_name}" -s -N -e "
        SELECT ROUND(SUM(DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2)
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = '${db_name}'
        $(engine_condition "${engine}")
        AND TABLE_TYPE = 'BASE TABLE';
    "
}

# Display detailed table sizes with data/index breakdown
# Args: $1 = mysql command, $2 = database name, $3 = table list (newline-separated)
display_detailed_sizes() {
    local mysql_cmd="$1"
    local db_name="$2"
    local table_list="$3"

    # Convert newline-separated list to SQL IN clause format
    local table_sql=$(echo "$table_list" | tr '\n' ',' | sed 's/,$//' | sed "s/[^,]*/'&'/g")

    ${mysql_cmd} -D "${db_name}" -t -e "
        SELECT
            TABLE_NAME,
            LPAD(FORMAT(TABLE_ROWS, 0), 15, ' ') AS \`ROWS\`,
            LPAD(ROUND((DATA_LENGTH) / 1024 / 1024, 2), 10, ' ') AS DATA_MB,
            LPAD(ROUND((INDEX_LENGTH) / 1024 / 1024, 2), 10, ' ') AS INDEX_MB,
            LPAD(ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2), 10, ' ') AS TOTAL_MB
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = '${db_name}'
        AND TABLE_NAME IN (${table_sql})
        ORDER BY (DATA_LENGTH + INDEX_LENGTH) DESC;
    "
}

# Display engine distribution
# Args: $1 = mysql command, $2 = database name
display_engine_distribution() {
    local mysql_cmd="$1"
    local db_name="$2"

    ${mysql_cmd} -D "${db_name}" -t -e "
        SELECT
            ENGINE,
            LPAD(COUNT(*), 8, ' ') as TABLES,
            LPAD(ROUND(SUM(DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2), 10, ' ') AS SIZE_MB
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = '${db_name}'
        AND TABLE_TYPE = 'BASE TABLE'
        GROUP BY ENGINE
        ORDER BY TABLES DESC;
    "
}

# =====================================================
# DATE COLUMNS
# =====================================================

# Get date columns for a table
# Args: $1 = mysql command, $2 = database name, $3 = table name
get_date_columns() {
    local mysql_cmd="$1"
    local db_name="$2"
    local table_name="$3"

    ${mysql_cmd} -D "${db_name}" -s -N -e "
        SELECT COLUMN_NAME
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = '${db_name}'
        AND TABLE_NAME = '${table_name}'
        AND DATA_TYPE IN ('date', 'datetime', 'timestamp');
    " 2>&1
}

# Count values whose date part has a zero year, month or day (0000-00-00, 1990-00-00, 1990-05-00)
# The first 10 characters are the date part of date, datetime and timestamp values alike.
# Args: $1 = mysql command, $2 = database name, $3 = table name, $4 = column name
count_zero_dates() {
    local mysql_cmd="$1"
    local db_name="$2"
    local table_name="$3"
    local column_name="$4"

    ${mysql_cmd} -D "${db_name}" -s -N -e "
        SELECT COUNT(*)
        FROM \`${table_name}\`
        WHERE LEFT(CAST(\`${column_name}\` AS CHAR), 10) REGEXP '^0000|-00';
    " 2>&1
}

# =====================================================
# TABLE OPERATIONS
# =====================================================

# Get table info (rows and size)
# Args: $1 = mysql command, $2 = database name, $3 = table name
# Returns: "rows size_mb" (space-separated)
get_table_info() {
    local mysql_cmd="$1"
    local db_name="$2"
    local table_name="$3"

    ${mysql_cmd} -D "${db_name}" -s -N -e "
        SELECT
            COALESCE(TABLE_ROWS, 0),
            COALESCE(ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2), 0)
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = '${db_name}'
        AND TABLE_NAME = '${table_name}';
    "
}

# Run a table maintenance statement (ANALYZE/OPTIMIZE TABLE) and print its result rows
# The mysql client exits 0 even when a result row reports an error, so the rows are checked too.
# Fails when the client fails or any row has Msg_type error or a status other than
# "OK" or "Table is already up to date" (what MySQL reports on success).
# Args: $1 = mysql command, $2 = database name, $3 = statement (e.g. ANALYZE), $4 = table name
run_table_maintenance() {
    local mysql_cmd="$1"
    local db_name="$2"
    local statement="$3"
    local table_name="$4"

    local output
    output=$(${mysql_cmd} -D "${db_name}" -e "${statement} TABLE \`${table_name}\`;" 2>&1) || {
        echo "$output"
        return 1
    }
    echo "$output"
    # Result columns: Table, Op, Msg_type, Msg_text
    awk -F'\t' 'NR > 1 && (tolower($3) == "error" || (tolower($3) == "status" && $4 != "OK" && $4 != "Table is already up to date")) { bad = 1 } END { exit bad }' <<< "$output"
}

# Analyze table (updates index statistics)
# Args: $1 = mysql command, $2 = database name, $3 = table name
analyze_table() {
    run_table_maintenance "$1" "$2" "ANALYZE" "$3"
}

# Optimize table (on InnoDB: rebuild + analyze)
# Args: $1 = mysql command, $2 = database name, $3 = table name
optimize_table() {
    run_table_maintenance "$1" "$2" "OPTIMIZE" "$3"
}

# =====================================================
# UTILITY FUNCTIONS
# =====================================================

# Calculate estimated migration time
# Args: $1 = total size in MB
estimate_migration_time() {
    local total_size="$1"
    # Estimate: ~3 minutes per 100MB
    local minutes=$(awk -v s="$total_size" 'BEGIN { print int(s / 100) * 3 }')
    [ "$minutes" -lt 1 ] && minutes=1
    echo "$minutes"
}

# Format duration from seconds
# Args: $1 = duration in seconds
# Returns: "Xm Ys" format
format_duration() {
    local total_seconds="$1"
    local minutes=$((total_seconds / 60))
    local seconds=$((total_seconds % 60))
    echo "${minutes}m ${seconds}s"
}

# Calculate space difference
# Args: $1 = size before, $2 = size after
# Prints: space saved/increased message
display_space_difference() {
    local size_before="$1"
    local size_after="$2"

    local space_saved=$(awk -v b="$size_before" -v a="$size_after" 'BEGIN { printf "%.2f", b - a }')

    if awk -v d="$space_saved" 'BEGIN { exit !(d > 0) }'; then
        local percent_saved=$(awk -v d="$space_saved" -v b="$size_before" 'BEGIN { printf "%.1f", d * 100 / b }')
        print_info "Space reclaimed: ${GREEN}${space_saved} MB${NC} (${percent_saved}%)"
    elif awk -v d="$space_saved" 'BEGIN { exit !(d < 0) }'; then
        local space_increased=$(awk -v d="$space_saved" 'BEGIN { printf "%.2f", -d }')
        print_warn "Size increased: ${YELLOW}${space_increased} MB${NC} (InnoDB overhead)"
    else
        print_info "Size unchanged"
    fi
}

# =====================================================
# END OF LIBRARY
# =====================================================
