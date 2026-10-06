#!/bin/bash
# =====================================================
# InnoDB Table Optimization & Analysis Script
# =====================================================
#
# This script:
# - Finds all InnoDB tables in a database (default isfdb_innodb)
# - Optimizes them
# - Shows detailed size information
# - Analyzes InnoDB buffer pool configuration
# - Provides recommendations for optimal settings
#
# Usage:
#   ./optimize_innodb.sh [--yes] [--user NAME] [--defaults-extra-file FILE] [--database DB] [login-path-name]
#
# Examples:
#   ./optimize_innodb.sh              # Uses 'local' login-path
#   ./optimize_innodb.sh production   # Uses 'production' login-path
#
# =====================================================

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the common library
if [ -f "${SCRIPT_DIR}/mysql_innodb_lib.sh" ]; then
    source "${SCRIPT_DIR}/mysql_innodb_lib.sh"
else
    echo "ERROR: Required library mysql_innodb_lib.sh not found in ${SCRIPT_DIR}"
    exit 1
fi

# =====================================================
# CONFIGURATION
# =====================================================

# isfdb stays MyISAM; the InnoDB tables are in the copy
DB_NAME="isfdb_innodb"
OPTION_VARIABLES["--database"]=DB_NAME
SCRIPT_USAGE_OPTIONS="[--database DB]"

# =====================================================
# MAIN SCRIPT
# =====================================================

main() {
    parse_connection_args "$@" || exit 1
    validate_database_name "--database" "${DB_NAME}" || exit 1
    connect_mysql || exit 1

    # Discover InnoDB tables
    discover_tables

    # Confirm before proceeding
    if ! confirm "Do you want to optimize these tables?"; then
        print_info "Operation cancelled"
        exit 0
    fi

    # Optimize tables
    optimize_all_tables

    # Display final results
    display_final_results

    # Configuration analysis
    analyze_configuration

    # Display summary
    display_summary

    [ "$OPTIMIZE_FAILED" -eq 0 ] || exit 1
}

# =====================================================
# DISCOVER TABLES
# =====================================================

discover_tables() {
    print_header "Discovering InnoDB Tables"

    INNODB_TABLES=$(get_tables_by_engine "${MYSQL_CMD}" "${DB_NAME}" "InnoDB")

    if [ $? -ne 0 ]; then
        print_error "Failed to query database: $INNODB_TABLES"
        exit 1
    fi

    if [ -z "$INNODB_TABLES" ]; then
        print_warn "No InnoDB tables found in database '${DB_NAME}'"
        exit 0
    fi

    TOTAL_TABLES=$(echo "$INNODB_TABLES" | wc -l)
    print_info "Found ${CYAN}${TOTAL_TABLES}${NC} InnoDB tables"
    echo ""

    # Show current sizes
    print_step "Current table sizes (before optimization):"
    display_detailed_sizes "${MYSQL_CMD}" "${DB_NAME}" "$INNODB_TABLES"

    TOTAL_SIZE_BEFORE=$(get_total_size "${MYSQL_CMD}" "${DB_NAME}" "InnoDB")
    echo ""
    print_info "Total database size: ${CYAN}${TOTAL_SIZE_BEFORE} MB${NC}"
    echo ""
}

# =====================================================
# OPTIMIZE ALL TABLES
# =====================================================

optimize_all_tables() {
    print_header "Optimizing InnoDB Tables"
    print_info "This may take several minutes for large tables..."
    echo ""

    START_TIME=$(date +%s)
    local current=0
    local output
    OPTIMIZE_FAILED=0

    while IFS= read -r table; do
        current=$((current + 1))
        echo -e "${CYAN}[${current}/${TOTAL_TABLES}]${NC} Optimizing ${CYAN}${table}${NC}..."

        if output=$(optimize_table "${MYSQL_CMD}" "${DB_NAME}" "$table"); then
            print_info "✓ Optimized ${CYAN}${table}${NC}"
        else
            print_warn "⚠ Failed to optimize ${CYAN}${table}${NC}"
            echo "$output" | sed 's/^/    /'
            OPTIMIZE_FAILED=$((OPTIMIZE_FAILED + 1))
        fi
    done <<< "$INNODB_TABLES"

    END_TIME=$(date +%s)
    TOTAL_DURATION=$((END_TIME - START_TIME))
    OPTIMIZATION_TIME=$(format_duration "$TOTAL_DURATION")

    echo ""
    if [ $OPTIMIZE_FAILED -eq 0 ]; then
        print_info "✓ All ${TOTAL_TABLES} table(s) optimized successfully in ${OPTIMIZATION_TIME}"
    else
        print_warn "⚠ ${OPTIMIZE_FAILED} table(s) failed, $((TOTAL_TABLES - OPTIMIZE_FAILED)) succeeded in ${OPTIMIZATION_TIME}"
    fi
}

# =====================================================
# DISPLAY FINAL RESULTS
# =====================================================

display_final_results() {
    echo ""
    print_header "Final Table Sizes"

    echo ""
    print_step "Individual table sizes (after optimization):"
    display_detailed_sizes "${MYSQL_CMD}" "${DB_NAME}" "$INNODB_TABLES"

    TOTAL_SIZE_AFTER=$(get_total_size "${MYSQL_CMD}" "${DB_NAME}" "InnoDB")

    echo ""
    print_info "Total database size: ${CYAN}${TOTAL_SIZE_AFTER} MB${NC}"
    display_space_difference "$TOTAL_SIZE_BEFORE" "$TOTAL_SIZE_AFTER"
}

# =====================================================
# CONFIGURATION ANALYSIS
# =====================================================

analyze_configuration() {
    echo ""
    print_header "InnoDB Configuration Analysis"
    display_innodb_recommendations "${MYSQL_CMD}" "$TOTAL_SIZE_AFTER"
}

# =====================================================
# DISPLAY SUMMARY
# =====================================================

display_summary() {
    echo ""
    print_header "Summary"
    echo ""
    print_info "Tables optimized:     ${CYAN}${TOTAL_TABLES}${NC}"
    print_info "Optimization time:    ${CYAN}${OPTIMIZATION_TIME}${NC}"
    print_info "Final database size:  ${CYAN}${TOTAL_SIZE_AFTER} MB${NC}"

    local total_ram_mb
    total_ram_mb=$(get_system_ram)
    if [ "$total_ram_mb" != "unknown" ]; then
        local buffer_pool_mb
        buffer_pool_mb=$(get_buffer_pool_size "${MYSQL_CMD}")
        local buffer_pool_percent=$((buffer_pool_mb * 100 / total_ram_mb))
        print_info "Buffer pool status:   ${CYAN}${buffer_pool_mb} MB${NC} (${buffer_pool_percent}% of RAM)"
    fi

    echo ""
    print_info "✓ Done!"
    echo ""
}

# =====================================================
# RUN MAIN
# =====================================================

main "$@"