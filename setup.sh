#!/usr/bin/env bash
# devbox setup — runs at container boot, before the box is usable.
#
#   setup.sh            full run, prints a summary   (compose `command`)
#   setup.sh --quiet    same work, speaks up only when needed
#   setup.sh --audit    host-bleed and guard checks only
#
# None of it needs root: the container runs with cap-drop=ALL +
# no-new-privileges, so sudo is unavailable by design.
#
# This file lives on the IMAGE at /usr/local/share/devbox/setup.sh, root-owned —
# not in a mounted repo. An agent in bypass mode can edit anything it can reach,
# and the script that decides whether the box is safe to start should not be one
# of those things. Change it by editing this file in the devbox repo (which is
# deliberately outside the playground) and rebuilding.
#
# It FAILS rather than warns when the isolation this box promises is not in
# place. A failure exits non-zero, which kills the container's command, which
# means the box does not come up — better than one that quietly reports "devbox
# ready" while an agent holds your whole account.
set -uo pipefail

MODE=full
case "${1:-}" in
  --quiet) MODE=quiet ;;
  --audit) MODE=audit ;;
esac
QUIET=0
[ "$MODE" = full ] || QUIET=1

say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { warn ""; warn "  xx devbox: $*"; warn ""; exit 1; }
must() { "$@" || die "required setup step failed: $*"; }

# The one folder this box can see. Everything outside it is unreachable, which
# is the whole security model.
PLAYGROUND="${DEVBOX_PLAYGROUND:-$PWD}"
# How deep to look for repositories. 3 covers ~/dev/repo, ~/dev/org/repo and the
# worktree convention ~/dev/repo.wt/branch without walking node_modules forever.
SCAN_DEPTH="${DEVBOX_SCAN_DEPTH:-3}"

# ---------------------------------------------------------------------------
# Checks that run in every mode.
# ---------------------------------------------------------------------------

# Keep the host out.
#
# Nothing should trigger any of this. Unlike the dev container this grew out of,
# there is no editor server in here copying your ~/.gitconfig in, installing a
# credential helper that bridges to your host's credential store, or forwarding
# your SSH agent — dropping that bridge is a large part of why this is plain
# Compose (see DESIGN.md).
#
# It stays because "Attach to Running Container" is one click away in VS Code,
# and doing that re-creates every one of those channels. This is the backstop
# for the day someone does.
#
# Returns non-zero only when something dangerous is still in place afterwards.
check_host_bleed() {
  local leaks=0 unfixed=0

  # Nothing in here uses Docker, so copied registry credentials are pure risk.
  # This file is in the container's own filesystem; deleting it touches nothing
  # on your host.
  if [ -s "$HOME/.docker/config.json" ] \
     && grep -q '"auths"' "$HOME/.docker/config.json" 2>/dev/null; then
    leaks=1
    warn ""
    # Say what happened, not what was attempted. Announcing a deletion that
    # silently failed is worse than not checking at all.
    if rm -f "$HOME/.docker/config.json" 2>/dev/null \
       && [ ! -e "$HOME/.docker/config.json" ]; then
      warn "  !! devbox: deleted host Docker registry credentials that something"
      warn "     copied in. If this was VS Code, set"
      warn "     \"dev.containers.dockerCredentialHelper\": false."
    else
      unfixed=1
      warn "  !! devbox: COULD NOT REMOVE host Docker registry credentials at"
      warn "     $HOME/.docker/config.json — they are readable by anything in"
      warn "     this container. Check the permissions on $HOME/.docker."
    fi
  fi

  # Any credential helper that is not ours points somewhere we do not control —
  # in practice at your host's credential store, which reaches every repo you
  # have ever pushed to. compose.yaml's GIT_CONFIG_* block out-ranks it, but that
  # is a mask, not a removal: `env -u GIT_CONFIG_COUNT git …` walks around it,
  # and an agent in bypass mode can do exactly that. So delete it.
  #
  # (The second grep drops entries with an EMPTY value — those are chain resets,
  # which is what we want to see. git prints an empty value as the key followed
  # by a trailing space, hence [[:space:]]*$ rather than $.)
  local foreign
  foreign_helpers_now() {
    git config --show-origin --get-regexp '^credential\..*helper$' 2>/dev/null \
      | grep -v 'gh auth git-credential' \
      | grep -vE 'credential\.[^[:space:]]*helper[[:space:]]*$' \
      || true
  }
  foreign="$(foreign_helpers_now)"
  if [ -n "$foreign" ]; then
    leaks=1
    warn ""
    warn "  !! devbox: a git credential helper other than gh's was configured:"
    printf '%s\n' "$foreign" | sed 's/^/       /' >&2

    git config --global --unset-all credential.helper 2>/dev/null || true
    local key
    for key in $(git config --global --name-only --get-regexp '^credential\..*helper$' 2>/dev/null); do
      case "$(git config --global --get "$key" 2>/dev/null)" in
        *'gh auth git-credential'*|'') : ;;
        *) git config --global --unset-all "$key" 2>/dev/null || true ;;
      esac
    done

    foreign="$(foreign_helpers_now)"
    if [ -n "$foreign" ]; then
      unfixed=1
      warn "     COULD NOT REMOVE these (they live outside the config we own):"
      printf '%s\n' "$foreign" | sed 's/^/       /' >&2
    else
      warn "     Removed from this container's git config."
    fi
  fi

  # A forwarded SSH agent socket is a key to every host you can ssh to, usable
  # by anything running in here. Clearing SSH_AUTH_SOCK is only half the job:
  # the socket itself can be found by globbing whether or not the variable is set.
  local sock socks
  socks="$(ls -1 "${TMPDIR:-/tmp}"/vscode-ssh-auth-*.sock 2>/dev/null || true)"
  if [ -n "$socks" ]; then
    leaks=1
    warn ""
    warn "  !! devbox: an SSH agent is forwarded into this container."
    for sock in $socks; do
      if rm -f "$sock" 2>/dev/null && [ ! -e "$sock" ]; then
        warn "     Removed $sock (it returns on the next attach)."
      else
        unfixed=1
        warn "     COULD NOT REMOVE $sock"
      fi
    done
    warn "     Fix it at the source: stop attaching an editor to this container,"
    warn "     or stop the agent on the host."
  fi

  # SSH_AUTH_SOCK pointing somewhere we did not recognise. What matters is not
  # the variable but whether it reaches a LIVE agent: a dangling value is inert,
  # a live socket is a key to every host you can ssh to. So try to remove it,
  # and treat one that survives as unfixed rather than as a note.
  if [ -n "${SSH_AUTH_SOCK:-}" ]; then
    leaks=1
    warn ""
    warn "  !! devbox: SSH_AUTH_SOCK is set to $SSH_AUTH_SOCK"
    if [ -S "$SSH_AUTH_SOCK" ]; then
      if rm -f "$SSH_AUTH_SOCK" 2>/dev/null && [ ! -e "$SSH_AUTH_SOCK" ]; then
        warn "     It was a live agent socket. Removed."
      else
        unfixed=1
        warn "     It is a LIVE agent socket and could not be removed."
        warn "     Anything in this container can use it to reach every host you"
        warn "     can ssh to. Find what mounted or created it."
      fi
    else
      warn "     Nothing is listening there, so it is inert — but something set"
      warn "     it, and compose.yaml sets it empty. Check what did."
    fi
  fi

  [ "$leaks" = 1 ] && warn ""
  return "$unfixed"
}

# The guards must be present, root-owned in the image, and actually reachable.
check_guards() {
  if [ ! -x /usr/local/share/devbox/bin/gh ] \
     || [ ! -x /usr/local/share/devbox/hooks/pre-push ]; then
    die "the guards are missing from the image. Rebuild the container."
  fi

  # core.hooksPath comes from the environment (compose.yaml), which outranks
  # every config file — so a repo-local hooksPath (husky, say) cannot displace
  # it. Verified from inside the playground rather than / because the answer is
  # repo-relative.
  local hooks
  hooks="$(cd "$PLAYGROUND" 2>/dev/null && git rev-parse --git-path hooks 2>/dev/null || true)"
  case "${hooks:-/usr/local/share/devbox/hooks}" in
    /usr/local/share/devbox/hooks*) : ;;
    *)
      warn ""
      warn "  !! devbox: the pre-push guard is NOT active."
      warn "     git resolves hooks to: $hooks"
      warn "     Pushes to protected branches are unguarded until that is fixed."
      warn ""
      ;;
  esac

  # Codex's program must stay on the image, not in its persistent volume. An
  # update run without CODEX_HOME pointed at the image copy moves ~320 MB into
  # the volume and repoints the binary there, which quietly undoes the install
  # layout and makes CODEX_VERSION stop meaning anything.
  local codex_link
  codex_link="$(readlink "$HOME/.local/bin/codex" 2>/dev/null || true)"
  case "$codex_link" in
    "${CODEX_HOME:-$HOME/.codex}"/*)
      warn ""
      warn "  !! devbox: codex now runs out of its persistent volume:"
      warn "       $codex_link"
      warn "     Something re-ran the installer without CODEX_HOME pointed at the"
      warn "     image copy. Put it back with:"
      warn "       curl -fsSL https://chatgpt.com/codex/install.sh -o /tmp/i.sh &&"
      warn "       CODEX_HOME=\"\$CODEX_STANDALONE_HOME\" sh /tmp/i.sh"
      warn ""
      ;;
  esac

  # The `gh` on PATH must be the shim, not the real thing.
  case "$(command -v gh 2>/dev/null || true)" in
    /usr/local/share/devbox/bin/gh) : ;;
    *)
      warn ""
      warn "  !! devbox: 'gh' resolves to $(command -v gh 2>/dev/null || echo '<nothing>'),"
      warn "     not the merge guard at /usr/local/share/devbox/bin/gh."
      warn "     PR merges are unguarded in this shell."
      warn ""
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 3. GitHub: identity and credentials, from the token in `gh`.
#
#    In a one-repo box the question was "does this token reach anything beyond
#    this repo". Here it inverts: the box holds many repositories, so the
#    question is "does this token reach anything that ISN'T in the box".
#
#    That inversion is the point. The predictable way this design rots is that
#    you clone something new, hit a 403, widen the token to fix it, and repeat
#    until the token covers your whole account. Comparing the token against what
#    is actually checked out turns that drift into a startup failure.
# ---------------------------------------------------------------------------

# Repositories present in the playground, as owner/name. Worktrees resolve to
# the same origin as their main checkout, so they dedupe away for free.
# `-print -prune` stops find descending into .git itself.
present_repos() {
  find "$PLAYGROUND" -maxdepth "$SCAN_DEPTH" -name .git -print -prune 2>/dev/null \
  | while IFS= read -r g; do
      url="$(git -C "$(dirname "$g")" remote get-url origin 2>/dev/null || true)"
      [ -n "$url" ] || continue
      printf '%s\n' "$url" \
        | sed -E 's#^(https?://[^/]+/|git@[^:]+:|ssh://[^/]+/)##; s#\.git$##'
    done | sort -u
}

GH_READY=0
TOKEN_KIND="none"
PRESENT_REPOS=""
PRESENT_COUNT=0
TOKEN_SCOPE=""
TOKEN_COUNT=0
EXTRA_LIST=""
EXTRA_COUNT=0
NOPUSH_LIST=""
TOKEN_BROAD=0
BROAD_REASON=""

# Verification only — it writes nothing, so --audit can call it too. Dies if the
# token is not one this box is willing to run agents against.
#
# The gate is whether a token is STORED, not whether `gh auth status` succeeds.
# Those differ in exactly the case that matters: a network failure makes the
# status check fail while leaving the token on disk, fully usable the moment
# connectivity returns. Keying off status let a classic token — the very thing
# this function exists to reject — start the box, and this box then runs for
# weeks without re-checking.
#
#   no token stored          -> unauthenticated, safe, box starts
#   token stored, verified   -> judged on its scope, below
#   token stored, unverified -> a working token of unknown reach: hard stop

# Every account whose credentials are stored in this container, as host/account.
#
# Read from hosts.yml rather than `gh auth status`, because this has to work
# with no network — the whole point of the check above is that a stored token
# outlives a failed status call.
gh_stored_accounts() {
  local hosts="${GH_CONFIG_DIR:-$HOME/.config/gh}/hosts.yml"
  [ -f "$hosts" ] || return 0
  # Accounts are the keys one level inside a host's `users:` block. The first
  # key encountered fixes the indent, so 2- and 4-space files both parse.
  awk '
    { match($0, /^[ \t]*/); ind = RLENGTH }
    /^[^ \t#]/ && /:[ \t]*$/ { host = $0; sub(/:[ \t]*$/, "", host); inu = 0; next }
    /^[ \t]*users:[ \t]*$/   { inu = 1; uind = ind; aind = -1; next }
    inu && NF && ind <= uind { inu = 0 }
    inu && /:[ \t]*$/ {
      if (aind < 0) aind = ind
      if (ind == aind) { a = $0; gsub(/[ \t]/, "", a); sub(/:$/, "", a); print host "/" a }
    }
  ' "$hosts"
}

# Every credential an agent in this container could authenticate with, as a
# source label.
#
# Not the same question as "which token will gh use". gh prefers a token from
# the environment over anything on disk, so an env token SHADOWS a stored one
# rather than replacing it: `env -u GH_TOKEN gh auth token` produces the stored
# credential again, and an agent in bypass mode can do exactly that. Counting
# accounts alone missed it, because one account with a stored token plus one
# environment token is still one account.
gh_credential_sources() {
  local v
  for v in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; do
    [ -n "${!v:-}" ] && printf 'environment/%s\n' "$v"
  done
  gh_stored_accounts
}

verify_token() {
  # ENUMERATE FIRST. The only safe reason to skip the rest of this function is
  # that there is no credential at all, and the only way to know that is to
  # look for all of them.
  #
  # This used to start from `gh auth token`, which resolves github.com — so a
  # credential gh holds for another host (GH_ENTERPRISE_TOKEN) produced an empty
  # answer, took the "not logged in" exit, and never reached the enumeration
  # three lines below. `gh auth token --hostname ghe.example` returned it
  # perfectly well.
  #
  # gh keeps every credential it holds usable, not just the selected one:
  # `gh auth token --user other` reaches an inactive account, dropping an
  # environment variable reaches the token on disk underneath it, and naming
  # another host reaches that host's. So require exactly one credential in the
  # container rather than validating each and unioning their scopes: the premise
  # here is one identity with one auditable scope, and a second credential is
  # the thing to remove, not to measure.
  CRED_SOURCES="$(gh_credential_sources)"
  STORED_TOKEN="$(gh auth token 2>/dev/null || true)"

  # Enumeration is not the only source of truth, in either direction. It can
  # miss a credential it cannot attribute — one in an OS keyring, or a config
  # shape this parser does not know — and if gh will hand a token over then a
  # credential exists whatever the enumeration found. Counting only what was
  # enumerated would call that "not logged in" and start the box.
  if [ -n "$STORED_TOKEN" ] && [ -z "$CRED_SOURCES" ]; then
    CRED_SOURCES="gh/selected"
  fi
  CRED_COUNT="$(printf '%s\n' "$CRED_SOURCES" | grep -c . || true)"

  # Zero now means zero both ways: nothing enumerable, and nothing gh will give
  # us. That is the only safe reason to skip the rest of this function.
  if [ "$CRED_COUNT" -eq 0 ] 2>/dev/null; then
    GH_READY=0
    return 0
  fi

  GH_READY=1
  GH_AUTH_OK=0
  gh auth status >/dev/null 2>&1 && GH_AUTH_OK=1
  if [ "$CRED_COUNT" -gt 1 ] 2>/dev/null; then
    TOKEN_BROAD=1
    BROAD_REASON="${BROAD_REASON:-$CRED_COUNT GitHub credentials are reachable in this container, and only the selected one can be checked}"
  fi

  case "$STORED_TOKEN" in
    # A credential exists (CRED_COUNT is at least 1) but gh will not hand it
    # over for github.com — in practice an enterprise-host token. Everything
    # below this point is github.com-shaped: the token prefixes, `user/repos`,
    # the url.insteadOf rewrite. So it cannot be classified or scope-checked,
    # and an unverifiable credential is a stop like any other.
    # Each of these preserves a reason already set above. When both apply — a
    # classic token AND a second credential behind it — "more than one
    # credential is reachable" is the more fundamental fact, and the token kind
    # is visible in the summary line either way.
    "")           TOKEN_KIND="unverifiable"
                  TOKEN_BROAD=1
                  BROAD_REASON="${BROAD_REASON:-a credential is present that this box cannot verify: devbox checks github.com credentials only, and gh returns nothing for github.com}" ;;
    github_pat_*) TOKEN_KIND="fine-grained" ;;
    gho_*)        TOKEN_KIND="oauth"
                  TOKEN_BROAD=1
                  BROAD_REASON="${BROAD_REASON:-it is an OAuth token from a browser login, which carries your whole account access}" ;;
    *)            TOKEN_KIND="classic"
                  TOKEN_BROAD=1
                  BROAD_REASON="${BROAD_REASON:-it is a classic token, which reaches every repo on your account}" ;;
  esac

  PRESENT_REPOS="$(present_repos)"
  PRESENT_COUNT="$(printf '%s\n' "$PRESENT_REPOS" | grep -c . || true)"

  # What the token reaches that MATTERS: repositories it can WRITE to, and
  # PRIVATE repositories it can read.
  #
  # Public read is deliberately NOT counted. A fine-grained token "always
  # include[s] read-only access to all public repositories on GitHub" (GitHub's
  # own words), so counting it rejects a perfectly-scoped token outright. That
  # access is also the one thing this box explicitly accepts: egress is open, so
  # every public repo is reachable regardless of the token.
  #
  # Failing to answer is a stop. `gh auth status` already reached GitHub a few
  # lines up, so a failure here does not mean "you are offline" — being offline
  # leaves GH_READY=0 and the box comes up unauthenticated, which is safe. It
  # means a working token of unknown scope, and unknown scope is not something
  # to point an unattended agent at.
  #
  # --paginate because the cap is 100 per page: without it, a token whose extra
  # repositories happen to sort onto page two would sail through.
  #
  # GH_TOKEN pins the call to the exact token classified above. Without it, gh
  # would resolve the account itself, so a switch between the two lines would
  # mean judging one token by another's scope.
  if [ -z "$STORED_TOKEN" ]; then
    : # nothing to ask GitHub about; already fatal above
  elif repos_json="$(GH_TOKEN="$STORED_TOKEN" gh api --paginate 'user/repos?per_page=100' 2>/dev/null)"; then
    # A jq failure means the answer is unparseable, not that the token is
    # narrow — pipefail makes the assignment fail so it lands in the same
    # "unverifiable" branch rather than looking like an empty result.
    if TOKEN_SCOPE="$(printf '%s' "$repos_json" \
        | jq -r '.[] | select(.private == true or .permissions.push == true) | .full_name' \
        | sort -u)"; then
      TOKEN_COUNT="$(printf '%s\n' "$TOKEN_SCOPE" | grep -c . || true)"

      # (a) Isolation: the token must not reach anything that is not in the box.
      EXTRA_LIST="$(printf '%s\n' "$TOKEN_SCOPE" \
        | grep -vxF -f <(printf '%s\n' "$PRESENT_REPOS") || true)"
      EXTRA_COUNT="$(printf '%s\n' "$EXTRA_LIST" | grep -c . || true)"

      # An EMPTY playground is the exception. On a fresh box there is nothing
      # checked out yet, so every repo the token reaches looks "extra" — failing
      # there would make the box impossible to start before it is used. There is
      # also nothing for an agent to be steered by yet. Report and continue.
      if [ "$PRESENT_COUNT" -eq 0 ] 2>/dev/null; then
        EXTRA_COUNT=0
      elif [ "$EXTRA_COUNT" -gt 0 ] 2>/dev/null; then
        TOKEN_BROAD=1
        BROAD_REASON="${BROAD_REASON:-it reaches $EXTRA_COUNT repositories that are not checked out in this box}"
      fi

      # (b) Capability: which of the repos actually here can be pushed to.
      #     Unlike the one-repo box this is NOT fatal — cloning something you
      #     can only read (an OSS project you are studying) is normal here. But
      #     silence would mean discovering it an hour later at `git push`.
      PUSHABLE="$(printf '%s' "$repos_json" \
        | jq -r '.[] | select(.permissions.push == true) | .full_name' | sort -u)"
      NOPUSH_LIST="$(printf '%s\n' "$PRESENT_REPOS" \
        | grep -vxF -f <(printf '%s\n' "$PUSHABLE") || true)"
    else
      TOKEN_BROAD=1
      BROAD_REASON="${BROAD_REASON:-its scope could not be verified — the answer GitHub returned about which repositories it reaches could not be parsed}"
    fi
  else
    TOKEN_BROAD=1
    BROAD_REASON="${BROAD_REASON:-its scope could not be verified — asking GitHub which repositories it reaches failed, even though the token itself authenticated}"
  fi

  if [ "$TOKEN_BROAD" = 1 ]; then
    if [ "${DEVBOX_ALLOW_BROAD_TOKEN:-0}" = "1" ]; then
      warn ""
      warn "  !! devbox: continuing with a broad token because"
      warn "     DEVBOX_ALLOW_BROAD_TOKEN=1 ($TOKEN_KIND, reaches ${TOKEN_COUNT:-?} repos,"
      warn "     ${EXTRA_COUNT:-?} of them not in this box)."
      warn "     This container is NOT limited to the repositories it holds."
      warn ""
    else
      warn ""
      warn "  !! devbox: the GitHub token in this container is too broad —"
      warn "     $BROAD_REASON."
      warn ""
      # Name what was found whenever there is anything to name — with a single
      # unverifiable credential this is the only clue as to what it even is.
      if [ -n "${CRED_SOURCES:-}" ]; then
        warn "     Credentials reachable in here:"
        printf '%s\n' "$CRED_SOURCES" | sed 's/^/       /' >&2
        warn ""
      fi
      if [ "${CRED_COUNT:-0}" -gt 1 ] 2>/dev/null; then
        warn "     Each is one 'gh auth switch' or one dropped environment"
        warn "     variable away from being the one in use. Keep exactly the"
        warn "     credential this box works as, and remove the rest:"
        printf '%s\n' "$CRED_SOURCES" \
          | sed -e 's#^environment/\(.*\)$#       unset \1   (and remove it from your .env)#' \
                -e 's#^\([^ /]*\)/\([^ ]*\)$#       gh auth logout -h \1 -u \2#' >&2
        warn ""
      fi
      if [ -n "$EXTRA_LIST" ] && [ "$EXTRA_COUNT" -gt 0 ] 2>/dev/null; then
        warn "     Reaches, but not checked out here:"
        printf '%s\n' "$EXTRA_LIST" | head -20 | sed 's/^/       /' >&2
        [ "$EXTRA_COUNT" -gt 20 ] && warn "       ... and $((EXTRA_COUNT - 20)) more"
        warn ""
      fi
      warn "     Repository scope is the boundary everything else here rests on,"
      warn "     so this is a hard stop rather than a warning. Re-issue a"
      warn "     fine-grained token listing exactly the repos in this box:"
      warn "       https://github.com/settings/personal-access-tokens"
      warn "       Repository access: Only select repositories"
      warn "       Permissions: Contents RW, Pull requests RW, Metadata RO"
      warn "     then:  gh auth login --hostname github.com --git-protocol https"
      warn ""
      if [ "$GH_AUTH_OK" = 0 ]; then
        warn "     Offline? The token is still on disk and becomes usable again"
        warn "     the moment the network returns, so it is checked either way."
        warn "     To start without GitHub access at all:  gh auth logout"
        warn ""
      fi
      warn "     Deliberate? Set DEVBOX_ALLOW_BROAD_TOKEN=1 in your .env."
      die "refusing to run agents in bypass mode against a token this wide."
    fi
  fi
}

# --audit is the same verdict as boot, minus the writes: it must be able to say
# "this box is still safe", and token scope is most of what that means. It is
# also the only way to re-check a box that has been up for weeks — a token can
# be re-scoped, or replaced by `gh auth login`, long after boot.
if [ "$MODE" = audit ]; then
  check_host_bleed || die "a host credential bridge is still in place and could not be removed."
  check_guards
  verify_token
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Git, in the container's own global config.
# ---------------------------------------------------------------------------
must git config --global init.defaultBranch main
# There is no signing key in here; leave signing to your host.
must git config --global commit.gpgsign false
must git config --global tag.gpgsign false

# No safe.directory entries. The container user shares your host uid, so
# bind-mounted repos are genuinely owned by the user running git and the
# dubious-ownership check never fires — which is better than suppressing it,
# because the check still works if that assumption ever breaks.

# If a repo's origin is an SSH URL, rewrite it to HTTPS *for this container
# only* — there is no SSH key in here, but there is a GitHub token. A global
# url.insteadOf rule leaves each repo's own .git/config, shared with your host
# through the bind mount, untouched.
git config --global --unset-all url."https://github.com/".insteadOf 2>/dev/null || true
must git config --global --add url."https://github.com/".insteadOf "git@github.com:"
must git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"

# ---------------------------------------------------------------------------
# 2. Keep the host out.
#
#    Fatal, not advisory. The per-repo dev container could let this slide at
#    create time because the editor's SSH proxy did not exist yet and a later
#    postAttach --audit would catch it. Nothing here runs --audit on a schedule,
#    so boot is the only automatic check there is: a credential bridge that
#    survives it survives for the life of the box.
# ---------------------------------------------------------------------------
check_host_bleed \
  || die "a host credential bridge is still in place and could not be removed."


verify_token

# Identity and the credential helper. These WRITE, so they are outside
# verify_token (which --audit calls) and run only once the token has passed.
if [ "$GH_READY" = 1 ]; then
  name="${DEVBOX_GIT_NAME:-}"
  email="${DEVBOX_GIT_EMAIL:-}"
  if [ -z "$name" ] || [ -z "$email" ]; then
    login="$(gh api user -q .login 2>/dev/null || true)"
    uid="$(gh api user -q .id 2>/dev/null || true)"
    if [ -n "$login" ] && [ -n "$uid" ]; then
      name="${name:-$login}"
      email="${email:-${uid}+${login}@users.noreply.github.com}"
    fi
  fi
  if [ -n "$name" ] && [ -n "$email" ]; then
    must git config --global user.name "$name"
    must git config --global user.email "$email"
  fi

  gh auth setup-git >/dev/null 2>&1 \
    || warn "devbox: gh auth setup-git failed; git push may not authenticate."
fi

# ---------------------------------------------------------------------------
# 4. Agent defaults — put both agents in bypass mode, ONCE.
#
#    Guarded by a stamp file rather than by "does the config exist". The Claude
#    installer writes its own settings.json at image build time, so "create if
#    absent" silently skipped the bypass setting. And once you have edited these
#    files they are yours: with the stamp in place, later starts never touch
#    them again.
# ---------------------------------------------------------------------------
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
must mkdir -p "$CLAUDE_DIR" "$CODEX_DIR"
# One stamp per agent, each inside that agent's own volume. A shared stamp would
# mean recreating just one volume left its agent unseeded.
CLAUDE_STAMP="$CLAUDE_DIR/.devbox-seeded"
CODEX_STAMP="$CODEX_DIR/.devbox-seeded"

seed_claude() {
  local f="$CLAUDE_DIR/settings.json"
  if [ ! -s "$f" ]; then
    cat > "$f" <<'JSON'
{
  "permissions": {
    "defaultMode": "bypassPermissions"
  }
}
JSON
    return
  fi
  # A settings.json is already here (the installer's). Merge, don't clobber.
  if ! command -v jq >/dev/null 2>&1; then
    warn "devbox: jq is missing, so $f was left alone."
    warn "        Add \"permissions\": { \"defaultMode\": \"bypassPermissions\" } by hand."
    return
  fi
  local merged
  merged="$(jq '.permissions.defaultMode = "bypassPermissions"' "$f")" || return 1
  printf '%s\n' "$merged" > "$f"
}

if [ ! -e "$CLAUDE_STAMP" ]; then
  seed_claude || die "could not seed $CLAUDE_DIR/settings.json"
  : > "$CLAUDE_STAMP" || die "could not write $CLAUDE_STAMP"
  say "[devbox] Put Claude Code in bypass mode (one time; edit"
  say "[devbox] $CLAUDE_DIR/settings.json freely from here)."
fi

if [ ! -e "$CODEX_STAMP" ]; then
  if [ ! -s "$CODEX_DIR/config.toml" ]; then
    cat > "$CODEX_DIR/config.toml" <<'TOML' || die "could not seed $CODEX_DIR/config.toml"
# devbox defaults. Codex runs unsandboxed here because the container is the
# sandbox: only the playground is mounted, and the GitHub token cannot reach
# repositories that are not in it.
approval_policy = "never"
sandbox_mode = "danger-full-access"
TOML
  fi
  : > "$CODEX_STAMP" || die "could not write $CODEX_STAMP"
  say "[devbox] Put Codex in bypass mode (one time; edit"
  say "[devbox] $CODEX_DIR/config.toml freely from here)."
fi

# ---------------------------------------------------------------------------
# 5. Shell niceties. ~/.bashrc lives in the image, not a volume, so this is
#    re-applied after every rebuild; the marker keeps it idempotent.
# ---------------------------------------------------------------------------
BASHRC="$HOME/.bashrc"
MARKER="# devbox shell setup"
if ! grep -qF "$MARKER" "$BASHRC" 2>/dev/null; then
  cat >> "$BASHRC" <<'RC' || die "could not write $BASHRC"

# devbox shell setup
shopt -s histappend
PROMPT_COMMAND="history -a${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
# Drop any forwarded host SSH agent: this box authenticates to GitHub with its
# own token, and an agent socket is a key to every host you can ssh to.
unset SSH_AUTH_SOCK
# node is already on PATH via fnm's `default` alias, which is what non-interactive
# shells and agent subshells use. This adds the interactive half: `fnm use` and
# automatic switching on a directory with .node-version / .nvmrc.
command -v fnm >/dev/null 2>&1 && eval "$(fnm env --use-on-cd --shell bash)"
# Both agents are already configured for bypass mode (see ~/.claude/settings.json
# and ~/.codex/config.toml); these just make it explicit at the call site.
alias cc='claude --dangerously-skip-permissions'
alias cx='codex --dangerously-bypass-approvals-and-sandbox'
RC
fi

# ---------------------------------------------------------------------------
# 6. Guardrail health check.
# ---------------------------------------------------------------------------
check_guards

# ---------------------------------------------------------------------------
# 7. Summary.
# ---------------------------------------------------------------------------
if [ -n "$NOPUSH_LIST" ]; then
  warn ""
  warn "  !  devbox: the token cannot push to these repositories in the box:"
  printf '%s\n' "$NOPUSH_LIST" | sed 's/^/       /' >&2
  warn "     Committing works; pushing a branch will not. Fine if they are"
  warn "     read-only on purpose."
  warn ""
fi

if [ "$GH_READY" = 0 ]; then
  cat <<'MSG'

  ---------------------------------------------------------------------------
  devbox: one-time GitHub setup needed.

  Create a fine-grained token listing exactly the repositories you keep in
  this box (https://github.com/settings/personal-access-tokens/new -
  Repository access: Only select repositories; Permissions: Contents RW,
  Pull requests RW, Metadata RO), then inside the box:

      gh auth login --hostname github.com --git-protocol https
        -> choose "Paste an authentication token"

      /usr/local/share/devbox/setup.sh     # picks up your commit identity

  A token that reaches repositories not checked out here is refused; see
  the README.

  Then log the agents in (once each; both persist across rebuilds):

      claude          -> /login
      codex login     -> add --device-auth if your browser cannot reach port 1455

  ---------------------------------------------------------------------------

MSG
  exit 0
fi

if [ "$QUIET" = 0 ]; then
  merges="blocked"
  [ "${DEVBOX_ALLOW_MERGE:-0}" = "1" ] && merges="allowed"
  cat <<MSG

  ---------------------------------------------------------------------------
  devbox ready.

    playground  $PLAYGROUND
    repos       $PRESENT_COUNT checked out
    commits as  $(git config --global user.name) <$(git config --global user.email)>
    github      $(gh api user -q .login 2>/dev/null || echo '?') - $TOKEN_KIND token
    scope       reaches $TOKEN_COUNT repos, $EXTRA_COUNT of them not in this box
    protected   ${DEVBOX_PROTECTED_BRANCHES:-<none>}   (push blocked)
    merges      $merges

    runtimes    $(python3 --version 2>&1)  /  node $(node --version 2>/dev/null || echo '?')
    agents      cc  = claude --dangerously-skip-permissions
                cx  = codex --dangerously-bypass-approvals-and-sandbox
                log in once: run 'claude' then /login, and 'codex login'
  ---------------------------------------------------------------------------

MSG
fi
