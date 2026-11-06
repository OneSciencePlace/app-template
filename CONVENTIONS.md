# app-* container repos — conventions

The conventions for OneSciencePlace's family of GitHub repos named `app-<thing>`.
Each one builds a Docker image **and** a Singularity/Apptainer `.sif` from a
single Dockerfile, and hosts both in GitHub Container Registry. The repos are
deliberately minimal: they exist to illustrate the configure → build → host
mechanism, not to be impressive software.

This file records the decisions that are *not* obvious from reading the files,
so a new working session (human or Claude) can pick up without re-deriving them.

It lives in `app-template`, the skeleton every app is copied from, and follows
the organisation-wide rules in
[`osp-conventions`](https://github.com/OneSciencePlace/osp-conventions)
(`conventions.md`: naming, versions, terms). Where the two differ,
`osp-conventions` wins. The internal material for these apps — how a system
is validated for interactive apps, and the design notes behind the hardening —
is in OSP's private `osp-ops` repository.

- **Design rationale, diagrams, rollout steps:** <https://claude.ai/code/artifact/0d075c28-9523-4374-9dc1-8be504fa31f2>
- **Layout:** `app-template/` is the copy-me skeleton (not a deployable app).
  Worked examples:
  `app-object-detection` (batch), `app-jupyter` (interactive, native token),
  `app-novnc` (interactive, gated).
  The same detector wrapped in each interactive branch:
  `app-object-detection-jupyter` (branch A, a tutorial notebook),
  `app-object-detection-novnc-pcmanfm` and `app-object-detection-novnc-xfce`
  (branch B, one desktop app on a light and a full desktop stack; identical
  below the desktop layer, and each README carries the comparison).

---

## 1. Naming — everything derives from the repo name

| Thing | Pattern |
|---|---|
| GitHub org | `OneSciencePlace` |
| repo | `github.com/OneSciencePlace/app-<thing>` |
| image | `ghcr.io/onescienceplace/app-<thing>` |
| sif | `ghcr.io/onescienceplace/app-<thing>-sif` |
| tags | `latest` (on `main`), `sha-<short>`, `<semver>` (on a `v*` git tag) |

`.github/workflows/build-and-push.yml` never mentions the app. It reads
`${{ github.repository }}` and derives both package names from it, which is why
the file is copied **byte-for-byte** into every repo and never edited — the one
exception being the `APPTAINER_VERSION` env var.

A git tag `v1.0.0` produces the `1.0.0` tag on *both* packages, so an image and
its `.sif` always carry the same version string. A Tapis app definition pins
that tag **and** its digest (`app-novnc:1.0.0@sha256:…`), never `latest`.

**Which version** (from `osp-conventions`): template and OSP-written images
use semver, starting at `1.0.0`. An image that packages versioned software
takes that software's version — `app-jupyter` is `4.6.3` for JupyterLab 4.6.3 —
and an OSP-only change in behaviour adds `-osp<n>` (`4.6.3-osp1`).

**Repo names** (also from `osp-conventions`): `app-<interface>` or
`app-<interface>-<software>`, with `<software>` the upstream's own name
(`app-novnc`, `app-novnc-paraview`). Repos that predate those conventions keep
their names.

**Case matters, and it differs between the two.** The GitHub org is
`OneSciencePlace`; the registry path is `ghcr.io/onescienceplace/...`. OCI
reference grammar permits only lowercase in a repository name, while
`${{ github.repository }}` preserves the owner's capitalisation — so the
workflow folds it to lowercase once (`${GITHUB_REPOSITORY,,}`) and both jobs
use that. Passing `github.repository` straight into a `docker://` or `oras://`
reference produces an invalid-reference failure.

`.sif` files are pushed with ORAS, not Docker. They are not `docker pull`-able,
which is why they live under a separate `-sif` package rather than a tag suffix
on the image.

---

## 2. The four rules every app must follow

These exist because a `.sif` behaves differently from a Docker container, and
because the node it lands on is not the machine you built it for. Violating them produces an image that works perfectly under
`docker run` and fails on the cluster.

1. **Install everything at build time.** A `.sif` is mounted read-only and HPC
   compute nodes are often offline. Nothing — model weights, reference data,
   a first-run cache — may be downloaded on first use.
2. **Scratch goes to `/tmp` or the working directory, never `/app`.** Libraries
   that write a cache into `$HOME` or their own install tree need an env var
   redirecting them. The baseline set is `HOME=/tmp`,
   `XDG_CACHE_HOME=/tmp/.cache`, `MPLCONFIGDIR=/tmp/matplotlib`; add whatever
   else your stack needs (`YOLO_CONFIG_DIR`, `NUMBA_CACHE_DIR`, `R_LIBS_USER`…).
   An app that needs a real home directory — a desktop, a notebook root, a
   place to seed files the user will edit — points `HOME` at a writable 1777
   home instead and redirects each library cache by name. That is a different
   arrangement, not an exemption: nothing may still write to `/app`. See §4a,
   *The session home, and seeding into it*.
3. **Do not trust an inherited path.** A scheduler's `$TMPDIR` points at a host
   directory Apptainer does not bind. Probe it, fall back, say which you took.
4. **Read and write relative to the current directory.** Docker honours the
   image's `WORKDIR`; Apptainer *ignores* it and uses the caller's directory.
   Baked-in assets are the exception — reference those by absolute path under
   `/app`. Never mix the two.

### File modes in the image

`COPY` preserves the build context's permissions. A checkout made under a
restrictive umask gives 0600/0700 files, and `chmod +x` on a 0600 file leaves
it `-rwx--x--x` — executable but unreadable, so `/bin/sh` reports *cannot open
… Permission denied* for anyone who is not the owner. Git tracks only the exec
bit, so the repo cannot guarantee the read bits either.

Every Dockerfile therefore sets modes explicitly rather than inheriting them:

```dockerfile
RUN chmod -R a+rX /app && chmod 0755 /app/entrypoint.sh
```

This is not cosmetic. It is the difference between an image that runs only as
root and one that runs for anybody — which is every Apptainer invocation, and
every `docker run --user`.

Mount points get the same treatment: `RUN mkdir -p /data && chmod 1777 /data`,
so a run without a bind mount still works for a non-root user.

---

## 3. `entrypoint.sh` is the contract

Every image's `ENTRYPOINT` is `/app/entrypoint.sh`: a POSIX shell script that
sets up the environment and then `exec`s the real program with `"$@"`.

`exec` matters — the program becomes PID 1 and receives signals. `"$@"` matters
— Tapis `appArgs` / `containerArgs` and `apptainer run` arguments arrive there.

Apps may be written in any language. Only two files know which: the `Dockerfile`
(which installs it) and `entrypoint.sh` (whose last line runs it). Everything
else — workflow, registry layout, pull commands — is identical across the
family. That uniformity is the whole point.

`entrypoint.sh` is also where a headless display goes (`Xvfb` for GUI, emulator
or visualisation apps) and where an environment gets activated (conda, a Spack
view, `LD_LIBRARY_PATH` for a vendored solver).

### The exception: an app that is several processes

A desktop is an X server, a window manager, a file manager, websockify and the
gate. There is no single real program to `exec` into, and `exec`ing one of them
discards the shell that owns the rest — along with its `trap`.

The `app-object-detection-novnc-*` apps found this the expensive way. Their
orderly shutdown was written, was correct, and had never run once, because
`exec /app/web/token-gate.sh` replaced the shell that installed it a hundred
lines earlier. Nothing was ever *stopped*; it was destroyed when the container's
namespace went away — and under Apptainer, where there is no namespace to go
away, not even that.

So a multi-process app's entrypoint stays and supervises: start everything in
the background, install the trap, and watch the two or three pids whose death
means the session is over. It is still PID 1 under Docker and still receives the
container's `SIGTERM`, more faithfully than before, because now something acts
on it.

Two costs, both cheap and both necessary:

- A shell at PID 1 has to reap its own children, or every window the user closes
  leaves a zombie.
- `kill -0` **succeeds for a zombie**, so a naive liveness check never notices
  the session ending. Read the process state and `wait` for what it finds dead;
  that does the reaping too.

Poll rather than block. POSIX `wait PID` waits on one child and bare `wait`
waits on all of them, and what is needed is whichever of three goes first.

**Detaching is not logging out.** Closing the browser tab leaves the session
running — Xvnc's `-AlwaysShared` means reopening the URL returns you to it with
the windows where you left them, which is what you want on a flaky link. Ending
a session therefore has to be an explicit act: a `Log out` launcher, or the
desktop's own if it has one, reaching the supervisor. Single-program apps keep
the `exec`; it is still the rule.

---

## 4. Dependencies

There is **no `requirements.txt` in the template** — that is a Python
convention, and these apps may be R, Node, Julia, compiled Fortran, or licensed
vendor software. Use whatever manifest the stack actually has, copy it into the
image *before* the source so the layer caches independently, and install it in
the Dockerfile.

**Pin exactly anything that ends up inside the image.** Reproducibility is the
reason to ship a container at all; an unpinned build defeats it.

**Accelerator wheels: install the CPU build first, explicitly.** PyPI's default
`torch` wheel for Linux is the CUDA build — roughly 2 GB of GPU runtime a CPU
node never touches, and the `.sif` carries every byte of it to every compute
node. `app-object-detection` installs torch from PyTorch's CPU index in its own
step *before* `requirements.txt`, so ultralytics finds the requirement already
satisfied. The GPU route is a commented block in the same Dockerfile. The same
trap exists for JAX, ONNX Runtime and TensorFlow.

---

## 4a. Interactive web and VNC apps

Anything serving a browser UI — JupyterLab, RStudio, noVNC, ParaView layered on
VNC — carries `web/` from the template and obeys four extra constraints, set by
the SDSC Satellite reverse proxy and by running unprivileged on a compute node.

1. **Per-session token auth, in the URL.** The user opens
   `https://<session-label>.<sat-id>.sat.<domain>/?<OSP_APP_TOKEN_NAME>=<OSP_APP_TOKEN>`
   (an opaque session label under the Satellite proxy's name).
2. **Exactly one exposed port.** HTML, assets and websockets all arrive on
   `OSP_APP_PORT`. Everything else binds `127.0.0.1`.
3. **No root, no sudo, no fakeroot at run time.** `OSP_APP_PORT` must be ≥ 1024,
   and nothing may write outside `/tmp` and the working directory.
4. **TLS is terminated upstream.** Satellite holds the certificate and speaks
   plain HTTP to the container over the trusted cluster network.

Satellite routes by **per-session subdomain, not path prefix** — so apps do
*not* need `--base-url` or prefix support. They do need `X-Forwarded-Proto:
https`, or they generate `ws://` URLs on an `https://` page and the browser
refuses them.

### The three variables

| Variable | Default | Meaning |
|---|---|---|
| `OSP_APP_PORT` | `8080` | the single port the container listens on |
| `OSP_APP_TOKEN` | generated | the per-session secret |
| `OSP_APP_TOKEN_NAME` | `token` | the query parameter it arrives in |

All three are settable on the `docker run` / `apptainer run` command line, which
is the only channel available — no sudo, no config files written into the image.
`web/session-env.sh` applies the defaults, generates a token if none was passed
(so a bare `docker run` still works), rejects a privileged port, and prints the
port and entry path for the job script to register with Satellite.

`OSP_APP_TOKEN_NAME` is **per-app and configurable**. It defaults to `token`
because that is what JupyterLab uses natively. nginx maps it to `$arg_<name>`
and `$cookie_<name>`, so keep it to `[A-Za-z0-9_]` — a dash silently becomes an
underscore.

### Two branches

**A — the app has native URL-token auth.** Bind it straight to
`0.0.0.0:$OSP_APP_PORT`, hand it `OSP_APP_TOKEN`, delete the gate files. `app-jupyter`.

**B — the app has none.** Start it on `127.0.0.1:$OSP_APP_UPSTREAM_PORT`, then
`exec web/token-gate.sh`, which renders `web/nginx.conf.template` and runs nginx
on `OSP_APP_PORT`. `app-novnc`.

Branch B is not a workaround for noVNC in particular, and the gate is not
redundant with auth the app already ships. websockify is the instructive case,
because it looks like it could do this itself and cannot: `--token-plugin` is a
*target selector* — it picks which backend to connect to and denies nothing —
while the auth plugins are `BasicHTTPAuth`, `ExpectOrigin` and
`ClientCertCNAuth`, whose interface is
`authenticate(headers, target_host, target_port)`. The query string is never
passed in, so a `?token=` check cannot be written against it without patching
websockify. (`--web-auth` does extend those plugins to static files; coverage
was never the gap.) Expect the same of the next branch-B app, and put the
authentication in the gate rather than re-solving it per app, in whatever
language that app happens to be.

### What the gate does, and why each piece is there

- Valid `?<name>=<token>` → `Set-Cookie` (HttpOnly, Secure, SameSite=Lax) and a
  **relative** 302 to the same path. The secret stops travelling in URLs,
  history and `Referer` headers after one hop.
- `absolute_redirect off` is not optional. Left on, nginx builds the Location
  from *our* scheme and port (`http://host:6080/`) and sends the browser
  somewhere that does not exist behind a TLS-terminating proxy.
- Cookie present → proxied through, websocket upgrade included. Neither → 403.
- `proxy_http_version 1.1` + the `Upgrade`/`Connection` pair is what makes
  noVNC, Jupyter terminals and RStudio work. Without it the page loads and then
  silently does nothing.
- `proxy_read_timeout 86400s` and `proxy_buffering off`: an idle interactive
  session must not be cut at nginx's 60s default.
- nginx runs unprivileged — no `user` directive (needs root), port ≥ 1024, and
  pid/logs/temp paths all under `$TMPDIR/nginx` because the `.sif` is read-only.
- `location /` is a single `proxy_pass` on purpose. Where the upstream serves
  static assets — noVNC's `vnc.html` and its JavaScript, say — nginx could
  serve them from a `root` directive and save a hop per file. Don't: the moment
  the location block knows what the app is, the template stops being the one
  file every branch-B app copies unedited.

### Configuration the image ships goes in /etc/xdg, not the home directory

Three times, across two apps, the same mistake: seeding a default into the
session home so that the user could change it. That makes the image's default a
user *override*, which then survives every later image update — so a fix never
reaches anyone who kept their home directory — and it leaves nothing working at
all when seeding is turned off.

The right split is the one XDG already defines. Defaults the image ships go in
the system location; the home directory holds only what the user creates.

| What | Ships at |
|---|---|
| File associations | `/usr/share/applications/mimeapps.list` |
| libfm / PCManFM | `/etc/xdg/libfm/libfm.conf` |
| XFCE channels | `/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/*.xml` |

Each of those is read *before* the user's own copy, so a change made through the
GUI still wins, and the daemon that owns the store only ever writes the user's
side. Seed into `$HOME` only what has to be a real file there — desktop
launchers, a tutorial notebook, a README — and never overwrite it.

**Check where the library actually reads from, not where it looks like it
should.** libfm loads `libfm/libfm.conf` from `XDG_CONFIG_DIRS` and then
`XDG_CONFIG_HOME`. It never opens `~/.config/pcmanfm/<profile>/libfm.conf` —
which is exactly where such a file seems to belong, sitting beside the
`pcmanfm.conf` that pcmanfm does read from there. Settings put in it load never
and fail silently, and the symptom is a desktop where some settings took and
others did not.

### The session home, and seeding into it

The older three apps set `HOME=/tmp` and work out of `/data`. The two
`app-object-detection-*` apps do it differently, and new interactive apps
should follow them: `USER ospuser`, home `/home/ospuser`, mode **1777**, and
that home is the `WORKDIR`.

1777 rather than 0755 because the runtime uid is never guaranteed to be 1000 —
`docker run --user` passes whatever the caller is, and Apptainer always does. A
0755 home owned by uid 1000 is a home nobody else can write to. The sticky bit
is what stops that from also meaning "anyone may delete anyone's files".

One trap on the way in: Ubuntu's base image has shipped a placeholder `ubuntu`
account at uid 1000 since 24.04, so `useradd --uid 1000` fails the build with
*UID 1000 is not unique*. Take the uid over rather than moving to 1001 — read
the holder's name out of `getent passwd`, `userdel -r` it, then check the uid
is actually free, because `userdel -r` exits 12 when there is no mail spool to
remove and that is not a failure. Debian-based images carry no such account,
which is why only the Ubuntu-based apps need any of this.

Under Docker, `WORKDIR` makes home and working directory one place. Under
Apptainer they part company on purpose: `$HOME` is the caller's real home,
where dotfile configuration belongs, and `$PWD` is the directory they ran from,
where their data is. Open windows on `$PWD`, write configuration to `$HOME`,
have the program read and write relative paths, and both cases come out right.

**Anything the user needs to edit is copied in at startup, not baked in.** A
tutorial notebook, a desktop's `gtk-3.0/settings.ini`, a project skeleton,
sample data: the master lives read-only under `/app` like the model weights,
and `entrypoint.sh` copies it into the session home if it is not already there.
Three reasons, each sufficient on its own — `/app` is inside the read-only
`.sif`, so the first Ctrl-S fails; a bind mount over the home directory hides
anything baked underneath it; and under Apptainer `$HOME` is a directory the
build never saw, so startup is the only moment the file can be put there at all.

**Never overwrite.** Skip any file that already exists, so a user's edits
survive a restart, and give it an off switch (`OSP_SEED_NOTEBOOKS`,
`OSP_SEED_DESKTOP`) for people who would rather nothing appeared in their home
directory. Probe the destination the way `entrypoint.sh` already probes
`$TMPDIR`: if it is not writable, say so on stderr and carry on rather than
dying under `set -e`.

### Two things that only bite locally

`docker run` starts the container as **root**; Apptainer never does. That cuts
two ways. An app that refuses uid 0 — JupyterLab does — needs a flag for the
Docker case (`--ServerApp.allow_root=True`). And anything the container writes
into a bind mount lands on the host owned by `root`, needing `sudo` to delete.

So always run locally with `--user "$(id -u):$(id -g)"`: files come out owned
by you, and it matches how Apptainer will run it. Both the flag and
`allow_root` are no-ops under Apptainer.

That uid has no `/etc/passwd` entry, so `whoami` fails and `ls -l` shows bare
numbers. Apptainer generates the entry itself, so this is a Docker-only
annoyance; locally, either run as `--user "$(id -u):0"` and let
`web/session-env.sh` append an entry (`/etc/passwd` is group-writable in the
interactive images for exactly this), or bind-mount `/etc/passwd` and
`/etc/group` read-only. Nothing actually breaks either way — only code that
calls `getpwuid()` notices.

Never declare `OSP_APP_TOKEN_NAME` as an `ENV`. BuildKit's
`SecretsUsedInArgOrEnv` check matches on the word TOKEN and warns on every
build, even though the value is a parameter name rather than a secret.
`web/session-env.sh` defaults it, so the `ENV` buys nothing.

### Where the token must not end up

A compute node is multi-user, so treat the session token like any other secret:

- **Never on a command line.** `/proc/<pid>/cmdline` is world-readable and
  `ps aux` will hand the session to anyone on the node. `/proc/<pid>/environ` is
  `0400`, so the environment is the right channel — `app-jupyter` passes
  `JUPYTER_TOKEN` rather than `--IdentityProvider.token`.
- **Never in a world-readable file.** The gate renders the token into
  `nginx.conf`, so `token-gate.sh` sets `umask 077` first.
- **Never in a log.** nginx's default `combined` format logs the full request
  line including the query string, and the first request of every session
  carries the token there. The gate logs `$uri` only.

The redirect that trades `?token=` for a cookie is part of the same discipline:
it keeps the secret out of browser history and `Referer` headers after one hop.

### TMPDIR points somewhere the container cannot see

Schedulers hand jobs a `TMPDIR` like `/scratch/$USER/job.12345`. Apptainer binds
`$HOME`, `/tmp` and `$PWD` by default — **not** `/scratch`. So inside the
container that path does not exist, the root filesystem is read-only, and
`mkdir -p "$TMPDIR"` fails with *cannot create directory '/scratch': Read-only
file system*, killing the entrypoint under `set -e` before the app ever starts.

Every entrypoint therefore probes rather than trusts: it walks `$TMPDIR`, then
`/tmp`, then `$HOME`, and takes the first it can actually create and write.
It says so on stderr when it falls back, so the substitution is never silent.

Bind the real scratch in if you want it used:

```bash
apptainer run --bind /scratch ...          # or --env TMPDIR=/tmp
```

The general rule: a container inherits environment variables from a host whose
filesystem it cannot see. Any inherited *path* is a claim to be verified, not a
fact — probe it, fall back, and say which one you took.

### Shared /tmp is the node's, not yours

Under Apptainer `/tmp` is normally the compute node's, shared with every other
user on it, and there is no network namespace either. Anything with a fixed
node-global name collides between two users; anything on TCP loopback is
visible to all of them. Three consequences, all handled in the examples:

- **Scratch directories get a uid suffix.** `$TMPDIR/nginx-$(id -u)`,
  `$TMPDIR/jupyter-$(id -u)`. Both tools create these `0700`, so a fixed path
  leaves the second user unable to write to the first user's directory.
  This applies to the standard environment variables too, and it is easy to
  miss because they get set once as an `ENV` and then forgotten:
  `XDG_RUNTIME_DIR` (dbus creates it `0700`), `XDG_CACHE_HOME` (a thumbnail
  cache), `MPLCONFIGDIR`, `YOLO_CONFIG_DIR`. Derive them in `entrypoint.sh`
  from `$TMPDIR` and the uid, leaving the `ENV` as the fallback for a bare
  `docker run`. `app-object-detection-novnc` does this;
  **`app-novnc` still has a fixed `XDG_RUNTIME_DIR=/tmp/run` and wants the
  same fix.** The symptom is a second session on a node with no thumbnails and
  nothing in any log saying why.
- **X display numbers are walked, not hardcoded.** `/tmp/.X<n>-lock` and
  `/tmp/.X11-unix/X<n>` are node-global; `app-novnc` tries `:1, :2, …` until
  one takes rather than failing on *Server is already active for display 1*.
- **Kernel/IPC channels avoid TCP.** JupyterLab runs with
  `--KernelManager.transport=ipc` so its ZMQ channels are unix sockets rather
  than ports on the node's loopback.

When adding an interactive app, ask what it names globally — a port, a lock
file, a socket path, a scratch directory — and scope every one of them.

### VNC specifics

Install a wallpaper setter (`feh`) even though nobody asked for a wallpaper.
Fluxbox's default style carries a `background:` directive, which makes it shell
out to `fbsetbg`, which needs one of feh / Esetroot / display / hsetroot to
exist. With none installed, `fbsetbg` reports the failure as an **xmessage
dialog on the desktop** — the first thing a user sees through noVNC. The same
trap waits behind any desktop environment layered on this skeleton.

Xvnc runs `-SecurityTypes None -localhost`, with no VNC password, on purpose:
its only client is websockify inside the same container, and a VNC password
would be a second secret guarding a socket nobody can reach. The gate is the
authentication that matters.

`/tmp/.X11-unix` must exist before Xvnc starts — X only creates it as root. The
Dockerfile pre-creates it (Docker case) and the entrypoint creates it too
(Apptainer case, where `/tmp` is usually bind-mounted from the host).

noVNC's client is `vnc.html` and needs query parameters to autoconnect, but the
gate strips the query string after the token exchange — so the image bakes an
`index.html` that redirects to `vnc.html?autoconnect=true&...`.

---

## 5. The workflow, and why it looks like that

**Triggers: pushes to `main`, `v*` tags, manual dispatch. Nothing else.**
Pull requests do not build. Every run of this workflow publishes, so there is
never a run whose result you have to go looking for.

**Actions are pinned to major tags** (`@v6`, `@v4`, `@v7`). Minor and patch
releases arrive without a commit; a major bump is a deliberate edit applied
across every `app-*` repo at once.

**Apptainer is installed by hand, from the upstream release `.deb`** — not from
a marketplace action. Two reasons, both load-bearing:

- Every marketplace action is a bundled Node.js program, and GitHub retires Node
  runtimes on its own schedule. `eWaterCycle/setup-apptainer` is a small
  community project that had not shipped a Node 24 major, so it produced a
  deprecation annotation with no fix available. A plain `run:` step has no Node
  runtime to deprecate.
- The release `.deb` ships the AppArmor profile that Ubuntu 24.04+ requires
  before Apptainer can create unprivileged user namespaces. The Apptainer PPA
  package notably does **not** include it.

The install step reads `/etc/os-release` to choose between the plain and
`-trixie+` `.deb` builds, so it survives `ubuntu-latest` moving off 24.04.
`APPTAINER_VERSION` is pinned exactly and is the only knob in the file.

**The `sif` job converts the image the `docker` job just pushed**, rather than
rebuilding from the Dockerfile. The `.sif` is then provably the same layers
users get from `docker pull`, not a parallel build that drifted.

**`platforms: linux/amd64`, on purpose.** It matches HPC. Multi-arch doubles
build time and has no `.sif` counterpart. It does mean `docker run` on an Apple
Silicon laptop emulates and is slow.

**No secrets.** Both jobs use the automatic `GITHUB_TOKEN` with
`packages: write` + `contents: read`.

---

## 6. GHCR notes for this owner

- Packages are created **public** here — no visibility change step is needed.
- `docker/metadata-action` emits the `org.opencontainers.image.source` label,
  which is what links the package to its repo. Nothing to do manually.

---

## 7. Creating a new app

```bash
cp -r app-template app-<thing> && cd app-<thing>
rm CONVENTIONS.md     # it lives in app-template only
# edit Dockerfile, entrypoint.sh, README.md; add the source
git init -b main && git add -A && git commit -m "initial app-<thing>"
gh repo create OneSciencePlace/app-<thing> --public --source=. --push
gh run watch          # the sif job is the slow one
git tag v1.0.0 && git push --tags   # once it stabilises
```

Before any of that, build and run it locally — no GitHub, no registry:

```bash
docker build -t app-NAME:dev .
docker save app-NAME:dev -o app-NAME.tar
apptainer build app-NAME.sif docker-archive://app-NAME.tar
```

Always test the `.sif`, not just the image. Rule 2 above (read-only filesystem)
is the one that passes under `docker run` and fails on the cluster, and this is
the cheapest place to catch it. Each repo's README has the run commands.

---

## 8. Verified stack (checked 2026-08-27)

Base images and actions current as of this date; re-check when starting a new
app. The `app-object-detection` Python stack below was resolved and run
end-to-end (import, `predict()`, `plot()`), not merely version-bumped.

| Component | Version |
|---|---|
| actions/checkout | v6 |
| docker/setup-buildx-action | v4 |
| docker/login-action | v4 |
| docker/metadata-action | v6 |
| docker/build-push-action | v7 |
| apptainer | 1.5.2 |
| ubuntu (template base) | 26.04 |
| python (detection) | 3.14-slim |
| ultralytics | 8.4.131 |
| torch / torchvision | 2.13.0 / 0.28.0, CPU-only |
| model weights | yolo11n.pt (yolo26n.pt also verified working) |

Known-unverified: the exact `torch==2.13.0` / `torchvision==0.28.0` pins were
resolved against PyPI, not against `download.pytorch.org/whl/cpu` directly. If a
build fails, it will be a version-not-found on that one line.
