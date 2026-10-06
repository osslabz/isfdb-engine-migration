# isfdb-engine-migration

Copies the Internet Speculative Fiction Database (ISFDB) into InnoDB tables, plus MySQL InnoDB maintenance tools.

## Scripts

| Script | Purpose |
|--------|---------|
| `dynamic_migration.sh` | Copies the `isfdb` database into `isfdb_innodb`, every table InnoDB |
| `analyze_innodb.sh` | Analyzes InnoDB tables (updates index statistics) |
| `optimize_innodb.sh` | Optimizes InnoDB tables (rebuild + analyze) |
| `mysql_innodb_lib.sh` | Shared function library (sourced by the scripts above) |

## Prerequisites

- MySQL 5.6+ or MariaDB 10.0+
- `mysql` or `mariadb` client; `mysql_config_editor` (MySQL only) only when you use a login-path
- Bash 4.0+

## Setup

Configure a MySQL login-path for secure credential storage:

```bash
mysql_config_editor set --login-path=local --user=root --password
```

For production:

```bash
mysql_config_editor set --login-path=production --user=isfdb --password
```

Verify your login-path:

```bash
mysql_config_editor print --all
```

## Options

All scripts take these options:

| Option | Effect |
|--------|--------|
| `[login-path]` | Login-path to connect with (default `isfdb_local`) |
| `--yes`, `-y` | Answer every confirmation with yes and never prompt. Same as `ISFDB_ASSUME_YES=1` |
| `--user NAME` | Connect as `NAME` instead of using a login-path (name without spaces) |
| `--defaults-extra-file FILE` | Read credentials from a MySQL option file instead of using a login-path (path without spaces) |
| `--source DB` | `dynamic_migration.sh` only: database to copy (default `isfdb`) |
| `--target DB` | `dynamic_migration.sh` only: database the copy replaces (default `isfdb_innodb`) |
| `--database DB` | `analyze_innodb.sh` and `optimize_innodb.sh` only: database to work on (default `isfdb_innodb`) |

Database names must match `[A-Za-z0-9_]+`. `--source` and `--target` must differ, and the copy also uses `<target>_next` and `<target>_old`.

`--user` and `--defaults-extra-file` replace the login-path (giving both is an error), so `mysql_config_editor` is not needed.
The `mysql` client also reads `MYSQL_PWD`, `MYSQL_HOST` and `MYSQL_TCP_PORT` from the environment.
Without `--yes`, the scripts prompt as usual. With `--yes` a missing login-path is an error instead of a setup prompt.
The scripts exit non-zero if the connection fails or a table cannot be copied, analyzed or verified.

## Usage

### Copy into InnoDB

```bash
./dynamic_migration.sh [login-path]
```

The script copies the database `isfdb` into `isfdb_innodb`:
- Builds the copy in `isfdb_innodb_next`: per table `CREATE TABLE ... LIKE`, `ALTER TABLE ... ENGINE = InnoDB` on the empty table, then `INSERT ... SELECT`
- Copies every value unchanged, zero and partial dates (`0000-00-00`, `1990-05-00`) included
- Keeps FULLTEXT indexes
- Analyzes the copied tables (updates index statistics)
- Verifies the copy before the swap: same tables, all InnoDB, same row counts, the same number of zero and partial dates per date column, and `pubs.pub_year` still has partial dates
- Replaces `isfdb_innodb` with one atomic `RENAME TABLE`. A failed run leaves the previous `isfdb_innodb` as it was
- Never changes `isfdb`

The copy keeps its writes out of the binary log (`SET SESSION sql_log_bin = 0`). The MySQL user needs
`SYSTEM_VARIABLES_ADMIN` or `SESSION_VARIABLES_ADMIN` for that.

### Analysis

```bash
./analyze_innodb.sh [login-path]
```

The analysis script:
- Finds all InnoDB tables of `isfdb_innodb` (or `--database DB`)
- Runs `ANALYZE TABLE` on each (updates index statistics for query optimizer)
- Shows detailed size information (data/index breakdown)
- Analyzes InnoDB buffer pool configuration
- Provides configuration recommendations

### Examples

```bash
# Use default 'local' login-path
./dynamic_migration.sh

# Use a specific login-path
./dynamic_migration.sh production
./analyze_innodb.sh production

# Analyze the original database instead of the copy
./analyze_innodb.sh --database isfdb production
```

### Unattended (e.g. inside the `mysql` Docker image)

```bash
docker compose exec -T isfdb sh -c \
    'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" /isfdb-engine-migration/dynamic_migration.sh --yes --user root'
```

Or with a credentials file:

```bash
./dynamic_migration.sh --yes --defaults-extra-file /run/secrets/isfdb.cnf
```

## Buffer Pool Recommendations

Both scripts provide InnoDB buffer pool sizing recommendations based on:
- Total system RAM
- Current database size
- MySQL best practices (typically 70-80% of RAM for dedicated servers)

The recommendation is never below 128 MB, MySQL's default.

Apply recommendations in your MySQL configuration:

```ini
[mysqld]
innodb_buffer_pool_size = 8G
```

## Tests

```bash
test/run.sh
```

Runs the scripts against a throwaway `mysql:9.7` container with a small ISFDB fixture (`test/fixture.sql`).
Needs Docker. The container publishes no port.
