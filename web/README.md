# web/ — the interactive-app contract

Drop this directory into any `app-*` repo that serves a browser UI: JupyterLab,
RStudio, noVNC, ParaView layered on VNC. Delete it for batch apps.

Everything here exists to satisfy four constraints imposed by the runtime
these containers land in.

## The four constraints

1. **Per-session token auth, passed in the URL.** The user opens
   `https://<session>.<satellite-domain>/?<OSP_APP_TOKEN_NAME>=<OSP_APP_TOKEN>`.
   The token authenticates that one session and nothing else.
2. **Exactly one port is exposed.** Everything the browser needs — HTML,
   static assets, websockets — arrives on `OSP_APP_PORT`. Anything else the app
   runs internally binds `127.0.0.1` and stays unreachable off-node.
3. **No root, no sudo, no fakeroot at run time.** The container runs as the
   invoking user. `OSP_APP_PORT` must be ≥ 1024, and nothing may write outside
   `/tmp` and the working directory.
4. **TLS is terminated upstream.** Satellite holds the certificate and speaks
   plain HTTP to us across the trusted cluster network.

Satellite routes by **per-session subdomain**, not by path prefix, so apps do
*not* need `--base-url` / prefix support. They do need to be told the browser's
scheme is `https`, which is what the `X-Forwarded-Proto` header is for.

## The three variables

| Variable | Default | Meaning |
|---|---|---|
| `OSP_APP_PORT` | `8080` | the single port the container listens on |
| `OSP_APP_TOKEN` | generated | the per-session secret |
| `OSP_APP_TOKEN_NAME` | `token` | the query parameter it arrives in |

All three are settable on the run command line:

```bash
docker run --rm --user "$(id -u):$(id -g)" \
  -p 6080:6080 \
  -e OSP_APP_PORT=6080 -e OSP_APP_TOKEN="$TOKEN" \
  ghcr.io/onescienceplace/app-NAME:latest

apptainer run \
  --env OSP_APP_PORT=6080 --env OSP_APP_TOKEN="$TOKEN" \
  app-NAME-sif_latest.sif
```

`session-env.sh` applies the defaults, generates a token if none was given (so
a bare `docker run` still works), rejects a privileged port, and prints the
port and entry path so the job script can register with Satellite.

## The two branches

**A — the app already has URL-token auth.** JupyterLab is the case: it reads
`?token=`, which is why `OSP_APP_TOKEN_NAME` defaults to `token`. Bind the app
directly to `0.0.0.0:$OSP_APP_PORT`, pass it `OSP_APP_TOKEN`, and delete
`nginx.conf.template` and `token-gate.sh`. See `app-jupyter`.

**B — the app has no URL-token auth.** noVNC, RStudio and ParaView all fall
here. Start the app on `127.0.0.1:$OSP_APP_UPSTREAM_PORT`, then `exec
token-gate.sh`, which renders `nginx.conf.template` and runs nginx on
`OSP_APP_PORT`. See `app-novnc`.

## What the gate does

```
browser ──https──▶ Satellite ──http──▶ 0.0.0.0:OSP_APP_PORT   nginx gate
                                              │
                                              ▼
                                    127.0.0.1:OSP_APP_UPSTREAM_PORT   the app
```

- Request carries a valid `?<name>=<token>` → `Set-Cookie` (HttpOnly, Secure,
  SameSite=Lax) and a **relative** 302 back to the same path. The secret stops
  travelling in URLs, browser history and `Referer` headers after one hop.
  The redirect must be relative: an absolute one would be built from *our*
  scheme and port (`http://…:6080/`) and send the browser nowhere.
- Request carries the cookie → proxied through, websocket upgrade included.
- Neither → `403`.

nginx runs unprivileged: no `user` directive, a port ≥ 1024, and pid, logs and
every temp path under `$TMPDIR/nginx`, because the `.sif` is read-only.


`session-env.sh` also adds an `/etc/passwd` entry for the runtime uid when it
can, so `whoami` works — see *Why `--user`* in the repo README for when that
applies. It is not specific to interactive apps.

## Where the token must not end up

On a shared compute node every other user can read your process list and,
depending on permissions, your files. Three places the secret leaks if you are
not deliberate:

- **The command line.** `/proc/<pid>/cmdline` is world-readable, so a token
  passed as a program argument is visible to `ps aux`. `/proc/<pid>/environ` is
  `0400`, owner only — so pass secrets in the environment, never as an argument.
  `app-jupyter` sets `JUPYTER_TOKEN` for exactly this reason.
- **The rendered config.** `nginx.conf` carries the token in plaintext, so
  `token-gate.sh` sets `umask 077` before writing it: `0600` in a `0700`
  directory.
- **The access log.** nginx's default `combined` format logs `$request`, which
  includes the query string — and the first request of every session has the
  token in it. The gate logs `$uri` instead, so the secret never reaches disk.

## Things that bite

- **Websockets.** `proxy_http_version 1.1` plus the `Upgrade`/`Connection`
  pair is what makes noVNC, Jupyter terminals and RStudio work. Without it the
  page loads and then silently does nothing.
- **Timeouts.** An idle interactive session must not be cut at nginx's default
  60s; the gate sets 86400s and disables buffering.
- **Token name.** nginx maps it to `$arg_<name>` and `$cookie_<name>`, so keep
  it to `[A-Za-z0-9_]`. A dash silently becomes an underscore.
- **Never `ENV OSP_APP_TOKEN_NAME`.** BuildKit's `SecretsUsedInArgOrEnv` check
  matches on the word TOKEN and warns, even though the value is a parameter
  name and not a secret. `session-env.sh` defaults it already.
- **Docker starts you as root; Apptainer does not.** Anything that refuses to
  run as uid 0 (JupyterLab does) needs an escape hatch for local `docker run`,
  or pass `--user "$(id -u):$(id -g)"` to match production more closely.
