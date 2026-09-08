# Design

Why this box is shaped the way it is. Most of it is the reasoning behind
decisions that look arbitrary in the code, and the failure modes that motivated
them.

## Two boundaries, and this box only keeps one

There are two different isolations people mean by "sandbox the agent":

1. **Host ↔ container** — the agent cannot touch anything on your machine.
2. **Repo ↔ repo** — an agent working on A cannot reach B.

The per-repo dev container this grew out of gave you both: one repo mounted, one
repo in the token. This box keeps (1) completely and **deliberately drops (2)**.
That is the whole trade, and it is worth being explicit about because it is not
recoverable by folder discipline — the token and the filesystem are shared by
everything in the box.

What that costs, concretely: in bypass mode an agent acts without asking, so
anything that reaches its context — a poisoned README, a fetched web page, an
issue comment — can steer it. Per-repo isolation caps the damage at one repo.
Here it is capped at the playground.

What it buys: one login instead of one per repo, one place to work, and
worktrees that span repositories. That is the actual friction that made the
per-repo model tiring — not disk (image layers are shared; the persistence
volumes are 50–100 MB), but re-authenticating Claude, Codex, and `gh` every time
a new repo appeared.

**When to use the other one instead:** a repo you did not write, a dependency
audit, anything where the content itself is untrusted. Those belong in a
throwaway single-repo container.

## Why Compose and not a dev container

The dev container's headline feature is the editor integration, and **the editor
integration is the largest hole in this threat model.**

With its default settings the VS Code Dev Containers extension copies your host
`~/.gitconfig` in, installs a credential helper bridging to your host's
credential store, copies your Docker registry credentials, and forwards your SSH
agent. Each of those hands the agent reach far beyond the box. The per-repo
template needed six documented host settings plus a container-side backstop just
to fight that to a draw.

Dropping the editor server deletes the entire category rather than mitigating
it. It also drops a 10 GB `vscode` volume, and it fits the lifecycle better: a
dev container is meant to be per-project and disposable, created on open and
rebuilt when its config changes. This is a daemon you `exec` into for weeks.

`check_host_bleed()` survives anyway, because **"Attach to Running Container" is
one click away** and re-creates every one of those channels. It is a backstop
for the day someone clicks it, not load-bearing.

## The scope check inverts

In a one-repo box the question was "does this token reach anything beyond this
repo". Here it is "does this token reach anything that **isn't** in the box".

The rot to design against is not a token that was wrong on day one — it is one
that gets widened one 403 at a time. You clone something new, the push fails,
you add the repo to the token. A year later it says "all repositories". Nothing
ever alerted you, because every individual step was reasonable.

So the check compares the token's reach against what is actually checked out,
and a repo in the token but not in the playground is a startup failure.

Three details that are easy to get wrong:

- **Public read is not counted.** A fine-grained token "always include[s]
  read-only access to all public repositories on GitHub" (GitHub's words), so
  counting repositories rejects a perfectly scoped token. The set that matters
  is `private == true or permissions.push == true`. Open egress means every
  public repo is reachable regardless of the token, so this is not a loss.
- **`--paginate`.** `per_page` caps at 100. Without it, a token whose extra
  repositories sort onto page two looks perfectly scoped.
- **An unparseable answer is not an empty one.** A `jq` failure must land in
  "unverifiable" (a stop), not look like a narrow token. `pipefail` makes the
  assignment fail so it takes the right branch.

The mirror question — *can* it push where you work — is a **warning** here, not a
stop. In a one-repo box a token that cannot push means a broken box. In a
multi-repo box, cloning something you can only read is normal.

**The empty-playground exception:** on a fresh box nothing is checked out, so
every repo the token reaches looks extra. Failing there would make the box
impossible to start before first use, and there is nothing for an agent to be
steered by yet. It reports and continues.

## Same path on both sides

The playground is mounted at the same absolute path inside the container as on
the host, and the container user shares your host uid.

The forcing constraint is **git worktrees**. A linked worktree's `.git` is a file
containing `gitdir: /abs/path/to/main/.git/worktrees/<name>`, and that directory
holds a `gitdir` file pointing back at the worktree — both absolute. If the two
sides disagree about the path, every worktree is broken on one of them, and
`git worktree repair` becomes a permanent part of the workflow.

Matching the uid on top of that means files an agent writes come out owned by
you on the host. That is why there are **no `safe.directory` entries** here: the
dubious-ownership check never fires because the ownership is genuinely correct,
which is better than suppressing a check that would still be meaningful if the
assumption broke.

`tests/worktree-roundtrip.sh` exercises both directions and asserts that
`git worktree repair` has nothing to say.

## Fail closed

`setup.sh` exits non-zero when the box's premise is not true, which kills the
container's command, which means the box does not come up. A container that
will not start is a better outcome than one that reports "devbox ready" while an
agent holds your whole account.

Isolation-critical steps run through `must()`. Advisory checks warn and continue.
Every hard stop has a named override (`DEVBOX_ALLOW_BROAD_TOKEN`,
`DEVBOX_ALLOW_MERGE`) so that "I meant that" is expressible without editing
code.

### Stored, not "logged in"

The token check keys off whether a token is **stored**, not whether
`gh auth status` succeeds. Those look interchangeable and are not.

An earlier version used `gh auth status`, reasoning that a failure meant
offline, and offline is safe because nothing can be pushed anywhere. That is
wrong in a way that only shows up in a long-lived box: a network failure does
not remove the token. It sits on disk, `gh auth token` still returns it, and it
works again the moment connectivity comes back — but `setup.sh` ran once, at
boot, and does not re-check. A **classic token**, the exact thing this check
exists to reject, started the box that way.

So the three states are kept distinct:

| | |
|---|---|
| No token on disk | unauthenticated, safe — box starts |
| Token whose scope verifies | judged on that scope |
| Token whose scope will not verify | a working token of unknown reach — **stop** |

Being genuinely offline with a token stored now lands in the third row. That is
intended: the escape hatch is `gh auth logout`, which makes the box honestly
unauthenticated, or `DEVBOX_ALLOW_BROAD_TOKEN=1` if you know what the token is.

`--audit` runs the same verification (minus the writes), so it is also the way
to re-check a box that has been up for weeks — a token can be re-scoped, or
replaced by `gh auth login`, long after boot.

### One account, not one active account

`gh auth token` returns the **active** account's token, but gh stores
credentials per account and keeps the inactive ones fully usable:
`gh auth token --user other` hands them over, and `gh auth switch` promotes
them. So validating the active token says nothing about what an agent can
reach — a narrow active account can sit in front of a classic token belonging
to an account that was never examined.

The box requires a **single stored account** rather than validating each one and
unioning their scopes. Its premise is one identity with one auditable scope; a
second set of credentials in it is the thing to remove, not to measure. That is
also the concrete risk for a personal box: the account you did not mean to bring
in is usually the work one.

Accounts are enumerated from `hosts.yml` rather than `gh auth status`, because
enumeration has to work with no network — the same reason the check keys off a
stored token in the first place. The API calls then pin `GH_TOKEN` to the exact
token that was classified, so a switch between "which token is this" and "what
does it reach" cannot judge one token by another's scope.

### Report what happened, not what was attempted

Every removal in `check_host_bleed` verifies that it worked. An earlier version
deleted `~/.docker/config.json` and announced the deletion unconditionally; with
a read-only `~/.docker` the file survived, the message said it had gone, and
nothing was marked unresolved. A check that lies is worse than no check, because
it also removes the reason to look.

### Boot is the only automatic check

`check_host_bleed` is **fatal** at startup. The per-repo dev container could let
it slide at create time, because the editor's SSH proxy did not exist yet and a
later `postAttach --audit` would catch it. Nothing here runs `--audit` on a
schedule, so a credential bridge that survives boot survives for the life of the
box.

The SSH_AUTH_SOCK case is judged on whether it reaches a **live** socket rather
than on the variable being set: a dangling value is inert and warns, a live
agent socket is removed, and one that cannot be removed is fatal.

## Where things live, and why

The rule: **programs on the image, state in volumes.** A volume mounted over an
image directory hides the image's copy. Anything installed under one is copied
into the volume once and then never tracks the image again — so a rebuild
silently keeps serving the old program, and version pinning quietly stops
meaning anything.

This bit us for real: Codex's installer unpacks ~320 MB into
`$CODEX_HOME/packages`, and `CODEX_HOME` is `~/.codex`, a volume. The fix is to
point `CODEX_HOME` at an image path *for the install only*, with a Dockerfile
assertion that the mount point stayed empty and a runtime check that the symlink
still points at the image.

| On the image | In a volume |
|---|---|
| `~/.local` — claude, codex, uv, fnm, python, node | `~/.claude`, `~/.codex` — config, logins, sessions |
| `/usr/local/share/devbox` — guards, `setup.sh` | `~/.config/gh` — the token |
| `~/.bashrc` (re-seeded each boot) | `~/.cache/uv`, `~/.npm`, `/commandhistory` |

`setup.sh` lives on the image too, root-owned. It is the script that decides
whether the box is safe to start, so it should not be something an agent in
bypass mode can edit. In the per-repo template it sat in the workspace, and it
could.

For the same reason **this repo is deliberately outside the playground**
(`~/devbox`, not `~/dev/devbox`). The running guards are safe either way — they
are baked into the image — but if the repo were mounted, an agent could edit the
`Dockerfile` that builds the *next* image.

## Git configuration through the environment

`GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n` is read after
every config file, so it cannot be overridden by a repo's `.git/config`, by a
helper an editor writes into `~/.gitconfig`, or by an agent running
`git config`. It shows up as origin `command line:`.

Three entries:

0. `core.hooksPath` — the pre-push guard, for every repo and every worktree at
   once, immune to a repo-local `core.hooksPath` (husky).
1. `credential.helper` **empty** — an empty value *resets* the accumulated list.
   Without it, a helper bridged in from a host would still be tried.
2. `credential.helper` = gh's — the only one left standing.

This is a mask, not a removal: `env -u GIT_CONFIG_COUNT git …` walks around it,
and an agent in bypass mode can do exactly that. So `check_host_bleed()` also
deletes foreign helpers rather than relying on precedence.

## Rejected alternatives

**Sharing code with `dev-container-templates`** (submodule or subtree). The
overlap is smaller than it looks and shrinking: the scope check inverts, the
lifecycle differs (entrypoint vs `postCreateCommand`), and the Dockerfiles
diverge because a standing box wants runtimes the template exists to omit. What
is genuinely identical is `guards/` — two small finished files. Forked, and the
duplication is cheaper than the coupling.

**A `~/.local` volume so `claude update` survives rebuilds.** That is the
shadowing bug on purpose. Updates persist for the life of the container, and a
rebuild installs whatever is current anyway.

**`nvm` for Node.** Correct but slow: it sources shell script on every startup,
and this box spawns a shell for every `exec` and every subshell an agent opens.
`fnm` is a single static binary. Its `default` alias is a stable path baked into
`PATH`, so node works in non-interactive shells without `eval $(fnm env)`; the
`.bashrc` adds the eval for interactive `fnm use` and `.node-version`.

**Mounting all of `~`.** Would make the box pointless. The mount *is* the
boundary.
