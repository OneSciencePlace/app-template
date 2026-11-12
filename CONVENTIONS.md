# app-* container repos — conventions

The conventions for OneSciencePlace's family of GitHub repos named `app-<thing>`.
Each one builds a Docker image **and** a Singularity/Apptainer `.sif` from a
single Dockerfile, and hosts both in GitHub Container Registry. The repos are
deliberately minimal: they exist to illustrate the configure → build → host
mechanism, not to be impressive software.

This file records the decisions that are *not* obvious from reading the files,
so a new working session (human or Claude) can pick up without re-deriving them.

It lives in `app-template`, the skeleton every app is copied from; an app
copied from the template deletes its copy (§7). Naming, versions and terms
come from the organization-wide rules in
[`osp-conventions`](https://github.com/OneSciencePlace/osp-conventions)
(`conventions.md`). Where the two differ, `osp-conventions` wins. The internal
material for these apps is in OSP's private `osp-ops` repository: how a
system and an image are validated for interactive apps
(`runbooks/validate-system.md`, with the scripts in `tools/`), which have
passed (`inventory/validations.yml`), and the design notes behind the
security model below (`design/app-hardening/`).

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
- **Status of the examples.** `app-template` and `app-novnc` (from `1.0.0`)
  follow this document. The other examples are being brought in line; until
  an example's first release after this change, where it and this document
  differ, this document is right.

---

## 1. Naming — everything derives from the repo name

| Thing | Pattern |
|---|---|
| GitHub org | `OneSciencePlace` |
| repo | `github.com/OneSciencePlace/app-<thing>` |
| image | `ghcr.io/onescienceplace/app-<thing>` |
| sif | `ghcr.io/onescienceplace/app-<thing>-sif` |
| tags | a push to `main`: `latest`; a manual run on another branch: `sha-<short>`; a `v<version>` git tag: `<version>`. The image also gets `sha-<short>` on every run |

`.github/workflows/build-and-push.yml` never mentions the app. It reads
`${{ github.repository }}` and derives both package names from it, which is why
the file is copied **byte-for-byte** into every repo and never edited — the one
exception being the `APPTAINER_VERSION` env var.

A git tag `v1.0.0` produces the `1.0.0` tag on *both* packages, so an image and
its `.sif` always carry the same version string. The `.sif` gets one tag per
run (the image's primary one), so a branch build's `.sif` is found by its
`sha-<short>` tag.

**Which version** (from `osp-conventions`): template and OSP-written images
(`app-template`, `app-novnc`, the object-detection apps) use semver, starting
at `1.0.0`. An image that packages versioned software takes that software's
version — `app-jupyter` is `4.6.3` for JupyterLab 4.6.3 — and an OSP-only
change in behavior with no new upstream release adds `-osp<n>`
(`4.6.3-osp1`, git tag `v4.6.3-osp1`). Any rebuild that changes content is a
new version.

**Pinning.** A Tapis app definition names the artifact for its runtime by tag
**and** digest, never `latest`: `app-novnc-sif:1.0.0@sha256:…` for
Apptainer / Singularity, `app-novnc:1.0.0@sha256:…` for Docker. The image and
its `.sif` have different digests, and each is validated on its own.

**Repo names** (also from `osp-conventions`): `app-<interface>` or
`app-<interface>-<software>`, with `<software>` the upstream's own name
(`app-novnc`, `app-novnc-paraview`). Repos that predate those conventions keep
their names.

**Case matters, and it differs between the two.** The GitHub org is
`OneSciencePlace`; the registry path is `ghcr.io/onescienceplace/...`. OCI
reference grammar permits only lowercase in a repository name, while
`${{ github.repository }}` preserves the owner's capitalization — so the
workflow folds it to lowercase once (`${GITHUB_REPOSITORY,,}`) and both jobs
use that. Passing `github.repository` straight into a `docker://` or `oras://`
reference produces an invalid-reference failure.

`.sif` files are pushed with ORAS, not Docker. They are not `docker pull`-able,
which is why they live under a separate `-sif` package rather than a tag suffix
on the image.

---

## 2. The four rules every app must follow

These exist because a `.sif` behaves differently from a Docker container, and
because the node it lands on is not the machine you built it for. Violating
them produces an image that works perfectly under `docker run` and fails on
the cluster.

1. **Install everything at build time.** A `.sif` is mounted read-only and HPC
   compute nodes are often offline. Nothing — model weights, reference data,
   a first-run cache — may be downloaded on first use.
2. **Two kinds of scratch, and never `/app`.** Under the run profile (§2a)
   `/tmp` is private to the session but small, and `$TMPDIR` is the job
   directory, on shared storage.
   - **Session-private** — secrets, sockets, rendered config, pid files, logs,
     X cookies, kernel connection files — goes in `$OSP_APP_SOCK_DIR`, a fresh
     `0700` directory under `/tmp` that `web/session-env.sh` creates
     (interactive apps). Small: the private `/tmp` is a tmpfs of about 64 MB.
   - **Bulk** — caches, large temporary files — goes under `$TMPDIR`, which the
     app definition points at `<job directory>/tmp`. **Never a socket or a
     secret under `$TMPDIR`**: sockets on Lustre or NFS are unreliable, and
     the job directory outlives the session.

   Libraries that write into `$HOME` or their own install tree need an
   environment variable redirecting them. The image's baseline is
   `HOME=/tmp`, `XDG_CACHE_HOME=/tmp/.cache`, `MPLCONFIGDIR=/tmp/matplotlib`,
   so something is writable under a read-only `.sif`; `web/session-env.sh`
   then moves `HOME` and `XDG_CACHE_HOME` per session while those defaults
   are still in effect (§4a, *Scope by session*). Add whatever else your stack
   needs (`YOLO_CONFIG_DIR`, `NUMBA_CACHE_DIR`, `R_LIBS_USER`…), and point
   large ones under `$TMPDIR` in `entrypoint.sh`. An app that needs a real
   home directory — a desktop, a notebook root, a place to seed files the
   user will edit — sees §4a, *The session home, and seeding into it*.
   Nothing may write to `/app`.
3. **Do not trust an inherited path.** Under the run profile the app
   definition sets `TMPDIR` deliberately. On a bare run a scheduler's
   `$TMPDIR` may point at a host directory Apptainer does not bind. Probe it,
   fall back, say which you took (§4a, *TMPDIR points somewhere the container
   cannot see*).
4. **Read and write relative to the current directory.** Docker honors the
   image's `WORKDIR`; Apptainer *ignores* it and uses the caller's directory
   (under the profile, the job directory, set by `--pwd`). Baked-in assets
   are the exception — reference those by absolute path under `/app`. Never
   mix the two.

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

**No setuid or setgid programs.** The template's Dockerfile strips those bits
from everything in the image, after the last package install
(`find / -xdev -perm /6000 -type f -exec chmod a-s {} +`). Interactive images
make `/etc/passwd` group-writable (§4a, *Two things that only bite locally*);
under a plain `docker run` without `no-new-privileges`, that plus a setuid
`su` is a way to root inside the container. Keep the line.

---

## 2a. Security model: shared accounts

**How these apps are run.** OSP runs portal users' jobs on HPC and cloud
systems, usually under a **community (service) account**: many portal users
execute as one Unix uid. This is a requirement of the model, not a deficiency
to engineer away. Two sessions of the same account are one identity to the
kernel; there is no root, and on most systems no network namespace. Isolation
comes from what an ordinary user has: mount namespaces with a restricted set
of binds, PID and IPC namespaces, and application-level authentication. Some
systems run jobs under the user's **own account**; the same profiles apply
there and keep one user's sessions apart from each other.

**The boundary, stated once.** OSP uses restricted filesystem mounts and
namespace isolation to prevent an application in one session from reaching
another session's resources. Correctly configured and validated, these
controls isolate what is visible from inside a container. They do not create
separate Unix identities, they do not prevent access through host-side
processes available to the same uid, and filesystem containment alone is not
a complete defense against deliberately malicious native code.

**The run profiles.** These go into each Tapis app definition, per system and
per runtime. They are never built into an image, and an image must work under
them unchanged. A Tapis app version names one runtime.

Apptainer / Singularity (`<jobdir>` is the job's working directory):

```
interactive: --contain --pid --ipc --cleanenv --no-mount bind-paths,cwd --pwd <jobdir> --bind <jobdir>:<jobdir>
batch:       --contain --cleanenv --no-mount bind-paths,cwd --pwd <jobdir> --bind <jobdir>:<jobdir>
```

with `TMPDIR=<jobdir>/tmp` passed in, the token passed as
`APPTAINERENV_OSP_APP_TOKEN` / `SINGULARITYENV_OSP_APP_TOKEN` (never
`--env OSP_APP_TOKEN=…`), and `APPTAINER_BIND`, `APPTAINER_BINDPATH`,
`SINGULARITY_BIND`, `SINGULARITY_BINDPATH` unset by the launcher. Write the
flags out: `--containall` expands differently between versions. Batch leaves
out `--pid --ipc`, which can conflict with MPI and scheduler tooling and guard
no session token; a system where batch jobs share hosts with interactive
sessions may require them for batch apps too. A system adds only what it must
(`--nv` / `--rocm` with `CUDA_VISIBLE_DEVICES`, a read-only bind of a
license or MPI path, a read-only dataset), never a scratch parent.

Docker:

```
--user <uid>:<gid> --cap-drop ALL --security-opt no-new-privileges --ipc private
--pids-limit <n> --memory <per-session budget>
```

on a network of the job's own, with `OSP_APP_BIND=0.0.0.0` (the tunnel reaches
the gate across that network, and nothing else is on it), a fixed
`OSP_APP_PORT`, and the token in the job's `--env-file`. Never `--privileged`,
`--network host`, `-p` / `--publish`, `--pid host`, `--ipc host`,
`--cap-add`, or a bind of `/`, of the Docker socket or of a parent of the job
directory. The image runs as whatever uid `--user` gives it.

What an image may assume under the Apptainer profile:

- `/tmp`, `/var/tmp` and `$HOME` are **private, empty and small** (a tmpfs,
  about 64 MB by default). Secrets and sockets belong there; bulk data does
  not.
- `$TMPDIR` is the **job directory**: room to grow, shared storage.
- The host environment is gone (`--cleanenv`); the image's `ENV` still applies.
- `$HOME` is not the user's home and does not persist between sessions.
- **The network is shared** with every other session on the node: loopback
  TCP ports and abstract Unix sockets are visible to all of them.

**The rule.** Every per-session resource is either in `$OSP_APP_SOCK_DIR`
(under the private `/tmp`) or is the one authenticated TCP listener. Nothing
else: no second TCP port, not even on `127.0.0.1`; no abstract Unix socket; no
socket or secret under `$TMPDIR` or in the job directory.

**Policy.** An interactive app is offered on a system only after three
validations pass, each recorded in `osp-ops`: the **system** (its profile keeps
a session's private places private there), the **image**, by digest (it keeps
everything in those places apart from its one authenticated listener, and
starts, stops and cleans up properly), and the **two together** on that
system, including the path through the Satellite proxy. No exceptions. Batch
apps are not gated this way. Where sessions share an account, users are told:

> Interactive sessions on this system run under an account shared with other
> users of this portal. Each session is kept apart from the others, but they
> are not separate accounts. Do not use these sessions for sensitive data.

**OSP-run clusters** (compute site `osp`: course and test clusters). There the
runtime configuration is OSP's to set, not a compute site's to probe:
interactive sessions on exclusive nodes first; where nodes are shared, OCI mode
or the enforced profile, `--pids-limit` and `--memory`, and no login as the
service account. The configuration is in `osp-ops`
(`design/app-hardening/osp-container-run-options-v7.md` §12).

---

## 3. `entrypoint.sh` is the contract

Every image's `ENTRYPOINT` is `/app/entrypoint.sh`: a shell script that sets up
the environment and then `exec`s the real program with `"$@"`. Its first lines
after the shebang are `set -eu` and `umask 077`, so nothing the session
creates is readable by any other Unix user unless it is made with an explicit
mode.

`exec` matters — the program becomes PID 1 and receives signals. `"$@"` matters
— Tapis `appArgs` / `containerArgs` and `apptainer run` arguments arrive there.

Apps may be written in any language. Only two files know which: the `Dockerfile`
(which installs it) and `entrypoint.sh` (whose last line runs it). Everything
else — workflow, registry layout, pull commands — is identical across the
family. That uniformity is the whole point.

`entrypoint.sh` is also where a headless display goes (`Xvfb` for GUI, emulator
or visualization apps) and where an environment gets activated (conda, a Spack
view, `LD_LIBRARY_PATH` for a vendored solver).

### The exception: an app that is several processes

A desktop is an X server, a window manager, websockify and the gate; a branch-B
app (§4a) is at least the app and the gate. There is no single real program to
`exec` into, and `exec`ing one of them discards the shell that owns the rest —
along with its `trap`.

The `app-object-detection-novnc-*` apps found this the expensive way. Their
orderly shutdown was written, was correct, and had never run once, because
`exec /app/web/token-gate.sh` replaced the shell that installed it a hundred
lines earlier. Nothing was ever *stopped*; it was destroyed when the container's
namespace went away — and under Apptainer without `--pid`, where there is no
namespace to go away, not even that.

So a multi-process app's entrypoint stays and supervises, with the shared
`web/supervise.sh`, copied unedited from the template. The entrypoint is bash
(≥ 5.1, for `wait -n -p`) and sources it after `web/session-env.sh`:

```bash
. /app/web/session-env.sh
. /app/web/supervise.sh              # installs the cleanup trap first

osp_spawn critical Xvnc       Xvnc       -- Xvnc ...       # first registered = stopped last
osp_spawn leader   fluxbox    fluxbox    -- fluxbox        # clean exit = normal log-out
osp_spawn helper   xterm      xterm      -- xterm
osp_spawn critical websockify websockify -- websockify ...
osp_spawn critical gate       nginx      -- /app/web/token-gate.sh
osp_supervise                                              # never returns
```

- **One process group per service.** Each is started with `setsid`, so
  stopping it stops everything it started — a terminal's shell, a desktop's
  panel.
- **Each launch is checked.** The recorded pid must lead its own group and run
  the expected program (`/proc/<pid>/comm`, the third argument), not a wrapper
  that has already handed off and exited.
- **Critical, leader, helper.** A `critical` or `leader` service exiting ends
  the session. A `leader` exiting 0 is a normal log-out (status 0); anything
  else is status 1; a cancel is 143. `helper`s are only stopped at the end.
  **websockify is critical**: if it dies and the session carries on, the gate
  answers 502 for as long as the job runs.
- **No polling, nothing missed.** Each round first checks that every watched
  service is still alive — so one that died while the rest of the session was
  starting is caught — then `wait -n` sleeps until a child exits (a SIGCHLD
  trap also wakes it). The check reads the process state from `/proc`, because
  `kill -0` succeeds for a zombie.
- **Cleanup on every exit path.** The `EXIT` trap is installed when
  `supervise.sh` is sourced, before the first service starts. It sends TERM to
  every group in reverse start order, the first-registered service (the X
  server) last so applications are not cut off mid-save, then KILL to whatever
  ignored it, then removes `$OSP_APP_SOCK_DIR`.
- **Logs to stderr.** Service output is relayed with a `[name] ` prefix, so
  Tapis captures it with the job and nothing is written into the job
  directory.

The launcher hands out a session's link once `/healthz` answers (§4a); tests
also wait for the supervisor's `[supervise] supervising:` line before acting
on a session.

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
the Satellite proxy, by running unprivileged on a compute node, and by sharing
that node with other sessions of the same account (§2a).

1. **Per-session token auth, in the URL.** The user opens
   `https://<session-label>.<sat-id>.sat.<domain>/?<OSP_APP_TOKEN_NAME>=<OSP_APP_TOKEN>`.
   The session hostname follows `osp-conventions`: an opaque session label
   (lowercase words joined by hyphens, no digits, no user, app or job
   information) under the name of the Satellite proxy that holds the tunnel,
   e.g. `ample-cedar-orbit-tundra.sdsc-01.sat.onescienceplace.org`. The app
   never needs to know it.
2. **Exactly one TCP listener, and it authenticates.** HTML, assets and
   websockets all arrive on `$OSP_APP_BIND:$OSP_APP_PORT`. `OSP_APP_BIND` is
   `127.0.0.1` by default, where the launcher's reverse tunnel connects;
   `0.0.0.0` only inside a Docker job's own network, or for a local
   `docker run -p`. **Everything else the app runs internally is a Unix socket
   in `$OSP_APP_SOCK_DIR`** — never a TCP port, not even on `127.0.0.1`, and
   never an abstract socket: loopback and the abstract namespace are shared by
   every session on the node.
3. **No root, no sudo, no fakeroot at run time.** `OSP_APP_PORT` must be ≥ 1024,
   and nothing may write outside `/tmp` and the working directory.
4. **TLS is terminated upstream.** The Satellite proxy holds the certificate.
   The request reaches the container as plain HTTP through the launcher's
   reverse SSH tunnel, which ends on the node's loopback (Docker: on the job's
   network).

The Satellite proxy routes by **per-session subdomain, not path prefix** — so
apps do *not* need `--base-url` or prefix support. They do need
`X-Forwarded-Proto: https`, or they generate `ws://` URLs on an `https://` page
and the browser refuses them.

### The variables

| Variable | Default | Set by | Meaning |
|---|---|---|---|
| `OSP_APP_PORT` | `8080` | caller | the one TCP port; ≥ 1024 |
| `OSP_APP_BIND` | `127.0.0.1` | caller | the address it binds |
| `OSP_APP_TOKEN` | generated | caller | the per-session secret: at most 200 characters of `[A-Za-z0-9._~-]` |
| `OSP_APP_TOKEN_NAME` | `token` | caller | the query parameter it arrives in, `[A-Za-z0-9_]` |
| `OSP_APP_HEALTH_PATH` | empty (`/`) | the app's entrypoint | what `/healthz` asks the upstream for (branch B; `vnc.html` for noVNC) |
| `OSP_APP_SOCK_DIR` | — | `session-env.sh` | a fresh `0700` directory under `/tmp`; never taken from the caller |

`OSP_APP_UPSTREAM_PORT` is retired: the branch-B upstream is
`$OSP_APP_SOCK_DIR/app.sock`.

**The token never goes on a command line**, not even the
`apptainer` / `docker` one: `ps` shows command lines to every user on the
node. Pass it through the environment — `APPTAINERENV_OSP_APP_TOKEN` (or
`SINGULARITYENV_OSP_APP_TOKEN`), which arrives as `OSP_APP_TOKEN` even under
`--cleanenv`; for Docker, `-e OSP_APP_TOKEN` with no `=value`, or the job's
`--env-file`. Non-secret values may go on the command line (`--env
OSP_APP_PORT=…`). No sudo and no config files written into the image: the
environment is the only channel.

`web/session-env.sh` applies the defaults, validates every value that ends up
in a configuration file, generates a token if none was passed (so a bare
`docker run` still works), rejects a privileged port, sets `umask 077`,
creates `$OSP_APP_SOCK_DIR`, moves `HOME` and `XDG_CACHE_HOME` off the image's
`/tmp` defaults, and prints the port. It prints the tokenized entry path
**only when it generated the token itself**; a token the launcher supplied is
never echoed into the job's output.

`OSP_APP_TOKEN_NAME` is **per-app and configurable**. It defaults to `token`
because that is what JupyterLab uses natively. nginx maps it to `$arg_<name>`
and `$cookie_<name>`, so keep it to `[A-Za-z0-9_]` — a dash silently becomes an
underscore.

### Two branches

Both are sketched in the template's `entrypoint.sh`.

**A — the app has native URL-token auth.** The app itself is the one listener:
bind it to `$OSP_APP_BIND:$OSP_APP_PORT` (never a hard-coded `0.0.0.0`), and
hand it the token through the environment (`JUPYTER_TOKEN`), not as an
argument. Delete the gate files. JupyterLab also needs
`--ServerApp.allow_remote_access=True`, or a loopback-bound server rejects the
Satellite proxy's public `Host` header. `app-jupyter`.

**B — the app has none.** The app listens on the Unix socket
`$OSP_APP_SOCK_DIR/app.sock`; `web/token-gate.sh` renders
`web/nginx.conf.template` and runs nginx on `$OSP_APP_BIND:$OSP_APP_PORT` in
front of it. The app and the gate are two processes, so they run under
`web/supervise.sh` (§3), the gate started once the app's socket exists. A
one-process app may instead start the app in the background and
`exec /app/web/token-gate.sh`, accepting that nothing then notices the app
exiting. `app-novnc`.

Whichever branch, the rule holds: **every interactive service binds loopback
or a Unix socket, gated or not.** Authentication on the app does not make a
`0.0.0.0` listener acceptable.

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
  **relative** 302 to the same path. The secret stops traveling in URLs,
  history and `Referer` headers after one hop.
- `absolute_redirect off` is not optional. Left on, nginx builds the Location
  from *our* scheme and port (`http://host:6080/`) and sends the browser
  somewhere that does not exist behind a TLS-terminating proxy.
- Cookie present → proxied to `unix:$OSP_APP_SOCK_DIR/app.sock`, websocket
  upgrade included. Neither → a bare `403`: no body, no hint of how to get in,
  no nginx version (`server_tokens off`).
- `GET /healthz`, ungated → `ok` with 200 once the app answers 2xx for
  `OSP_APP_HEALTH_PATH`, 503 before. It is `auth_request` against the upstream
  plus a static `ok` file, so nothing of the app's own response reaches the
  caller. The launcher waits for it before handing out the link. It means
  "ready", not "the desktop is usable".
- **Every `proxy_set_header` is inside `location /`.** nginx inherits
  `proxy_set_header` from an enclosing block *only* when the current block
  defines none, so splitting them between `server {}` and `location {}`
  silently drops the outer ones.
- `proxy_http_version 1.1` + the `Upgrade`/`Connection` pair is what makes
  noVNC, Jupyter terminals and RStudio work. Without it the page loads and then
  silently does nothing.
- `proxy_read_timeout 86400s` and `proxy_buffering off`: an idle interactive
  session must not be cut at nginx's 60s default.
- `map_hash_bucket_size 256`, before the first `map`. The token is a key in the
  gate's maps, and the default bucket (often 64 bytes) cannot hold a
  64-character token: nginx refuses to start. 256 holds any token
  `session-env.sh` accepts.
- nginx runs unprivileged — no `user` directive (needs root), port ≥ 1024, its
  error log on stderr, and pid, access log, rendered config and every temp path
  under `$OSP_APP_SOCK_DIR/nginx`, because the `.sif` is read-only and the
  rendered config holds the token.
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

**Under the run profile the home is private, empty and small, every session.**
`--contain` gives each session a fresh home on the private tmpfs. Seeding
therefore runs every time, and nothing a user saves in `~` survives the
session: their work belongs in `$PWD`, the job directory, and file managers and
terminals should open there. Say so in the startup log rather than advising
users to tidy a home that will be gone. A persistent per-user home is an
app-definition decision (`--home <that user's own directory>`, a leaf
directory, never a parent other users' homes sit under), not something an
image arranges.

For Docker, the two `app-object-detection-*` desktop apps show the shape new
interactive apps should follow: `USER ospuser`, home `/home/ospuser`, mode
**1777**, and that home is the `WORKDIR`. The older apps set `HOME=/tmp` and
work out of `/data`.

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
Apptainer they part company on purpose: `$HOME` is the home Apptainer provides
(under the profile, the private one above), where dotfile configuration
belongs, and `$PWD` is the job directory, where the user's data is. Open
windows on `$PWD`, write configuration to `$HOME`, have the program read and
write relative paths, and both cases come out right.

**Anything the user needs to edit is copied in at startup, not baked in.** A
tutorial notebook, a desktop's `gtk-3.0/settings.ini`, a project skeleton,
sample data: the master lives read-only under `/app` like the model weights,
and `entrypoint.sh` copies it into the session home (or the working directory)
if it is not already there. Three reasons, each sufficient on its own —
`/app` is inside the read-only `.sif`, so the first Ctrl-S fails; a bind mount
over the home directory hides anything baked underneath it; and under
Apptainer `$HOME` is a directory the build never saw, so startup is the only
moment the file can be put there at all.

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
by you, and it matches how Apptainer — and OSP's Docker profile — will run it.
Both the flag and `allow_root` are no-ops under Apptainer. Publish the port on
the host's loopback only, and let the gate bind every interface inside the
container, because `-p` cannot reach a container's loopback:

```bash
export OSP_APP_TOKEN=$(openssl rand -hex 32)
docker run --rm --user "$(id -u):$(id -g)" \
  -p 127.0.0.1:6080:6080 \
  -e OSP_APP_PORT=6080 -e OSP_APP_BIND=0.0.0.0 -e OSP_APP_TOKEN \
  ghcr.io/onescienceplace/app-NAME:latest
```

That uid has no `/etc/passwd` entry, so `whoami` fails and `ls -l` shows bare
numbers. Apptainer generates the entry itself, so this is a Docker-only
annoyance; locally, either run as `--user "$(id -u):0"` and let
`web/session-env.sh` append an entry (`/etc/passwd` is group-writable in the
interactive images for exactly this, which is safe only because the images
carry no setuid programs, §2), or bind-mount `/etc/passwd` and `/etc/group`
read-only. Nothing actually breaks either way — only code that calls
`getpwuid()` notices.

Never declare `OSP_APP_TOKEN_NAME` as an `ENV`. BuildKit's
`SecretsUsedInArgOrEnv` check matches on the word TOKEN and warns on every
build, even though the value is a parameter name rather than a secret.
`web/session-env.sh` defaults it, so the `ENV` buys nothing.

### Where the token must not end up

A compute node is multi-user, and under a service account every session is the
same user, so treat the session token like any other secret:

- **Never on a command line** — the app's, or the `apptainer` / `docker`
  command that starts the container, README examples included.
  `/proc/<pid>/cmdline` is world-readable and `ps aux` will hand the session
  to anyone on the node. `/proc/<pid>/environ` is `0400`, so the environment
  is the right channel — `app-jupyter` passes `JUPYTER_TOKEN` rather than
  `--IdentityProvider.token`.
- **Never in the job's output.** stdout and stderr land in the job's archived
  output. `session-env.sh` does not echo a supplied token; check once that the
  app's own start-up banner does not either (Jupyter prints its URL).
- **Never in a file anyone else can reach.** The gate renders the token into
  `nginx.conf`, so that lives in `$OSP_APP_SOCK_DIR` (`0700`, under the
  private `/tmp`), never under `$TMPDIR` or in the job directory, and
  `token-gate.sh` sets `umask 077` first.
- **Never in a log.** nginx's default `combined` format logs the full request
  line including the query string, and the first request of every session
  carries the token there. The gate logs `$uri` only.
- **Not in processes that do not need it.** Today the token is in the
  environment of every process of the session, which `--pid` keeps from other
  sessions; handing it only to the process that checks it (the gate, or
  Jupyter as `JUPYTER_TOKEN`) is planned.

The redirect that trades `?token=` for a cookie is part of the same discipline:
it keeps the secret out of browser history and `Referer` headers after one hop.

One accepted exception: for a Tapis-native token (Jupyter's `JUPYTER_TOKEN`),
Tapis itself writes the value into `tapisjob.env` / `tapisjob.sh` in the job
directory and may render it onto the container command line. That is outside
the image's control; the run profile's mount allowlist and `--pid` contain it.

### TMPDIR points somewhere the container cannot see

Schedulers hand jobs a `TMPDIR` like `/scratch/$USER/job.12345`. Apptainer binds
`$HOME`, `/tmp` and `$PWD` by default — **not** `/scratch`, and under the run
profile not even those. So inside the container that path may not exist, the
root filesystem is read-only, and `mkdir -p "$TMPDIR"` fails with *cannot
create directory '/scratch': Read-only file system*, killing the entrypoint
under `set -e` before the app ever starts.

Every entrypoint therefore probes rather than trusts: it walks `$TMPDIR`, then
`/tmp`, then `$HOME`, and takes the first it can actually create and write.
It says so on stderr when it falls back, so the substitution is never silent.
Under the run profile the probe finds `TMPDIR` as the app definition set it
(`<job directory>/tmp`); the probe guards the bare runs.

**Do not bind a scratch parent to make an inherited `TMPDIR` work.** Set
`TMPDIR=<job directory>/tmp` in the app definition instead. A bind of
`/scratch`, a Lustre root or a group directory shows the container every other
job directory of the account — exactly what the profile's
`--no-mount bind-paths` is there to prevent.

The general rule: a container inherits environment variables from a host whose
filesystem it cannot see. Any inherited *path* is a claim to be verified, not a
fact — probe it, fall back, and say which one you took.

### Scope by session, not by uid

Without the run profile, `/tmp` is the compute node's, shared with every other
user on it; with or without it, the network is shared. Anything with a fixed
node-global name collides between two sessions; anything on TCP loopback or in
the abstract socket namespace is visible to all of them. A uid suffix
(`nginx-$(id -u)`) used to be the answer and **is not enough**: under a
service account two sessions have the same uid, and so the same suffix.

- **Per-session paths live in `$OSP_APP_SOCK_DIR`.** The gate's nginx
  directory, the X cookie (`XAUTHORITY`), `XDG_RUNTIME_DIR`, D-Bus, pid files,
  logs, Jupyter's runtime directory with its kernel connection files: all in
  the session directory, which `session-env.sh` creates fresh, `0700`, with an
  unguessable name, so even on a node-shared `/tmp` it is never another
  session's.
- **Per-session bulk paths are named by session, not uid.** A large cache that
  belongs under `$TMPDIR` goes in a directory named after the session
  directory: `session-env.sh` uses `$TMPDIR/<session directory name>/cache`
  for `XDG_CACHE_HOME`; do the same for `MPLCONFIGDIR`, `YOLO_CONFIG_DIR` and
  friends in `entrypoint.sh`.
- **Image defaults that point into `/tmp` move per session.** An image's
  `ENV HOME=/tmp` and `XDG_CACHE_HOME=/tmp/.cache` belong, on a node-shared
  `/tmp`, to whichever user came first. `session-env.sh` moves them while they
  are still in effect, keeping any value the job set itself.
- **X display numbers are walked, not hard-coded.** `/tmp/.X<n>-lock` and
  `/tmp/.X11-unix/X<n>` are node-global without the profile; `app-novnc` tries
  `:1, :2, …` until one takes rather than failing on *Server is already active
  for display 1*. `/tmp/.X11-unix` is created `mkdir -m 1777` (under
  `umask 077` it would otherwise be `0700` and lock every other user out), and
  if it exists but is not writable the entrypoint says so and exits, rather
  than walking every display to a misleading *no free X display*.
- **No loopback TCP except the gate, and no abstract sockets at all.** X runs
  with `-nolisten tcp -nolisten local`; a D-Bus session bus listens on
  `unix:path=$OSP_APP_SOCK_DIR/…`, never `dbus-launch`'s default (an abstract
  socket on Linux); a desktop's ICE listener is checked; Jupyter's kernels use
  `--KernelManager.transport=ipc`, with the sockets in its runtime directory.
  Check a running session with `ss -ltn` (only the gate's port) and
  `ss -xl | grep '@'` (nothing of the session's).

When adding an interactive app, ask what it names globally — a port, a lock
file, a socket path, a scratch directory — and scope every one of them to the
session.

### VNC specifics

Xvnc speaks RFB only on a Unix socket in the session directory:

```
Xvnc :<n> -rfbunixpath "$OSP_APP_SOCK_DIR/vnc.sock" -rfbunixmode 0600 -rfbport -1 \
     -nolisten tcp -nolisten local -SecurityTypes None -auth "$XAUTHORITY" ...
```

`-rfbport -1` turns its TCP listener off; `-nolisten tcp` and
`-nolisten local` turn off the X server's own TCP and abstract sockets, so X
clients use the filesystem socket `/tmp/.X11-unix/X<n>` and the cookie. There
is no VNC password, on purpose: no socket anyone outside the session can reach,
and a password file would be readable by the same uid that could read the token
anyway. The gate is the authentication that matters. TigerVNC's `-help` lists
its options without the leading dash (`rfbunixpath`), which is what the
Dockerfile's build check greps for.

websockify bridges Unix socket to Unix socket and serves the noVNC client:
`--unix-listen="$OSP_APP_SOCK_DIR/app.sock" --unix-listen-mode=0600
--unix-target="$OSP_APP_SOCK_DIR/vnc.sock"`. That needs a websockify with
`--unix-listen`: Ubuntu 26.04's package has it, 24.04's (0.10) does not. The
entrypoint waits until `app.sock` accepts a connection before starting the
gate, so the first request does not get a 502.

The Dockerfile fails the build, not the session, if a package lacks what the
entrypoint depends on: Xvnc's `rfbunixpath`, websockify's `--unix-listen`,
nginx's `http_auth_request_module`, bash ≥ 5.1.

Install a wallpaper setter (`feh`) even though nobody asked for a wallpaper.
Fluxbox's default style carries a `background:` directive, which makes it shell
out to `fbsetbg`, which needs one of feh / Esetroot / display / hsetroot to
exist. With none installed, `fbsetbg` reports the failure as an **xmessage
dialog on the desktop** — the first thing a user sees through noVNC. The same
trap waits behind any desktop environment layered on this skeleton.

Logging out is the window manager exiting (§3, *leader*). fluxbox's default
keys include `Control Mod1 Delete :Exit`, the same command its menu's **Exit**
runs, which is also how a test logs out without a browser.

`/tmp/.X11-unix` must exist before Xvnc starts — X only creates it as root. The
Dockerfile pre-creates it (Docker case) and the entrypoint creates it too
(Apptainer case, where `/tmp` is the session's own under the profile, or the
node's without it).

noVNC's client is `vnc.html` and needs query parameters to autoconnect, but the
gate strips the query string after the token exchange — so the image bakes an
`index.html` that redirects to `vnc.html?autoconnect=true&...`. `/healthz`
asks for `vnc.html` (`OSP_APP_HEALTH_PATH`).

---

## 5. The workflow, and why it looks like that

**Triggers: pushes to `main`, `v*` tags, manual dispatch. Nothing else.**
Pull requests do not build. Every run of this workflow publishes, so there is
never a run whose result you have to go looking for. To build a branch for
testing, dispatch it by hand: `gh workflow run build-and-push.yml --ref <branch>`
publishes `sha-<short>`.

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
git tag v1.0.0 && git push --tags   # once it stabilizes (§1 for the version)
```

Before any of that, build and run it locally — no GitHub, no registry:

```bash
docker build -t app-NAME:dev .
docker save app-NAME:dev -o app-NAME.tar
apptainer build app-NAME.sif docker-archive://app-NAME.tar
```

Always test the `.sif`, not just the image, and test it **under the run
profile** (§2a), exactly as written there: the interactive one for an
interactive app, the batch one for a batch app, with `TMPDIR=$PWD/tmp` and, for
an interactive app, the token in `APPTAINERENV_OSP_APP_TOKEN`. Rule 2 above
(read-only filesystem, small private `/tmp`) is the one that passes under
`docker run` and fails on the cluster, and this is the cheapest place to catch
it. Each repo's README has the run commands.

For an interactive app, then start **two** sessions as the same user on the
same host, with different ports and tokens, and check they cannot reach each
other: each gate refuses the other's cookie, neither session sees the other's
processes, files or sockets, and only the gate's port is listening. OSP's
isolation checks for this (`tools/two-session-check.sh` and the rest of part B
of `runbooks/validate-system.md`, in `osp-ops`) are what the image's validation
runs.

---

## 8. Verified stack (checked 2026-11-12)

Base images and actions current as of this date; re-check when starting a new
app. The `app-object-detection` Python stack below was resolved and run
end-to-end (import, `predict()`, `plot()`), not merely version-bumped (checked
2026-08-27).

| Component | Version |
|---|---|
| actions/checkout | v6 |
| docker/setup-buildx-action | v4 |
| docker/login-action | v4 |
| docker/metadata-action | v6 |
| docker/build-push-action | v7 |
| apptainer (workflow) | 1.5.2 |
| ubuntu (template base) | 26.04 |
| bash | ≥ 5.1 (`wait -n -p`); Ubuntu 26.04's, checked at build |
| TigerVNC (`tigervnc-standalone-server`) | Ubuntu 26.04's; `-rfbunixpath` checked at build |
| websockify | Ubuntu 26.04's; `--unix-listen` checked at build (24.04's 0.10 lacks it) |
| nginx (`nginx-light`) | Ubuntu 26.04's; `http_auth_request_module` checked at build |
| python (detection) | 3.14-slim |
| ultralytics | 8.4.131 |
| torch / torchvision | 2.13.0 / 0.28.0, CPU-only |
| model weights | yolo11n.pt (yolo26n.pt also verified working) |

Where the run profiles have been exercised:

| Runtime | What | Date |
|---|---|---|
| SingularityCE 3.11.4 (setuid) | a FORK test system on AWS: the system and the `app-novnc` `1.0.0` image pass validation; the two together await the check through the Satellite proxy | 2026-11-12 |
| Apptainer 1.5.2 (unprivileged) | a test rig: all three validation parts, with `app-novnc` pre-release builds | 2026-11-10 |
| Docker 29.9.2 | a test rig: `app-novnc` under OSP's Docker profile, two sessions on two job networks | 2026-11-12 |

Validate on the target runtime version before relying on a profile there:
what `--containall` expands to, and how the private `/tmp` is backed, differ
between versions.

Known-unverified: the exact `torch==2.13.0` / `torchvision==0.28.0` pins were
resolved against PyPI, not against `download.pytorch.org/whl/cpu` directly. If a
build fails, it will be a version-not-found on that one line.
