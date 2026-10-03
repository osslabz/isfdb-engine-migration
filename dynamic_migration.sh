#!/bin/bash
# =====================================================
# ISFDB Dynamic MyISAM to InnoDB Migration Script v2
# =====================================================
# Refactored version using mysql_innodb_lib.sh

# Source the library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/mysql_innodb_lib.sh"

# Configuration
DB_NAME="isfdb"

# =====================================================
# Main Migration Functions
# =====================================================

# Display migration confirmation and get user approval
# Args: $1 = total tables, $2 = total size (MB), $3 = estimated minutes
confirm_migration() {
    local total_tables="$1"
    local total_size="$2"
    local estimated_minutes="$3"

    print_header "Migration Confirmation"
    echo ""
    echo -e "Database:     ${CYAN}${DB_NAME}${NC}"
    echo -e "Connection:   ${CYAN}${CONNECTION_LABEL}${NC}"
    echo -e "Tables:       ${CYAN}${total_tables}${NC} MyISAM → InnoDB"
    echo -e "Total size:   ${CYAN}${total_size} MB${NC}"
    echo -e "Est. time:    ${CYAN}~${estimated_minutes} minutes${NC}"
    echo ""
    print_warn "⚠  The database will be locked during conversion"
    print_warn "⚠  Make sure you have a backup before proceeding"
    echo ""

    if ! confirm "Do you want to proceed with migration?"; then
        print_info "Migration cancelled"
        return 1
    fi
    return 0
}

# Convert a single table from MyISAM to InnoDB
# Args: $1 = mysql command, $2 = database name, $3 = table name, $4 = current count, $5 = total count, $6 = mysql version
# Returns: 0 on success, 1 on failure
convert_table() {
    local mysql_cmd="$1"
    local db_name="$2"
    local table="$3"
    local current="$4"
    local total="$5"
    local mysql_version="$6"

    # Get table info
    local table_info=$(get_table_info "${mysql_cmd}" "${db_name}" "${table}")
    local table_rows=$(echo "$table_info" | awk '{print $1}')
    local table_size=$(echo "$table_info" | awk '{print $2}')

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    print_info "[${current}/${total}] Converting: ${CYAN}${table}${NC}"
    echo -e "Rows: ${table_rows} | Size: ${table_size} MB"


    if ! check_and_fix_dates "${mysql_cmd}" "${db_name}" "${table}"; then
        print_warn "⚠ Date fixing encountered issues but continuing..."
    fi
    echo ""

    # Convert table
    print_step "Converting to InnoDB..."
    local table_start=$(date +%s)

    if convert_to_innodb "${mysql_cmd}" "${db_name}" "${table}"; then
        local table_end=$(date +%s)
        local table_duration=$((table_end - table_start))
        print_info "✓ Converted in ${table_duration} seconds"

        # Verify conversion
        local new_engine=$(get_table_engine "${mysql_cmd}" "${db_name}" "${table}")

        if [ "$new_engine" = "InnoDB" ]; then
            print_info "✓ Verified: ${table} is now ${GREEN}InnoDB${NC}"


        else
            print_warn "⚠ Engine is ${new_engine}, not InnoDB"
            return 1
        fi
    else
        print_error "✗ Failed to convert ${table}"
        return 1
    fi

    return 0
}

# Analyze all converted tables (updates index statistics)
# Args: $1 = mysql command, $2 = database name, $3 = table list (newline-separated)
analyze_converted_tables() {
    local mysql_cmd="$1"
    local db_name="$2"
    local tables="$3"

    print_header "Analyzing Converted Tables"
    print_info "Running ANALYZE TABLE on all converted InnoDB tables..."
    echo ""

    local total_tables=$(echo "$tables" | wc -l)
    local analyze_count=0
    local analyze_failed=0

    while IFS= read -r table; do
        analyze_count=$((analyze_count + 1))
        echo -e "${CYAN}[${analyze_count}/${total_tables}]${NC} Analyzing ${CYAN}${table}${NC}..."

        if analyze_table "${mysql_cmd}" "${db_name}" "${table}"; then
            print_info "✓ Analyzed ${CYAN}${table}${NC}"
        else
            print_warn "⚠ Failed to analyze ${CYAN}${table}${NC}"
            analyze_failed=$((analyze_failed + 1))
        fi
    done <<< "$tables"

    echo ""
    if [ $analyze_failed -eq 0 ]; then
        print_info "✓ All ${total_tables} table(s) analyzed successfully"
    else
        print_warn "⚠ ${analyze_failed} table(s) failed to analyze, $((total_tables - analyze_failed)) succeeded"
    fi
}

# Warm up InnoDB buffer pool by loading table data and indexes
# Args: $1 = mysql command, $2 = database name, $3 = table list (newline-separated)
warmup_buffer_pool() {
    local mysql_cmd="$1"
    local db_name="$2"
    local tables="$3"

    print_header "Warming Up InnoDB Buffer Pool"
    print_info "Loading table data and indexes into memory..."
    print_warn "Note: This may take some time for large tables"
    echo ""

    local total_tables=$(echo "$tables" | wc -l)
    local current_table=0
    local success_count=0
    local failed_count=0
    local total_queries=0
    local failed_queries=0

    while IFS= read -r table; do
        current_table=$((current_table + 1))
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN}[${current_table}/${total_tables}]${NC} Warming up ${CYAN}${table}${NC}"
        echo ""

        local table_success=1

        # Warm up table data (full table scan)
        print_step "Loading table data..."
        local result=$(warmup_table_data "${mysql_cmd}" "${db_name}" "${table}")
        local duration=$(echo "$result" | cut -d: -f1)
        local precision=$(echo "$result" | cut -d: -f2)
        local exit_code=$(echo "$result" | cut -d: -f3)

        total_queries=$((total_queries + 1))

        if [ "$exit_code" -eq 0 ]; then
            local formatted_time=$(format_duration_detailed "$duration" "$precision")
            echo -e "  ${GREEN}✓${NC} Table data loaded (${formatted_time})"
        else
            echo -e "  ${YELLOW}⚠${NC} Failed to load table data"
            failed_queries=$((failed_queries + 1))
            table_success=0
        fi

        # Warm up indexes
        print_step "Loading indexes..."
        local indexes=$(get_regular_indexes "${mysql_cmd}" "${db_name}" "${table}")

        if [ -z "$indexes" ]; then
            echo -e "  ${CYAN}→${NC} No indexes to warm up"
        else
            local index_count=$(echo "$indexes" | wc -l)
            local current_index=0

            while IFS=: read -r index_name columns; do
                current_index=$((current_index + 1))
                total_queries=$((total_queries + 1))

                result=$(warmup_index "${mysql_cmd}" "${db_name}" "${table}" "${index_name}" "${columns}")
                duration=$(echo "$result" | cut -d: -f1)
                precision=$(echo "$result" | cut -d: -f2)
                exit_code=$(echo "$result" | cut -d: -f3)

                if [ "$exit_code" -eq 0 ]; then
                    formatted_time=$(format_duration_detailed "$duration" "$precision")
                    echo -e "  ${GREEN}✓${NC} Index ${CYAN}${index_name}${NC} loaded (${formatted_time})"
                else
                    echo -e "  ${YELLOW}⚠${NC} Index ${CYAN}${index_name}${NC} failed"
                    failed_queries=$((failed_queries + 1))
                    table_success=0
                fi
            done <<< "$indexes"
        fi

        echo ""

        if [ "$table_success" -eq 1 ]; then
            success_count=$((success_count + 1))
        else
            failed_count=$((failed_count + 1))
        fi

    done <<< "$tables"

    # Summary
    print_separator
    echo ""
    if [ $failed_count -eq 0 ]; then
        print_info "✓ All ${total_tables} table(s) warmed up successfully"
        print_info "Total queries executed: ${CYAN}${total_queries}${NC}"
    else
        print_warn "⚠ ${failed_count} table(s) had failures, ${success_count} succeeded"
        print_info "Successful queries: ${CYAN}$((total_queries - failed_queries))${NC}/${total_queries}"
    fi
    echo ""
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

    # Build table name list for query
    local table_list=$(echo "$tables" | tr '\n' ',' | sed 's/,$//' | sed "s/[^,]*/'&'/g")

    ${mysql_cmd} -D "${db_name}" -t -e "
        SELECT
            TABLE_NAME,
            LPAD(FORMAT(TABLE_ROWS, 0), 15, ' ') AS \`ROWS\`,
            LPAD(ROUND((DATA_LENGTH) / 1024 / 1024, 2), 10, ' ') AS DATA_MB,
            LPAD(ROUND((INDEX_LENGTH) / 1024 / 1024, 2), 10, ' ') AS INDEX_MB,
            LPAD(ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2), 10, ' ') AS TOTAL_MB
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = '${db_name}'
        AND TABLE_NAME IN (${table_list})
        ORDER BY (DATA_LENGTH + INDEX_LENGTH) DESC;
    "

    local final_size=$(${mysql_cmd} -D "${db_name}" -s -N -e "
        SELECT ROUND(SUM(DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2)
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = '${db_name}'
        AND TABLE_NAME IN (${table_list});
    ")

    echo ""
    print_info "Total size of converted tables: ${CYAN}${final_size} MB${NC}"

    # Show space difference
    display_space_difference "$original_size" "$final_size"
}

# Verify migration results
# Args: $1 = mysql command, $2 = database name
verify_migration() {
    local mysql_cmd="$1"
    local db_name="$2"

    print_header "Verification"

    local remaining_myisam=$(${mysql_cmd} -D "${db_name}" -s -N -e "
        SELECT COUNT(*)
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = '${db_name}'
        AND ENGINE = 'MyISAM';
    ")

    if [ "$remaining_myisam" -eq 0 ]; then
        print_info "✓ No MyISAM tables remaining"
    else
        print_warn "⚠ ${remaining_myisam} MyISAM tables still exist"
    fi

    echo ""
    print_step "Final engine distribution:"
    display_engine_distribution "${mysql_cmd}" "${db_name}"
}

# =====================================================
# Main Script
# =====================================================

main() {
    parse_connection_args "$@" || exit 1
    connect_mysql || exit 1

    echo ""

    # Discover MyISAM tables
    print_header "Discovering MyISAM Tables"

    MYISAM_TABLES=$(get_tables_by_engine "${MYSQL_CMD}" "${DB_NAME}" "MyISAM")
    MIGRATION_NEEDED=0

    if [ -z "$MYISAM_TABLES" ]; then
        print_info "✓ No MyISAM tables found"
        echo ""

        # Get existing InnoDB tables for optimization/warmup
        print_header "Existing InnoDB Tables"
        INNODB_TABLES=$(get_tables_by_engine "${MYSQL_CMD}" "${DB_NAME}" "InnoDB")

        if [ -z "$INNODB_TABLES" ]; then
            print_warn "No InnoDB tables found in database"
            exit 0
        fi

        TOTAL_TABLES=$(echo "$INNODB_TABLES" | wc -l)
        print_info "Found ${CYAN}${TOTAL_TABLES}${NC} InnoDB tables"
        echo ""

        # Display table details
        print_step "Table details (sorted by size):"
        display_table_details "${MYSQL_CMD}" "${DB_NAME}" "InnoDB"

        TOTAL_SIZE=$(get_total_size "${MYSQL_CMD}" "${DB_NAME}" "InnoDB")
        print_info "Total size: ${CYAN}${TOTAL_SIZE} MB${NC}"
        echo ""

        # Ask user what they want to do
        print_header "Available Operations"
        echo ""
        confirm "Would you like to analyze existing InnoDB tables?" && RUN_ANALYZE="yes"
        confirm "Would you like to warm up the buffer pool?" && RUN_WARMUP="yes"
        echo ""

        if [ "$RUN_ANALYZE" != "yes" ] && [ "$RUN_WARMUP" != "yes" ]; then
            print_info "No operations selected. Showing current status..."
            echo ""

            # Show engine distribution
            print_header "Database Status"
            display_engine_distribution "${MYSQL_CMD}" "${DB_NAME}"
            echo ""

            # Show buffer pool configuration
            display_innodb_recommendations "${MYSQL_CMD}" "${TOTAL_SIZE}"
            echo ""
            print_info "✓ Done!"
            echo ""
            exit 0
        fi

        # Use InnoDB tables for operations
        TABLES_TO_PROCESS="$INNODB_TABLES"
        MIGRATION_NEEDED=0
    else
        TOTAL_TABLES=$(echo "$MYISAM_TABLES" | wc -l)
        print_info "Found ${CYAN}${TOTAL_TABLES}${NC} MyISAM tables to convert"
        echo ""

        # Display table details
        print_step "Table details (sorted by size):"
        display_table_details "${MYSQL_CMD}" "${DB_NAME}" "MyISAM"

        TOTAL_SIZE=$(get_total_size "${MYSQL_CMD}" "${DB_NAME}" "MyISAM")
        print_info "Total size to migrate: ${CYAN}${TOTAL_SIZE} MB${NC}"

        ESTIMATED_MINUTES=$(estimate_migration_time "${TOTAL_SIZE}")
        print_info "Estimated migration time: ${CYAN}~${ESTIMATED_MINUTES} minutes${NC}"
        echo ""

        # Confirmation
        confirm_migration "${TOTAL_TABLES}" "${TOTAL_SIZE}" "${ESTIMATED_MINUTES}" || exit 0

        # Use MyISAM tables for migration
        TABLES_TO_PROCESS="$MYISAM_TABLES"
        MIGRATION_NEEDED=1
        RUN_ANALYZE="yes"
        RUN_WARMUP="yes"
    fi

    # Start migration (only if MyISAM tables found)
    FAILED_TABLES=""
    if [ "$MIGRATION_NEEDED" -eq 1 ]; then
        echo ""
        print_header "Starting Migration"
        START_TIME=$(date +%s)

        print_step "Disabling foreign key checks..."
        set_foreign_key_checks "${MYSQL_CMD}" "${DB_NAME}" 0

        CURRENT=0

        # Convert each table
        while IFS= read -r TABLE; do
            CURRENT=$((CURRENT + 1))

            if ! convert_table "${MYSQL_CMD}" "${DB_NAME}" "${TABLE}" "${CURRENT}" "${TOTAL_TABLES}" "${MYSQL_VERSION}"; then
                FAILED_TABLES="${FAILED_TABLES}${TABLE}\n"
            fi

        done <<< "$TABLES_TO_PROCESS"

        print_step "Re-enabling foreign key checks..."
        set_foreign_key_checks "${MYSQL_CMD}" "${DB_NAME}" 1

        END_TIME=$(date +%s)
        TOTAL_DURATION=$((END_TIME - START_TIME))
        TOTAL_MINUTES=$((TOTAL_DURATION / 60))
        TOTAL_SECONDS=$((TOTAL_DURATION % 60))

        # Summary
        echo ""
        print_header "Migration Complete"
        echo ""
        print_info "Total time:       ${CYAN}${TOTAL_MINUTES}m ${TOTAL_SECONDS}s${NC}"
        print_info "Tables processed: ${CYAN}${TOTAL_TABLES}${NC}"
        echo ""

        if [ -n "$FAILED_TABLES" ]; then
            print_error "Failed tables:"
            echo -e "$FAILED_TABLES" | sed 's/^/  /'
            echo ""
        else
            print_info "✓ All tables converted successfully!"
        fi

        # Verification
        echo ""
        verify_migration "${MYSQL_CMD}" "${DB_NAME}"
    fi

    # Analyze tables (if requested or after migration)
    if [ "$RUN_ANALYZE" = "yes" ] && [ -z "$FAILED_TABLES" ]; then
        echo ""
        analyze_converted_tables "${MYSQL_CMD}" "${DB_NAME}" "$TABLES_TO_PROCESS"
    fi

    # Warm up buffer pool (if requested or after migration)
    if [ "$RUN_WARMUP" = "yes" ] && [ -z "$FAILED_TABLES" ]; then
        echo ""
        warmup_buffer_pool "${MYSQL_CMD}" "${DB_NAME}" "$TABLES_TO_PROCESS"
    fi

    # Show final table sizes
    if [ "$MIGRATION_NEEDED" -eq 1 ]; then
        # Show sizes for migrated tables
        echo ""
        show_final_sizes "${MYSQL_CMD}" "${DB_NAME}" "$TABLES_TO_PROCESS" "${TOTAL_SIZE}"
    elif [ "$RUN_ANALYZE" = "yes" ] || [ "$RUN_WARMUP" = "yes" ]; then
        # Show sizes for existing InnoDB tables after operations
        echo ""
        print_header "Final Table Sizes"
        echo ""
        display_detailed_sizes "${MYSQL_CMD}" "${DB_NAME}" "$TABLES_TO_PROCESS"
        echo ""
    fi

    # InnoDB configuration analysis
    echo ""
    display_innodb_recommendations "${MYSQL_CMD}" "${TOTAL_SIZE}"

    echo ""
    if [ "$MIGRATION_NEEDED" -eq 1 ]; then
        print_info "Migration completed at: ${CYAN}$(date)${NC}"
    else
        print_info "Operations completed at: ${CYAN}$(date)${NC}"
    fi
    print_info "✓ Done!"
    echo ""

    [ -z "$FAILED_TABLES" ] || exit 1
}

# Run main
main "$@"