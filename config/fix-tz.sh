# Sourced (not run) by the agent shims and by devstack, so the export lands in
# the process that execs the agent / runs the migrate+seed steps.
#
# sbx forwards the host's TZ, and macOS sends POSIX abbreviations like "PDT7" —
# not an IANA zone. Intl then resolves timeZone to undefined and every
# temporal-polyfill call throws "Invalid string: undefined". The image's
# ENV TZ=UTC loses to that inherited value, so normalize here: keep any zone
# node can resolve, replace anything else with UTC.
if [ -n "${TZ:-}" ] && ! node -e 'Intl.DateTimeFormat().resolvedOptions().timeZone || process.exit(1)' >/dev/null 2>&1; then
  export TZ=UTC
fi
