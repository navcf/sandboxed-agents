# Database — already up, use `manifest`

PostgreSQL 17 is baked into the image (`pg_cron`, `pg_stat_statements`,
`btree_gin`, `pg_trgm`, `pgcrypto`, `unaccent` — matching
`postgres/Dockerfile`/`postgres/init-db.sql` in this repo) and is started,
password-set, and schema-bootstrapped before any agent CLI even launches.
Every agent launch also runs `pnpm manifest db migrate` — idempotent, so it's
a fast no-op when nothing's pending, and it catches migrations landed since
the last launch in a container that's stayed up across several sessions.

Use the project's own `manifest` CLI (`apps/cli/manifest.sh`) directly:

- `pnpm manifest db status` — migration status, connection info.
- `pnpm manifest db migrate` — apply pending migrations (safe, idempotent;
  already run automatically at every launch).
- `pnpm manifest db reset` — **destructive**: drops and rebuilds the database,
  re-migrates, regenerates types. Only run this deliberately.
- `pnpm manifest db psql` — open a psql shell to the local database.
- `pnpm manifest test unit|api|e2e` — the sanctioned way to run tests. `api`
  and `e2e` bootstrap their own isolated schema and server on a dedicated
  port and tear both down on exit; don't hand-roll that yourself.
- `pnpm manifest seed` — seed sample data into the main `manifest` database
  (not the isolated per-test schemas `manifest test` uses).

If `pnpm manifest db status` reports something unexpected, that's the place
to start — never hand-edit `/etc/postgresql` or the database/schema directly.

## Environment facts

- Connection: `localhost:5432`, user/password `postgres`/`postgres`, database
  `manifest`, `sslmode=require` (encrypts; does not verify the cert/hostname —
  see `libs/server/db/src/db.ts` `buildSslConfig()`).
- If date/Intl code throws `Invalid string: undefined`, the inherited `TZ` is
  not an IANA zone (e.g. macOS "PDT7"). The launcher normally fixes this; if
  it leaks through, prefix commands with `TZ=UTC`.
