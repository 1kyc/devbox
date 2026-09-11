# devbox — one long-lived container for running Claude Code and Codex in bypass
# mode against a whole folder of repositories.
#
# The container IS the sandbox: agents run without approval prompts, and what
# stops them is the boundary around the box (one mounted folder, one repo-scoped
# token, no root) rather than a prompt inside it. See DESIGN.md.
#
# Not a dev container. There is no editor server in here and nothing bridges
# your host's credentials in — that bridge is the single biggest hole in the
# per-repo dev container this grew out of. You `docker compose exec` into it.
FROM debian:bookworm-slim

# Everything an agent session needs must be baked in HERE: the running container
# drops all capabilities and sets no-new-privileges, so there is no apt-get and
# no sudo at runtime. To add a package, edit this and rebuild.
#
#   git, curl, ca-certificates  the job, and every installer below
#   less                        git's pager
#   jq                          setup.sh merges Claude's settings.json with it
#   zstd                        lets the Claude installer take its smaller path
#   build-essential             python wheels and node native modules need cc
#   ripgrep, unzip, procps      what agents actually reach for
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl git jq less zstd build-essential ripgrep unzip procps \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# The GitHub CLI, from its own apt repository rather than a pinned tarball: it
# is the credential helper for every git operation in here, and a stale gh is a
# worse failure than a non-reproducible one. Lands at /usr/bin/gh, which matters
# — the merge shim finds it by scanning PATH for the first gh that is not itself.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod 0644 /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gh \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# The user everything runs as.
#
# The name and uid are NOT cosmetic. The playground is bind-mounted at the same
# absolute path inside the container as on the host, because git worktrees store
# absolute paths in .git and break the moment those disagree. Matching the host
# uid on top of that means files written by an agent are owned by you on the
# host, with no safe.directory workaround and no chown dance.
#
#   USERNAME=kyc USER_UID=1000  ->  /home/kyc, uid 1000, same as the WSL account
ARG USERNAME=kyc
ARG USER_UID=1000
ARG USER_GID=1000
RUN groupadd --gid "$USER_GID" "$USERNAME" \
 && useradd --uid "$USER_UID" --gid "$USER_GID" --create-home --shell /bin/bash "$USERNAME"

# Pre-create the directories that named volumes mount onto, owned by the user,
# so each fresh volume inherits that ownership on first init. There is no sudo
# at runtime, so a missed chown here is unrecoverable without a rebuild.
#   ~/.claude       Claude Code config, login, history   (CLAUDE_CONFIG_DIR)
#   ~/.codex        Codex config, login, sessions        (CODEX_HOME)
#   ~/.config/gh    the gh CLI's GitHub token
#   ~/.cache/uv     Python package cache
#   ~/.npm          npm package cache
#   /commandhistory shell history that survives rebuilds
RUN mkdir -p "/home/$USERNAME/.claude" "/home/$USERNAME/.codex" \
             "/home/$USERNAME/.config/gh" "/home/$USERNAME/.cache/uv" \
             "/home/$USERNAME/.npm" "/home/$USERNAME/.local/bin" /commandhistory \
 && chown -R "$USER_UID:$USER_GID" "/home/$USERNAME" /commandhistory

# The devbox bin dir goes FIRST so its `gh` shim shadows the real gh. HOME is
# set explicitly because Docker's USER instruction does not change it, and every
# installer below sites its work off $HOME.
ENV HOME=/home/$USERNAME
ENV FNM_DIR=/home/$USERNAME/.local/share/fnm
# Defined ONCE and used three times below. Spelling this list out separately in
# each place is how the login-shell restores silently drift from the image PATH —
# and a drift that drops the guard dir is exactly the failure they exist to
# prevent.
ENV DEVBOX_PATH=/usr/local/share/devbox/bin:/home/$USERNAME/.local/bin:$FNM_DIR/aliases/default/bin
ENV PATH=$DEVBOX_PATH:$PATH

# ENV alone is not enough: a LOGIN shell (bash -l, some task runners) sources
# /etc/profile, which overwrites PATH with a fixed default — dropping node and,
# worse, the guard dir, so `bash -lc 'gh pr merge …'` would reach the real gh and
# walk straight past the shim. /etc/profile.d runs after that reset, so this puts
# the entries back. Root-owned, like the guards.
RUN printf '%s\n' \
      '# devbox: restore PATH after /etc/profile resets it for login shells.' \
      "PATH=\"$DEVBOX_PATH:\$PATH\"" \
      'export PATH' \
      > /etc/profile.d/10-devbox-path.sh \
 && chmod 0644 /etc/profile.d/10-devbox-path.sh

USER $USERNAME

# --- agents -----------------------------------------------------------------
#
# Both come from their vendor's official installer, downloaded THEN run (not
# `curl | bash`) so a failed fetch fails the build instead of shipping an image
# without the agent. Each verifies its download against a published sha256 and
# lands in ~/.local/bin, which is writable — so `claude update` and re-running
# the Codex installer both work without root.
#
# Versions default to current: this image is rolling-latest by design. Because
# this box is long-lived and rebuilt rarely, in-place updates matter more here
# than they did per-repo — they persist for the life of the container and are
# lost on rebuild, which then installs whatever is current anyway.
ARG CLAUDE_VERSION=stable
RUN curl -fsSL https://claude.ai/install.sh -o /tmp/install-claude.sh \
 && bash /tmp/install-claude.sh "$CLAUDE_VERSION" \
 && rm /tmp/install-claude.sh

# CODEX_HOME is overridden FOR THE INSTALL ONLY. The installer unpacks ~320 MB
# into $CODEX_HOME/packages/standalone and symlinks ~/.local/bin/codex at it —
# and CODEX_HOME at runtime is ~/.codex, which is a named VOLUME. Installing
# there would copy the whole program into the volume, and a volume with content
# shadows the image, leaving `codex: command not found` after a rebuild. So the
# program lives on the image and the volume keeps only what should persist:
# config.toml, auth.json, history and sessions.
ARG CODEX_VERSION=latest
ENV CODEX_STANDALONE_HOME=/home/$USERNAME/.local/share/codex
RUN curl -fsSL https://chatgpt.com/codex/install.sh -o /tmp/install-codex.sh \
 && if [ "$CODEX_VERSION" = "latest" ]; then \
      CODEX_HOME="$CODEX_STANDALONE_HOME" CODEX_NON_INTERACTIVE=1 sh /tmp/install-codex.sh; \
    else \
      CODEX_HOME="$CODEX_STANDALONE_HOME" CODEX_NON_INTERACTIVE=1 sh /tmp/install-codex.sh --release "$CODEX_VERSION"; \
    fi \
 && rm /tmp/install-codex.sh \
 && test ! -e /home/$USERNAME/.codex/packages   # the volume mount point must stay empty

# --- runtimes ---------------------------------------------------------------
#
# Neither agent gives you a usable runtime: Claude Code's is embedded and not on
# PATH, and Codex is a static Rust binary. Both of these install user-space, so
# you can add versions later without rebuilding and without root.

# Python, via uv. Interpreters go on the IMAGE (~/.local/share/uv); only the
# package cache is a volume. UV_LINK_MODE=copy because hardlinks cannot cross
# the volume boundary and uv warns on every install otherwise.
ENV UV_PYTHON_INSTALL_DIR=/home/$USERNAME/.local/share/uv/python \
    UV_CACHE_DIR=/home/$USERNAME/.cache/uv \
    UV_LINK_MODE=copy
ARG PYTHON_VERSION=3.13
RUN curl -fsSL https://astral.sh/uv/install.sh -o /tmp/install-uv.sh \
 && sh /tmp/install-uv.sh \
 && rm /tmp/install-uv.sh \
 && "$HOME/.local/bin/uv" python install "$PYTHON_VERSION" \
 && ln -sf "$("$HOME/.local/bin/uv" python find "$PYTHON_VERSION")" "$HOME/.local/bin/python3" \
 && ln -sf "$HOME/.local/bin/python3" "$HOME/.local/bin/python"

# Node, via fnm rather than nvm: a single static binary with no shell sourcing,
# which matters when every `exec` and every subshell an agent spawns pays that
# cost. The `default` alias is a stable path baked into PATH above, so node is
# present in non-interactive shells without `eval $(fnm env)`; .bashrc adds the
# eval so `fnm use` and .node-version still work interactively.
#
# `lts-latest` rather than the `--lts` flag: the flag only exists on `install`,
# and the same string has to work for `alias` too. A plain version ("22") works
# here as well.
ARG NODE_VERSION=lts-latest
RUN curl -fsSL https://fnm.vercel.app/install -o /tmp/install-fnm.sh \
 && bash /tmp/install-fnm.sh --install-dir "$HOME/.local/bin" --skip-shell \
 && rm /tmp/install-fnm.sh \
 && "$HOME/.local/bin/fnm" install "$NODE_VERSION" \
 && "$HOME/.local/bin/fnm" alias "$NODE_VERSION" default \
 && "$FNM_DIR/aliases/default/bin/corepack" enable --install-directory "$HOME/.local/bin"

# --- login-shell PATH, the last word -----------------------------------------
#
# /etc/profile.d/10-devbox-path.sh restores PATH after /etc/profile wipes it,
# but it is not the last thing a login shell reads. Debian's stock ~/.profile
# runs after it and ends with:
#
#     if [ -d "$HOME/.local/bin" ] ; then PATH="$HOME/.local/bin:$PATH" ; fi
#
# which puts ~/.local/bin in FRONT of the guard dir. Everything installed above
# lives there, so in a login shell — which is how the box is entered, and how
# `devbox cc`/`cx` start an agent — a real binary shadows its wrapper.
#
# Not hypothetical: `codex update` reached the real codex and died with "Could
# not detect the Codex installation method" while its wrapper sat unreachable
# two entries further down. The test that should have caught it asserted
# resolution in a NON-login shell, where the ENV PATH above still held, so it
# passed for every build while the box was broken for every user.
#
# The gh shim survived only by accident of address: gh is in /usr/bin, which the
# guard dir still outranks. But ~/.local/bin is writable by the agent, so while
# it sat in front, `cp "$(command -v -a gh | tail -1)" ~/.local/bin/gh` was
# enough to make the merge shim disappear. Ordering was doing load-bearing work
# it had not actually been given.
#
# bash reads the FIRST of ~/.bash_profile, ~/.bash_login, ~/.profile, so this
# file wins by existing. It sources ~/.profile rather than replacing it, then
# re-applies DEVBOX_PATH: a new file instead of an edit to a stock one, and
# immune to whatever a later installer appends to ~/.profile.
RUN printf '%s\n' \
      '# devbox: bash reads THIS instead of ~/.profile, so source that first.' \
      '[ -f "$HOME/.profile" ] && . "$HOME/.profile"' \
      '' \
      '# ...then have the last word on PATH. ~/.profile ends by prepending' \
      '# ~/.local/bin, which would otherwise shadow the guard dir and with it' \
      '# every wrapper this box relies on.' \
      "PATH=\"$DEVBOX_PATH:\$PATH\"" \
      'export PATH' \
      > "$HOME/.bash_profile" \
 && chmod 0644 "$HOME/.bash_profile"

# --- guards ------------------------------------------------------------------
#
# LAST on purpose. These are the files under active development in this repo,
# and everything above them is ~1.06 GB of vendor downloads (Claude 335 MB,
# Codex 335 MB, Node 228 MB, Python 158 MB). Copied in earlier, a one-character
# edit to setup.sh invalidated all four installer layers and a comment fix cost
# a full re-download. Nothing above consumes them, so they belong here.
#
# Root-owned and outside the playground ON PURPOSE: an agent running as
# $USERNAME cannot rewrite them, unlike anything in a mounted repo. setup.sh
# joins them rather than being run from a mount for the same reason — it is the
# script that decides whether the box is safe to start. (In the per-repo dev
# container it lived in the workspace, and an agent could edit it.)
USER root
COPY --chown=root:root --chmod=0755 guards/ /usr/local/share/devbox/
COPY --chown=root:root --chmod=0755 setup.sh /usr/local/share/devbox/setup.sh
USER $USERNAME

CMD ["bash"]
