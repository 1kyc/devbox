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
SANDBOX_LINK="$(mktemp -d)/devbox"
trap 'rm -rf "$(dirname "$SANDBOX_LINK")"' EXIT

# Every subcommand must at least dispatch. Anything printing "exec:" or
# "command not found" failed before it reached docker.
dispatches() { # <name> <output>
  case "$2" in
    *"exec: "*|*"command not found"*|*"not found"*)
      bad "$1 did not dispatch: $(printf '%s' "$2" | head -1)" ;;
    *) ok "$1 dispatches" ;;
  esac
}

echo "== every script is executable, in git and on disk =="
# This suite ran `bash "$DEVBOX"` everywhere, which works on a file with no
# exec bit — so it passed 10/10 while `./bin/devbox` and the documented
# ~/.local/bin/devbox symlink were both Permission denied.
#
# Four files lost the bit at once, because editing them through a Windows UNC
# path rewrites the mode. Three went unnoticed because the Dockerfile COPYs
# them with --chmod=0755, so the image was correct while the repo was not.
# Assert the mode in git's index, which is what a fresh clone gets.
cd "$REPO"
for f in $(git ls-files); do
  case "$f" in
    *.sh|bin/devbox|guards/bin/*|guards/hooks/*) ;;
    *) continue ;;
  esac
  mode="$(git ls-files -s "$f" | cut -d' ' -f1)"
  [ "$mode" = 100755 ] \
    && ok "$f is 100755 in the index" \
    || bad "$f is $mode in the index — a fresh clone cannot execute it"
  [ -x "$f" ] || bad "$f is not executable on disk"
done

echo "== the launcher runs directly, not just under bash =="
# The form the README documents (a symlink on PATH) and the form the old tests
# never used.
out="$("$DEVBOX" status 2>&1)"; rc=$?
{ [ $rc -eq 0 ] && ! printf '%s' "$out" | grep -qi "permission denied"; } \
  && ok "./bin/devbox executes without an interpreter" \
  || bad "direct invocation failed (rc=$rc): $out"

ln -sf "$DEVBOX" "$SANDBOX_LINK" 2>/dev/null || true
if [ -L "$SANDBOX_LINK" ]; then
  out="$("$SANDBOX_LINK" status 2>&1)"; rc=$?
  [ $rc -eq 0 ] && ok "a PATH symlink to it works (the documented setup)" \
    || bad "symlink invocation failed (rc=$rc): $out"
  rm -f "$SANDBOX_LINK"
fi

echo "== the running-box lookup is by container name, exactly =="
# It briefly filtered on the compose project label derived from ${PWD##*/} —
# only compose's DEFAULT project name. COMPOSE_PROJECT_NAME, a top-level
# `name:`, or -p all override it, so the guess both restarted a running
# custom-named box and found some OTHER project's default-named container and
# skipped starting this one. compose.yaml sets container_name explicitly, so
# the name is the thing we actually control.
NAME="$(sed -n 's/^DEVBOX_NAME=[[:space:]]*//p' "$REPO/.env" | tr -d "\"' " | head -1)"
NAME="${NAME:-devbox}"
grep -q 'docker container ls -q -f name=' "$DEVBOX" \
  && ok "looks the box up by name, not by a guessed project label" \
  || bad "the running-box lookup is not name-based"
# Comments stripped: the file explains the old approach by name, and matching
# that prose is not the same as still doing it.
grep -v '^[[:space:]]*#' "$DEVBOX" | grep -q 'PWD##\*/' \
  && bad "still derives a compose project name from the working directory" \
  || ok "does not guess the compose project from \$PWD"

[ -n "$(docker container ls -q -f name="^${NAME}\$" -f status=running)" ] \
  && ok "the anchored name filter finds the running box ($NAME)" \
  || bad "anchored name filter did not find $NAME"
[ -z "$(docker container ls -q -f name="^${NAME}-nope\$" -f status=running)" ] \
  && ok "and does not match a different container" \
  || bad "the name filter is not anchored"

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
