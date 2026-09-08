#!/usr/bin/env bash
# Runs INSIDE the box. Checks the things that are supposed to be true of it.
#
#   docker cp tests/in-container.sh devbox:/tmp/t.sh
#   docker compose exec devbox bash /tmp/t.sh
set -uo pipefail
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   - $1"; }
bad() { fail=$((fail+1)); echo "  FAIL - $1"; }

PLAYGROUND="${DEVBOX_PLAYGROUND:-/home/kyc/dev}"

echo "== identity =="
[ "$(id -un)" = "$(stat -c %U "$PLAYGROUND")" ] \
  && ok "container user owns the playground ($(id -un), uid $(id -u))" \
  || bad "uid mismatch: running as $(id -un)/$(id -u), playground owned by $(stat -c %U "$PLAYGROUND")"
sudo -n true 2>/dev/null && bad "sudo is available (should not be)" || ok "no sudo"
[ "$(id -u)" = 1000 ] && ok "uid is 1000" || bad "uid is $(id -u)"

echo "== the playground is mounted at the same absolute path as on the host =="
# If this is wrong, worktrees break in both directions. Everything else about
# the box still works, which is exactly why it needs an explicit test.
[ -d "$PLAYGROUND" ] && ok "$PLAYGROUND exists inside the container" || bad "$PLAYGROUND missing"
[ "$(pwd -P)" = "$PLAYGROUND" ] || cd "$PLAYGROUND"
mnt="$(awk -v p="$PLAYGROUND" '$2 == p {found=1} END {print found+0}' /proc/mounts)"
[ "$mnt" = 1 ] && ok "$PLAYGROUND is a mount point, not an image directory" \
  || bad "$PLAYGROUND is not mounted (agent writes would vanish on recreate)"

echo "== tools =="
for t in claude codex gh git jq python3 node npm uv fnm rg; do
  command -v "$t" >/dev/null && ok "$t on PATH ($(command -v $t))" || bad "$t missing"
done
claude --version >/dev/null 2>&1 && ok "claude runs: $(claude --version 2>&1 | head -1)" || bad "claude runs"
codex  --version >/dev/null 2>&1 && ok "codex runs: $(codex --version 2>&1 | head -1)"   || bad "codex runs"
ok "python is $(python3 --version 2>&1), node is $(node --version 2>&1)"

echo "== login shells keep the guard dir on PATH =="
# /etc/profile resets PATH for login shells; without /etc/profile.d/10-devbox-path.sh
# `bash -lc 'gh pr merge'` would reach the real gh and walk past the shim.
[ "$(bash -lc 'command -v gh')" = /usr/local/share/devbox/bin/gh ] \
  && ok "bash -l resolves gh to the shim" || bad "bash -l gh -> $(bash -lc 'command -v gh')"
bash -lc 'command -v node >/dev/null' && ok "bash -l has node" || bad "bash -l lost node"
bash -lc 'command -v claude >/dev/null' && ok "bash -l has claude" || bad "bash -l lost claude"

echo "== programs live on the image, not in a volume =="
# A volume mounted over an image directory HIDES the image's copy: anything
# installed under one is copied into the volume once and then never tracks the
# image again, so a rebuild silently keeps serving the old program.
[ ! -e "$HOME/.codex/packages" ] \
  && ok "the codex package is not under the ~/.codex mount point" \
  || bad "codex installed into its volume ($(du -sh $HOME/.codex | cut -f1))"
readlink "$HOME/.local/bin/codex" | grep -q '^/home/[^/]*/\.local/share/codex/' \
  && ok "codex symlink points at the image" \
  || bad "codex symlink -> $(readlink $HOME/.local/bin/codex)"
for d in .claude .codex .config/gh .cache/uv .npm; do
  awk -v p="$HOME/$d" '$2 == p {f=1} END {exit !f}' /proc/mounts \
    && ok "~/$d is a volume (persists)" || bad "~/$d is NOT a volume"
done
awk -v p="$HOME/.local" '$2 == p {f=1} END {exit f}' /proc/mounts \
  && ok "~/.local is NOT a volume (programs track the image)" \
  || bad "~/.local is a volume; rebuilds will not update the agents"

echo "== guards are root-owned and unwritable by the agent =="
for f in /usr/local/share/devbox/bin/gh /usr/local/share/devbox/hooks/pre-push \
         /usr/local/share/devbox/setup.sh; do
  [ -x "$f" ] && ok "$(basename $f) exists and is executable" || bad "$f executable"
  [ "$(stat -c %U "$f")" = root ] && ok "$(basename $f) owned by root" || bad "$f owned by root"
  ( : > "$f" ) 2>/dev/null && bad "$f is writable by the agent!" || ok "$(basename $f) not agent-writable"
done

echo "== hook wiring =="
mkdir -p /tmp/t && cd /tmp/t
[ "$(git config --get core.hooksPath)" = /usr/local/share/devbox/hooks ] \
  && ok "core.hooksPath comes from the environment" \
  || bad "core.hooksPath = $(git config --get core.hooksPath)"

rm -rf repo remote.git && git init -q repo && cd repo
git config user.email t@example.com && git config user.name t
echo hi > a.txt && git add a.txt && git commit -qm init && git branch -M main
git init -q --bare /tmp/t/remote.git && git remote add origin /tmp/t/remote.git

git config core.hooksPath /tmp/evil-hooks && mkdir -p /tmp/evil-hooks
[ "$(git rev-parse --git-path hooks)" = /usr/local/share/devbox/hooks ] \
  && ok "repo-local core.hooksPath cannot displace the guard" \
  || bad "repo-local hooksPath won: $(git rev-parse --git-path hooks)"

out=$(git push origin main 2>&1); rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "refusing to push to 'main'"; } \
  && ok "push to main is blocked" || bad "push to main (rc=$rc): $out"

git switch -qc feature
git push -q origin feature 2>&1 && ok "push to a feature branch succeeds" || bad "push feature failed"

echo "== the guard also covers worktrees =="
# core.hooksPath is global, so a worktree inherits it. Worth proving: worktrees
# are the whole reason for the path-identical mount, and a guard that stopped at
# the main checkout would be a hole exactly where parallel agents run.
cd /tmp/t/repo && git worktree add -q /tmp/t/wt -b wt-branch 2>/dev/null
if [ -d /tmp/t/wt ]; then
  cd /tmp/t/wt
  [ "$(git rev-parse --git-path hooks)" = /usr/local/share/devbox/hooks ] \
    && ok "guard is active inside a worktree" || bad "worktree hooksPath escaped the guard"
  git branch -M main 2>/dev/null
  out=$(git push origin main 2>&1); rc=$?
  { [ $rc -ne 0 ] && echo "$out" | grep -q "refusing to push"; } \
    && ok "push to main from a worktree is blocked" || bad "worktree push to main (rc=$rc)"
  cd /tmp/t/repo && git worktree remove --force /tmp/t/wt 2>/dev/null
else
  bad "could not create a worktree (test inconclusive)"
fi

echo "== protected branches tolerate any whitespace, as documented =="
# The list is documented "space separated" and was consumed by `for p in
# $protected`, which splits on IFS. A flattening to a literal-space glob kept
# "main master" working and silently stopped protecting main for a tab or a
# newline — a widening you would only discover from a push that succeeded.
cd /tmp/t/repo && git switch -q main 2>/dev/null || git checkout -q main 2>/dev/null
for sep in ' ' '	' '
'; do
  out=$(DEVBOX_PROTECTED_BRANCHES="main${sep}master" git push origin main 2>&1); rc=$?
  case "$sep" in
    ' ')  label="space" ;;
    '	') label="tab" ;;
    *)    label="newline" ;;
  esac
  { [ $rc -ne 0 ] && echo "$out" | grep -q "refusing to push"; } \
    && ok "separated by a $label: push to main refused" \
    || bad "separated by a $label: push to main ALLOWED (rc=$rc)"
done
# An empty value must still mean "protect nothing".
git push -q origin main 2>/dev/null; rc=$?
out=$(DEVBOX_PROTECTED_BRANCHES="" git push origin main 2>&1); rc=$?
[ $rc -eq 0 ] && ok "an empty list still disables the guard" \
  || bad "empty list did not disable the guard (rc=$rc): $out"

echo "== gh merge shim =="
out=$(gh pr merge 1 2>&1); rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "merging is disabled"; } \
  && ok "gh pr merge is blocked" || bad "gh pr merge (rc=$rc): $out"
out=$(gh api -X PUT repos/o/r/pulls/1/merge 2>&1); rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "merging is disabled"; } \
  && ok "the REST merge endpoint is blocked too" || bad "REST merge (rc=$rc): $out"
out=$(DEVBOX_ALLOW_MERGE=1 gh pr merge 2>&1); rc=$?
echo "$out" | grep -q "merging is disabled" \
  && bad "DEVBOX_ALLOW_MERGE=1 did not lift the block" \
  || ok "DEVBOX_ALLOW_MERGE=1 lifts the block"
[ "$(bash -lc 'command -v gh')" = /usr/local/share/devbox/bin/gh ] \
  && ok "the shim is not bypassable via a login shell" || bad "login shell bypasses the shim"

echo "== setup.sh =="
cd "$PLAYGROUND"
out=$(/usr/local/share/devbox/setup.sh 2>&1); rc=$?
[ $rc -eq 0 ] && ok "setup.sh exits 0" || bad "setup.sh rc=$rc: $out"
[ -f "$HOME/.claude/settings.json" ] && ok "seeded ~/.claude/settings.json" || bad "claude settings"
jq -e '.permissions.defaultMode == "bypassPermissions"' "$HOME/.claude/settings.json" >/dev/null \
  && ok "claude is in bypass mode" || bad "claude bypass setting"
jq -e 'has("autoUpdatesChannel")' "$HOME/.claude/settings.json" >/dev/null \
  && ok "merged into the installer's settings instead of clobbering them" \
  || bad "the installer's own settings key was lost"
grep -q 'danger-full-access' "$HOME/.codex/config.toml" \
  && ok "codex is in bypass mode" || bad "codex bypass setting"

# Your edits must survive a restart.
jq '.permissions.defaultMode = "acceptEdits"' "$HOME/.claude/settings.json" > /tmp/s \
  && mv /tmp/s "$HOME/.claude/settings.json"
/usr/local/share/devbox/setup.sh --quiet >/dev/null 2>&1
jq -e '.permissions.defaultMode == "acceptEdits"' "$HOME/.claude/settings.json" >/dev/null \
  && ok "a later start does not re-impose the default over your edit" \
  || bad "setup.sh overwrote a user edit"
jq '.permissions.defaultMode = "bypassPermissions"' "$HOME/.claude/settings.json" > /tmp/s \
  && mv /tmp/s "$HOME/.claude/settings.json"

grep -q "devbox shell setup" "$HOME/.bashrc" && ok "bashrc block added" || bad "bashrc block"
/usr/local/share/devbox/setup.sh --quiet >/dev/null 2>&1
[ "$(grep -c 'devbox shell setup' "$HOME/.bashrc")" = 1 ] \
  && ok "bashrc block is not duplicated on re-run" || bad "bashrc duplicated"

echo "== ssh remotes resolve over https without touching the repo's config =="
( cd /tmp && rm -rf sshtest && git init -q sshtest && cd sshtest \
  && git remote add origin git@github.com:1kyc/example.git \
  && [ "$(git ls-remote --get-url origin)" = "https://github.com/1kyc/example.git" ] \
  && [ "$(git config --get remote.origin.url)" = "git@github.com:1kyc/example.git" ] ) \
  && ok "insteadOf rewrites the URL in-container only" || bad "insteadOf rule"

echo "== credential helper chain =="
helpers="$(git config --show-origin --get-all credential.helper 2>/dev/null)"
echo "$helpers" | grep -q 'gh auth git-credential' \
  && ok "gh's credential helper is configured" || bad "gh helper missing: $helpers"
# --get-all prints "<origin>:<TAB><value>", so an EMPTY helper — the entry that
# resets the accumulated chain — comes out as a line ending at the tab. That one
# is wanted; anything else that is not gh's is a leak.
echo "$helpers" | grep -vE '(gh auth git-credential|:[[:space:]]*$)' | grep -q . \
  && bad "a foreign credential helper is present: $helpers" \
  || ok "the chain is exactly: reset, then gh's helper"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
