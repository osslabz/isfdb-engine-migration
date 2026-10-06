#!/bin/bash
# =====================================================
# ISFDB InnoDB Copy Script
# =====================================================
# Copies the ISFDB database into a second database with every table
# in InnoDB and every value unchanged. The source is never modified.

# Source the library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/mysql_innodb_lib.sh"

# Configuration
SOURCE_DB="isfdb"
TARGET_DB="isfdb_innodb"
OPTION_VARIABLES["--source"]=SOURCE_DB
OPTION_VARIABLES["--target"]=TARGET_DB
SCRIPT_USAGE_OPTIONS="[--source DB] [--target DB]"
# The copy is built in <target>_next; the replaced target tables pass through <target>_old
SCRATCH_SUFFIX="_next"
OLD_TARGET_SUFFIX="_old"
# MySQL's limit for database names
MAX_DATABASE_NAME_LENGTH=64

# The copy is rebuilt from the dump, never replicated, so its writes stay out of the binary log
NO_BINLOG="SET SESSION sql_log_bin = 0;"

# =====================================================
# Main Copy Functions
# =====================================================

# Display copy confirmation and get user approval
# Args: $1 = total tables, $2 = total size (MB), $3 = estimated minutes
confirm_migration() {
    local total_tables="$1"
    local total_size="$2"
    local estimated_minutes="$3"

    print_header "Copy Confirmation"
    echo ""
    echo -e "Source:       ${CYAN}${SOURCE_DB}${NC}"
    echo -e "Target:       ${CYAN}${TARGET_DB}${NC}"
    echo -e "Connection:   ${CYAN}${CONNECTION_LABEL}${NC}"
    echo -e "Tables:       ${CYAN}${total_tables}${NC} → InnoDB"
    echo -e "Total size:   ${CYAN}${total_size} MB${NC}"
    echo -e "Est. time:    ${CYAN}~${estimated_minutes} minutes${NC}"
    echo ""
    print_info "${CYAN}${SOURCE_DB}${NC} stays untouched"
    print_warn "⚠  ${CYAN}${TARGET_DB}${NC} will be replaced by the new copy"
    echo ""

    if ! confirm "Do you want to proceed with the copy?"; then
        print_info "Copy cancelled"
        return 1
    fi
    return 0
}

# Check the database names before anything connects or changes
# Args: $1 = source database, $2 = target database
validate_database_names() {
    local source_db="$1"
    local target_db="$2"

    validate_database_name "--source" "${source_db}" || return 1
    validate_database_name "--target" "${target_db}" || return 1
    if [ "${source_db}" = "${target_db}" ]; then
        print_error "--source and --target must differ"
        return 1
    fi

    local derived
    for derived in "${target_db}${SCRATCH_SUFFIX}" "${target_db}${OLD_TARGET_SUFFIX}"; do
        if [ "${derived}" = "${source_db}" ]; then
            print_error "--source must not be ${CYAN}${derived}${NC}, the copy uses it for scratch"
            return 1
        fi
        if [ ${#derived} -gt "$MAX_DATABASE_NAME_LENGTH" ]; then
            print_error "--target is too long: ${CYAN}${derived}${NC} exceeds ${MAX_DATABASE_NAME_LENGTH} characters"
            return 1
        fi
    done
}

# Drop and recreate the scratch database, which also clears what a failed run left behind
# Args: $1 = mysql command, $2 = scratch database
prepare_scratch_database() {
    local mysql_cmd="$1"
    local scratch_db="$2"

    print_step "Preparing ${CYAN}${scratch_db}${NC}..."
    ${mysql_cmd} -e "
        ${NO_BINLOG}
        DROP DATABASE IF EXISTS \`${scratch_db}\`;
        CREATE DATABASE \`${scratch_db}\`;
    " 2>&1
}

# Copy one table into the scratch database as InnoDB, values unchanged
# Each mysql call is a new session, so the SETs must share the call with the statements.
# The sql_mode lets zero and partial dates through whatever the server default is.
# Args: $1 = mysql command, $2 = source database, $3 = scratch database, $4 = table name
copy_table() {
    local mysql_cmd="$1"
    local source_db="$2"
    local scratch_db="$3"
    local table="$4"

    ${mysql_cmd} -e "
        ${NO_BINLOG}
        SET SESSION sql_mode = 'NO_ENGINE_SUBSTITUTION';
        CREATE TABLE \`${scratch_db}\`.\`${table}\` LIKE \`${source_db}\`.\`${table}\`;
        ALTER TABLE \`${scratch_db}\`.\`${table}\` ENGINE = InnoDB;
        INSERT INTO \`${scratch_db}\`.\`${table}\` SELECT * FROM \`${source_db}\`.\`${table}\`;
    " 2>&1
}

# Copy every table; a failed table is reported and the copy goes on
# Args: $1 = mysql command, $2 = source database, $3 = scratch database, $4 = table list (newline-separated)
# Returns: 1 if any table failed
copy_tables() {
    local mysql_cmd="$1"
    local source_db="$2"
    local scratch_db="$3"
    local tables="$4"

    local total=$(count_lines "$tables")
    local current=0
    local failed=""
    local output

    while IFS= read -r table; do
        current=$((current + 1))
        local table_info=$(get_table_info "${mysql_cmd}" "${source_db}" "${table}")

        echo ""
        print_separator
        print_info "[${current}/${total}] Copying: ${CYAN}${table}${NC}"
        echo -e "Rows: $(echo "$table_info" | awk '{print $1}') | Size: $(echo "$table_info" | awk '{print $2}') MB"

        local table_start=$(date +%s)
        if output=$(copy_table "${mysql_cmd}" "${source_db}" "${scratch_db}" "${table}"); then
            print_info "✓ Copied in $(($(date +%s) - table_start)) seconds"
        else
            print_error "✗ Failed to copy ${CYAN}${table}${NC}"
            echo "$output" | sed 's/^/    /'
            failed="${failed}${table}\n"
        fi
    done <<< "$tables"

    if [ -n "$failed" ]; then
        echo ""
        print_error "Failed tables:"
        echo -e "$failed" | sed '/^$/d; s/^/  /'
        return 1
    fi
}

# Analyze all copied tables (updates index statistics)
# NO_WRITE_TO_BINLOG keeps ANALYZE out of the binary log like the rest of the copy.
# Args: $1 = mysql command, $2 = database name, $3 = table list (newline-separated)
analyze_copied_tables() {
    local mysql_cmd="$1"
    local db_name="$2"
    local tables="$3"

    print_header "Analyzing Copied Tables"
    print_info "Running ANALYZE TABLE on all copied tables..."
    echo ""

    local total_tables=$(count_lines "$tables")
    local analyze_count=0
    local analyze_failed=0
    local output

    while IFS= read -r table; do
        analyze_count=$((analyze_count + 1))
        echo -e "${CYAN}[${analyze_count}/${total_tables}]${NC} Analyzing ${CYAN}${table}${NC}..."

        if output=$(run_table_maintenance "${mysql_cmd}" "${db_name}" "ANALYZE NO_WRITE_TO_BINLOG" "${table}"); then
            print_info "✓ Analyzed ${CYAN}${table}${NC}"
        else
            print_warn "⚠ Failed to analyze ${CYAN}${table}${NC}"
            echo "$output" | sed 's/^/    /'
            analyze_failed=$((analyze_failed + 1))
        fi
    done <<< "$tables"

    echo ""
    if [ $analyze_failed -eq 0 ]; then
        print_info "✓ All ${total_tables} table(s) analyzed successfully"
    else
        print_warn "⚠ ${analyze_failed} table(s) failed to analyze, $((total_tables - analyze_failed)) succeeded"
        return 1
    fi
}

# Count the rows of one table exactly; TABLE_ROWS is only an estimate for InnoDB
# Args: $1 = mysql command, $2 = database name, $3 = table name
count_rows() {
    local mysql_cmd="$1"
    local db_name="$2"
    local table_name="$3"

    ${mysql_cmd} -s -N -e "SELECT COUNT(*) FROM \`${db_name}\`.\`${table_name}\`;" 2>&1
}

# Args: $1 = mysql command, $2 = source database, $3 = copy database, $4 = source table list (newline-separated)
verify_table_names() {
    local mysql_cmd="$1"
    local source_db="$2"
    local copy_db="$3"
    local source_tables="$4"

    local copy_tables
    copy_tables=$(get_tables_by_engine "${mysql_cmd}" "${copy_db}" "") || {
        print_error "✗ Listing the tables of ${CYAN}${copy_db}${NC} failed: ${copy_tables}"
        return 1
    }
    source_tables=$(echo "$source_tables" | sort)
    copy_tables=$(echo "$copy_tables" | sort)

    if [ "$source_tables" != "$copy_tables" ]; then
        print_error "✗ Tables differ between ${CYAN}${source_db}${NC} and ${CYAN}${copy_db}${NC}:"
        comm -23 <(echo "$source_tables") <(echo "$copy_tables") | sed "s/^/  only in ${source_db}: /"
        comm -13 <(echo "$source_tables") <(echo "$copy_tables") | sed "s/^/  only in ${copy_db}: /"
        return 1
    fi
    print_info "✓ Same $(count_lines "$source_tables") tables"
}

# Args: $1 = mysql command, $2 = copy database
verify_engines() {
    local mysql_cmd="$1"
    local copy_db="$2"

    local not_innodb
    not_innodb=$(${mysql_cmd} -s -N -e "
        SELECT TABLE_NAME, ENGINE
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = '${copy_db}'
        AND TABLE_TYPE = 'BASE TABLE'
        AND ENGINE <> 'InnoDB'
        ORDER BY TABLE_NAME;
    " 2>&1) || {
        print_error "✗ Listing the engines of ${CYAN}${copy_db}${NC} failed: ${not_innodb}"
        return 1
    }
    if [ -n "$not_innodb" ]; then
        print_error "✗ Tables not InnoDB in ${CYAN}${copy_db}${NC}:"
        echo "$not_innodb" | sed 's/^/  /'
        return 1
    fi
    print_info "✓ All tables InnoDB"
}

# Args: $1 = mysql command, $2 = source database, $3 = copy database, $4 = table list (newline-separated)
verify_row_counts() {
    local mysql_cmd="$1"
    local source_db="$2"
    local copy_db="$3"
    local tables="$4"

    local failed=0
    local source_count copy_count
    while IFS= read -r table; do
        source_count=$(count_rows "${mysql_cmd}" "${source_db}" "${table}") || {
            print_error "✗ Counting the rows of ${CYAN}${table}${NC} in ${CYAN}${source_db}${NC} failed: ${source_count}"
            failed=1
            continue
        }
        copy_count=$(count_rows "${mysql_cmd}" "${copy_db}" "${table}") || {
            print_error "✗ Counting the rows of ${CYAN}${table}${NC} in ${CYAN}${copy_db}${NC} failed: ${copy_count}"
            failed=1
            continue
        }
        if [ "$source_count" != "$copy_count" ]; then
            print_error "✗ ${CYAN}${table}${NC}: ${source_count} rows in ${CYAN}${source_db}${NC}, ${copy_count} in ${CYAN}${copy_db}${NC}"
            failed=1
        fi
    done <<< "$tables"

    [ $failed -eq 0 ] && print_info "✓ Row counts match"
    return $failed
}

# Compare the number of zero and partial dates per date, datetime and timestamp column
# Args: $1 = mysql command, $2 = source database, $3 = copy database, $4 = table list (newline-separated)
verify_zero_dates() {
    local mysql_cmd="$1"
    local source_db="$2"
    local copy_db="$3"
    local tables="$4"

    local failed=0
    local columns source_count copy_count
    while IFS= read -r table; do
        columns=$(get_date_columns "${mysql_cmd}" "${source_db}" "${table}") || {
            print_error "✗ Listing the date columns of ${CYAN}${table}${NC} failed: ${columns}"
            failed=1
            continue
        }
        [ -z "$columns" ] && continue
        while IFS= read -r column; do
            source_count=$(count_zero_dates "${mysql_cmd}" "${source_db}" "${table}" "${column}") || {
                print_error "✗ Counting the zero dates of ${CYAN}${table}.${column}${NC} in ${CYAN}${source_db}${NC} failed: ${source_count}"
                failed=1
                continue
            }
            copy_count=$(count_zero_dates "${mysql_cmd}" "${copy_db}" "${table}" "${column}") || {
                print_error "✗ Counting the zero dates of ${CYAN}${table}.${column}${NC} in ${CYAN}${copy_db}${NC} failed: ${copy_count}"
                failed=1
                continue
            }
            if [ "$source_count" != "$copy_count" ]; then
                print_error "✗ ${CYAN}${table}.${column}${NC}: ${source_count} zero or partial dates in ${CYAN}${source_db}${NC}, ${copy_count} in ${CYAN}${copy_db}${NC}"
                failed=1
            fi
        done <<< "$columns"
    done <<< "$tables"

    [ $failed -eq 0 ] && print_info "✓ Zero and partial date counts match"
    return $failed
}

# Spot check: the 2025-11-15 dump has 346,049 pubs with an unknown day.
# None means the source already went through a date rewrite.
# Args: $1 = mysql command, $2 = copy database
verify_partial_dates_kept() {
    local mysql_cmd="$1"
    local copy_db="$2"

    local partial
    partial=$(${mysql_cmd} -s -N -e "
        SELECT COUNT(*) FROM \`${copy_db}\`.pubs WHERE CAST(pub_year AS CHAR) LIKE '%-00';
    " 2>&1) || {
        print_error "✗ Counting the partial dates of ${CYAN}${copy_db}.pubs${NC} failed: ${partial}"
        return 1
    }
    if [ "$partial" -eq 0 ]; then
        print_error "✗ ${CYAN}${copy_db}.pubs.pub_year${NC} has no partial date (YYYY-MM-00); the source looks rewritten"
        return 1
    fi
    print_info "✓ ${CYAN}${copy_db}.pubs.pub_year${NC} keeps ${partial} partial dates"
}

# Compare the copy with its source; the checks after the table names need the same tables
# Args: $1 = mysql command, $2 = source database, $3 = copy database, $4 = source table list (newline-separated)
# Returns: 1 if any check fails
verify_copy() {
    local mysql_cmd="$1"
    local source_db="$2"
    local copy_db="$3"
    local tables="$4"

    print_header "Verifying ${copy_db}"
    verify_table_names "${mysql_cmd}" "${source_db}" "${copy_db}" "${tables}" || return 1

    local failed=0
    verify_engines "${mysql_cmd}" "${copy_db}" || failed=1
    verify_row_counts "${mysql_cmd}" "${source_db}" "${copy_db}" "${tables}" || failed=1
    verify_zero_dates "${mysql_cmd}" "${source_db}" "${copy_db}" "${tables}" || failed=1
    verify_partial_dates_kept "${mysql_cmd}" "${copy_db}" || failed=1
    return $failed
}

# Move the scratch tables into the target with one atomic RENAME TABLE, then drop the helper databases
# The target's own tables pass through the old-target database, so the target ends up with exactly the scratch tables.
# The drops are a second call; one call would not show whether the RENAME had succeeded when it failed.
# Args: $1 = mysql command, $2 = scratch database, $3 = target database, $4 = old-target database
swap_into_target() {
    local mysql_cmd="$1"
    local scratch_db="$2"
    local target_db="$3"
    local old_target_db="$4"

    local target_existed
    target_existed=$(${mysql_cmd} -s -N -e "
        SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '${target_db}';
    " 2>&1) || {
        print_error "Failed to move the copy into ${CYAN}${target_db}${NC}: ${target_existed}"
        return 1
    }
    local current_tables=""
    if [ "$target_existed" = "1" ]; then
        current_tables=$(get_tables_by_engine "${mysql_cmd}" "${target_db}" "") || {
            print_error "Failed to move the copy into ${CYAN}${target_db}${NC}: ${current_tables}"
            return 1
        }
    fi
    local scratch_tables
    scratch_tables=$(get_tables_by_engine "${mysql_cmd}" "${scratch_db}" "") || {
        print_error "Failed to move the copy into ${CYAN}${target_db}${NC}: ${scratch_tables}"
        return 1
    }

    local renames=""
    local table
    while IFS= read -r table; do
        [ -n "$table" ] && renames="${renames}, \`${target_db}\`.\`${table}\` TO \`${old_target_db}\`.\`${table}\`"
    done <<< "$current_tables"
    while IFS= read -r table; do
        renames="${renames}, \`${scratch_db}\`.\`${table}\` TO \`${target_db}\`.\`${table}\`"
    done <<< "$scratch_tables"

    local output
    if ! output=$(${mysql_cmd} -e "
        ${NO_BINLOG}
        DROP DATABASE IF EXISTS \`${old_target_db}\`;
        CREATE DATABASE \`${old_target_db}\`;
        CREATE DATABASE IF NOT EXISTS \`${target_db}\`;
        RENAME TABLE ${renames#, };
    " 2>&1); then
        print_error "Failed to move the copy into ${CYAN}${target_db}${NC}: ${output}"
        # The failed RENAME moved nothing, so the old-target database is empty
        # and a target this call created is empty too, which would pass for a copy
        local cleanup="DROP DATABASE IF EXISTS \`${old_target_db}\`;"
        [ "$target_existed" = "0" ] && cleanup="${cleanup} DROP DATABASE IF EXISTS \`${target_db}\`;"
        output=$(${mysql_cmd} -e "${NO_BINLOG} ${cleanup}" 2>&1) ||
            print_error "Cleaning up after the failed move failed: ${output}"
        return 1
    fi

    output=$(${mysql_cmd} -e "
        ${NO_BINLOG}
        DROP DATABASE \`${old_target_db}\`;
        DROP DATABASE \`${scratch_db}\`;
    " 2>&1) || {
        print_error "The copy is in ${CYAN}${target_db}${NC}, but dropping ${CYAN}${old_target_db}${NC} and ${CYAN}${scratch_db}${NC} failed: ${output}"
        return 1
    }
}

# Show final table sizes and space difference
# Args: $1 = mysql command, $2 = database name, $3 = table list (newline-separated), $4 = original total size
show_final_sizes() {
    local mysql_cmd="$1"
    local db_name="$2"
    local tables="$3"
    local original_size="$4"

    print_header "Final Table Sizes"
    echo ""
    print_step "Individual table sizes:"
    display_detailed_sizes "${mysql_cmd}" "${db_name}" "$tables"

    local final_size=$(get_total_size "${mysql_cmd}" "${db_name}" "")

    echo ""
    print_info "Total size of copied tables: ${CYAN}${final_size} MB${NC}"

    # Show space difference
    display_space_difference "$original_size" "$final_size"
}

# =====================================================
# Main Script
# =====================================================

main() {
    parse_connection_args "$@" || exit 1
    validate_database_names "${SOURCE_DB}" "${TARGET_DB}" || exit 1
    SCRATCH_DB="${TARGET_DB}${SCRATCH_SUFFIX}"
    OLD_TARGET_DB="${TARGET_DB}${OLD_TARGET_SUFFIX}"
    connect_mysql || exit 1

    echo ""
    print_header "Discovering Source Tables"

    SOURCE_TABLES=$(get_tables_by_engine "${MYSQL_CMD}" "${SOURCE_DB}" "") || {
        print_error "Listing the tables of ${CYAN}${SOURCE_DB}${NC} failed: ${SOURCE_TABLES}"
        exit 1
    }
    if [ -z "$SOURCE_TABLES" ]; then
        print_error "Source database ${CYAN}${SOURCE_DB}${NC} has no tables"
        exit 1
    fi
    TOTAL_TABLES=$(count_lines "$SOURCE_TABLES")
    print_info "Found ${CYAN}${TOTAL_TABLES}${NC} tables in ${CYAN}${SOURCE_DB}${NC}"
    echo ""

    print_step "Table details (sorted by size):"
    display_table_details "${MYSQL_CMD}" "${SOURCE_DB}" ""

    TOTAL_SIZE=$(get_total_size "${MYSQL_CMD}" "${SOURCE_DB}" "")
    print_info "Total size to copy: ${CYAN}${TOTAL_SIZE} MB${NC}"

    ESTIMATED_MINUTES=$(estimate_migration_time "${TOTAL_SIZE}")
    print_info "Estimated copy time: ${CYAN}~${ESTIMATED_MINUTES} minutes${NC}"
    echo ""

    confirm_migration "${TOTAL_TABLES}" "${TOTAL_SIZE}" "${ESTIMATED_MINUTES}" || exit 0

    echo ""
    print_header "Copying Tables"
    START_TIME=$(date +%s)

    prepare_scratch_database "${MYSQL_CMD}" "${SCRATCH_DB}" || {
        print_error "Failed to prepare ${CYAN}${SCRATCH_DB}${NC}"
        exit 1
    }
    copy_tables "${MYSQL_CMD}" "${SOURCE_DB}" "${SCRATCH_DB}" "${SOURCE_TABLES}" || exit 1

    echo ""
    analyze_copied_tables "${MYSQL_CMD}" "${SCRATCH_DB}" "${SOURCE_TABLES}" || exit 1

    echo ""
    verify_copy "${MYSQL_CMD}" "${SOURCE_DB}" "${SCRATCH_DB}" "${SOURCE_TABLES}" || exit 1

    echo ""
    print_header "Replacing ${TARGET_DB}"
    swap_into_target "${MYSQL_CMD}" "${SCRATCH_DB}" "${TARGET_DB}" "${OLD_TARGET_DB}" || exit 1
    print_info "✓ ${CYAN}${TARGET_DB}${NC} holds the new copy"
    print_info "Total time: ${CYAN}$(format_duration $(($(date +%s) - START_TIME)))${NC}"

    echo ""
    show_final_sizes "${MYSQL_CMD}" "${TARGET_DB}" "${SOURCE_TABLES}" "${TOTAL_SIZE}"

    echo ""
    print_info "Copy completed at: ${CYAN}$(date)${NC}"
    print_info "✓ Done!"
    echo ""
}

# Tests source this file to call single functions
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
