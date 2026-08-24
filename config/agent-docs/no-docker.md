# Routing project tooling around Docker

There is no Docker daemon in the sandbox (`/var/run/docker.sock` does not
exist), by design. Everything a dev stack needs is already native in the
image: PostgreSQL 18 on localhost:5432 (managed by `devstack`), Node, the
headless browser, xvfb.

When project tooling shells out to Docker, route around it:

- A CLI that runs `docker compose up` for a database is almost always a
  fallback after probing for a local server — make sure Postgres is running
  (`devstack up`) so the probe succeeds, and point its connection at
  localhost:5432.
- A migrate/codegen tail that calls `docker exec … pg_dump` after migrations
  already applied: absorb it with `TOLERATE_MIGRATE_FAIL_IF` in
  `.local/.devstack.conf` — do not hand-roll a replacement for the step.
- A test helper that hard-requires `docker compose` with no native path:
  report the gap to the user rather than working around it — the durable fix
  is in the project's tooling (probe localhost:5432 first, use Docker only
  when nothing answers).
