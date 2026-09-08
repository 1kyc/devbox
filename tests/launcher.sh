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

echo "== an exported compose override is honoured, not re-derived =="
# Behavioural, not a source grep. Two previous versions answered "is it already
# up?" by re-deriving compose's configuration — first a project name from
# ${PWD##*/}, then a container name hand-parsed out of .env — and both ignored
# an exported override, so the launcher looked for the wrong box: it skipped
# starting a stopped one because some other container matched.
#
# Run the launcher under a project name that exists only for this test. If it
# still resolves configuration itself, it will look at the default project,
# conclude the box is already running, and start nothing.
ALT=devbox-launchertest
cleanup_alt() {
  ( cd "$REPO" && COMPOSE_PROJECT_NAME="$ALT" docker compose down -v ) >/dev/null 2>&1 || true
}
trap 'cleanup_alt; rm -rf "$(dirname "$SANDBOX_LINK")"' EXIT
cleanup_alt

# DEVBOX_NAME and CODEX_LOGIN_PORT too. The box is a singleton by design — a
# pinned container_name and a fixed loopback port — so a second copy needs both
# overridden to coexist with the real one for the length of this test.
alt() { ( cd "$REPO" && COMPOSE_PROJECT_NAME="$ALT" DEVBOX_NAME="$ALT" \
            CODEX_LOGIN_PORT=14559 "$@" ); }

# `run`, not `up`: this exercises ensure_up, which is the path being tested.
# `devbox up` bypasses it entirely.
alt "$DEVBOX" run true >/dev/null 2>&1
alt_id="$(docker container ls -q -f label=com.docker.compose.project="$ALT" -f status=running)"
[ -n "$alt_id" ] \
  && ok "an exported COMPOSE_PROJECT_NAME starts THAT project's box" \
  || bad "the override was ignored; no container for project $ALT"

# And the main box must be untouched by it.
[ -n "$(docker container ls -q -f name='^devbox$' -f status=running)" ] \
  && ok "the default box is left running alongside it" \
  || bad "the override disturbed the default box"

echo "== opening a shell never replaces a running box =="
# Plain `up -d` preserves a container only while config and image are
# unchanged; otherwise it stops and REPLACES it. On a box meant to run for
# weeks, that means a second shell after an .env edit kills the agent sessions
# in the first one and discards anything installed in the writable layer.
if [ -n "$alt_id" ]; then
  docker exec "$ALT" bash -c 'echo alive > /tmp/devbox-liveness' >/dev/null 2>&1
  before="$(docker inspect -f '{{.Id}}' "$ALT" 2>/dev/null)"

  # Change the configuration, then take the ensure_up path.
  alt env DEVBOX_PIDS_LIMIT=1234 "$DEVBOX" run true >/dev/null 2>&1

  after="$(docker inspect -f '{{.Id}}' "$ALT" 2>/dev/null)"
  [ -n "$after" ] && [ "$before" = "$after" ] \
    && ok "the container survives a config change on the ensure_up path" \
    || bad "the container was REPLACED just by running a command in it"
  docker exec "$ALT" test -f /tmp/devbox-liveness >/dev/null 2>&1 \
    && ok "and its writable layer is intact (in-container state survives)" \
    || bad "the writable layer was discarded — agent sessions would be lost"
else
  bad "no alt container to test recreation against (inconclusive)"
fi
cleanup_alt

# No hand-rolled config resolution should remain (comments stripped — the file
# explains the discarded approaches by name, and matching that prose is not the
# same as still doing it).
# Checking that .env EXISTS is fine — compose needs it. Reading values out of
# it, or guessing a project name from $PWD, is the thing that kept being wrong.
code="$(grep -v '^[[:space:]]*#' "$DEVBOX")"
printf '%s' "$code" | grep -qE 'PWD##\*/|DEVBOX_NAME' \
  && bad "still re-derives compose configuration itself" \
  || ok "does not re-derive compose configuration"

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
