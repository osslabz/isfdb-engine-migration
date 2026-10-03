# isfdb-scripts

MySQL InnoDB migration and analysis tools for the Internet Speculative Fiction Database (ISFDB).

## Scripts

| Script | Purpose |
|--------|---------|
| `dynamic_migration.sh` | Converts MyISAM tables to InnoDB |
| `analyze_innodb.sh` | Analyzes InnoDB tables (updates index statistics) |
| `optimize_innodb.sh` | Optimizes InnoDB tables (rebuild + analyze) |
| `mysql_innodb_lib.sh` | Shared function library (sourced by the scripts above) |

## Prerequisites

- MySQL 5.6+ or MariaDB 10.0+
- `mysql` client; `mysql_config_editor` only when you use a login-path
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

All scripts take the same options:

| Option | Effect |
|--------|--------|
| `[login-path]` | Login-path to connect with (default `isfdb_local`) |
| `--yes`, `-y` | Answer every confirmation with yes and never prompt. Same as `ISFDB_ASSUME_YES=1` |
| `--user NAME` | Connect as `NAME` instead of using a login-path (name without spaces) |
| `--defaults-extra-file FILE` | Read credentials from a MySQL option file instead of using a login-path (path without spaces) |

`--user` and `--defaults-extra-file` replace the login-path (giving both is an error), so `mysql_config_editor` is not needed.
The `mysql` client also reads `MYSQL_PWD`, `MYSQL_HOST` and `MYSQL_TCP_PORT` from the environment.
Without `--yes`, the scripts prompt as usual. With `--yes` a missing login-path is an error instead of a setup prompt.
The scripts exit non-zero if the connection fails or a table cannot be converted or analyzed.

## Usage

### Migration (MyISAM → InnoDB)

```bash
./dynamic_migration.sh [login-path]
```

The migration script:
- Discovers all MyISAM tables in the `isfdb` database
- Fixes invalid dates (required for InnoDB strict mode)
- Keeps FULLTEXT indexes (MySQL 5.6+ and MariaDB 10.0+ convert them with the table)
- Converts tables to InnoDB
- Analyzes converted tables (updates index statistics)
- Provides buffer pool configuration recommendations

### Analysis

```bash
./analyze_innodb.sh [login-path]
```

The analysis script:
- Finds all InnoDB tables
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
```

### Unattended (e.g. inside the `mysql` Docker image)

```bash
docker compose exec -T isfdb sh -c \
    'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" /isfdb-scripts/dynamic_migration.sh --yes --user root'
```

Or with a credentials file:

```bash
./dynamic_migration.sh --yes --defaults-extra-file /run/secrets/isfdb.cnf
```

## Database Configuration

The scripts target the `isfdb` database by default. This is configured at the top of each script if you need to change it.

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
