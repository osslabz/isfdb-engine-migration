#!/bin/bash
# Runs the scripts against a throwaway MySQL 9.7 container and checks the results.
# Usage: test/run.sh   (needs docker; publishes no host port)
# Every function named test_* is a test. Each starts from a server that holds only the fixture in isfdb.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="${REPO_DIR}/test/fixture.sql"
FIXTURE_TABLES="authors mw_user_groups pubs submissions titles"
CONTAINER="isfdb-engine-migration-test-$$"
ROOT_PASSWORD="test_root_pwd"
LOG_DIR="$(mktemp -d)"
PASSED=0
FAILED=0
CURRENT_TEST=""

cleanup() {
    docker rm -f "$CONTAINER" > /dev/null 2>&1
    rm -rf "$LOG_DIR"
}
trap cleanup EXIT

# =====================================================
# Server
# =====================================================

start_server() {
    docker run -d --name "$CONTAINER" \
        -e MYSQL_ROOT_PASSWORD="$ROOT_PASSWORD" \
        --tmpfs /var/lib/mysql \
        -v "${REPO_DIR}:/isfdb-engine-migration:ro" \
        mysql:9.7 > /dev/null || exit 1
    local attempt
    for attempt in $(seq 1 90); do
        # The entrypoint's init server listens on port 0; only the final server reports 3306.
        if docker logs "$CONTAINER" 2>&1 | grep 'ready for connections.*port: 3306' > /dev/null; then
            return 0
        fi
        sleep 2
    done
    echo "MySQL did not start" >&2
    exit 1
}

# Run the mysql client as root in the container
# Args: mysql client options
sql() {
    docker exec -i -e MYSQL_PWD="$ROOT_PASSWORD" "$CONTAINER" \
        mysql --user=root --batch --skip-column-names "$@"
}

# Load the fixture into a new database
# Args: $1 = database name
load_fixture_as() {
    sed "s/^CREATE DATABASE isfdb;$/CREATE DATABASE \`$1\`;/; s/^USE isfdb;$/USE \`$1\`;/" "$FIXTURE" | sql
}

# Drop every database and user the tests create, then load the fixture into isfdb
# Databases go in name order: a_refs must go before isfdb_innodb_old, which its foreign key blocks
reset_server() {
    local db
    for db in $(sql -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys') ORDER BY SCHEMA_NAME"); do
        sql -e "DROP DATABASE \`${db}\`"
    done
    sql -e "DROP USER IF EXISTS copier"
    load_fixture_as isfdb
}

# Run a repo script in the container; its output goes to the test's log
# Args: $1 = MySQL user, $2 = password, $3 = script file name, rest = script options
# Returns: the script's exit code
run_script_as() {
    local user="$1"
    local password="$2"
    local script="$3"
    shift 3
    docker exec -e MYSQL_PWD="$password" "$CONTAINER" \
        "/isfdb-engine-migration/${script}" --user "$user" "$@" >> "$(log_file)" 2>&1
}

# Args: options for dynamic_migration.sh
run_migration() {
    run_script_as root "$ROOT_PASSWORD" dynamic_migration.sh --yes "$@"
}

# =====================================================
# State
# =====================================================

# Print "table<TAB>checksum" for every table of a database, by table name
# Args: $1 = database name
checksums() {
    local tables
    tables=$(sql -e "SELECT GROUP_CONCAT(CONCAT('\`', TABLE_NAME, '\`') ORDER BY TABLE_NAME) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$1'")
    if [ "$tables" = "NULL" ]; then
        return 0
    fi
    sql -D "$1" -e "CHECKSUM TABLE ${tables}" | sed "s/^$1\.//"
}

# Print "table<TAB>engine" for every table of a database, by table name
# Args: $1 = database name
engines() {
    sql -e "SELECT TABLE_NAME, ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$1' ORDER BY TABLE_NAME"
}

# Args: $1 = database name
database_exists() {
    [ -n "$(sql -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$1'")" ]
}

# =====================================================
# Assertions
# =====================================================

log_file() { echo "${LOG_DIR}/${CURRENT_TEST}.log"; }
failures_file() { echo "${LOG_DIR}/${CURRENT_TEST}.failures"; }

# The test's log without color codes
log_text() { sed 's/\x1b\[[0-9;]*m//g' "$(log_file)"; }

fail() { echo "$1" >> "$(failures_file)"; }

# Args: $1 = description, $2 = expected, $3 = actual
assert_eq() {
    if [ "$2" != "$3" ]; then
        fail "$1: expected [$2], got [$3]"
    fi
}

assert_database_exists() {
    if ! database_exists "$1"; then
        fail "database $1 is missing"
    fi
}

assert_no_database() {
    if database_exists "$1"; then
        fail "database $1 exists"
    fi
}

assert_log_contains() {
    local text
    text=$(log_text) || { fail "cannot read the output"; return; }
    if ! grep -F -- "$1" <<< "$text" > /dev/null; then
        fail "output lacks [$1]"
    fi
}

assert_log_lacks() {
    local text
    text=$(log_text) || { fail "cannot read the output"; return; }
    if grep -F -- "$1" <<< "$text" > /dev/null; then
        fail "output contains [$1]"
    fi
}

# =====================================================
# Tests: copy
# =====================================================

test_copy_leaves_source_unchanged() {
    local engines_before checksums_before
    engines_before=$(engines isfdb)
    checksums_before=$(checksums isfdb)

    run_migration
    assert_eq "exit code" 0 "$?"
    assert_eq "isfdb engines" "$engines_before" "$(engines isfdb)"
    assert_eq "isfdb checksums" "$checksums_before" "$(checksums isfdb)"
}

test_copy_matches_source() {
    run_migration
    assert_eq "exit code" 0 "$?"
    assert_eq "tables" "$FIXTURE_TABLES" "$(engines isfdb_innodb | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
    assert_eq "engines not InnoDB" "" "$(engines isfdb_innodb | awk -F'\t' '$2 != "InnoDB"')"
    assert_eq "checksums" "$(checksums isfdb)" "$(checksums isfdb_innodb)"
    assert_no_database isfdb_innodb_next
    assert_no_database isfdb_innodb_old
}

test_copy_prints_one_line_per_analyzed_table() {
    run_migration
    assert_eq "exit code" 0 "$?"
    assert_log_contains "[INFO] ✓ Analyzed pubs"
    assert_log_contains "[INFO] ✓ All 5 table(s) analyzed successfully"
    assert_log_lacks "Msg_text"
}

test_analyze_reports_failed_table() {
    sql -e "CREATE DATABASE bad_copy"
    call_function analyze_copied_tables bad_copy nope
    assert_eq "exit code" 1 "$?"
    assert_log_contains "[WARN] ⚠ Failed to analyze nope"
    assert_log_contains "bad_copy.nope	analyze	Error	Table 'bad_copy.nope' doesn't exist"
    assert_log_contains "[WARN] ⚠ 1 table(s) failed to analyze, 0 succeeded"
}

test_copy_keeps_partial_dates() {
    run_migration
    assert_eq "exit code" 0 "$?"
    assert_eq "pubs.pub_year" \
        "$(printf '1\t0000-00-00\n2\t2016-11-00\n3\t1990-00-00\n4\t1990-05-00\n5\t1984-07-01\n6\tNULL')" \
        "$(sql -e "SELECT pub_id, CAST(pub_year AS CHAR) FROM isfdb_innodb.pubs ORDER BY pub_id")"
    assert_eq "titles.title_copyright" \
        "$(printf '1\t1965-00-00\n2\t1969-10-15\n3\t2016-00-00\n4\t0000-00-00\n5\tNULL')" \
        "$(sql -e "SELECT title_id, CAST(title_copyright AS CHAR) FROM isfdb_innodb.titles ORDER BY title_id")"
    assert_eq "authors dates" \
        "$(printf '1\t1920-10-08\t1986-02-11\n2\t1901-00-00\t0000-00-00\n3\tNULL\tNULL')" \
        "$(sql -e "SELECT author_id, CAST(author_birthdate AS CHAR), CAST(author_deathdate AS CHAR) FROM isfdb_innodb.authors ORDER BY author_id")"
    assert_eq "submissions.sub_time" \
        "$(printf '1\t0000-00-00 00:00:00\n2\t2025-11-15 10:20:30')" \
        "$(sql -e "SELECT sub_id, CAST(sub_time AS CHAR) FROM isfdb_innodb.submissions ORDER BY sub_id")"
}

test_copy_keeps_fulltext_index() {
    run_migration
    assert_eq "exit code" 0 "$?"
    assert_eq "FULLTEXT index" "full_text" \
        "$(sql -e "SELECT DISTINCT INDEX_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = 'isfdb_innodb' AND TABLE_NAME = 'titles' AND INDEX_TYPE = 'FULLTEXT'")"
    assert_eq "FULLTEXT match" "2" \
        "$(sql -e "SELECT title_id FROM isfdb_innodb.titles WHERE MATCH(title_title) AGAINST('Messiah')")"
}

test_second_run_replaces_target() {
    run_migration
    assert_eq "first exit code" 0 "$?"
    run_migration
    assert_eq "second exit code" 0 "$?"
    assert_eq "checksums" "$(checksums isfdb)" "$(checksums isfdb_innodb)"
    assert_no_database isfdb_innodb_next
    assert_no_database isfdb_innodb_old
}

test_rerun_drops_stale_scratch() {
    sql -e "CREATE DATABASE isfdb_innodb_next; CREATE TABLE isfdb_innodb_next.leftover (id int) ENGINE = InnoDB"

    run_migration
    assert_eq "exit code" 0 "$?"
    assert_eq "checksums" "$(checksums isfdb)" "$(checksums isfdb_innodb)"
    assert_no_database isfdb_innodb_next
}

test_swap_moves_out_tables_the_copy_lacks() {
    run_migration
    assert_eq "first exit code" 0 "$?"
    sql -e "CREATE TABLE isfdb_innodb.dropped_upstream (id int) ENGINE = InnoDB"

    run_migration
    assert_eq "second exit code" 0 "$?"
    assert_eq "tables" "$FIXTURE_TABLES" "$(engines isfdb_innodb | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
    assert_no_database isfdb_innodb_old
}

test_failed_table_keeps_old_target() {
    run_migration
    assert_eq "first exit code" 0 "$?"
    local target_before
    target_before=$(checksums isfdb_innodb)
    # InnoDB allows at most 1017 columns, MyISAM more
    sql -e "CREATE TABLE isfdb.wide ($(seq -f 'c%g int' -s ', ' 1 1020)) ENGINE = MyISAM"

    run_migration
    assert_eq "second exit code" 1 "$?"
    assert_log_contains "Failed to copy wide"
    assert_log_contains "Too many columns"
    assert_eq "isfdb_innodb checksums" "$target_before" "$(checksums isfdb_innodb)"
    assert_no_database isfdb_innodb_old
    assert_eq "other tables copied after the failure" \
        "$(checksums isfdb | grep -v '^wide')" "$(checksums isfdb_innodb_next | grep -v '^wide')"
}

test_failed_rename_leaves_no_empty_old_database() {
    # A view named like a copied table makes the RENAME fail
    sql -e "CREATE DATABASE isfdb_innodb; CREATE VIEW isfdb_innodb.pubs AS SELECT 1 AS x"

    run_migration
    assert_eq "exit code" 1 "$?"
    assert_log_contains "already exists"
    assert_log_contains "Failed to move the copy into isfdb_innodb"
    assert_no_database isfdb_innodb_old
    assert_database_exists isfdb_innodb_next
    assert_eq "isfdb_innodb tables" "pubs" "$(engines isfdb_innodb | cut -f1)"
}

test_failed_drop_after_rename_reports_the_copy_in_place() {
    run_migration
    assert_eq "first exit code" 0 "$?"
    # A foreign key from another database follows the renamed authors table and blocks dropping isfdb_innodb_old
    sql -e "CREATE DATABASE a_refs;
        CREATE TABLE a_refs.refs (author_id int NOT NULL, FOREIGN KEY (author_id) REFERENCES isfdb_innodb.authors (author_id)) ENGINE = InnoDB"

    run_migration
    assert_eq "second exit code" 1 "$?"
    assert_log_contains "[ERROR] The copy is in isfdb_innodb, but dropping isfdb_innodb_old and isfdb_innodb_next failed: ERROR 3730 (HY000) at line 3: Cannot drop table 'authors' referenced by a foreign key constraint 'refs_ibfk_1' on table 'refs'."
    assert_log_lacks "Failed to move the copy"
    assert_eq "isfdb_innodb checksums" "$(checksums isfdb)" "$(checksums isfdb_innodb)"
    assert_database_exists isfdb_innodb_old
}

test_failed_first_rename_leaves_no_empty_target() {
    # The user may create isfdb_innodb but not move tables into it, so the RENAME fails
    sql -e "CREATE USER copier IDENTIFIED BY 'copier_pwd';
        GRANT SELECT ON isfdb.* TO copier;
        GRANT ALL ON isfdb_innodb_next.* TO copier;
        GRANT ALL ON isfdb_innodb_old.* TO copier;
        GRANT CREATE, DROP ON isfdb_innodb.* TO copier;
        GRANT SESSION_VARIABLES_ADMIN ON *.* TO copier"

    run_script_as copier copier_pwd dynamic_migration.sh --yes
    assert_eq "exit code" 1 "$?"
    assert_log_contains "Failed to move the copy into isfdb_innodb"
    assert_no_database isfdb_innodb
    assert_no_database isfdb_innodb_old
    assert_database_exists isfdb_innodb_next
}

test_mariadb_client_is_not_used() {
    docker exec "$CONTAINER" bash -c \
        'mkdir -p /tmp/mariadb-only && for f in /usr/bin/*; do [ "${f##*/}" = mysql ] || ln -sf "$f" /tmp/mariadb-only/; done && ln -sf /usr/bin/mysql /tmp/mariadb-only/mariadb'
    docker exec -e MYSQL_PWD="$ROOT_PASSWORD" -e PATH=/tmp/mariadb-only "$CONTAINER" \
        /isfdb-engine-migration/dynamic_migration.sh --yes --user root >> "$(log_file)" 2>&1
    assert_eq "exit code" 1 "$?"
    assert_log_contains "mysql client not found!"
    assert_no_database isfdb_innodb_next
    assert_no_database isfdb_innodb
}

test_missing_privilege_changes_nothing() {
    sql -e "CREATE USER copier IDENTIFIED BY 'copier_pwd'; GRANT ALL ON *.* TO copier; REVOKE SYSTEM_VARIABLES_ADMIN, SESSION_VARIABLES_ADMIN, SUPER ON *.* FROM copier"

    run_script_as copier copier_pwd dynamic_migration.sh --yes
    assert_eq "exit code" 1 "$?"
    assert_log_contains "SESSION_VARIABLES_ADMIN"
    assert_no_database isfdb_innodb_next
    assert_no_database isfdb_innodb
}

test_declined_prompt_changes_nothing() {
    printf 'no\n' | docker exec -i -e MYSQL_PWD="$ROOT_PASSWORD" "$CONTAINER" \
        /isfdb-engine-migration/dynamic_migration.sh --user root >> "$(log_file)" 2>&1
    assert_eq "exit code" 0 "$?"
    assert_log_contains "Copy cancelled"
    assert_no_database isfdb_innodb_next
    assert_no_database isfdb_innodb
}

# =====================================================
# Tests: options
# =====================================================

# Databases besides the system ones, by name
user_databases() {
    sql -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys') ORDER BY SCHEMA_NAME" | tr '\n' ' ' | sed 's/ $//'
}

test_custom_target() {
    run_migration --source isfdb --target isfdb_copy
    assert_eq "exit code" 0 "$?"
    assert_eq "checksums" "$(checksums isfdb)" "$(checksums isfdb_copy)"
    assert_eq "databases" "isfdb isfdb_copy" "$(user_databases)"
}

test_missing_source_database() {
    run_migration --source nope
    assert_eq "exit code" 1 "$?"
    assert_log_contains "[ERROR] Listing the tables of nope failed: ERROR 1049 (42000): Unknown database 'nope'"
    assert_log_lacks "has no tables"
    assert_eq "databases" "isfdb" "$(user_databases)"
}

test_empty_source_database() {
    sql -e "CREATE DATABASE empty_source"
    run_migration --source empty_source
    assert_eq "exit code" 1 "$?"
    assert_log_contains "[ERROR] Source database empty_source has no tables"
    assert_log_lacks "Listing the tables"
    assert_eq "databases" "empty_source isfdb" "$(user_databases)"
}

test_source_equals_target() {
    local checksums_before
    checksums_before=$(checksums isfdb)
    run_migration --source isfdb --target isfdb
    assert_eq "exit code" 1 "$?"
    assert_log_contains "--source and --target must differ"
    assert_eq "isfdb checksums" "$checksums_before" "$(checksums isfdb)"
    assert_eq "databases" "isfdb" "$(user_databases)"
}

test_invalid_database_name() {
    run_migration --target 'isfdb-innodb'
    assert_eq "exit code" 1 "$?"
    assert_log_contains "--target must match [A-Za-z0-9_]+, got 'isfdb-innodb'"
    assert_eq "databases" "isfdb" "$(user_databases)"
}

# Args: $1 = length
name_of_length() {
    printf 'a%.0s' $(seq 1 "$1")
}

# <target>_next is the longest derived name, so a 59-character target makes it exactly 64
test_derived_name_at_length_limit() {
    local target
    target=$(name_of_length 59)
    run_migration --target "$target"
    assert_eq "exit code" 0 "$?"
    assert_eq "checksums" "$(checksums isfdb)" "$(checksums "$target")"
    assert_eq "databases" "${target} isfdb" "$(user_databases)"
}

test_derived_name_over_length_limit() {
    local target
    target=$(name_of_length 60)
    run_migration --target "$target"
    assert_eq "exit code" 1 "$?"
    assert_log_contains "--target is too long: ${target}_next exceeds 64 characters"
    assert_eq "databases" "isfdb" "$(user_databases)"
}

test_scratch_name_equals_source() {
    run_migration --source isfdb_next --target isfdb
    assert_eq "exit code" 1 "$?"
    assert_log_contains "--source must not be isfdb_next, the copy uses it for scratch"
    assert_eq "databases" "isfdb" "$(user_databases)"
}

test_old_target_name_equals_source() {
    run_migration --source isfdb_old --target isfdb
    assert_eq "exit code" 1 "$?"
    assert_log_contains "--source must not be isfdb_old, the copy uses it for scratch"
    assert_eq "databases" "isfdb" "$(user_databases)"
}

test_option_without_value() {
    run_migration --target
    assert_eq "exit code" 1 "$?"
    assert_log_contains "Option --target needs a value"
    assert_eq "databases" "isfdb" "$(user_databases)"
}

test_unknown_option() {
    run_migration --database isfdb
    assert_eq "exit code" 1 "$?"
    assert_log_contains "Unknown option: --database"
    assert_log_contains "[--source DB] [--target DB]"
}

# =====================================================
# Tests: maintenance helpers
# =====================================================

test_analyze_fails_without_database() {
    run_script_as root "$ROOT_PASSWORD" analyze_innodb.sh --yes
    assert_eq "exit code" 1 "$?"
    assert_log_contains "Failed to query database: ERROR 1049 (42000): Unknown database 'isfdb_innodb'"
    assert_log_lacks "No InnoDB tables found"
}

test_optimize_fails_without_database() {
    run_script_as root "$ROOT_PASSWORD" optimize_innodb.sh --yes
    assert_eq "exit code" 1 "$?"
    assert_log_contains "Failed to query database: ERROR 1049 (42000): Unknown database 'isfdb_innodb'"
    assert_log_lacks "No InnoDB tables found"
}

test_analyze_defaults_to_innodb_copy() {
    run_migration
    assert_eq "migration exit code" 0 "$?"
    run_script_as root "$ROOT_PASSWORD" analyze_innodb.sh --yes
    assert_eq "exit code" 0 "$?"
    assert_log_contains "Found 5 InnoDB tables"
}

test_analyze_takes_database() {
    run_script_as root "$ROOT_PASSWORD" analyze_innodb.sh --yes --database isfdb
    assert_eq "exit code" 0 "$?"
    assert_log_contains "Found 1 InnoDB tables"
}

test_optimize_defaults_to_innodb_copy() {
    run_migration
    assert_eq "migration exit code" 0 "$?"
    run_script_as root "$ROOT_PASSWORD" optimize_innodb.sh --yes
    assert_eq "exit code" 0 "$?"
    assert_log_contains "Found 5 InnoDB tables"
}

test_optimize_takes_database() {
    run_script_as root "$ROOT_PASSWORD" optimize_innodb.sh --yes --database isfdb
    assert_eq "exit code" 0 "$?"
    assert_log_contains "Found 1 InnoDB tables"
}

test_helpers_print_no_buffer_pool_advice() {
    run_migration
    assert_eq "migration exit code" 0 "$?"
    : > "$(log_file)"
    run_script_as root "$ROOT_PASSWORD" analyze_innodb.sh --yes
    assert_eq "analyze exit code" 0 "$?"
    run_script_as root "$ROOT_PASSWORD" optimize_innodb.sh --yes
    assert_eq "optimize exit code" 0 "$?"
    assert_log_lacks "Buffer pool"
    assert_log_lacks "InnoDB Configuration Analysis"
}

test_analyze_rejects_invalid_database() {
    run_script_as root "$ROOT_PASSWORD" analyze_innodb.sh --yes --database 'bad-name'
    assert_eq "exit code" 1 "$?"
    assert_log_contains "--database must match [A-Za-z0-9_]+, got 'bad-name'"
}

test_optimize_rejects_invalid_database() {
    run_script_as root "$ROOT_PASSWORD" optimize_innodb.sh --yes --database 'bad-name'
    assert_eq "exit code" 1 "$?"
    assert_log_contains "--database must match [A-Za-z0-9_]+, got 'bad-name'"
}

# =====================================================
# Tests: verification
# =====================================================

# Call a function of the sourced dynamic_migration.sh; output goes to the test's log
# Args: $1 = function, rest = its arguments after the mysql command
# Returns: the function's exit code
call_function() {
    local function_name="$1"
    shift
    docker exec -e MYSQL_PWD="$ROOT_PASSWORD" "$CONTAINER" bash -c \
        'source /isfdb-engine-migration/dynamic_migration.sh && "$@"' \
        _ "$function_name" "mysql --user=root" "$@" >> "$(log_file)" 2>&1
}

# Args: $1 = database name
base_tables() {
    sql -e "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$1' AND TABLE_TYPE = 'BASE TABLE'"
}

# Call verify_copy on the base tables of the source
# Args: $1 = source database, $2 = copy database
# Returns: verify_copy's exit code
run_verify() {
    call_function verify_copy "$1" "$2" "$(base_tables "$1")"
}

test_rewritten_source_keeps_old_target() {
    run_migration
    assert_eq "first exit code" 0 "$?"
    local target_before
    target_before=$(checksums isfdb_innodb)
    load_fixture_as isfdb_rewritten
    sql -e "UPDATE isfdb_rewritten.pubs SET pub_year = NULL WHERE CAST(pub_year AS CHAR) LIKE '%-00'"

    run_migration --source isfdb_rewritten
    assert_eq "second exit code" 1 "$?"
    assert_log_contains "isfdb_innodb_next.pubs.pub_year has no partial date"
    assert_eq "isfdb_innodb checksums" "$target_before" "$(checksums isfdb_innodb)"
    assert_no_database isfdb_innodb_old
}

test_verify_accepts_exact_copy() {
    run_migration --target good_copy
    assert_eq "migration exit code" 0 "$?"
    run_verify isfdb good_copy
    assert_eq "exit code" 0 "$?"
    assert_log_contains "good_copy.pubs.pub_year keeps 4 partial dates"
}

test_verify_reports_missing_table() {
    run_migration --target bad_copy
    assert_eq "migration exit code" 0 "$?"
    sql -e "DROP TABLE bad_copy.authors"
    run_verify isfdb bad_copy
    assert_eq "exit code" 1 "$?"
    assert_log_contains "only in isfdb: authors"
}

test_verify_counts_no_tables() {
    sql -e "CREATE DATABASE empty_source; CREATE DATABASE empty_copy"
    call_function verify_table_names empty_source empty_copy ""
    assert_eq "exit code" 0 "$?"
    assert_log_contains "[INFO] ✓ Same 0 tables"
}

test_verify_reports_extra_table() {
    run_migration --target bad_copy
    assert_eq "migration exit code" 0 "$?"
    sql -e "CREATE TABLE bad_copy.extra (id int) ENGINE = InnoDB"
    run_verify isfdb bad_copy
    assert_eq "exit code" 1 "$?"
    assert_log_contains "only in bad_copy: extra"
}

test_verify_fails_when_listing_fails() {
    run_verify isfdb no_such_copy
    assert_eq "exit code" 1 "$?"
    assert_log_contains "Listing the tables of no_such_copy failed: ERROR 1049 (42000): Unknown database 'no_such_copy'"
}

test_verify_reports_wrong_engine() {
    run_migration --target bad_copy
    assert_eq "migration exit code" 0 "$?"
    sql -e "ALTER TABLE bad_copy.mw_user_groups ENGINE = MyISAM"
    run_verify isfdb bad_copy
    assert_eq "exit code" 1 "$?"
    assert_log_contains "Tables not InnoDB in bad_copy"
    assert_log_contains "mw_user_groups"
}

test_verify_reports_row_count() {
    run_migration --target bad_copy
    assert_eq "migration exit code" 0 "$?"
    sql -e "DELETE FROM bad_copy.titles WHERE title_id = 2"
    run_verify isfdb bad_copy
    assert_eq "exit code" 1 "$?"
    assert_log_contains "titles: 5 rows in isfdb, 4 in bad_copy"
}

test_verify_reports_failed_source_row_count() {
    run_migration --target bad_copy
    assert_eq "migration exit code" 0 "$?"
    call_function verify_row_counts isfdb bad_copy "$(printf 'authors\nnope')"
    assert_eq "exit code" 1 "$?"
    assert_eq "output" "[ERROR] ✗ Counting the rows of nope in isfdb failed: ERROR 1146 (42S02) at line 1: Table 'isfdb.nope' doesn't exist" "$(log_text | tail -n 1)"
}

test_verify_reports_failed_copy_row_count() {
    run_migration --target bad_copy
    assert_eq "migration exit code" 0 "$?"
    sql -e "DROP TABLE bad_copy.authors"
    call_function verify_row_counts isfdb bad_copy "$(printf 'titles\nauthors')"
    assert_eq "exit code" 1 "$?"
    assert_eq "output" "[ERROR] ✗ Counting the rows of authors in bad_copy failed: ERROR 1146 (42S02) at line 1: Table 'bad_copy.authors' doesn't exist" "$(log_text | tail -n 1)"
}

test_verify_reports_failed_copy_zero_date_count() {
    run_migration --target bad_copy
    assert_eq "migration exit code" 0 "$?"
    sql -e "DROP TABLE bad_copy.authors"
    call_function verify_zero_dates isfdb bad_copy "$(printf 'titles\nauthors')"
    assert_eq "exit code" 1 "$?"
    assert_eq "output" "[ERROR] ✗ Counting the zero dates of authors.author_birthdate in bad_copy failed: ERROR 1146 (42S02) at line 2: Table 'bad_copy.authors' doesn't exist
[ERROR] ✗ Counting the zero dates of authors.author_deathdate in bad_copy failed: ERROR 1146 (42S02) at line 2: Table 'bad_copy.authors' doesn't exist" "$(log_text | tail -n 2)"
}

test_verify_reports_changed_datetime_zero() {
    run_migration --target bad_copy
    assert_eq "migration exit code" 0 "$?"
    sql -e "UPDATE bad_copy.submissions SET sub_time = '2001-01-01 00:00:00' WHERE sub_id = 1"
    run_verify isfdb bad_copy
    assert_eq "exit code" 1 "$?"
    assert_log_contains "submissions.sub_time: 1 zero or partial dates in isfdb, 0 in bad_copy"
}

test_verify_reports_changed_partial_date() {
    run_migration --target bad_copy
    assert_eq "migration exit code" 0 "$?"
    sql -e "SET SESSION sql_mode = 'NO_ENGINE_SUBSTITUTION'; UPDATE bad_copy.authors SET author_birthdate = '1901-01-01' WHERE author_id = 2"
    run_verify isfdb bad_copy
    assert_eq "exit code" 1 "$?"
    assert_log_contains "authors.author_birthdate: 1 zero or partial dates in isfdb, 0 in bad_copy"
}

# =====================================================
# Runner
# =====================================================

run_test() {
    CURRENT_TEST="$1"
    : > "$(log_file)"
    reset_server
    "$CURRENT_TEST"
    if [ -s "$(failures_file)" ]; then
        echo "not ok - ${CURRENT_TEST}"
        sed 's/^/    /' "$(failures_file)"
        echo "    --- output"
        sed 's/^/    /' "$(log_file)"
        FAILED=$((FAILED + 1))
    else
        echo "ok - ${CURRENT_TEST}"
        PASSED=$((PASSED + 1))
    fi
}

start_server
for test_name in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
    run_test "$test_name"
done
echo ""
echo "${PASSED} passed, ${FAILED} failed"
[ "$FAILED" -eq 0 ]
