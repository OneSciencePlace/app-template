# app-template

**This is the skeleton, not an app.** Copy it to `app-<thing>`, replace this
README, and delete anything you do not need. Nothing here is meant to build
or deploy as-is.

---

# app-NAME

One-line description of what this app does.

Built and published by `.github/workflows/build-and-push.yml` on every push to
`main` (and on `v*` tags):

- `ghcr.io/onescienceplace/app-NAME` — OCI image
- `ghcr.io/onescienceplace/app-NAME-sif` — Apptainer `.sif` (ORAS artifact)

```bash
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$PWD:/data" ghcr.io/onescienceplace/app-NAME:latest --input in.dat

apptainer pull oras://ghcr.io/onescienceplace/app-NAME-sif:latest
# (fine for a quick try; a Tapis app definition pins <version>@sha256:<digest>)
apptainer run app-NAME-sif_latest.sif --input in.dat
```

## What's in here

| File | Purpose |
|---|---|
| `Dockerfile` | Base image + all dependencies, installed at build time. |
| `entrypoint.sh` | The image ENTRYPOINT. Passes `"$@"` through to the real program. |
| `.github/workflows/build-and-push.yml` | App-agnostic. Copy verbatim; the only knob is `APPTAINER_VERSION`. |
| `web/` | Interactive web/VNC apps only — the token gate and session contract. Delete for batch apps. |

The app itself can be anything — a Python script, an R script, a compiled
solver, a headless GUI tool, vendor scientific software. Only two files know
what language it is: the `Dockerfile` (which installs it) and `entrypoint.sh`
(which runs it). There is deliberately no `requirements.txt` here, because
`requirements.txt` is a Python convention; use whatever manifest your stack
has and install it in the Dockerfile.

## Interactive web and VNC apps

If the app serves a browser UI — JupyterLab, RStudio, noVNC, ParaView over VNC —
it must also honour the contract in [`web/README.md`](web/README.md): a
per-session token arriving as `?<name>=<token>`, a single exposed port ≥ 1024,
no root at run time, and TLS terminated upstream by the Satellite reverse proxy.

Two branches, both worked out in full elsewhere in this directory:

- **A — native URL-token auth.** Bind the app straight to `OSP_APP_PORT` and hand it
  the token. `app-jupyter` is the example.
- **B — no URL-token auth.** Run the app on `127.0.0.1` and put the nginx token
  gate on `OSP_APP_PORT` in front of it. `app-novnc` is the example.

Batch apps delete `web/` entirely.

## The four rules an app must follow

1. **Install everything at build time.** A `.sif` is read-only and compute
   nodes are often offline. Nothing may be downloaded on first use.
2. **Scratch goes to `/tmp` or the working directory.** Never into `/app`.
   Caches that default to `$HOME` need an env var pointing them elsewhere.
3. **Do not trust an inherited path.** `$TMPDIR` usually points at a host
   directory (`/scratch/$USER/job.N`) that Apptainer does not bind, so probing
   it beats assuming — `entrypoint.sh` walks `$TMPDIR`, `/tmp`, `$HOME`.
4. **Read and write relative to the current directory.** Docker sets it from
   `WORKDIR`; Apptainer ignores `WORKDIR` and uses the caller's directory.
   Baked-in assets are the exception — reference those by absolute path.

## To create a new app from this template

1. `cp -r app-template app-NAME && cd app-NAME`
2. Edit `Dockerfile`, `entrypoint.sh`, and this README; add your source.
3. `git init -b main && git add -A && git commit -m "initial app-NAME"`
4. `gh repo create OneSciencePlace/app-NAME --public --source=. --push`

The workflow file needs no edits — it derives every name from
`${{ github.repository }}`.

## Keeping it current

GitHub actions are pinned to major tags (`@v6`, `@v4`, `@v7`), so minor and
patch releases arrive automatically and a major bump is a deliberate edit
across all `app-*` repos at once. Apptainer is pinned exactly, via
`APPTAINER_VERSION` in the workflow, and installed from the upstream release
`.deb` — which is also what supplies the AppArmor profile Ubuntu 24.04+ needs
to allow unprivileged user namespaces. Base images in the Dockerfile above
are current as of August 2026; check them when you start a new app.

## Build and test locally

Skip GitHub and the registry entirely — same Dockerfile, built by hand:

```bash
docker build -t app-NAME:dev .        # add --platform linux/amd64 on Apple Silicon
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$PWD:/data" app-NAME:dev --input in.dat
```

Then the `.sif`, without pushing anything:

```bash
docker save app-NAME:dev -o app-NAME.tar
apptainer build app-NAME.sif docker-archive://app-NAME.tar
apptainer run app-NAME.sif --input in.dat
```

### Why `--user`

Docker runs the container as root, so anything it writes into the bind-mounted
directory lands on your disk owned by `root` and needs `sudo` to delete.
`--user "$(id -u):$(id -g)"` makes the container write as you, and matches how
Apptainer runs it — Apptainer is always the invoking user, so it never has this
problem.

To reclaim files a previous root-owned run left behind:

```bash
sudo chown -R "$(id -u):$(id -g)" .
```

The one visible side effect: that uid has no `/etc/passwd` entry inside the
container, so `whoami` fails and `ls -l` shows bare numbers. Nothing actually
breaks — only code calling `getpwuid()` notices — and Apptainer generates the
entry itself, so this never shows up in production. If you want a name locally:

```bash
# 1. Interactive apps only: web/session-env.sh adds an entry when it can.
#    /etc/passwd is group-writable in the image, so group 0 is enough.
docker run --rm --user "$(id -u):0" ...

# 2. Any app: show the container your real identity, keeping your own gid.
docker run --rm --user "$(id -u):$(id -g)" \
  -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro ...
```

Set `OSP_APP_USER` to change the name option 1 uses.

`apptainer build` from a local archive needs no root and no fakeroot. Test the
`.sif` and not just the image: read-only-filesystem bugs never show up under
`docker run`.
