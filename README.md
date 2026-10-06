# isfdb-engine-migration

Copies the Internet Speculative Fiction Database (ISFDB) from its imported MyISAM tables into a separate
database with every table in InnoDB and every value unchanged. The source is only read. The next pipeline
step, `codelabz-net/isfdb-schema-migration`, reads InnoDB tables only. InnoDB is MySQL's default engine,
transactional and crash-safe, and it locks rows instead of whole tables. The script copies instead of
converting in place, so the imported `isfdb` stays as dumped and the script can compare the copy with it
before it hands the copy on. The repository also has two InnoDB maintenance helpers.

```bash
./dynamic_migration.sh
```

## Pipeline

```
ISFDB backup -> import -> isfdb            (MyISAM, as dumped, never changed)
                       -> dynamic_migration.sh
                       -> isfdb_innodb     (InnoDB, values unchanged)
                       -> isfdb-schema-migration
                       -> target database
```

All databases live on one MySQL server. In isbn-bff, `infra/isfdb/refresh.sh` runs this step inside the
MySQL container.

## Scripts

| Script | Purpose |
|--------|---------|
| `dynamic_migration.sh` | Copies `isfdb` into `isfdb_innodb`, every table InnoDB |
| `analyze_innodb.sh` | Runs `ANALYZE TABLE` on the InnoDB tables of one database (updates index statistics) |
| `optimize_innodb.sh` | Runs `OPTIMIZE TABLE` on the InnoDB tables of one database (rebuild and analyze) |
| `mysql_innodb_lib.sh` | Shared functions, sourced by the scripts above |

## Requirements

- MySQL 9.7. Other versions are not tested. MariaDB is not supported
- `mysql` client; `mysql_config_editor` only when you use a login-path
- Bash 4.0+
- A MySQL user that can create and drop databases and set `sql_log_bin` (`SYSTEM_VARIABLES_ADMIN` or
  `SESSION_VARIABLES_ADMIN`). Root can
- Disk for `isfdb`, `isfdb_innodb` and, during a run, the new copy in `isfdb_innodb_next`

## Setup

Store credentials in a login-path:

```bash
mysql_config_editor set --login-path=isfdb_local --user=root --password
mysql_config_editor print --all
```

Or skip the login-path and pass `--user` or `--defaults-extra-file`.

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

`--user` and `--defaults-extra-file` replace the login-path and can be used together. Combining a login-path with either of them is an error.
The `mysql` client also reads `MYSQL_PWD`, `MYSQL_HOST` and `MYSQL_TCP_PORT` from the environment.
Without `--yes` the scripts prompt. With `--yes` a missing login-path is an error instead of a setup prompt.

Database names must match `[A-Za-z0-9_]+`. `--source` and `--target` must differ. The copy also uses
`<target>_next` and `<target>_old`. Neither may equal the source, and both must fit MySQL's 64-character
limit. The script checks the names before it connects.

## Copy into InnoDB

```bash
./dynamic_migration.sh [--yes] [[--user NAME] [--defaults-extra-file FILE] | login-path] [--source DB] [--target DB]
```

A run:

1. Lists the tables of the source, whatever their engine, and asks for confirmation unless `--yes`.
   A source that is missing or has no tables exits 1 before anything is created.
2. Drops and recreates `<target>_next`. This also clears what an earlier failed run left there.
3. Copies each table into `<target>_next`: `CREATE TABLE ... LIKE`, `ALTER TABLE ... ENGINE = InnoDB` on
   the empty table, then `INSERT ... SELECT`. Keys, FULLTEXT indexes and `AUTO_INCREMENT` columns carry
   over. Tables that are InnoDB already are copied the same way.
4. Runs `ANALYZE TABLE` on every copied table.
5. Verifies the copy.
6. Swaps the copy in with one `RENAME TABLE`, then drops `<target>_old` and `<target>_next`.

### Session settings

The script sets these in its own sessions. The server configuration needs no change for the copy.

- `sql_mode = 'NO_ENGINE_SUBSTITUTION'` while copying. ISFDB stores unknown dates as zero dates:
  `0000-00-00` for unknown, `1990-00-00` for a known year, `1990-05-00` for a known month. MySQL's
  default strict mode (`NO_ZERO_DATE`, `NO_ZERO_IN_DATE`) rejects them. With this mode they copy unchanged.
- `sql_log_bin = 0` in every session that writes, and `ANALYZE NO_WRITE_TO_BINLOG`. The copy is rebuilt
  from the dump and never replicated, so it stays out of the binary log. This needs the privilege named
  under Requirements.

Importing the dump into `isfdb` needs the same `sql_mode` on the server, for the same dates. That is the
importer's job. isbn-bff sets it in `infra/isfdb/isfdb.cnf`.

### Verification

Before the swap the script checks `<target>_next` against the source:

- the same base tables, by name (views are not compared);
- every table InnoDB;
- the same row count per table, by `COUNT(*)`, because `TABLE_ROWS` is only an estimate for InnoDB;
- per `date`, `datetime` and `timestamp` column, the same number of values with a zero year, month or day;
- `pubs.pub_year` still has values with an unknown day (`YYYY-MM-00`, which also counts `0000-00-00`).
  None means the source went through a date rewrite.

Any failed check exits 1. The last check is written for the ISFDB schema, so it fails on a source
without a `pubs` table.

### Atomic swap

The tables of `<target>` move to `<target>_old` and the tables of `<target>_next` move to `<target>`
in one multi-table `RENAME TABLE`. That statement is atomic. Readers of `<target>` see the old tables or
the new ones, never a mix. `<target>` ends up with exactly the copied base tables. Views in `<target>` do
not move and stay. A view named like a copied table makes the `RENAME TABLE` fail. Both helper databases
are dropped after the swap. The target is created first when it does not exist.

### Failure behaviour

| Exit code | When |
|-----------|------|
| 0 | The copy is in `<target>`. Also when you answer no at the prompt, and then nothing changes |
| 1 | Invalid options or names, failed connection, missing or empty source, failed preparation of `<target>_next`, failed table, failed `ANALYZE`, failed verification, failed swap before or at the `RENAME TABLE`, or failed drop of a helper database after a successful `RENAME TABLE` |

Every failure before the swap leaves `<target>` as the last good run left it, or absent. Only
`<target>_next` may stay behind, and the next run drops it first.

A failed `RENAME TABLE` changes nothing. The script then drops `<target>_old`, and drops `<target>` if
this run created it.

If a helper database cannot be dropped after a successful `RENAME TABLE`, `<target>` already holds the new
copy. The script says so and exits 1. The next run drops `<target>_next` before the copy and `<target>_old`
at the swap.

A table that fails to copy is reported and the other tables are still copied. The run lists all failing
tables, then exits 1 without analyzing or swapping.

Callers must stop on exit code 1. After a failed run `<target>` may still hold an older dump.

## Maintenance helpers

```bash
./analyze_innodb.sh [--database DB] [login-path]
./optimize_innodb.sh [--database DB] [login-path]
```

Both find the InnoDB tables of `isfdb_innodb` (or `--database DB`), run `ANALYZE TABLE` or
`OPTIMIZE TABLE` on each and show data and index sizes. `isfdb` stays MyISAM, so the default is the copy.
The pipeline does not call them.

## Examples

```bash
# Default login-path isfdb_local, copies isfdb into isfdb_innodb
./dynamic_migration.sh

# Another login-path and target
./dynamic_migration.sh --target isfdb_innodb_test production

# Analyze another database than the default
./analyze_innodb.sh --database isfdb_innodb_test production
```

Unattended, inside the `mysql` Docker image:

```bash
docker compose exec -T isfdb sh -c \
    'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" /isfdb-engine-migration/dynamic_migration.sh --yes --user root'
```

With a credentials file:

```bash
./dynamic_migration.sh --yes --defaults-extra-file /run/secrets/isfdb.cnf
```

## Tests

```bash
test/run.sh
```

Runs the scripts against a throwaway `mysql:9.7` container with a small ISFDB fixture (`test/fixture.sql`).
Needs Docker and the `mysql:9.7` image. The container publishes no host port.
