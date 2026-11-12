# web/ — the interactive-app contract

Drop this directory into any `app-*` repo that serves a browser UI: JupyterLab,
RStudio, noVNC, ParaView layered on VNC. Delete it for batch apps.

| File | Used by | What it is |
|---|---|---|
| `session-env.sh` | every interactive app (sourced) | the variables, their validation, the session's private directory |
| `token-gate.sh` | branch B | renders the nginx config and execs nginx |
| `nginx.conf.template` | branch B | the token gate |
| `supervise.sh` | multi-process apps (sourced, bash) | starts, watches and stops the session's processes |

Copy the files unedited. A fix made here reaches every app the next time
`web/` is copied.

## The constraints

1. **Per-session token auth, passed in the URL.** The user opens
   `https://<session-label>.<sat-id>.sat.<domain>/?<OSP_APP_TOKEN_NAME>=<OSP_APP_TOKEN>`.
   The token authenticates that one session and nothing else.
2. **Exactly one TCP listener, on loopback, authenticated.** Everything the
   browser needs — HTML, static assets, websockets — arrives on
   `$OSP_APP_BIND:$OSP_APP_PORT`, default `127.0.0.1`, where the launcher's
   reverse SSH tunnel connects. Everything else the app runs internally is a
   **Unix socket in `$OSP_APP_SOCK_DIR`** — never a TCP port, not even on
   `127.0.0.1`, and never an abstract socket.
3. **No root, no sudo, no fakeroot at run time.** The container runs as the
   invoking user. `OSP_APP_PORT` must be ≥ 1024, and nothing may write outside
   `/tmp` and the working directory.
4. **TLS is terminated upstream.** The Satellite proxy holds the certificate
   and reaches us as plain HTTP through the reverse SSH tunnel.

The Satellite proxy routes by **per-session subdomain**, not by path prefix, so apps do
*not* need `--base-url` / prefix support. They do need to be told the browser's
scheme is `https`, which is what the `X-Forwarded-Proto` header is for.

## What the gate assumes

The container is run with the OSP interactive run profile
(`--contain --pid --ipc --cleanenv --no-mount bind-paths,cwd`), validated on
that system; or, under Docker, with OSP's Docker run profile (`--user`,
`--cap-drop ALL`, `--security-opt no-new-privileges`, `--ipc private`, limits)
on a network of the job's own, where the gate binds `0.0.0.0` because nothing
else is on that network. Both profiles are in `CONVENTIONS.md` §2a. The session token is present
in the rendered `nginx.conf` and in the environment of the session's
processes. The branch-B upstream is a Unix socket in `$OSP_APP_SOCK_DIR` under
the session's private `/tmp`, never a TCP port. Sessions that share a Unix uid
on a node without these namespaces, or with any directory bound into both, are
a single trust domain; the gate does not protect them from each other. The
gate's own port is on the node's loopback and is protected by the token alone.

Put plainly: OSP uses restricted filesystem mounts and namespace isolation to
prevent an application in one session from reaching another session's
resources. Those controls isolate what is visible from inside a container.
They do not create separate Unix identities, they do not stop host-side
processes running as the same uid, and they are not a complete defense against
deliberately malicious native code.

## The variables

| Variable | Default | Set by | Meaning |
|---|---|---|---|
| `OSP_APP_PORT` | `8080` | caller | the one TCP port; ≥ 1024 |
| `OSP_APP_BIND` | `127.0.0.1` | caller | the address it binds; `0.0.0.0` only inside a Docker job's own network, or for local `docker run -p` |
| `OSP_APP_TOKEN` | generated | caller | the per-session secret, `[A-Za-z0-9._~-]` |
| `OSP_APP_TOKEN_NAME` | `token` | caller | the query parameter it arrives in, `[A-Za-z0-9_]` |
| `OSP_APP_HEALTH_PATH` | empty (`/`) | the app | what `/healthz` asks the upstream for (branch B) |
| `OSP_APP_SOCK_DIR` | — | `session-env.sh` | fresh `0700` directory under `/tmp`; never taken from the caller |

`OSP_APP_UPSTREAM_PORT` is gone: the upstream is `$OSP_APP_SOCK_DIR/app.sock`.

**The token never goes on a command line.** `ps` shows command lines to every
user on the node.

```bash
# Docker: -e NAME with no "=value" copies it from your environment.
export OSP_APP_TOKEN="$TOKEN"
docker run --rm --user "$(id -u):$(id -g)" \
  -p 127.0.0.1:6080:6080 \
  -e OSP_APP_PORT=6080 -e OSP_APP_BIND=0.0.0.0 -e OSP_APP_TOKEN \
  ghcr.io/onescienceplace/app-NAME:latest     # production pins <version>@sha256:<digest>

# Apptainer: APPTAINERENV_<NAME> arrives as <NAME>, even with --cleanenv.
export APPTAINERENV_OSP_APP_TOKEN="$TOKEN"
apptainer run \
  --contain --pid --ipc --cleanenv --no-mount bind-paths,cwd \
  --pwd "$PWD" --bind "$PWD:$PWD" \
  --env OSP_APP_PORT=6080 --env TMPDIR="$PWD/tmp" \
  app-NAME-sif_latest.sif
```

`session-env.sh` applies the defaults, validates every value that ends up in a
configuration file, generates a token if none was given (so a bare
`docker run` still works), rejects a privileged port, creates
`$OSP_APP_SOCK_DIR`, sets `umask 077`, moves `HOME` and `XDG_CACHE_HOME` off
an image's `/tmp` defaults (below), and prints the port. It prints the
tokenized entry path **only when it generated the token itself**; a token the
launcher supplied is never echoed into the job's output.

## Two kinds of scratch

| What | Where | Why |
|---|---|---|
| secrets, sockets, rendered config, pid files, X cookie, `XDG_RUNTIME_DIR`, kernel connection files | `$OSP_APP_SOCK_DIR` (private `/tmp`) | private to the session under the run profile; small (a ~64 MB tmpfs) |
| caches, large temporary data | `$TMPDIR` (the job directory under the run profile) | room to grow; shared storage, so nothing secret and no sockets |

Images set `HOME=/tmp` and `XDG_CACHE_HOME=/tmp/.cache` so something is
writable under a read-only `.sif`. On a node-shared `/tmp` (a run without the
profile) those paths belong to whichever user came first. Where they are still
in effect, `session-env.sh` gives the session its own: `HOME` becomes
`$OSP_APP_SOCK_DIR/home`, `XDG_CACHE_HOME` becomes
`$TMPDIR/<session directory name>/cache` (`$OSP_APP_SOCK_DIR/cache` when
`TMPDIR` is unset or `/tmp`). Values the job set itself, including the real
`HOME` Apptainer provides, are kept.

## The two branches

**A — the app already has URL-token auth.** JupyterLab is the case: it reads
`?token=`, which is why `OSP_APP_TOKEN_NAME` defaults to `token`. Bind the app
to `$OSP_APP_BIND:$OSP_APP_PORT` (not `0.0.0.0`), pass it the token through
the environment (`JUPYTER_TOKEN`), and delete `nginx.conf.template`,
`token-gate.sh` and `supervise.sh`. See `app-jupyter`.

**B — the app has no URL-token auth.** noVNC, RStudio and ParaView all fall
here. Start the app listening on `$OSP_APP_SOCK_DIR/app.sock`, then start
`token-gate.sh`, which renders `nginx.conf.template` and runs nginx on
`$OSP_APP_BIND:$OSP_APP_PORT`. A single-process app can simply
`exec /app/web/token-gate.sh`; a multi-process app starts it as one more
supervised service. See `app-novnc`.

## What the gate does

```
browser ──https──▶ Satellite ──ssh tunnel──▶ 127.0.0.1:OSP_APP_PORT   nginx gate
                                                    │
                                                    ▼
                                    $OSP_APP_SOCK_DIR/app.sock          the app
```

- Request carries a valid `?<name>=<token>` → `Set-Cookie` (HttpOnly, Secure,
  SameSite=Lax) and a **relative** 302 back to the same path. The secret stops
  traveling in URLs, browser history and `Referer` headers after one hop.
  The redirect must be relative: an absolute one would be built from *our*
  scheme and port (`http://…:6080/`) and send the browser nowhere.
- Request carries the cookie → proxied through, websocket upgrade included.
- Neither → a bare `403`, with no hint of how to get in and no nginx version.
- `GET /healthz` (ungated) → `ok` with 200 once the app answers 2xx for
  `OSP_APP_HEALTH_PATH`, 503 before. It uses `auth_request`, so nothing of the
  app's own response reaches the caller. Readiness only: it does not say the
  desktop is usable.

Every `proxy_set_header` is in `location /`. nginx inherits `proxy_set_header`
from an enclosing block **only** when the current block defines none, so
splitting them between `server {}` and `location {}` silently drops the outer
ones.

nginx runs unprivileged: no `user` directive, a port ≥ 1024, its error log on
stderr, and pid, access log and every temp path under
`$OSP_APP_SOCK_DIR/nginx`, because the `.sif` is read-only.

`session-env.sh` also adds an `/etc/passwd` entry for the runtime uid when it
can, so `whoami` works — see *Why `--user`* in the repo README for when that
applies.

## Multi-process apps: `supervise.sh`

A desktop is an X server, a window manager, websockify and the gate. There is
no single program to `exec`, and `exec`ing one of them throws away the shell
that owns the rest, along with its cleanup trap. So the entrypoint (bash,
≥ 5.1) sources `supervise.sh` and stays:

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

The third argument is the program name the kernel reports
(`/proc/<pid>/comm`, at most 15 characters) once the launch has settled.

- Each service runs in **its own process group** (`setsid`), so stopping it
  stops everything it started.
- Each launch is **checked**: the pid must lead its own group and run the
  expected program, not a wrapper that has already handed off.
- **critical** and **leader** services end the session when they exit
  (`wait -n`, no polling), even one that died while the rest of the session
  was still starting: each round first checks that every watched service is
  alive. A **leader** exiting 0 is a normal log-out (status 0), anything else
  is status 1, SIGTERM is 143. **helpers** are only stopped at the end.
- Cleanup sends TERM in reverse start order, the first-registered service
  last, then KILL to whatever ignored it, then removes `$OSP_APP_SOCK_DIR`.
- Output is relayed to stderr with a `[name] ` prefix, so Tapis captures it.

`osp_start` and `osp_register` are the two halves of `osp_spawn`, for a launch
that must be checked before it is registered (the X display walk in
`app-novnc`). `osp_alive PID` tells a running process from a zombie, which
`kill -0` cannot.

## Where the token must not end up

- **A command line.** `/proc/<pid>/cmdline` is world-readable, so a token
  passed as a program argument — to the app, or to `apptainer run --env` — is
  visible to `ps aux`. Use the environment.
- **The job's output.** `session-env.sh` does not echo a supplied token; check
  that the app's own start-up banner does not either.
- **A file anyone else can reach.** `nginx.conf` carries the token in
  plaintext, so it lives in `$OSP_APP_SOCK_DIR` (`0700`, under the private
  `/tmp`), never under `$TMPDIR` or the job directory.
- **The access log.** nginx's default `combined` format logs `$request`, which
  includes the query string — and the first request of every session has the
  token in it. The gate logs `$uri` instead.

## Things that bite

- **Websockets.** `proxy_http_version 1.1` plus the `Upgrade`/`Connection`
  pair is what makes noVNC, Jupyter terminals and RStudio work. Without it the
  page loads and then silently does nothing.
- **Timeouts.** An idle interactive session must not be cut at nginx's default
  60s; the gate sets 86400s and disables buffering.
- **Token name.** nginx maps it to `$arg_<name>` and `$cookie_<name>`, so keep
  it to `[A-Za-z0-9_]`; `session-env.sh` enforces this.
- **Never `ENV OSP_APP_TOKEN_NAME`.** BuildKit's `SecretsUsedInArgOrEnv` check
  matches on the word TOKEN and warns, even though the value is a parameter
  name and not a secret. `session-env.sh` defaults it already.
- **Docker starts you as root; Apptainer does not.** Anything that refuses to
  run as uid 0 (JupyterLab does) needs an escape hatch for local `docker run`,
  or pass `--user "$(id -u):$(id -g)"` to match production more closely.
- **`umask 077` is on.** Anything the session must share with *other* users —
  `/tmp/.X11-unix` on a node-shared `/tmp`, say — needs an explicit mode
  (`mkdir -m 1777`).
