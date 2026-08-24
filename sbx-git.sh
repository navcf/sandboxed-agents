#!/usr/bin/env sh
# Sync git work between the host repo and its `sbx create --clone` sandboxes.
#
# Clone-mode plumbing sbx already provides, which this script wraps:
# - Each running clone sandbox serves a git daemon (published to a host
#   loopback port); sbx maintains a `sandbox-<name>` remote in the host repo
#   pointing at it while the sandbox runs (removed on stop, re-added with a
#   fresh port on `sbx run` — but NOT on `sbx exec`, so this script falls
#   back to reading the port from `sbx ls`).
# - The host repo is mounted live and read-only inside the sandbox at
#   /run/sandbox/source; the shims register it as the `host` remote in the
#   clone, so host->sandbox is a fetch run inside the sandbox.
# Only commits cross the boundary in either direction.
#
# Usage: sbx-git ls | pull [SANDBOX] [BRANCH] | push [SANDBOX] [BRANCH] | harvest SANDBOX
set -eu

usage() {
  cat <<'EOF'
usage: sbx-git ls
       sbx-git pull [--force] [SANDBOX] [BRANCH]
       sbx-git push [SANDBOX] [BRANCH]
       sbx-git harvest SANDBOX
       sbx-git clean [--force] [SANDBOX] [BRANCH]

Sync commits between the host repo and its --clone sandboxes. Run from
anywhere inside the workspace repo.

  ls       fetch every sandbox of this repo and show each one's branches
           (last commit + how far ahead of your HEAD); stopped sandboxes are
           listed with a harvest hint
  pull     fetch SANDBOX's branches and check BRANCH out in a worktree at
           ../<repo>-wt/<sandbox>-<branch>, on local branch
           sbx/<sandbox>/<branch> — inspect and run tests there without
           touching your working tree. BRANCH defaults to the branch checked
           out in the sandbox. When the sandbox amended/rebased commits you
           already pulled, the worktree follows the rewrite automatically —
           unless it has local changes or commits, which need --force (or a
           manual rescue) to discard
  push     make the sandbox's clone see your host commits: runs
           `git fetch host [BRANCH]` inside the sandbox (`host` is the live
           read-only mount of this repo). The agent still has to rebase —
           tell it to `git rebase host/<branch>`
  harvest  fetch from a STOPPED sandbox: wake it with `sbx exec`, fetch all
           branches, stop it again (a running sandbox is left running)
  clean    undo pull: remove the worktree(s) and local sbx/<sandbox>/*
           branch(es) for SANDBOX (all of them, or just BRANCH). Refuses a
           dirty worktree or a branch with commits its sandbox never saw
           unless --force is given. Once the sandbox itself is gone (sbx rm),
           also drops the leftover fetch refs and stale remote

SANDBOX is the sbx sandbox name (`sbx ls`), e.g. claude-1234; pull/push may
omit it when exactly one sandbox remote exists for this repo. Only commits
cross the boundary — uncommitted sandbox changes are invisible until the
agent commits (the baked instructions tell agents to commit early, on a
branch).
EOF
}

die() { echo "sbx-git: $*" >&2; exit 1; }

# --- helpers ---------------------------------------------------------------

sbx_state() { # STATUS column for sandbox $1, empty if unknown
  sbx ls 2>/dev/null | awk -v n="$1" '$1 == n { print $3 }'
}

# Die early when sandbox $sb exists but belongs to another repo — otherwise
# the daemon rejects the fetch with a misleading "repository not exported".
# The primary workspace is the first path column in its `sbx ls` row (later
# paths are extra mounts like Notes or the SSH key dir).
check_workspace() {
  ws=$(sbx ls 2>/dev/null | awk -v n="$sb" \
    '$1 == n { for (i = 2; i <= NF; i++) if ($i ~ /^\//) { sub(/,$/, "", $i); print $i; exit } }')
  [ -z "$ws" ] || [ "$ws" = "$top" ] \
    || die "sandbox '$sb' belongs to $ws — run sbx-git from that repo"
}

# Resolve $sb from an explicit arg, or from the sole sandbox-* remote.
resolve_sandbox() {
  if [ -n "${1:-}" ]; then
    sb=${1#sandbox-}
    return
  fi
  set -- $(git remote | sed -n 's/^sandbox-//p')
  case $# in
    1) sb=$1 ;;
    0) die "no sandbox remote for this repo — pass a sandbox name (see: sbx ls; stopped sandboxes need 'sbx-git harvest <name>')" ;;
    *) die "multiple sandboxes for this repo ($*) — pass one" ;;
  esac
}

# Set $tgt to something fetchable for sandbox $sb: the sbx-managed remote if
# present, else a git:// URL built from the daemon port in `sbx ls` (covers
# sandboxes woken by `sbx exec`, where sbx does not re-add the remote).
sandbox_target() {
  if git remote get-url "sandbox-$sb" >/dev/null 2>&1; then
    tgt=sandbox-$sb
    return 0
  fi
  port=$(sbx ls 2>/dev/null | awk -v n="$sb" '$1 == n' \
    | sed -n 's/.*127\.0\.0\.1:\([0-9]*\)->9418.*/\1/p')
  [ -n "$port" ] || return 1
  tgt=git://127.0.0.1:$port/$repo
}

# Fetch all of $sb's branches into refs/remotes/sandbox-$sb/*.
fetch_sandbox() {
  sandbox_target || return 1
  git fetch -q --prune "$tgt" "+refs/heads/*:refs/remotes/sandbox-$sb/*"
}

# Set $hb to the branch checked out in sandbox $sb (daemon HEAD symref);
# falls back to the sole fetched branch when HEAD is detached.
sb_head_branch() {
  hb=$(git ls-remote --symref "$tgt" HEAD 2>/dev/null \
    | sed -n 's|^ref: refs/heads/\(.*\)[[:space:]]HEAD$|\1|p')
  if [ -z "$hb" ]; then
    set -- $(git for-each-ref "refs/remotes/sandbox-$sb" --format='%(refname:lstrip=3)' | grep -vx HEAD)
    [ $# -eq 1 ] && hb=$1
  fi
}

print_branches() { # branches of $sb, with ahead-of-HEAD counts
  # grep -vx HEAD: git >= 2.42 records the remote's HEAD as
  # refs/remotes/<remote>/HEAD on fetch — not a branch, skip it.
  refs=$(git for-each-ref "refs/remotes/sandbox-$sb" --format='%(refname)' \
    | grep -v "^refs/remotes/sandbox-$sb/HEAD\$" || true)
  [ -n "$refs" ] || { echo '  (no branches)'; return; }
  for ref in $refs; do
    printf '  %-40s %s  [%s ahead of HEAD]\n' \
      "${ref#refs/remotes/sandbox-$sb/}" \
      "$(git log -1 --format='%h %s' "$ref")" \
      "$(git rev-list --count "HEAD..$ref")"
  done
}

# --- commands ---------------------------------------------------------------

cmd_ls() {
  # Union of sbx-managed remotes and `sbx ls` rows for this workspace: a
  # stopped sandbox has no remote, a crashed/removed one may leave a stale one.
  names=$({ git remote | sed -n 's/^sandbox-//p'
            sbx ls 2>/dev/null | awk -v ws="$top" 'NR > 1 && index($0, ws) { print $1 }'
          } | sort -u)
  if [ -z "$names" ]; then
    echo "no clone sandboxes found for this repo (running ones appear as sandbox-<name> remotes; see sbx ls)"
    return
  fi
  for sb in $names; do
    if [ "$(sbx_state "$sb")" = stopped ]; then
      echo "$sb: stopped — fetch with: sbx-git harvest $sb"
      continue
    fi
    if fetch_sandbox 2>/dev/null; then
      echo "$sb:"
      print_branches
    else
      echo "$sb: unreachable — stale remote, or not a clone sandbox? (sbx ls)"
    fi
  done
}

cmd_pull() {
  force=
  case ${1:-} in -f|--force) force=1; shift ;; esac
  resolve_sandbox "${1:-}"
  check_workspace
  fetch_sandbox || die "cannot reach sandbox '$sb' — is it running? (sbx ls; use 'sbx-git harvest $sb' if stopped)"
  br=${2:-}
  if [ -z "$br" ]; then
    sb_head_branch
    br=$hb
    [ -n "$br" ] || die "cannot tell which branch the sandbox has checked out (detached HEAD?) — pass one of: $(git for-each-ref "refs/remotes/sandbox-$sb" --format='%(refname:lstrip=3)' | tr '\n' ' ')"
  fi
  ref=refs/remotes/sandbox-$sb/$br
  git rev-parse -q --verify "$ref" >/dev/null || die "sandbox '$sb' has no branch '$br'"
  lbr=sbx/$sb/$br
  wt=$(dirname "$top")/$repo-wt/$sb-$(printf %s "$br" | tr / -)
  sync_worktree() {
    git -C "$wt" merge --ff-only "$ref" >/dev/null 2>&1 && return 0
    # Non-fast-forward: the agent amended or rebased commits we already
    # pulled. Following the rewrite is the normal case — refuse only when the
    # reset could lose something local: uncommitted changes, or a tip the
    # sandbox ref never pointed at (i.e. commits made here, not in the
    # sandbox; past tips are read from the remote-tracking ref's reflog).
    old=$(git -C "$wt" rev-parse --short HEAD)
    if [ -z "$force" ]; then
      [ -z "$(git -C "$wt" status --porcelain)" ] \
        || die "sandbox '$sb' rewrote '$br', but the worktree has local changes — commit/stash them in $wt, or discard everything with: sbx-git pull --force $sb $br"
      git rev-list -g "$ref" 2>/dev/null | grep -qx "$(git -C "$wt" rev-parse HEAD)" \
        || die "sandbox '$sb' rewrote '$br', but the worktree has local commits (tip $old was never a sandbox tip) — rescue them, or discard with: sbx-git pull --force $sb $br"
    fi
    git -C "$wt" reset --hard "$ref" >/dev/null
    echo "==> sandbox rewrote $br (amend/rebase) — worktree reset: $old -> $(git rev-parse --short "$ref")"
  }
  if [ -d "$wt" ]; then
    sync_worktree
  elif git show-ref -q --verify "refs/heads/$lbr"; then
    mkdir -p "$(dirname "$wt")"
    git worktree add "$wt" "$lbr"
    sync_worktree
  else
    mkdir -p "$(dirname "$wt")"
    git worktree add -b "$lbr" "$wt" "$ref"
  fi
  echo "==> $lbr at $(git rev-parse --short "$ref") — worktree: $wt"
}

cmd_push() {
  resolve_sandbox "${1:-}"
  check_workspace
  br=${2:-}
  [ -z "$br" ] || git show-ref -q --verify "refs/heads/$br" \
    || die "no local branch '$br' to push"
  # Push into the daemon is impossible by design (no receive-pack); the
  # equivalent is a fetch from the live host mount, run inside the sandbox.
  sbx exec "$sb" -- sh -c "
    [ -e /run/sandbox/source/.git ] || { echo 'not a --clone sandbox (no /run/sandbox/source)' >&2; exit 3; }
    git -C \"$top\" remote get-url host >/dev/null 2>&1 \
      || git -C \"$top\" remote add host /run/sandbox/source
    git -C \"$top\" fetch host $br" \
    || die "fetch inside sandbox '$sb' failed"
  echo "==> sandbox $sb now sees your commits${br:+ on $br} — tell the agent to run: git rebase host/${br:-<branch>}"
}

cmd_clean() {
  force=
  case ${1:-} in -f|--force) force=1; shift ;; esac
  if [ -n "${1:-}" ]; then
    sb=${1#sandbox-}
  else
    # No remote to resolve from (the sandbox is often already removed) —
    # infer from the sbx/* branches pull created.
    set -- $(git for-each-ref 'refs/heads/sbx' --format='%(refname:lstrip=3)' | cut -d/ -f1 | sort -u)
    case $# in
      1) sb=$1 ;;
      0) die "no sbx/* branches to clean" ;;
      *) die "sbx/* branches exist for several sandboxes ($*) — pass one" ;;
    esac
  fi
  br=${2:-}
  branches=$(git for-each-ref "refs/heads/sbx/$sb/${br:-}" --format='%(refname:lstrip=2)')
  [ -n "$branches" ] || die "nothing to clean: no local branch sbx/$sb/${br:-*}"
  for lbr in $branches; do
    b=${lbr#sbx/$sb/}
    wt=$(dirname "$top")/$repo-wt/$sb-$(printf %s "$b" | tr / -)
    if [ -d "$wt" ]; then
      git worktree remove ${force:+--force} "$wt" 2>/dev/null \
        || die "worktree $wt has local changes — commit/stash them, or re-run with --force"
      echo "==> removed worktree $wt"
    fi
    # -d treats "merged into upstream" (= the sandbox saw these commits) as
    # merged, so a plain re-pulled branch deletes fine even before you merge
    # it; only commits made locally on top require --force.
    if [ -n "$force" ]; then git branch -q -D "$lbr"
    else
      git branch -q -d "$lbr" \
        || die "branch $lbr has commits the sandbox never saw — merge them, or re-run with --force"
    fi
    echo "==> deleted branch $lbr"
  done
  rmdir "$(dirname "$top")/$repo-wt" 2>/dev/null || true
  # Sandbox gone entirely: nothing will refresh the fetched refs again, and a
  # crash can leave the sbx-managed remote behind — drop both.
  if [ -z "$(sbx_state "$sb")" ]; then
    git remote remove "sandbox-$sb" 2>/dev/null || true
    git for-each-ref "refs/remotes/sandbox-$sb" --format='%(refname)' \
      | while read -r r; do git update-ref -d "$r"; done
  fi
}

cmd_harvest() {
  sb=${1#sandbox-}
  state=$(sbx_state "$sb")
  [ -n "$state" ] || die "no sandbox named '$sb' (sbx ls)"
  check_workspace
  # `sbx exec` starts a stopped sandbox; the daemon port lands in `sbx ls`
  # moments later (no remote is re-added on exec — sandbox_target handles it).
  sbx exec "$sb" -- true >/dev/null 2>&1 || die "cannot start sandbox '$sb'"
  n=0
  until fetch_sandbox 2>/dev/null; do
    n=$((n + 1))
    [ "$n" -lt 5 ] || die "started '$sb' but its git daemon is unreachable"
    sleep 1
  done
  echo "$sb:"
  print_branches
  if [ "$state" != running ]; then
    sbx stop "$sb" >/dev/null 2>&1 && echo "==> $sb stopped again" \
      || echo "warn: failed to stop '$sb' again — sbx stop $sb" >&2
  fi
}

# --- main --------------------------------------------------------------------

[ $# -ge 1 ] || { usage >&2; exit 2; }
case $1 in -h|--help) usage; exit 0 ;; esac

top=$(git rev-parse --show-toplevel 2>/dev/null) || die "run from inside a git workspace"
repo=$(basename "$top")

cmd=$1
shift
case $cmd in
  ls)      cmd_ls ;;
  pull)    cmd_pull "$@" ;;
  push)    cmd_push "$@" ;;
  harvest) [ $# -ge 1 ] || die "harvest needs a sandbox name (sbx ls)"; cmd_harvest "$@" ;;
  clean)   cmd_clean "$@" ;;
  *)       die "unknown command '$cmd' (see: sbx-git --help)" ;;
esac
