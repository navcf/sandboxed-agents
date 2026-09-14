#!/bin/sh
# Installed at /home/agent/.local/bin/codex, which precedes the real
# npm-global binary on PATH.
exec /usr/local/bin/sbx-agent launch codex "$@"
