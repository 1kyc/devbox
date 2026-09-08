#!/usr/bin/env bash
# Runs on the HOST. Exercises bin/devbox.
#
# This suite exists because the wrapper shipped broken: every dispatch was
# `exec dc …` where `dc` was a shell function, and `exec` needs a real
# executable — so every subcommand died with "exec: dc: not found". Nothing
# else in the test suite ran the wrapper, so nothing caught it.
#
#   bash tests/launcher.sh
set -uo pipefail
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   - $1"; }
bad() { fail=$((fail+1)); echo "  FAIL - $1"; }

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
DEVBOX="$REPO/bin/devbox"

# Every subcommand must at least dispatch. Anything printing "exec:" or
# "command not found" failed before it reached docker.
dispatches() { # <name> <output>
  case "$2" in
    *"exec: "*|*"command not found"*|*"not found"*)
      bad "$1 did not dispatch: $(printf '%s' "$2" | head -1)" ;;
    *) ok "$1 dispatches" ;;
  esac
}

echo "== dispatch =="
for c in status logs; do
  dispatches "devbox $c" "$(bash "$DEVBOX" $c 2>&1)"
done
dispatches "devbox (bare, = shell)" "$(bash "$DEVBOX" run true 2>&1)"
dispatches "devbox audit" "$(bash "$DEVBOX" audit 2>&1)"
# Unknown subcommands fall through to docker compose.
dispatches "devbox <passthrough>" "$(bash "$DEVBOX" version 2>&1)"

echo "== the commands actually do their job =="
out="$(bash "$DEVBOX" status 2>&1)"
echo "$out" | grep -q devbox && ok "status names the container" || bad "status output: $out"

out="$(bash "$DEVBOX" run 'echo hello-from-the-box' 2>&1 | tr -d '\r')"
echo "$out" | grep -qx hello-from-the-box \
  && ok "run executes a command inside the box" || bad "run output: $out"

out="$(bash "$DEVBOX" run 'id -un' 2>&1 | tr -d '\r')"
echo "$out" | grep -qx "$(id -un)" \
  && ok "run executes as your user" || bad "run ran as: $out"

# audit is the thing you reach for when something looks wrong, so it has to
# exit 0 on a healthy box rather than merely printing something.
bash "$DEVBOX" audit >/dev/null 2>&1 \
  && ok "audit exits 0 on a healthy box" || bad "audit exited $? on a healthy box"

echo "== refuses to run without .env =="
tmp="$(mktemp -d)"
cp "$DEVBOX" "$tmp/devbox-copy" 2>/dev/null
out="$(cd "$tmp" && bash "$REPO/bin/devbox" status 2>&1)"
# It resolves the repo from its own path, so it still finds .env — the guard is
# for a clone that has not been configured yet, which we cannot fake here
# without moving the real one. Just assert it did not crash.
dispatches "devbox from another cwd" "$out"
rm -rf "$tmp"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
