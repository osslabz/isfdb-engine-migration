# isfdb-scripts

MySQL InnoDB migration and analysis tools for the Internet Speculative Fiction Database (ISFDB).

## Scripts

| Script | Purpose |
|--------|---------|
| `dynamic_migration.sh` | Converts MyISAM tables to InnoDB |
| `analyze_innodb.sh` | Analyzes InnoDB tables (updates index statistics) |
| `mysql_innodb_lib.sh` | Shared function library (sourced by the scripts above) |

## Prerequisites

- MySQL 5.6+ or MariaDB 10.0+
- `mysql_config_editor` (comes with MySQL client tools)
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

## Usage

### Migration (MyISAM → InnoDB)

```bash
./dynamic_migration.sh [login-path]
```

The migration script:
- Discovers all MyISAM tables in the `isfdb` database
- Fixes invalid dates (required for InnoDB strict mode)
- Handles FULLTEXT indexes (drops before conversion, recreates after)
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

## Database Configuration

The scripts target the `isfdb` database by default. This is configured at the top of each script if you need to change it.

## Buffer Pool Recommendations

Both scripts provide InnoDB buffer pool sizing recommendations based on:
- Total system RAM
- Current database size
- MySQL best practices (typically 70-80% of RAM for dedicated servers)

Apply recommendations in your MySQL configuration:

```ini
[mysqld]
innodb_buffer_pool_size = 8G
```
