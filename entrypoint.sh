#!/bin/sh
# entrypoint.sh - the one contract every app-* image honours.
#
#   * It is the image ENTRYPOINT, so whatever the caller appends on the
#     command line arrives here as "$@" and must be passed through.
#   * It runs with the caller's working directory as CWD. Docker gets that
#     from WORKDIR; Apptainer ignores WORKDIR and uses the directory the user
#     invoked from. Read inputs and write outputs relative to CWD; reference
#     anything baked into the image by absolute path under /app.
#   * The container filesystem is READ-ONLY under Apptainer. Scratch goes in
#     /tmp (or under CWD), never into /app.
#   * It runs as the invoking user: no root, no sudo, no fakeroot. Any port
#     it binds must be >= 1024.
#
# Replace the exec line at the bottom with whatever this app actually runs.
# The language does not matter -- only that the process is exec'd (so it gets
# PID 1 and receives signals) and that "$@" reaches it.

set -eu

# Scratch directory. The scheduler usually hands us a TMPDIR pointing at a host
# path like /scratch/$USER/job.12345 -- and Apptainer binds $HOME, /tmp and $PWD
# by default, NOT necessarily /scratch. Inside the container that path does not
# exist and the root filesystem is read-only, so `mkdir -p "$TMPDIR"` dies with
# "cannot create directory '/scratch': Read-only file system". Try the
# candidates in order and use the first one we can actually write to. Bind the
# real scratch in (`--bind /scratch`) if you want it used.
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
# section above, uncomment ONE of the two branches below, and see web/README.md.
#
# . /app/web/session-env.sh      # sets OSP_APP_PORT, OSP_APP_TOKEN, OSP_APP_TOKEN_NAME
#
# --- branch A: the app has native ?token= auth (JupyterLab) -----------------
# Bind it straight to OSP_APP_PORT and hand it OSP_APP_TOKEN. No gate needed.
#
#   exec jupyter lab --ServerApp.ip=0.0.0.0 \
#                    --ServerApp.port="${OSP_APP_PORT}" \
#                    --ServerApp.token="${OSP_APP_TOKEN}" "$@"
#
# --- branch B: the app has no URL-token auth (noVNC, RStudio, ParaView) -----
# Start it on 127.0.0.1 so nothing off-node can reach it directly, then exec
# the nginx gate on OSP_APP_PORT. The gate validates ?TOKEN_NAME=, trades it for
# an HttpOnly cookie, and proxies everything (websockets included) inward.
#
#   export OSP_APP_UPSTREAM_PORT="${OSP_APP_UPSTREAM_PORT:-$((OSP_APP_PORT + 1))}"
#   the_app --bind 127.0.0.1 --port "${OSP_APP_UPSTREAM_PORT}" &
#   exec /app/web/token-gate.sh
