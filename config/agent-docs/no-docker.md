# Routing project tooling around Docker

There is no Docker daemon in the sandbox (`/var/run/docker.sock` does not
exist), by design. Everything a dev stack needs is already native in the
image: PostgreSQL 17 on localhost:5432 (already running and migrated — see
docs/database.md), Node, the headless browser, xvfb.

`docker-compose.yml`, `postgres/Dockerfile`, and anything invoking `docker` or
`docker compose` directly do not work here — route around them:

- A CLI that runs `docker compose up` for a database is almost always a
  fallback after probing for a local server — Postgres is already running on
  localhost:5432, so the probe succeeds on its own; point any explicit
  connection config at localhost:5432 if it isn't already.
- When a probe checks a port Postgres isn't actually listening on (a test
  config pinning e.g. `DATABASE_PORT=5433`) — `manifest dev set <port>` (see
  `pnpm manifest dev show`) is the project's own mechanism for this; prefer it
  over an inline env override, since the runner often loads its own env file
  (Nx, dotenv-cli and friends read `.env.test` themselves) after your
  override anyway.
- A migrate/codegen tail that calls `docker exec … pg_dump` after migrations
  already applied, or any other manifest CLI step with no native path: report
  the gap to the user rather than hand-rolling a workaround — it's a fix that
  belongs in the project's own tooling.
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
