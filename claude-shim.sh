#!/bin/sh
# Installed at /home/agent/.local/bin/claude, replacing the native-install
# launcher symlink (moved to claude-real by the Dockerfile).
exec /usr/local/bin/sbx-agent launch claude "$@"
