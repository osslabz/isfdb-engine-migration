#!/bin/bash
# =====================================================
# InnoDB Table Analysis Script
# =====================================================
#
# This script:
# - Finds all InnoDB tables in a database
# - Analyzes them (updates index statistics)
# - Shows detailed size information
# - Analyzes InnoDB buffer pool configuration
# - Provides recommendations for optimal settings
#
# Usage:
#   ./analyze_innodb.sh [login-path-name]
#
# Examples:
#   ./analyze_innodb.sh              # Uses 'isfdb_local' login-path
#   ./analyze_innodb.sh production   # Uses 'production' login-path
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

DB_NAME="isfdb"
LOGIN_PATH="${1:-isfdb_local}"

# =====================================================
# MAIN SCRIPT
# =====================================================

main() {
    # Check prerequisites
    check_mysql_tools || exit 1

    # Setup authentication
    print_header "MySQL Authentication Setup"
    setup_login_path "${LOGIN_PATH}" || exit 1

    # MySQL command
    MYSQL_CMD="mysql --login-path=${LOGIN_PATH}"

    # Test connection
    test_mysql_connection "${MYSQL_CMD}" || exit 1

    # Discover InnoDB tables
    discover_tables

    # Confirm before proceeding
    read -p "Do you want to analyze these tables? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        print_info "Operation cancelled"
        exit 0
    fi

    # Analyze tables
    analyze_all_tables

    # Display final results
    display_final_results

    # Configuration analysis
    analyze_configuration

    # Display summary
    display_summary
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
    print_step "Current table sizes:"
    display_detailed_sizes "${MYSQL_CMD}" "${DB_NAME}" "$INNODB_TABLES"

    TOTAL_SIZE=$(get_total_size "${MYSQL_CMD}" "${DB_NAME}" "InnoDB")
    echo ""
    print_info "Total database size: ${CYAN}${TOTAL_SIZE} MB${NC}"
    echo ""
}

# =====================================================
# ANALYZE ALL TABLES
# =====================================================

analyze_all_tables() {
    print_header "Analyzing InnoDB Tables"
    print_info "Updating index statistics..."
    echo ""

    START_TIME=$(date +%s)
    local current=0
    ANALYZE_FAILED=0

    while IFS= read -r table; do
        current=$((current + 1))
        echo -e "${CYAN}[${current}/${TOTAL_TABLES}]${NC} Analyzing ${CYAN}${table}${NC}..."

        if analyze_table "${MYSQL_CMD}" "${DB_NAME}" "$table" > /dev/null 2>&1; then
            print_info "✓ Analyzed ${CYAN}${table}${NC}"
        else
            print_warn "⚠ Failed to analyze ${CYAN}${table}${NC}"
            ANALYZE_FAILED=$((ANALYZE_FAILED + 1))
        fi
    done <<< "$INNODB_TABLES"

    END_TIME=$(date +%s)
    TOTAL_DURATION=$((END_TIME - START_TIME))
    ANALYSIS_TIME=$(format_duration "$TOTAL_DURATION")

    echo ""
    if [ $ANALYZE_FAILED -eq 0 ]; then
        print_info "✓ All ${TOTAL_TABLES} table(s) analyzed successfully in ${ANALYSIS_TIME}"
    else
        print_warn "⚠ ${ANALYZE_FAILED} table(s) failed, $((TOTAL_TABLES - ANALYZE_FAILED)) succeeded in ${ANALYSIS_TIME}"
    fi
}

# =====================================================
# DISPLAY FINAL RESULTS
# =====================================================

display_final_results() {
    echo ""
    print_header "Table Sizes"

    echo ""
    print_step "Individual table sizes:"
    display_detailed_sizes "${MYSQL_CMD}" "${DB_NAME}" "$INNODB_TABLES"

    echo ""
    print_info "Total database size: ${CYAN}${TOTAL_SIZE} MB${NC}"
}

# =====================================================
# CONFIGURATION ANALYSIS
# =====================================================

analyze_configuration() {
    echo ""
    print_header "InnoDB Configuration Analysis"
    display_innodb_recommendations "${MYSQL_CMD}" "$TOTAL_SIZE"
}

# =====================================================
# DISPLAY SUMMARY
# =====================================================

display_summary() {
    echo ""
    print_header "Summary"
    echo ""
    print_info "Tables analyzed:      ${CYAN}${TOTAL_TABLES}${NC}"
    print_info "Analysis time:        ${CYAN}${ANALYSIS_TIME}${NC}"
    print_info "Database size:        ${CYAN}${TOTAL_SIZE} MB${NC}"

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
