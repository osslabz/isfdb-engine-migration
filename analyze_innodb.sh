#!/bin/bash
# =====================================================
# InnoDB Table Analysis Script
# =====================================================
#
# This script:
# - Finds all InnoDB tables in a database (default isfdb_innodb)
# - Analyzes them (updates index statistics)
# - Shows detailed size information
#
# Usage:
#   ./analyze_innodb.sh [--yes] [--user NAME] [--defaults-extra-file FILE] [--database DB] [login-path-name]
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
    if ! confirm "Do you want to analyze these tables?"; then
        print_info "Operation cancelled"
        exit 0
    fi

    # Analyze tables
    analyze_all_tables

    # Display final results
    display_final_results

    # Display summary
    display_summary

    [ "$ANALYZE_FAILED" -eq 0 ] || exit 1
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
    local output
    ANALYZE_FAILED=0

    while IFS= read -r table; do
        current=$((current + 1))
        echo -e "${CYAN}[${current}/${TOTAL_TABLES}]${NC} Analyzing ${CYAN}${table}${NC}..."

        if output=$(analyze_table "${MYSQL_CMD}" "${DB_NAME}" "$table"); then
            print_info "✓ Analyzed ${CYAN}${table}${NC}"
        else
            print_warn "⚠ Failed to analyze ${CYAN}${table}${NC}"
            echo "$output" | sed 's/^/    /'
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
# DISPLAY SUMMARY
# =====================================================

display_summary() {
    echo ""
    print_header "Summary"
    echo ""
    print_info "Tables analyzed:      ${CYAN}${TOTAL_TABLES}${NC}"
    print_info "Analysis time:        ${CYAN}${ANALYSIS_TIME}${NC}"
    print_info "Database size:        ${CYAN}${TOTAL_SIZE} MB${NC}"

    echo ""
    print_info "✓ Done!"
    echo ""
}

# =====================================================
# RUN MAIN
# =====================================================

main "$@"
