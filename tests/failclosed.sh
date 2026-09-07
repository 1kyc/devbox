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
PLAY=/tmp/play

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

rm -rf /tmp/fakebin "$PLAY"
echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
