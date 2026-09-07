#!/usr/bin/env bash
# Runs on the HOST (inside WSL). Proves the reason the playground is mounted at
# the same absolute path on both sides.
#
# A linked worktree stores absolute paths in two places — the worktree's .git
# file points at <main>/.git/worktrees/<name>, and that directory's `gitdir`
# file points back at the worktree. If the container saw the playground at a
# different path, a worktree made on one side would be broken on the other, and
# `git worktree repair` would be a permanent part of the workflow.
#
#   bash tests/worktree-roundtrip.sh
set -uo pipefail
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   - $1"; }
bad() { fail=$((fail+1)); echo "  FAIL - $1"; }

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$REPO"
PLAYGROUND="$(grep -E '^PLAYGROUND=' .env | cut -d= -f2-)"
T="$PLAYGROUND/.devbox-wt-test"

inbox() { docker compose exec -T devbox bash -lc "$1" 2>&1; }

cleanup() { rm -rf "$T"; }
trap cleanup EXIT
cleanup; mkdir -p "$T"

echo "== both sides see the same path =="
[ "$(inbox "cd '$T' && pwd -P" | tr -d '\r')" = "$T" ] \
  && ok "the container resolves $T to the same path" \
  || bad "path differs inside the container"

echo "== a repo created on the HOST =="
git init -q "$T/repo"
git -C "$T/repo" config user.email t@example.com
git -C "$T/repo" config user.name t
echo one > "$T/repo/a.txt"
git -C "$T/repo" add a.txt && git -C "$T/repo" commit -qm init
git -C "$T/repo" branch -M main
ok "created $T/repo on the host"

echo "== worktree made in the CONTAINER, used on the HOST =="
inbox "cd '$T/repo' && git worktree add -q '$T/from-container' -b from-container" >/dev/null
if [ -d "$T/from-container" ]; then
  ok "the container created $T/from-container"
  out="$(git -C "$T/from-container" status --short --branch 2>&1)"
  echo "$out" | grep -q 'from-container' \
    && ok "the HOST can use it (git status works, on the right branch)" \
    || bad "host cannot use the container's worktree: $out"
  git -C "$T/from-container" log --oneline -1 >/dev/null 2>&1 \
    && ok "the host reads its history through the shared .git" \
    || bad "host cannot read history in the container's worktree"
else
  bad "the container could not create a worktree"
fi

echo "== worktree made on the HOST, used in the CONTAINER =="
git -C "$T/repo" worktree add -q "$T/from-host" -b from-host 2>/dev/null
if [ -d "$T/from-host" ]; then
  ok "the host created $T/from-host"
  out="$(inbox "cd '$T/from-host' && git status --short --branch")"
  echo "$out" | grep -q 'from-host' \
    && ok "the CONTAINER can use it (git status works, on the right branch)" \
    || bad "container cannot use the host's worktree: $out"
else
  bad "the host could not create a worktree"
fi

echo "== no repair is needed in either direction =="
# `git worktree repair` rewrites the stored paths. If the mount were wrong this
# would report fixes; on a correct setup it is silent.
out="$(git -C "$T/repo" worktree repair 2>&1)"
[ -z "$out" ] && ok "host: nothing to repair" || bad "host repair said: $out"
out="$(inbox "cd '$T/repo' && git worktree repair")"
[ -z "$(echo "$out" | tr -d '\r')" ] && ok "container: nothing to repair" || bad "container repair said: $out"

echo "== files an agent writes come out owned by you =="
inbox "cd '$T/from-container' && echo written-by-the-box > owned.txt" >/dev/null
if [ -f "$T/from-container/owned.txt" ]; then
  owner="$(stat -c %U "$T/from-container/owned.txt")"
  [ "$owner" = "$(id -un)" ] \
    && ok "a file written in the container is owned by $(id -un) on the host" \
    || bad "written file is owned by $owner, not $(id -un)"
else
  bad "the container's write did not appear on the host"
fi

echo "== the push guard applies to a host-created worktree too =="
git -C "$T/repo" config --local core.hooksPath /tmp/nope 2>/dev/null
out="$(inbox "cd '$T/from-host' && git rev-parse --git-path hooks")"
echo "$out" | tr -d '\r' | grep -qx /usr/local/share/devbox/hooks \
  && ok "the guard still wins inside it" || bad "hooks resolved to: $out"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
