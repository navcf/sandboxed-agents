#!/bin/sh
# setup-ssh.sh — GitHub-over-SSH provisioning at sandbox launch.
#
# The private key is NEVER baked into an image (images are pushed to a
# registry; a secret in a layer is published). Instead the host mounts a
# dedicated key directory at sandbox creation:
#
#     sbx create ... claude . ~/.ssh/sandbox:ro
#
# Extra workspaces mount at the same absolute path as on the host, so the key
# appears at e.g. /Users/<user>/.ssh/sandbox/id_ed25519 inside the container.
# A bind mount preserves host ownership and ssh insists on a 600 key owned by
# the current user, so the key cannot be used in place — this script copies it
# into ~/.ssh with the right owner/mode at every launch (idempotent; re-copy
# also picks up a rotated key). See the README's "GitHub over SSH" section for
# the one-time host setup (dedicated keypair, deploy-key grant, policy allow).
#
# Called by the claude/codex shims on every launch; cursor has no shim — run
# this once by hand inside a cursor sandbox. Opt-in and gracefully degrading:
# no mounted key means exit 0 with no changes, and the sandbox stays HTTPS-only.
set -u

SSH_DIR="${HOME}/.ssh"
KEY_DST="${SSH_DIR}/github_sandbox"
KNOWN_HOSTS_SRC=/usr/local/share/sbx/github-known-hosts

# Locate the mounted private key: explicit override first, then the documented
# host location (~/.ssh/sandbox) under either macOS or Linux home roots.
KEY_SRC="${SANDBOX_GITHUB_KEY:-}"
if [ -z "$KEY_SRC" ]; then
  for k in /Users/*/.ssh/sandbox/id_ed25519 /home/*/.ssh/sandbox/id_ed25519; do
    [ -f "$k" ] && { KEY_SRC="$k"; break; }
  done
fi
[ -n "$KEY_SRC" ] && [ -f "$KEY_SRC" ] || exit 0

umask 077
mkdir -p "$SSH_DIR"

cp "$KEY_SRC" "$KEY_DST"
chmod 600 "$KEY_DST"
if [ -f "${KEY_SRC}.pub" ]; then
  cp "${KEY_SRC}.pub" "${KEY_DST}.pub"
  chmod 644 "${KEY_DST}.pub"
fi

# GitHub's published host keys (shipped in the image — no ssh-keyscan TOFU),
# so the first git operation never hangs on a host-key prompt.
if ! grep -qs '^github.com ' "${SSH_DIR}/known_hosts"; then
  cat "$KNOWN_HOSTS_SRC" >> "${SSH_DIR}/known_hosts"
fi

# Point github.com at the key. Grep-guarded append, never a rewrite — the same
# pattern as gitnexus-mcp-codex.sh. ssh.github.com:443 is the SSH-over-HTTPS
# fallback for environments where port 22 egress is blocked (remote URL form:
# ssh://git@ssh.github.com:443/owner/repo.git).
if ! grep -qs 'BEGIN sandbox github' "${SSH_DIR}/config"; then
  cat >> "${SSH_DIR}/config" <<EOF
# BEGIN sandbox github (setup-ssh.sh)
Host github.com
  User git
  IdentityFile ${KEY_DST}
  IdentitiesOnly yes
Host ssh.github.com
  User git
  Port 443
  IdentityFile ${KEY_DST}
  IdentitiesOnly yes
# END sandbox github
EOF
fi
chmod 600 "${SSH_DIR}/config"
