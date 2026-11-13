#!/bin/sh
# entrypoint.sh - the one contract every app-* image honors.
#
#   * It is the image ENTRYPOINT, so whatever the caller appends on the
#     command line arrives here as "$@" and must be passed through.
#   * It runs with the caller's working directory as CWD. Docker gets that
#     from WORKDIR; Apptainer ignores WORKDIR and uses the directory the user
#     invoked from (the job directory, under the OSP run profile). Read inputs
#     and write outputs relative to CWD; reference anything baked into the
#     image by absolute path under /app.
#   * The container filesystem is READ-ONLY under Apptainer. Nothing is ever
#     written into /app; "Where things go" below says what goes where.
#   * It runs as the invoking user: no root, no sudo, no fakeroot. Any port
#     it binds must be >= 1024.
#
# Replace the exec line at the bottom with whatever this app actually runs.
# The language does not matter -- only that the process is exec'd (so it gets
# PID 1 and receives signals) and that "$@" reaches it.
#
# Where things go. Under the OSP run profile every session gets a private,
# empty and small /tmp (a tmpfs, about 64 MB), and the app definition points
# TMPDIR at <job directory>/tmp:
#
#   secrets, sockets, rendered config, pid files, logs, X cookies
#       -> $OSP_APP_SOCK_DIR: a fresh 0700 directory under the private /tmp,
#          created by web/session-env.sh (interactive apps)
#   bulk scratch: caches, large temporary files
#       -> $TMPDIR: the job directory under the profile. Shared storage, so
#          never a secret and never a Unix socket.
#   inputs and outputs
#       -> the current directory

set -eu
# Nothing this container creates is readable by any other Unix user unless it
# is made with an explicit mode: the session's secrets above all. A batch app
# whose outputs must be readable by a group sets a wider umask just before its
# exec line.
umask 077

# Bulk scratch directory. The scheduler usually hands us a TMPDIR pointing at a
# host path like /scratch/$USER/job.12345 -- and Apptainer does not necessarily
# bind it. Inside the container that path may not exist and the root
# filesystem is read-only, so `mkdir -p "$TMPDIR"` would die with "Read-only
# file system". Try the candidates in order and use the first one we can
# actually write to. Under the OSP run profile the app definition sets
# TMPDIR=<job directory>/tmp, which is bound and writable. Never bind a
# scratch parent (/scratch, a Lustre root) to make an inherited TMPDIR work:
# it shows every other job directory of the account to this container.
_pick_tmpdir() {
    for _d in "${TMPDIR:-}" /tmp "${HOME:-}"; do
        [ -n "$_d" ] || continue
        mkdir -p "$_d" 2>/dev/null || continue
        [ -w "$_d" ] || continue
        printf '%s' "$_d"
        return 0
    done
    return 1
}
_tmpdir_was="${TMPDIR:-}"
TMPDIR="$(_pick_tmpdir)" || {
    echo "[app] no writable scratch directory (tried TMPDIR, /tmp, HOME)" >&2
    exit 1
}
export TMPDIR
if [ -n "$_tmpdir_was" ] && [ "$_tmpdir_was" != "$TMPDIR" ]; then
    echo "[app] TMPDIR=$_tmpdir_was is not writable in this container; using $TMPDIR" >&2
fi

# === BATCH APPS ============================================================
# Delete the interactive section below and keep this.

# --- optional: source an environment the app needs -------------------------
# A conda/micromamba env, a Spack view, a module-style setup script, an
# LD_LIBRARY_PATH for a vendored solver -- anything that has to happen before
# the program starts belongs here.
#
# . /opt/conda/etc/profile.d/conda.sh && conda activate app
# export LD_LIBRARY_PATH="/app/lib:${LD_LIBRARY_PATH:-}"

# --- run the app -----------------------------------------------------------
# Pick one and delete the rest:
#
#   exec python3 /app/run.py "$@"          # Python
#   exec Rscript /app/run.R "$@"           # R
#   exec node /app/run.js "$@"             # Node
#   exec /app/bin/solver "$@"              # compiled C/C++/Fortran/Rust/Go
#   exec julia /app/run.jl "$@"            # Julia
#   exec /opt/vendor/bin/sciapp -batch "$@" # vendor scientific software
#
exec /app/bin/app "$@"


# === INTERACTIVE WEB / VNC APPS ============================================
# JupyterLab, RStudio, noVNC, ParaView-over-VNC and friends. Delete the batch
# section above, uncomment the block below, and see web/README.md. web/ comes
# from the kit image (the Dockerfile's interactive block).
#
# Every interactive app has the same shape. The app listens on a Unix socket
# in the session directory, never on a TCP port, not even 127.0.0.1. The nginx
# gate (web/token-gate.sh) is the one TCP listener, on
# $OSP_APP_BIND:$OSP_APP_PORT: it checks ?<OSP_APP_TOKEN_NAME>=, trades it for
# an HttpOnly cookie, and proxies everything (websockets included) to
# $OSP_APP_SOCK_DIR/app.sock. An app with a login of its own (JupyterLab's
# token) turns it off: the gate is the authentication.
#
# The app and the gate are two processes, so the supervisor runs them: the
# session ends when either exits, and a cancel stops both. supervise.sh needs
# bash >= 5.1, so change the first line of this file to #!/bin/bash. The app
# starts without OSP_APP_TOKEN in its environment (env -u): only the gate needs
# it.
#
#   . /app/web/session-env.sh                    # the variables; creates OSP_APP_SOCK_DIR
#   . /app/web/supervise.sh                      # installs the cleanup trap first
#   export OSP_APP_HEALTH_PATH=""                # what /healthz asks the app for ("" = /)
#   osp_spawn leader app the_app -- env -u OSP_APP_TOKEN \
#       the_app --listen "unix:$OSP_APP_SOCK_DIR/app.sock"
#   _i=0                                         # no gate until the app is listening
#   until [ -S "$OSP_APP_SOCK_DIR/app.sock" ]; do
#       _i=$((_i + 1))
#       [ "$_i" -lt 300 ] || { echo "[app] the app did not start" >&2; exit 1; }
#       sleep 0.1
#   done
#   osp_spawn critical gate nginx -- /app/web/token-gate.sh
#   osp_supervise                                # never returns
#
# The third argument of osp_spawn is the program name the kernel reports
# (/proc/<pid>/comm) once env has handed over. `leader` makes the app's clean
# exit a normal log-out (status 0); use `critical` for an app without one.
# Worked examples: app-jupyter (JupyterLab on --ServerApp.sock, its own token
# off) and app-novnc (a desktop: X server, window manager and websockify the
# same way).
