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
- When that probe checks a port devstack does not serve — a test config
  pinning e.g. `DATABASE_PORT=5433` — an inline env override usually loses,
  because the runner loads its own env file (Nx, dotenv-cli and friends read
  `.env.test` themselves) after your override. Forward the port rather than
  fight the config, and create the test database first if the config names a
  separate one:

      PGPASSWORD=postgres psql -U postgres -h localhost -p 5432 \
        -c "CREATE DATABASE <test-db>"
      socat TCP-LISTEN:5433,fork,reuseaddr TCP:127.0.0.1:5432

  A suite behind such a probe is NOT the no-native-path case below; it runs
  fully natively once the probe is satisfied. Record the recipe for the
  workspace in `TEST_HINT` (`.local/.devstack.conf`) so the next session does
  not rediscover it.
- A migrate/codegen tail that calls `docker exec … pg_dump` after migrations
  already applied: absorb it with `TOLERATE_MIGRATE_FAIL_IF` in
  `.local/.devstack.conf` — do not hand-roll a replacement for the step.
- A test helper that hard-requires `docker compose` with no native path:
  report the gap to the user rather than working around it — the durable fix
  is in the project's tooling (probe localhost:5432 first, use Docker only
  when nothing answers).

## Long-lived helper processes

A port forwarder is the common case; the same applies to any helper meant to
outlive one command.

- Do not assume a bare `nohup … &` survives. Whether a detached helper is
  reaped when the command wrapper returns varies by agent harness — observed
  reaped under codex, surviving under claude. If the helper is gone by the
  next command, keep it in a supervised background session instead.
- Never stop one with `pkill -f <pattern>`. The pattern is part of the
  killing command's own command line, so `pkill` matches itself and kills the
  shell running it — the call dies with exit 144 and no output. Kill by PID:

      pgrep -f 'socat TCP-LISTEN:5433' | xargs -r kill

- Leave the sandbox's own `socat UNIX-LISTEN:/run/ssh-agent.sock …` process
  alone; killing it breaks ssh-agent forwarding for the rest of the session.
  This is the other reason to match precisely rather than on `socat` alone.
