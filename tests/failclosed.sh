#!/usr/bin/env bash
# Does the box actually refuse to start when its boundary is not in place?
#
# The check under test is the inverted one: a box holding many repositories asks
# "does this token reach anything that ISN'T here", because the way this design
# rots is a token that gets widened one 403 at a time until it covers the whole
# account.
#
#   docker cp tests/failclosed.sh devbox:/tmp/f.sh
#   docker compose exec devbox bash /tmp/f.sh
set -uo pipefail
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   - $1"; }
bad() { fail=$((fail+1)); echo "  FAIL - $1"; }

SETUP=/usr/local/share/devbox/setup.sh

# This suite writes credential files, Docker configs and shell rc files, and the
# documented way to run it is against the LIVE box — which holds your real
# GitHub login. So it must never touch the real ones.
#
# It used to. An earlier version saved and restored ~/.config/gh/hosts.yml, and
# then a later test added below the restore deleted it again: one run destroyed
# a real login, and the second run went green precisely BECAUSE the credential
# was gone. Backing up and restoring is not enough; the suite has to work
# somewhere else entirely.
REAL_GH="${GH_CONFIG_DIR:-$HOME/.config/gh}"
real_fingerprint() { ( cd "$REAL_GH" 2>/dev/null && md5sum ./* 2>/dev/null ) | md5sum; }
REAL_BEFORE="$(real_fingerprint)"

SANDBOX="$(mktemp -d)"
cleanup() { chmod -R u+w "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX" /tmp/fakebin; }
trap cleanup EXIT

export HOME="$SANDBOX/home"
export GH_CONFIG_DIR="$HOME/.config/gh"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export CODEX_HOME="$HOME/.codex"
PLAY="$SANDBOX/play"
GHCFG="$GH_CONFIG_DIR"
mkdir -p "$GHCFG" "$CLAUDE_CONFIG_DIR" "$CODEX_HOME" "$PLAY"

# A playground containing the named repos (owner/name), plus one local-only repo
# that is not on GitHub at all.
mkplay() {
  rm -rf "$PLAY"; mkdir -p "$PLAY"
  local r
  for r in "$@"; do
    mkdir -p "$PLAY/${r##*/}"
    git init -q "$PLAY/${r##*/}"
    git -C "$PLAY/${r##*/}" remote add origin "https://github.com/$r.git"
  done
  mkdir -p "$PLAY/scratch" && git init -q "$PLAY/scratch"   # no origin
}

# A fake gh whose token kind and repo list we control. Page two is served ONLY
# when --paginate is passed, so a test that depends on it proves the flag is
# really being used rather than that we meant to use it.
mkgh() { # <token> <page1-json> [page2-json]
  mkdir -p /tmp/fakebin
  printf '%s\n' "$2" > /tmp/fakebin/repos.json
  : > /tmp/fakebin/repos-page2.json
  [ -n "${3:-}" ] && printf '%s\n' "$3" > /tmp/fakebin/repos-page2.json
  cat > /tmp/fakebin/gh <<EOF
#!/usr/bin/env bash
case "\$*" in
  "auth status") exit 0 ;;
  "auth token")  echo "$1"; exit 0 ;;
  "auth setup-git") exit 0 ;;
  *"user -q .login") echo tester; exit 0 ;;
  *"user -q .id")    echo 4242; exit 0 ;;
  *--paginate*user/repos*) cat /tmp/fakebin/repos.json /tmp/fakebin/repos-page2.json 2>/dev/null; exit 0 ;;
  *user/repos*)  cat /tmp/fakebin/repos.json; exit 0 ;;
esac
exit 0
EOF
  chmod +x /tmp/fakebin/gh
}

run() { ( export PATH="/tmp/fakebin:$PATH" DEVBOX_PLAYGROUND="$PLAY"; cd "$PLAY" && bash "$SETUP" "$@" 2>&1 ); }

# Exactly the repos in the box, plus the read-only public access GitHub always
# grants a fine-grained token. This is the case that must NOT be rejected.
SCOPED='[
 {"full_name":"tester/alpha","private":false,"permissions":{"push":true}},
 {"full_name":"tester/beta","private":true,"permissions":{"push":true}},
 {"full_name":"someone/oss","private":false,"permissions":{"push":false}}]'
# The same, plus one repo that is NOT checked out here. This is the drift.
DRIFTED='[
 {"full_name":"tester/alpha","private":false,"permissions":{"push":true}},
 {"full_name":"tester/beta","private":true,"permissions":{"push":true}},
 {"full_name":"tester/secrets","private":true,"permissions":{"push":true}}]'
PAGE2='[
 {"full_name":"tester/hidden","private":true,"permissions":{"push":true}}]'
# Everything present, but one of them is read-only.
READONLY_ONE='[
 {"full_name":"tester/alpha","private":false,"permissions":{"push":true}},
 {"full_name":"tester/beta","private":true,"permissions":{"push":false}}]'

echo "== the inverted scope check =="
mkplay tester/alpha tester/beta
mkgh "github_pat_x" "$SCOPED"
out=$(run); rc=$?
{ [ $rc -eq 0 ] && echo "$out" | grep -q "devbox ready"; } \
  && ok "a token scoped to exactly the repos in the box is accepted" \
  || bad "correctly scoped token rejected (rc=$rc): $out"
echo "$out" | grep -q "repos       2 checked out" \
  && ok "counts the 2 GitHub repos and ignores the local-only one" \
  || bad "wrong repo count: $(echo "$out" | grep 'repos ')"

mkgh "github_pat_x" "$DRIFTED"
out=$(run); rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "not checked out in this box"; } \
  && ok "a token reaching a repo that is NOT in the box: REFUSED" \
  || bad "drifted token accepted (rc=$rc): $out"
echo "$out" | grep -q "tester/secrets" \
  && ok "names the offending repository" || bad "did not name the extra repo"
echo "$out" | grep -q "devbox ready" && bad "still printed 'devbox ready'" || ok "did not print 'devbox ready'"

# Without --paginate this token looks perfectly scoped: the extra repo is on
# page two.
mkgh "github_pat_x" "$SCOPED" "$PAGE2"
out=$(run); rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "tester/hidden"; } \
  && ok "an extra repo on PAGE TWO is still caught (--paginate)" \
  || bad "page-two repo missed (rc=$rc): $out"

echo "== capability, which is NOT fatal here =="
# Cloning something you can only read is normal in a multi-repo box, so this
# warns rather than stopping — but it must not be silent, or you find out an
# hour later at `git push`.
mkgh "github_pat_x" "$READONLY_ONE"
out=$(run); rc=$?
{ [ $rc -eq 0 ] && echo "$out" | grep -q "cannot push to these repositories"; } \
  && ok "a repo the token cannot push to: warns, still starts" \
  || bad "no-push handling wrong (rc=$rc): $out"
echo "$out" | grep -q "tester/beta" && ok "names the unpushable repo" || bad "did not name it"

echo "== the empty-playground exception =="
# Nothing is checked out yet, so every repo the token reaches would look extra.
# Failing here would make a fresh box impossible to start before it is used.
rm -rf "$PLAY"; mkdir -p "$PLAY"
mkgh "github_pat_x" "$DRIFTED"
out=$(run); rc=$?
{ [ $rc -eq 0 ] && echo "$out" | grep -q "repos       0 checked out"; } \
  && ok "an empty playground starts instead of failing" \
  || bad "empty playground failed (rc=$rc): $out"

echo "== worktrees do not count as extra repositories =="
mkplay tester/alpha tester/beta
( cd "$PLAY/alpha" && git config user.email t@e.com && git config user.name t \
  && git commit -q --allow-empty -m init \
  && git worktree add -q "$PLAY/alpha.wt" -b feature ) 2>/dev/null
mkgh "github_pat_x" "$SCOPED"
out=$(run); rc=$?
{ [ $rc -eq 0 ] && echo "$out" | grep -q "repos       2 checked out"; } \
  && ok "a worktree resolves to its repo's origin, not a third repo" \
  || bad "worktree miscounted (rc=$rc): $(echo "$out" | grep 'repos ')"

echo "== token kinds =="
mkplay tester/alpha tester/beta
mkgh "ghp_classicclassic" "$SCOPED"
out=$(run); rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "classic token"; } \
  && ok "classic token: REFUSED" || bad "classic not refused (rc=$rc)"

mkgh "gho_oauthoauth" "$SCOPED"
out=$(run); rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "OAuth token"; } \
  && ok "OAuth token: REFUSED" || bad "oauth not refused (rc=$rc)"

mkgh "ghp_classicclassic" "$SCOPED"
out=$(DEVBOX_ALLOW_BROAD_TOKEN=1 run); rc=$?
{ [ $rc -eq 0 ] && echo "$out" | grep -q "DEVBOX_ALLOW_BROAD_TOKEN=1"; } \
  && ok "the override lets a broad token through, loudly" || bad "override failed (rc=$rc)"

echo '== a stored token is checked even when "gh auth status" fails =='
# The regression this guards: keying validation off `gh auth status` meant a
# network failure looked like "not logged in". The token stays on disk and works
# again the moment connectivity returns — and this box runs for weeks without
# re-checking. A classic token used to start the box this way.
mkplay tester/alpha tester/beta
cat > /tmp/fakebin/gh <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "auth status") exit 1 ;;                                    # looks offline
  "auth token")  echo "ghp_classicclassicclassic"; exit 0 ;;  # ...token still stored
esac
exit 1
EOF
chmod +x /tmp/fakebin/gh
out=$(run); rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "classic token"; } \
  && ok "a stored classic token is refused even with auth status failing" \
  || bad "offline classic token started the box (rc=$rc): $out"
echo "$out" | grep -q "gh auth logout" \
  && ok "tells you how to start with no GitHub access at all" \
  || bad "no escape hatch offered"

# ...and a fine-grained token whose scope cannot be read is equally a stop,
# rather than being mistaken for "not logged in".
cat > /tmp/fakebin/gh <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "auth status") exit 1 ;;
  "auth token")  echo "github_pat_x"; exit 0 ;;
esac
exit 1
EOF
chmod +x /tmp/fakebin/gh
out=$(run); rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "scope could not be verified"; } \
  && ok "a stored token of unreadable scope is refused" \
  || bad "unverifiable stored token started the box (rc=$rc)"

# The genuinely-unauthenticated case must still start: NO token on disk.
cat > /tmp/fakebin/gh <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "auth token") exit 1 ;;
esac
exit 1
EOF
chmod +x /tmp/fakebin/gh
out=$(run); rc=$?
{ [ $rc -eq 0 ] && echo "$out" | grep -q "one-time GitHub setup needed"; } \
  && ok "no token stored at all: starts unauthenticated (safe)" \
  || bad "unauthenticated start failed (rc=$rc): $out"

echo "== only one GitHub account may be stored =="
# `gh auth token` returns the ACTIVE account's token, but gh keeps inactive
# accounts fully usable: `gh auth token --user other` hands them over and
# `gh auth switch` promotes them. A narrow active account in front of a classic
# one used to pass, because only the active token was ever examined.
mkplay tester/alpha tester/beta
mkgh "github_pat_x" "$SCOPED"        # the ACTIVE token is perfectly scoped
cat > "$GHCFG/hosts.yml" <<'EOF'
github.com:
    users:
        narrow:
            oauth_token: github_pat_x
        broad:
            oauth_token: ghp_classicbroadtoken
    git_protocol: https
    user: narrow
    oauth_token: github_pat_x
EOF
out=$(run); rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "GitHub credentials are reachable"; } \
  && ok "a second stored account is refused even when the ACTIVE token is fine" \
  || bad "second account accepted (rc=$rc): $out"
echo "$out" | grep -q "gh auth logout -h github.com -u broad" \
  && ok "prints the exact logout command for each account" \
  || bad "no per-account logout command offered"

echo "== an environment token must not shadow a stored one =="
# gh prefers a token from the environment over anything on disk, so GH_TOKEN
# does not REPLACE the stored credential — it hides it. `env -u GH_TOKEN gh auth
# token` produces the stored one again, which an agent can do. Counting accounts
# missed this: one account plus one env token is still one account.
cat > "$GHCFG/hosts.yml" <<'EOF'
github.com:
    users:
        stored:
            oauth_token: ghp_classicSTORED
    user: stored
    oauth_token: ghp_classicSTORED
EOF
mkgh "github_pat_x" "$SCOPED"        # the env token is narrow and well scoped
out=$( export PATH="/tmp/fakebin:$PATH" DEVBOX_PLAYGROUND="$PLAY" GH_TOKEN=github_pat_x; \
       cd "$PLAY" && bash "$SETUP" 2>&1 ); rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "GitHub credentials are reachable"; } \
  && ok "a narrow GH_TOKEN over a stored classic token: REFUSED" \
  || bad "env token hid a stored token (rc=$rc): $out"
echo "$out" | grep -q "environment/GH_TOKEN" \
  && ok "names the environment variable as a credential source" \
  || bad "did not list the env token"
echo "$out" | grep -q "unset GH_TOKEN" \
  && ok "tells you to unset it" || bad "no unset instruction"
rm -f "$GHCFG/hosts.yml"

# An env token on its own is a legitimate single credential.
out=$( export PATH="/tmp/fakebin:$PATH" DEVBOX_PLAYGROUND="$PLAY" GH_TOKEN=github_pat_x; \
       cd "$PLAY" && bash "$SETUP" 2>&1 ); rc=$?
[ $rc -eq 0 ] && ok "GH_TOKEN alone, with nothing stored, is accepted" \
  || bad "lone env token rejected (rc=$rc): $out"

# GITHUB_TOKEN is the other name gh honours.
cat > "$GHCFG/hosts.yml" <<'EOF'
github.com:
    users:
        stored:
            oauth_token: ghp_classicSTORED
    user: stored
    oauth_token: ghp_classicSTORED
EOF
out=$( export PATH="/tmp/fakebin:$PATH" DEVBOX_PLAYGROUND="$PLAY" GITHUB_TOKEN=github_pat_x; \
       cd "$PLAY" && bash "$SETUP" 2>&1 ); rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "environment/GITHUB_TOKEN"; } \
  && ok "GITHUB_TOKEN counts as a credential source too" \
  || bad "GITHUB_TOKEN not counted (rc=$rc)"
rm -f "$GHCFG/hosts.yml"

# One account must still be fine, including a 2-space file.
cat > "$GHCFG/hosts.yml" <<'EOF'
github.com:
  users:
    narrow:
      oauth_token: github_pat_x
  git_protocol: https
  user: narrow
  oauth_token: github_pat_x
EOF
out=$(run); rc=$?
[ $rc -eq 0 ] && ok "a single account parses and passes (2-space indent)" \
  || bad "single account rejected (rc=$rc): $out"
rm -f "$GHCFG/hosts.yml"

echo "== a credential for another host is not mistaken for no credential =="
# `gh auth token` resolves github.com. A credential gh holds for a different
# host returns nothing there, which used to take the "not logged in" exit
# BEFORE enumeration ran — while `gh auth token --hostname ghe.example` handed
# it over perfectly well. Enumeration has to come first.
rm -f "$GHCFG/hosts.yml"
mkplay tester/alpha tester/beta
cat > /tmp/fakebin/gh <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "auth token")  exit 1 ;;          # nothing for github.com
  "auth status") exit 1 ;;
esac
exit 1
EOF
chmod +x /tmp/fakebin/gh
out=$( export PATH="/tmp/fakebin:$PATH" DEVBOX_PLAYGROUND="$PLAY" \
              GH_ENTERPRISE_TOKEN=ghp_enterpriseONE; \
       cd "$PLAY" && bash "$SETUP" 2>&1 ); rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "cannot verify"; } \
  && ok "a lone enterprise credential is refused, not read as unauthenticated" \
  || bad "enterprise-only credential started the box (rc=$rc): $out"
echo "$out" | grep -q "environment/GH_ENTERPRISE_TOKEN" \
  && ok "names the enterprise variable" || bad "did not name it"

# Two of them, with nothing for github.com: still caught, and counted as two.
out=$( export PATH="/tmp/fakebin:$PATH" DEVBOX_PLAYGROUND="$PLAY" \
              GH_ENTERPRISE_TOKEN=ghp_one GITHUB_ENTERPRISE_TOKEN=ghp_two; \
       cd "$PLAY" && bash "$SETUP" 2>&1 ); rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "2 GitHub credentials are reachable"; } \
  && ok "two enterprise credentials count as two, not zero" \
  || bad "enterprise pair miscounted (rc=$rc): $out"

# And with genuinely nothing set, the same fake gh must still start the box.
out=$( export PATH="/tmp/fakebin:$PATH" DEVBOX_PLAYGROUND="$PLAY"; \
       cd "$PLAY" && bash "$SETUP" 2>&1 ); rc=$?
{ [ $rc -eq 0 ] && echo "$out" | grep -q "one-time GitHub setup needed"; } \
  && ok "zero sources still means unauthenticated, not failure" \
  || bad "zero-source start broke (rc=$rc): $out"

# A token gh will hand over that enumeration cannot attribute — a keyring, or a
# config shape the parser does not know — is still a credential. Counting only
# enumerated sources called this "not logged in" and started the box.
rm -f "$GHCFG/hosts.yml"
mkgh "ghp_classicKEYRING" "$SCOPED"   # returns a token; nothing on disk explains it
out=$(run); rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "classic token"; } \
  && ok "a token with no enumerable source is still checked" \
  || bad "unattributed token was ignored (rc=$rc): $out"

echo "== GH_CONFIG_DIR must not hide the default store =="
# gh prefers GH_CONFIG_DIR over ~/.config/gh, so pointing it at an empty
# directory made `gh auth token` return nothing AND made a store-of-one check
# find nothing — the two agreed there were no credentials while the default
# store still held a token, one dropped variable away.
mkplay tester/alpha tester/beta
mkdir -p "$HOME/.config/gh" "$SANDBOX/emptycfg"
cat > "$HOME/.config/gh/hosts.yml" <<'EOF'
github.com:
    users:
        hidden:
            oauth_token: ghp_classicHIDDEN
    user: hidden
    oauth_token: ghp_classicHIDDEN
EOF
cat > /tmp/fakebin/gh <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "auth token")  exit 1 ;;      # the override points somewhere empty
  "auth status") exit 1 ;;
esac
exit 1
EOF
chmod +x /tmp/fakebin/gh
out=$( export PATH="/tmp/fakebin:$PATH" DEVBOX_PLAYGROUND="$PLAY" GH_CONFIG_DIR="$SANDBOX/emptycfg"; \
       cd "$PLAY" && bash "$SETUP" 2>&1 ); rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "github.com/hidden"; } \
  && ok "a store hidden behind GH_CONFIG_DIR is still found" \
  || bad "default store hidden by GH_CONFIG_DIR (rc=$rc): $out"
echo "$out" | grep -q "GH_CONFIG_DIR=.* gh auth logout -h github.com -u hidden" \
  && ok "the logout command names the store it lives in" \
  || bad "no store-qualified logout command: $out"

# XDG_CONFIG_HOME is the other way the default location moves.
rm -f "$HOME/.config/gh/hosts.yml"
mkdir -p "$SANDBOX/xdg/gh"
cat > "$SANDBOX/xdg/gh/hosts.yml" <<'EOF'
github.com:
    users:
        xdguser:
            oauth_token: ghp_classicXDG
    user: xdguser
    oauth_token: ghp_classicXDG
EOF
out=$( export PATH="/tmp/fakebin:$PATH" DEVBOX_PLAYGROUND="$PLAY" \
              GH_CONFIG_DIR="$SANDBOX/emptycfg" XDG_CONFIG_HOME="$SANDBOX/xdg"; \
       cd "$PLAY" && bash "$SETUP" 2>&1 ); rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "github.com/xdguser"; } \
  && ok "an XDG_CONFIG_HOME store is found too" \
  || bad "XDG store missed (rc=$rc): $out"
rm -rf "$SANDBOX/xdg" "$SANDBOX/emptycfg"

echo "== undeletable Docker credentials are fatal, not announced as deleted =="
# The message used to claim deletion regardless of whether rm worked.
rm -rf "$HOME/.docker"; mkdir -p "$HOME/.docker"
printf '{"auths":{"ghcr.io":{"auth":"ZmFrZQ=="}}}\n' > "$HOME/.docker/config.json"
chmod 500 "$HOME/.docker"            # readable, not writable: rm must fail
mkgh "github_pat_x" "$SCOPED"
out=$(run); rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "COULD NOT REMOVE host Docker"; } \
  && ok "credentials it cannot delete are fatal" \
  || bad "undeletable docker creds did not stop the box (rc=$rc): $out"
echo "$out" | grep -q "deleted host Docker" \
  && bad "still claims it deleted them" || ok "does not claim a deletion that failed"
chmod 700 "$HOME/.docker"

# ...and when it CAN delete them, it does, and says so.
out=$(run); rc=$?
{ [ $rc -eq 0 ] && [ ! -e "$HOME/.docker/config.json" ] \
  && echo "$out" | grep -q "deleted host Docker"; } \
  && ok "credentials it can delete are removed and the box starts" \
  || bad "deletable docker creds mishandled (rc=$rc)"
rm -rf "$HOME/.docker"

echo "== --audit checks token scope too =="
mkgh "github_pat_x" "$DRIFTED"
out=$( export PATH="/tmp/fakebin:$PATH" DEVBOX_PLAYGROUND="$PLAY"; cd "$PLAY" && bash "$SETUP" --audit 2>&1 ); rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "not checked out in this box"; } \
  && ok "audit catches a drifted token (not just guards)" \
  || bad "audit ignored token scope (rc=$rc): $out"
mkgh "github_pat_x" "$SCOPED"
( export PATH="/tmp/fakebin:$PATH" DEVBOX_PLAYGROUND="$PLAY"; cd "$PLAY" && bash "$SETUP" --audit >/dev/null 2>&1 ) \
  && ok "audit still passes on a correctly scoped token" || bad "audit false positive"

echo "== an unremovable credential bridge is fatal at STARTUP =="
# Previously `check_host_bleed || true`: the check ran, found something it could
# not remove, and the box started anyway. Nothing here re-runs audit on a
# schedule, so boot is the only automatic check there is.
#
# Simulated with a live agent socket in a directory we can read but not write,
# which is exactly the "detected but unremovable" shape.
LOCK="$SANDBOX/lockdir"
rm -rf "$LOCK"; mkdir -p "$LOCK"
perl -MIO::Socket::UNIX -e \
  'IO::Socket::UNIX->new(Local=>q('"$LOCK"'/vscode-ssh-auth-x.sock), Listen=>1) or die; sleep 60' &
sockpid=$!
timeout 10 bash -c "until [ -S $LOCK/vscode-ssh-auth-x.sock ]; do :; done"
chmod 500 "$LOCK"
if [ -S "$LOCK/vscode-ssh-auth-x.sock" ]; then
  mkgh "github_pat_x" "$SCOPED"
  out=$( export PATH="/tmp/fakebin:$PATH" DEVBOX_PLAYGROUND="$PLAY" TMPDIR="$LOCK"; \
         cd "$PLAY" && bash "$SETUP" 2>&1 ); rc=$?
  { [ $rc -ne 0 ] && echo "$out" | grep -q "COULD NOT REMOVE"; } \
    && ok "startup FAILS on a bridge it cannot remove" \
    || bad "startup continued despite an unremovable bridge (rc=$rc): $out"
  echo "$out" | grep -q "devbox ready" && bad "still printed 'devbox ready'" || ok "did not print 'devbox ready'"
else
  bad "could not create the locked socket (test inconclusive)"
fi
kill "${sockpid:-0}" 2>/dev/null
chmod 700 "$LOCK" 2>/dev/null; rm -rf "$LOCK"

echo "== a socket it CAN remove is removed, and startup continues =="
mkgh "github_pat_x" "$SCOPED"
FREE="$SANDBOX/freedir"; rm -rf "$FREE"; mkdir -p "$FREE"
perl -MIO::Socket::UNIX -e \
  'IO::Socket::UNIX->new(Local=>q('"$FREE"'/vscode-ssh-auth-y.sock), Listen=>1) or die; sleep 60' &
sockpid=$!
timeout 10 bash -c "until [ -S $FREE/vscode-ssh-auth-y.sock ]; do :; done"
out=$( export PATH="/tmp/fakebin:$PATH" DEVBOX_PLAYGROUND="$PLAY" TMPDIR="$FREE"; \
       cd "$PLAY" && bash "$SETUP" 2>&1 ); rc=$?
{ [ $rc -eq 0 ] && [ ! -e "$FREE/vscode-ssh-auth-y.sock" ]; } \
  && ok "removable socket is deleted and the box still starts" \
  || bad "removable socket handling wrong (rc=$rc, socket present: $([ -e "$FREE/vscode-ssh-auth-y.sock" ] && echo yes || echo no))"
kill "${sockpid:-0}" 2>/dev/null; rm -rf "$FREE"

echo "== a dangling SSH_AUTH_SOCK is inert, not fatal =="
mkgh "github_pat_x" "$SCOPED"
out=$( export PATH="/tmp/fakebin:$PATH" DEVBOX_PLAYGROUND="$PLAY" SSH_AUTH_SOCK=/tmp/nothing-here.sock; \
       cd "$PLAY" && bash "$SETUP" 2>&1 ); rc=$?
{ [ $rc -eq 0 ] && echo "$out" | grep -q "Nothing is listening there"; } \
  && ok "a value pointing at no socket warns but does not stop the box" \
  || bad "dangling SSH_AUTH_SOCK handling wrong (rc=$rc): $out"

echo "== unverifiable vs offline =="
# A token that authenticates but whose scope cannot be read is a stop: unknown
# scope is not something to point an unattended agent at.
cat > /tmp/fakebin/gh <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "auth status") exit 0 ;;
  "auth token")  echo "github_pat_x"; exit 0 ;;
  *user/repos*)  exit 1 ;;
esac
exit 0
EOF
chmod +x /tmp/fakebin/gh
out=$(run); rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "scope could not be verified"; } \
  && ok "an authenticated token of UNVERIFIABLE scope is refused" \
  || bad "unverifiable scope allowed (rc=$rc): $out"

# ...but being genuinely offline must NOT fail the box: gh auth status fails
# first, so it comes up unauthenticated, which is safe.
printf '#!/usr/bin/env bash\nexit 1\n' > /tmp/fakebin/gh && chmod +x /tmp/fakebin/gh
out=$(run); rc=$?
{ [ $rc -eq 0 ] && echo "$out" | grep -q "one-time GitHub setup needed"; } \
  && ok "fully offline comes up unauthenticated rather than failing" \
  || bad "offline start failed (rc=$rc): $out"

echo "== malformed API answer is not read as 'narrow' =="
mkgh "github_pat_x" 'this is not json'
out=$(run); rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "could not be parsed"; } \
  && ok "an unparseable answer is a stop, not an empty scope" \
  || bad "malformed json was treated as narrow (rc=$rc): $out"


echo "== the suite left the real credential store alone =="
# The check on the checker. A green run that quietly deleted your GitHub login
# is worse than a red one, and the second run would go green *because* of it.
[ "$(real_fingerprint)" = "$REAL_BEFORE" ] \
  && ok "$REAL_GH is byte-identical to before the run" \
  || bad "THE SUITE MODIFIED $REAL_GH — real credentials may have been destroyed"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
