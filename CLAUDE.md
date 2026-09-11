# Working on this repo

`devbox` is a Docker Compose container for running coding agents in bypass mode
over a folder of repositories. **Read [DESIGN.md](DESIGN.md) before changing
anything structural** — most of what looks arbitrary here is load-bearing, and
the reasoning is there rather than in the code.

## Things that will look like mistakes and are not

- **The playground is mounted at the same absolute path on both sides**, and the
  container user shares the host uid. Git worktrees store absolute paths; change
  either and every worktree breaks on one side.
- **No `safe.directory` entries.** Ownership genuinely matches, so the check
  never fires. Adding one would suppress a check that is still meaningful.
- **`setup.sh` and `guards/` are copied onto the image, root-owned**, not run
  from a mount. An agent in bypass mode must not be able to edit the script that
  decides whether the box is safe to start.
- **`~/.local` is not a volume.** A volume over an image directory hides the
  image's copy, so programs there would stop tracking rebuilds.
- **`CODEX_HOME` is overridden for the install only.** Otherwise ~320 MB lands
  in the `~/.codex` volume and shadows the image after a rebuild.
- **The token check runs "token reach minus repos present"**, not the reverse.
  It exists to catch scope drift, not to validate a single repo.
- **Public-repo read access is not counted** as token breadth. Fine-grained
  tokens always have it; counting it rejects a correct token.

## Conventions

- Comments explain **why**, not what. If a line exists because of a specific
  failure, name the failure.
- Anything that changes what is enforced gets a test in `tests/`.
- Hard stops need a named `DEVBOX_ALLOW_*` override.
- Shell is bash, LF endings (`.gitattributes` enforces it), `bash -n` clean.

## Testing a change

```bash
docker compose build && docker compose up -d --force-recreate
docker cp tests/in-container.sh devbox:/tmp/t.sh && docker compose exec devbox bash /tmp/t.sh
docker cp tests/failclosed.sh   devbox:/tmp/f.sh && docker compose exec devbox bash /tmp/f.sh
bash tests/worktree-roundtrip.sh
bash tests/launcher.sh
```

All four must be green (183 assertions). The fail-closed suite uses a fake `gh`,
so it needs no credentials; the others run against the real box.

## Editing from Windows

Writing these files through a `\\wsl.localhost\...` UNC path **drops the
executable bit**. It has happened twice, and three of the four files were
invisible both times because the Dockerfile `COPY --chmod=0755`s them, so the
image was right while the repo was wrong.

After any editing session: `chmod +x bin/devbox setup.sh guards/bin/* guards/hooks/* tests/*.sh`,
then `git add -A` so the index records mode 100755. `tests/launcher.sh` asserts
this for every tracked script and will fail loudly if you forget.

## Host notes

Run compose from **inside WSL**, never PowerShell — `PLAYGROUND` is a Linux
absolute path. The playground must be on the Linux filesystem, not `/mnt/c`.
