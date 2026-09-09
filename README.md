# devbox

One standing container for running **Claude Code** and **Codex** in bypass mode
— no approval prompts — over a whole folder of repositories.

Both agents authenticate with your normal subscription, not an API key, and
those logins persist across rebuilds. The container is the sandbox: what stops a
runaway agent is the boundary around the box, not a prompt inside it.

```
┌─ your machine ────────────────────────────────────────────┐
│  ~/dev  ──bind mount, same path──┐                        │
│  everything else: unreachable    │                        │
│                          ┌───────▼──────────────────────┐ │
│                          │ devbox                       │ │
│                          │  claude, codex   no root     │ │
│                          │  python, node    no sudo     │ │
│                          │  gh + token scoped to the    │ │
│                          │     repos in ~/dev only      │ │
│                          └──────────────────────────────┘ │
└───────────────────────────────────────────────────────────┘
```

## Quick start

Run everything from **inside WSL or Linux**, never from PowerShell — `PLAYGROUND`
is a Linux absolute path and a Windows Docker client would mangle it.

```bash
git clone https://github.com/1kyc/devbox ~/devbox
cd ~/devbox
cp .env.example .env          # set PLAYGROUND, DEVBOX_USER, DEVBOX_UID
docker compose up -d
docker compose exec devbox bash -l
```

Then, once, inside the box:

```bash
gh auth login --hostname github.com --git-protocol https   # paste a token
claude          # /login
codex login     # --device-auth if your browser cannot reach port 1455
```

Both agent logins live in named volumes, so you do this once — not once per
repo, and not again after a rebuild.

Optionally put the wrapper on your PATH:

```bash
ln -s ~/devbox/bin/devbox ~/.local/bin/devbox
devbox              # shell in (starts the box if it is down)
devbox cc           # claude, bypass mode
devbox cx           # codex, bypass mode
devbox logs         # what setup.sh said at boot — start here when it will not come up
devbox rebuild      # pull base images, rebuild, recreate
devbox audit        # re-check guards, host bleed and token scope on a live box
```

## The token

This is the boundary everything else rests on, so the box refuses to start
without a good one.

Create a [fine-grained token](https://github.com/settings/personal-access-tokens/new)
with **Repository access: Only select repositories** → the repos you keep in the
playground, and permissions **Contents: RW**, **Pull requests: RW**,
**Metadata: RO**.

At boot, `setup.sh` asks GitHub what the token actually reaches and compares it
against the repositories checked out in the playground:

| Situation | Result |
|---|---|
| Token reaches a repo that is **not** in the box | **hard stop**, names the repo |
| Classic or OAuth token | **hard stop** — those carry your whole account |
| More than one credential reachable (second account, GH_TOKEN over a stored token, an enterprise token) | **hard stop** — only the selected one can be checked |
| A credential devbox cannot verify (enterprise host) | **hard stop** — github.com credentials only |
| Scope cannot be verified (API error, offline, unparseable answer) | **hard stop** |
| Playground empty (fresh box) | reported, box starts |
| No token stored at all | box starts unauthenticated, prints instructions |

That comparison runs in the direction that matters. The predictable way this
setup rots is that you clone something new, hit a 403, widen the token, and
repeat until it covers your whole account — checking against what is actually
checked out turns that drift into a startup failure instead of a slow leak.

**"Reaches" is measured, not read.** No GitHub endpoint reports what a
fine-grained token was granted (`GET /user/repos` reports what you *own*, which
is a different question), so the box finds out by asking for each private repo
you own that is not checked out here: granted repos come back, the rest 404.
Public repositories are never counted — every fine-grained token can read them
whatever you selected. That makes the reported count a floor, which is why it
prints as `reaches >=N`. See DESIGN.md, "A listing is not a grant".

**Clone from the host, not from inside the box.** The playground is bind-mounted
from your machine, so `cd ~/dev && gh repo clone owner/name` in WSL uses your
normal credentials and the box simply sees the result. There is no ordering
problem to solve — a repo does not need to be in the token before you can put it
in the playground. Add it to the token when you want the box to push it.

Note the last two rows: the check keys off whether a token is **stored**, not
whether `gh auth status` succeeds. A network failure leaves the token on disk
and fully usable once connectivity returns, so "offline" is not treated as
"logged out". If you want a box with no GitHub access, `gh auth logout` — that
is the honest version of it.

`devbox audit` re-runs the same verification against a box that is already up,
which is how you re-check after re-scoping a token or running `gh auth login`.

**What this covers.** The four `GH_*`/`GITHUB_*` token variables, `hosts.yml` in
every directory gh might use (`GH_CONFIG_DIR`, `XDG_CONFIG_HOME/gh`,
`~/.config/gh`), and anything `gh auth token` will hand over. It cannot prove no
credential exists anywhere an agent can read — a token pasted into a file in the
playground is outside its reach. It is a guardrail against credential sprawl in
the paths gh itself uses, not a proof of absence.

Override with `DEVBOX_ALLOW_BROAD_TOKEN=1` in `.env` if you mean it.

## What is actually enforced

Two tiers, and the difference is worth knowing before you type
`--dangerously-skip-permissions`.

**Enforced** — an agent cannot get around these:

- Only `PLAYGROUND` is mounted. Nothing else on your machine exists to it.
- The GitHub token cannot reach repositories outside the box.
- No root, no sudo, `cap_drop: ALL`, `no-new-privileges`. Nothing can be
  installed or escalated at runtime.
- The guards and `setup.sh` are root-owned on the image, outside the playground.
  An agent can edit any file it can reach; these are not among them.

**Guardrails** — deliberate speed bumps, defeatable on purpose:

- `pre-push` refuses pushes to `main`/`master`, in every repo and every worktree
  at once (via `core.hooksPath` from the environment, so a repo-local
  `core.hooksPath` — husky — cannot displace it). `--no-verify` skips it.
- A `gh` shim blocks PR merges, including the REST and GraphQL forms. The token
  can still merge over plain HTTP if something is determined to.

The enforced-by-GitHub version of the branch rule is a ruleset on the repo:

```
Settings → Rules → New ruleset → Target: main
  ☑ Require a pull request before merging
```

## Worktrees

The playground is mounted at **the same absolute path** inside the container as
on the host. That is not tidiness — a linked worktree stores absolute paths in
its `.git` file and in the main repo's `.git/worktrees/<name>/gitdir`, so
mismatched paths mean every worktree is broken on one side or the other.

With matching paths, worktrees round-trip freely: create one in the box and use
it on the host, or the reverse. `tests/worktree-roundtrip.sh` proves it.

```bash
git worktree add ~/dev/myrepo.wt/feature-x -b feature-x
```

Keep worktrees **under the playground** — anywhere else and they are invisible
to the box. If you run several agents in parallel this way, note that they share
one `pids_limit` (`DEVBOX_PIDS_LIMIT`, default 4096) and one `~/.claude`.

## Configuration

Everything lives in `.env` (gitignored; `.env.example` is the template).

| Variable | Default | What it does |
|---|---|---|
| `PLAYGROUND` | — | the one folder the box can see |
| `DEVBOX_USER` / `_UID` / `_GID` | `kyc` / `1000` | match your host account so files come out owned by you |
| `DEVBOX_PROTECTED_BRANCHES` | `main master` | pre-push refuses these; `""` disables |
| `DEVBOX_ALLOW_MERGE` | `0` | let agents merge PRs |
| `DEVBOX_ALLOW_BROAD_TOKEN` | `0` | start despite a token that reaches outside the box |
| `DEVBOX_PIDS_LIMIT` | `4096` | shared across every agent running at once |
| `CLAUDE_VERSION` / `CODEX_VERSION` | `stable` / `latest` | pin for a reproducible image |
| `PYTHON_VERSION` / `NODE_VERSION` | `3.13` / `lts-latest` | build-time versions |

## Runtimes

Neither agent ships a usable runtime — Claude Code's is embedded and not on
`PATH`, and Codex is a static Rust binary. Both of these install into `$HOME`,
so you can add versions later without a rebuild and without root:

```bash
uv python install 3.12        # then `uv venv` per project
fnm install 22 && fnm use 22   # respects .node-version / .nvmrc on cd
```

Package caches (`~/.cache/uv`, `~/.npm`) are volumes, so a rebuild does not
re-download the world.

## Tests

```bash
docker cp tests/in-container.sh devbox:/tmp/t.sh && docker compose exec devbox bash /tmp/t.sh
docker cp tests/failclosed.sh   devbox:/tmp/f.sh && docker compose exec devbox bash /tmp/f.sh
bash tests/worktree-roundtrip.sh
bash tests/launcher.sh
```

178 assertions: the box's invariants, the scope check's refusals (with a fake
`gh` whose listing and whose grant are set separately, because on GitHub they
are different things), and the worktree round-trip.

## Troubleshooting

**The container keeps restarting.** `setup.sh` refused to start it — that is the
design. `devbox logs` says which check failed.

**`codex: command not found` after a rebuild.** Something re-ran the Codex
installer without `CODEX_HOME` pointed at the image copy, moving the program
into the `~/.codex` volume where it shadows the image. `setup.sh --audit`
detects this and prints the fix.

**Slow file access, or file watching that misses changes.** The playground is on
`/mnt/c/...`. Move it to the Linux filesystem.

**You attached VS Code to the container.** That re-creates the host credential
bridge and SSH-agent forwarding this design exists to avoid. `setup.sh --audit`
(`devbox audit`) removes what it can and is loud about the rest.

## Related

[`1kyc/dev-container-templates`](https://github.com/1kyc/dev-container-templates)
— the per-repo dev container this grew out of. Still the right tool for a single
repo you want isolated from everything else, especially code you did not write.
This box trades repo-to-repo isolation for one login and one place to work; see
[DESIGN.md](DESIGN.md) for why that trade is the right one here and when it is
not.
