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
# (see parse_connection_args). ISFDB_ASSUME_YES=1 is the same as --yes.
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

# Parse the options shared by all scripts
# Args: the script's command line
# Sets: ASSUME_YES, LOGIN_PATH, DB_USER, DEFAULTS_EXTRA_FILE
parse_connection_args() {
    local login_path_given=0
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes)
                ASSUME_YES=1
                ;;
            --user|--defaults-extra-file)
                if [ $# -lt 2 ]; then
                    print_error "Option $1 needs a value"
                    return 1
                fi
                if [ "$1" = "--user" ]; then DB_USER="$2"; else DEFAULTS_EXTRA_FILE="$2"; fi
                shift
                ;;
            -*)
                print_error "Unknown option: $1"
                echo "Usage: $(basename "$0") [--yes] [--user NAME] [--defaults-extra-file FILE] [login-path]"
                return 1
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
        echo "Usage: $(basename "$0") [--yes] [--user NAME] [--defaults-extra-file FILE] [login-path]"
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

# Get tables by engine type
# Args: $1 = mysql command, $2 = database name, $3 = engine (InnoDB/MyISAM)
# Returns: table list (one per line)
get_tables_by_engine() {
    local mysql_cmd="$1"
    local db_name="$2"
    local engine="$3"

    ${mysql_cmd} -D "${db_name}" -s -N -e "
        SELECT TABLE_NAME
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = '${db_name}'
        AND ENGINE = '${engine}'
        AND TABLE_TYPE = 'BASE TABLE'
        ORDER BY (DATA_LENGTH + INDEX_LENGTH) ASC;
    " 2>&1
}

# Display table details with formatted output
# Args: $1 = mysql command, $2 = database name, $3 = engine
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
        AND ENGINE = '${engine}'
        ORDER BY SIZE_MB DESC
        LIMIT 20;
    "
}

# Get total size of tables
# Args: $1 = mysql command, $2 = database name, $3 = engine
get_total_size() {
    local mysql_cmd="$1"
    local db_name="$2"
    local engine="$3"

    ${mysql_cmd} -D "${db_name}" -s -N -e "
        SELECT ROUND(SUM(DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2)
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = '${db_name}'
        AND ENGINE = '${engine}'
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
# DATE VALIDATION AND FIXING
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

# Count invalid dates in a column
# Args: $1 = mysql command, $2 = database name, $3 = table name, $4 = column name
count_invalid_dates() {
    local mysql_cmd="$1"
    local db_name="$2"
    local table_name="$3"
    local column_name="$4"

    ${mysql_cmd} -D "${db_name}" -s -N -e "
        SELECT COUNT(*)
        FROM \`${table_name}\`
        WHERE
            CAST(\`${column_name}\` AS CHAR) = '0000-00-00'
            OR CAST(\`${column_name}\` AS CHAR) LIKE '____-00-00'
            OR CAST(\`${column_name}\` AS CHAR) LIKE '____-00-__'
            OR CAST(\`${column_name}\` AS CHAR) LIKE '____-__-00';
    " 2>&1
}

# Fix invalid dates in a column
# Args: $1 = mysql command, $2 = database name, $3 = table name, $4 = column name
fix_invalid_dates() {
    local mysql_cmd="$1"
    local db_name="$2"
    local table_name="$3"
    local column_name="$4"

    ${mysql_cmd} -D "${db_name}" -e "
        UPDATE \`${table_name}\`
        SET \`${column_name}\` = CASE
            WHEN CAST(\`${column_name}\` AS CHAR) = '0000-00-00' THEN NULL
            WHEN CAST(\`${column_name}\` AS CHAR) LIKE '____-00-00' THEN
                CONCAT(SUBSTRING(CAST(\`${column_name}\` AS CHAR), 1, 4), '-01-01')
            WHEN CAST(\`${column_name}\` AS CHAR) LIKE '____-00-__' THEN
                CONCAT(SUBSTRING(CAST(\`${column_name}\` AS CHAR), 1, 4), '-01', SUBSTRING(CAST(\`${column_name}\` AS CHAR), 8, 3))
            WHEN CAST(\`${column_name}\` AS CHAR) LIKE '____-__-00' THEN
                CONCAT(SUBSTRING(CAST(\`${column_name}\` AS CHAR), 1, 7), '-01')
            ELSE \`${column_name}\`
        END
        WHERE
            CAST(\`${column_name}\` AS CHAR) = '0000-00-00'
            OR CAST(\`${column_name}\` AS CHAR) LIKE '____-00-00'
            OR CAST(\`${column_name}\` AS CHAR) LIKE '____-00-__'
            OR CAST(\`${column_name}\` AS CHAR) LIKE '____-__-00';
    " 2>&1
}

# Check and fix all date columns in a table
# Args: $1 = mysql command, $2 = database name, $3 = table name
check_and_fix_dates() {
    local mysql_cmd="$1"
    local db_name="$2"
    local table_name="$3"

    print_step "Checking for invalid dates..."

    local date_columns
    date_columns=$(get_date_columns "$mysql_cmd" "$db_name" "$table_name")

    if [ -z "$date_columns" ]; then
        echo -e "✓ No date columns in this table"
        return 0
    fi

    local total_invalid=0
    local columns_with_invalid=""

    while IFS= read -r col; do
        local invalid_count
        invalid_count=$(count_invalid_dates "$mysql_cmd" "$db_name" "$table_name" "$col")

        if [ "$invalid_count" -gt 0 ]; then
            total_invalid=$((total_invalid + invalid_count))
            columns_with_invalid="${columns_with_invalid}${col}:${invalid_count} "
            echo -e "Found ${YELLOW}${invalid_count}${NC} invalid date(s) in ${CYAN}${col}${NC}"
        fi
    done <<< "$date_columns"

    if [ $total_invalid -gt 0 ]; then
        print_warn "Found ${total_invalid} total invalid date(s) - fixing..."

        for col_info in $columns_with_invalid; do
            local col=$(echo "$col_info" | cut -d: -f1)
            local count=$(echo "$col_info" | cut -d: -f2)

            echo -e "Fixing ${CYAN}${col}${NC} (${count} rows)..."

            if fix_invalid_dates "$mysql_cmd" "$db_name" "$table_name" "$col" > /dev/null 2>&1; then
                print_info "✓ Fixed ${CYAN}${col}${NC}"
            else
                print_error "✗ Failed to fix ${CYAN}${col}${NC}"
            fi
        done
        echo ""
    else
        echo -e "✓ No invalid dates found"
    fi

    return 0
}

# =====================================================
# INDEX MANAGEMENT
# =====================================================

# Get regular indexes (non-FULLTEXT, including PRIMARY) for a table
# Args: $1 = mysql command, $2 = database name, $3 = table name
# Returns: index_name:columns (one per line), columns in index order
get_regular_indexes() {
    local mysql_cmd="$1"
    local db_name="$2"
    local table_name="$3"

    ${mysql_cmd} -D "${db_name}" -s -N -e "
        SELECT CONCAT(INDEX_NAME, ':', GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ','))
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = '${db_name}'
        AND TABLE_NAME = '${table_name}'
        AND INDEX_TYPE != 'FULLTEXT'
        AND COLUMN_NAME IS NOT NULL
        GROUP BY INDEX_NAME
        ORDER BY INDEX_NAME;
    " 2>&1
}

# Warm up table data by full table scan
# Args: $1 = mysql command, $2 = database name, $3 = table name
# Returns: duration:precision:exit_code
warmup_table_data() {
    local mysql_cmd="$1"
    local db_name="$2"
    local table_name="$3"

    local start_time=$(get_time_ms)
    local time_precision=$TIME_PRECISION_MS

    # Execute full table scan, discard output
    ${mysql_cmd} -D "${db_name}" -s -N -e "SELECT * FROM \`${table_name}\`;" > /dev/null 2>&1
    local exit_code=$?

    local end_time=$(get_time_ms)
    local duration=$((end_time - start_time))

    # Return format: duration:precision:exit_code
    echo "${duration}:${time_precision}:${exit_code}"
}

# Warm up a specific index
# Args: $1 = mysql command, $2 = database name, $3 = table name,
#       $4 = index name, $5 = column list (comma-separated)
# Returns: duration:precision:exit_code
warmup_index() {
    local mysql_cmd="$1"
    local db_name="$2"
    local table_name="$3"
    local index_name="$4"
    local columns="$5"

    local start_time=$(get_time_ms)
    local time_precision=$TIME_PRECISION_MS

    # Build column list for SELECT and ORDER BY
    local select_cols=$(echo "$columns" | sed 's/,/, /g')
    local order_cols="$select_cols"

    # Execute query using FORCE INDEX, discard output
    if [ "$index_name" = "PRIMARY" ]; then
        # PRIMARY KEY doesn't need backticks in FORCE INDEX
        ${mysql_cmd} -D "${db_name}" -s -N -e "SELECT ${select_cols} FROM \`${table_name}\` FORCE INDEX (PRIMARY) ORDER BY ${order_cols};" > /dev/null 2>&1
    else
        ${mysql_cmd} -D "${db_name}" -s -N -e "SELECT ${select_cols} FROM \`${table_name}\` FORCE INDEX (\`${index_name}\`) ORDER BY ${order_cols};" > /dev/null 2>&1
    fi
    local exit_code=$?

    local end_time=$(get_time_ms)
    local duration=$((end_time - start_time))

    # Return format: duration:precision:exit_code
    echo "${duration}:${time_precision}:${exit_code}"
}

# =====================================================
# TABLE OPERATIONS
# =====================================================

# Convert table to InnoDB
# Args: $1 = mysql command, $2 = database name, $3 = table name
convert_to_innodb() {
    local mysql_cmd="$1"
    local db_name="$2"
    local table_name="$3"

    ${mysql_cmd} -D "${db_name}" -e "ALTER TABLE \`${table_name}\` ENGINE=InnoDB;" 2>&1
}

# Verify table engine
# Args: $1 = mysql command, $2 = database name, $3 = table name
# Returns: engine name
get_table_engine() {
    local mysql_cmd="$1"
    local db_name="$2"
    local table_name="$3"

    ${mysql_cmd} -D "${db_name}" -s -N -e "
        SELECT ENGINE
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = '${db_name}'
        AND TABLE_NAME = '${table_name}';
    "
}

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

# Analyze table (updates index statistics)
# Args: $1 = mysql command, $2 = database name, $3 = table name
analyze_table() {
    local mysql_cmd="$1"
    local db_name="$2"
    local table_name="$3"

    ${mysql_cmd} -D "${db_name}" -e "ANALYZE TABLE \`${table_name}\`;" 2>&1
}

# Optimize table (on InnoDB: rebuild + analyze)
# Fails when the client fails or any result row reports an error or a status other than OK
# Args: $1 = mysql command, $2 = database name, $3 = table name
optimize_table() {
    local mysql_cmd="$1"
    local db_name="$2"
    local table_name="$3"

    local output
    output=$(${mysql_cmd} -D "${db_name}" -e "OPTIMIZE TABLE \`${table_name}\`;" 2>&1) || {
        echo "$output"
        return 1
    }
    echo "$output"
    # Result columns: Table, Op, Msg_type, Msg_text
    awk -F'\t' 'NR > 1 && (tolower($3) == "error" || (tolower($3) == "status" && $4 != "OK")) { bad = 1 } END { exit bad }' <<< "$output"
}

# =====================================================
# INNODB CONFIGURATION ANALYSIS
# =====================================================

# Get InnoDB buffer pool size in MB
# Args: $1 = mysql command
get_buffer_pool_size() {
    local mysql_cmd="$1"

    local size
    size=$(${mysql_cmd} -s -N -e "SELECT @@innodb_buffer_pool_size / 1024 / 1024;" 2>&1)
    printf "%.0f" "$size"
}

# Get total system RAM in MB
get_system_ram() {
    if command -v free &> /dev/null; then
        free -m | awk '/^Mem:/{print $2}'
    elif [ -r /proc/meminfo ]; then
        awk '/^MemTotal:/{print int($2 / 1024)}' /proc/meminfo
    elif command -v sysctl &> /dev/null; then
        # macOS
        local ram_bytes
        ram_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
        echo $((ram_bytes / 1024 / 1024))
    else
        echo "unknown"
    fi
}

# Calculate recommended buffer pool size
# Args: $1 = total RAM in MB, $2 = database size in MB
# Returns: recommended size in MB
calculate_recommended_buffer_pool() {
    local total_ram="$1"
    local db_size="$2"

    local recommended_min=$((total_ram * 70 / 100))
    local recommended_max=$((total_ram * 80 / 100))

    # Convert float to int for comparison
    local db_size_int=$(printf "%.0f" "$db_size")
    local db_size_times_1_2=$(awk -v s="$db_size" 'BEGIN { printf "%.0f", s * 1.2 }')

    if awk -v s="$db_size" -v m="$recommended_max" 'BEGIN { exit !(s > m) }'; then
        # If DB is larger than 80% of RAM, recommend 80% of RAM
        echo "$recommended_max"
    elif [ "$db_size_times_1_2" -lt "$recommended_min" ]; then
        # If DB is much smaller, recommend DB size * 1.2
        echo "$db_size_times_1_2"
    else
        # Otherwise recommend 70% of RAM
        echo "$recommended_min"
    fi
}

# Display InnoDB configuration recommendations
# Args: $1 = mysql command, $2 = database size in MB
display_innodb_recommendations() {
    local mysql_cmd="$1"
    local db_size="$2"

    local buffer_pool_mb
    buffer_pool_mb=$(get_buffer_pool_size "$mysql_cmd")

    local total_ram_mb
    total_ram_mb=$(get_system_ram)

    echo ""
    print_step "Current InnoDB settings:"
    echo -e "Buffer pool size:     ${CYAN}${buffer_pool_mb} MB${NC}"

    if [ "$total_ram_mb" != "unknown" ]; then
        echo -e "Total system RAM:     ${CYAN}${total_ram_mb} MB${NC}"
        local buffer_pool_percent=$((buffer_pool_mb * 100 / total_ram_mb))
        echo -e "Buffer pool usage:    ${CYAN}${buffer_pool_percent}%${NC} of RAM"
    fi

    echo -e "Database size:        ${CYAN}${db_size} MB${NC}"

    # Calculate recommendations
    if [ "$total_ram_mb" != "unknown" ] && [ "$total_ram_mb" -gt 0 ]; then
        local recommended_min=$((total_ram_mb * 70 / 100))
        local recommended_max=$((total_ram_mb * 80 / 100))
        local recommended
        recommended=$(calculate_recommended_buffer_pool "$total_ram_mb" "$db_size")

        echo ""
        if [ "$buffer_pool_mb" -lt "$recommended_min" ]; then
            print_warn "⚠ Buffer pool size is suboptimal"
            echo ""
            echo -e "${YELLOW}Recommendation:${NC}"
            echo -e "Your InnoDB buffer pool (${buffer_pool_mb} MB) is smaller than recommended."
            echo -e "For optimal performance, set it to ${CYAN}${recommended}-${recommended_max} MB${NC}"
            echo ""
            echo -e "${CYAN}Add to your MySQL configuration (my.cnf or my.ini):${NC}"
            echo ""
            echo -e "[mysqld]"
            echo -e "innodb_buffer_pool_size = ${recommended}M"
            echo ""
            echo -e "Other recommended InnoDB settings:"
            echo -e "innodb_log_file_size = 256M"
            echo -e "innodb_flush_log_at_trx_commit = 2"
            echo -e "innodb_flush_method = O_DIRECT"
            echo ""
            echo -e "After changing, restart MySQL to apply settings."
        elif [ "$buffer_pool_mb" -gt "$recommended_max" ]; then
            print_warn "⚠ Buffer pool size might be too large"
            echo ""
            echo -e "Your buffer pool (${buffer_pool_mb} MB) uses ${buffer_pool_percent}% of RAM."
            echo -e "Recommended range: ${CYAN}${recommended_min}-${recommended_max} MB${NC} (70-80% of RAM)"
            echo -e "Leave some RAM for OS and other processes."
        else
            print_info "✓ Buffer pool size is well configured (${buffer_pool_percent}% of RAM)"
        fi
    fi
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

# Get current time in milliseconds with fallback
# Returns: timestamp in milliseconds (or seconds * 1000 if ms not available)
# Sets: TIME_PRECISION_MS=1 if milliseconds available, 0 otherwise
get_time_ms() {
    if command -v gdate &> /dev/null; then
        gdate +%s%3N
        TIME_PRECISION_MS=1
    elif date +%s%3N 2>/dev/null | grep -qv 'N'; then
        date +%s%3N
        TIME_PRECISION_MS=1
    else
        echo $(($(date +%s) * 1000))
        TIME_PRECISION_MS=0
    fi
}

# Format duration with millisecond precision
# Args: $1 = duration in milliseconds, $2 = precision flag (1=ms available, 0=seconds only)
# Returns: formatted string (e.g., "150ms", "45s", "2m 30s")
format_duration_detailed() {
    local duration_ms="$1"
    local has_ms_precision="${2:-1}"

    if [ "$has_ms_precision" -eq 0 ]; then
        # Seconds-only precision, duration_ms is actually seconds * 1000
        local seconds=$((duration_ms / 1000))
        if [ "$seconds" -lt 60 ]; then
            echo "${seconds}s"
        else
            local minutes=$((seconds / 60))
            local remaining_seconds=$((seconds % 60))
            echo "${minutes}m ${remaining_seconds}s"
        fi
    else
        # Millisecond precision
        if [ "$duration_ms" -lt 1000 ]; then
            echo "${duration_ms}ms"
        elif [ "$duration_ms" -lt 60000 ]; then
            local seconds=$((duration_ms / 1000))
            echo "${seconds}s"
        else
            local total_seconds=$((duration_ms / 1000))
            local minutes=$((total_seconds / 60))
            local remaining_seconds=$((total_seconds % 60))
            echo "${minutes}m ${remaining_seconds}s"
        fi
    fi
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
