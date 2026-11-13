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

# Apptainer, under the OSP batch run profile, as a Tapis job runs it: only
# the working directory is visible, /tmp and $HOME are private and empty,
# nothing from the host environment comes in, and bulk scratch goes to ./tmp.
mkdir -p tmp
apptainer run \
  --contain --cleanenv --no-mount bind-paths,cwd \
  --pwd "$PWD" --bind "$PWD:$PWD" --env TMPDIR="$PWD/tmp" \
  app-NAME-sif_latest.sif --input in.dat
```

The run profile goes in the Tapis app definition, never in the image; see
§2a of [`CONVENTIONS.md`](CONVENTIONS.md).

## What's in here

| File | Purpose |
|---|---|
| `Dockerfile` | Base image + all dependencies, installed at build time. |
| `entrypoint.sh` | The image ENTRYPOINT. Passes `"$@"` through to the real program. |
| `.github/workflows/build-and-push.yml` | App-agnostic. Copy verbatim; the only knob is `APPTAINER_VERSION`. |
| `web/` | The interactive session contract and token gate. The source of the `app-kit` image: apps copy these files from that image (`COPY --from`), not from here. |
| `kit/Dockerfile`, `.github/workflows/kit.yml` | Build and publish `ghcr.io/onescienceplace/app-kit` from `web/`, with the template's version. In this repository only. |

The app itself can be anything — a Python script, an R script, a compiled
solver, a headless GUI tool, vendor scientific software. Only two files know
what language it is: the `Dockerfile` (which installs it) and `entrypoint.sh`
(which runs it). There is deliberately no `requirements.txt` here, because
`requirements.txt` is a Python convention; use whatever manifest your stack
has and install it in the Dockerfile.

## Interactive web and VNC apps

If the app serves a browser UI — JupyterLab, RStudio, noVNC, ParaView over VNC —
it must also honor the contract in [`web/README.md`](web/README.md): a
per-session token arriving as `?<name>=<token>`; exactly one TCP listener,
on `$OSP_APP_BIND:$OSP_APP_PORT` (loopback by default, port ≥ 1024),
checking that token; everything else the app runs internally on Unix sockets
in the session's private directory `$OSP_APP_SOCK_DIR`; no root at run time;
and TLS terminated upstream by the Satellite proxy.

One shape for all of them, sketched in `entrypoint.sh`: the app listens on
the Unix socket `$OSP_APP_SOCK_DIR/app.sock`, and the nginx token gate on
`$OSP_APP_BIND:$OSP_APP_PORT` checks the token and proxies to it, both under
`web/supervise.sh`. An app with a login of its own (JupyterLab) turns it off
behind the gate. `app-jupyter` and `app-novnc` are the worked examples.

Run it the way production does: the token goes through the environment,
never on a command line (`ps` shows command lines to everyone on the node).

```bash
export OSP_APP_TOKEN=$(openssl rand -hex 32)

# Docker (local). -e OSP_APP_TOKEN with no "=value" copies it from your
# environment. OSP_APP_BIND=0.0.0.0 because `-p` cannot reach a container's
# loopback; the host side is still published on 127.0.0.1 only.
docker run --rm --user "$(id -u):$(id -g)" \
  -p 127.0.0.1:8080:8080 -v "$PWD:/data" \
  -e OSP_APP_PORT=8080 -e OSP_APP_BIND=0.0.0.0 -e OSP_APP_TOKEN \
  ghcr.io/onescienceplace/app-NAME:latest

# Apptainer, under the OSP interactive run profile.
# APPTAINERENV_<NAME> reaches the container as <NAME>, even with --cleanenv
# (SingularityCE: SINGULARITYENV_<NAME>).
mkdir -p tmp
export APPTAINERENV_OSP_APP_TOKEN="$OSP_APP_TOKEN"
apptainer run \
  --contain --pid --ipc --cleanenv --no-mount bind-paths,cwd \
  --pwd "$PWD" --bind "$PWD:$PWD" \
  --env OSP_APP_PORT=8080 --env TMPDIR="$PWD/tmp" \
  app-NAME-sif_latest.sif
```

Then open `http://127.0.0.1:8080/?token=<the token>` in a browser (add an
`ssh -L 8080:127.0.0.1:8080 <host>` forward first if it runs elsewhere).

An interactive app's `Dockerfile` takes these files from the kit image,
pinned (the commented interactive block in the `Dockerfile` shows how), so a
fix to them reaches an app by bumping one line.

## The four rules an app must follow

1. **Install everything at build time.** A `.sif` is read-only and compute
   nodes are often offline. Nothing may be downloaded on first use.
2. **Two kinds of scratch, and never `/app`.** Secrets, sockets, rendered
   config, pid files and logs go in `$OSP_APP_SOCK_DIR`, the session's
   private directory under `/tmp` (small: about 64 MB under the run profile).
   Caches and large temporary files go under `$TMPDIR`, which the run profile
   points at the job directory; never a socket or a secret there. Caches that
   default to `$HOME` need an environment variable pointing them elsewhere.
3. **Do not trust an inherited path.** Under the run profile the app
   definition sets `TMPDIR` deliberately; on a bare run it may point at a host
   directory (`/scratch/$USER/job.N`) that Apptainer does not bind, so probing
   it beats assuming — `entrypoint.sh` walks `$TMPDIR`, `/tmp`, `$HOME`. Never
   bind a scratch parent (`/scratch`) to make it work: that shows the
   container every other job directory of the account.
4. **Read and write relative to the current directory.** Docker sets it from
   `WORKDIR`; Apptainer ignores `WORKDIR` and uses the caller's directory.
   Baked-in assets are the exception — reference those by absolute path.

## To create a new app from this template

1. `cp -r app-template app-NAME && cd app-NAME`
2. `rm -r CONVENTIONS.md web kit .github/workflows/kit.yml` — they belong to
   the template. An interactive app gets `web/` from the kit image instead.
3. Edit `Dockerfile`, `entrypoint.sh`, and this README; add your source.
4. `git init -b main && git add -A && git commit -m "initial app-NAME"`
5. `gh repo create OneSciencePlace/app-NAME --public --source=. --push`

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
