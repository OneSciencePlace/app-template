# Base image: pick whatever suits the app. Nothing below assumes Python.
# Current-as-of-2026-08 choices:
#   ubuntu:26.04                            compiled code, vendor software, GUI
#   python:3.14-slim                        Python
#   r-base:4.6.0                            R
#   node:24-slim                            Node (24 is the active LTS)
#   nvidia/cuda:13.3.0-runtime-ubuntu24.04  GPU
FROM ubuntu:26.04

# Keeps apt from stopping on tzdata-style prompts during the build.
ENV DEBIAN_FRONTEND=noninteractive

# --- dependencies ----------------------------------------------------------
# Install everything the app needs at BUILD time. Nothing may be fetched at
# run time: a .sif is read-only and HPC compute nodes are often offline.
# Pin versions -- an unpinned build is not reproducible, which defeats the
# point of shipping a container.
#
# System packages:
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*
#
# A headless display for a GUI / emulator app, if entrypoint.sh starts Xvfb:
#     xvfb x11-utils libgl1 libglib2.0-0
#
# Language runtimes each have their own idiom -- use whichever fits, and copy
# only the manifest first so the layer caches independently of your source:
#     COPY requirements.txt .   &&  RUN pip install --no-cache-dir -r requirements.txt
#     COPY environment.yml  .   &&  RUN micromamba install -y -f environment.yml
#     COPY package*.json    .   &&  RUN npm ci --omit=dev
#     COPY renv.lock        .   &&  RUN Rscript -e 'renv::restore()'
#     COPY spack.yaml       .   &&  RUN spack -e . install
#
# Compiled or vendor software: build/unpack it here, into /app or /opt.

WORKDIR /app

# --- baked-in assets -------------------------------------------------------
# Model weights, reference data, lookup tables: fetch them NOW, at an absolute
# path, and have the app read them from there. Downloading on first use works
# in Docker and fails in a read-only .sif.
#
#     RUN curl -fsSL -o /app/model.bin https://example.org/model.bin

# --- library scratch paths -------------------------------------------------
# Anything that writes into $HOME or the install tree fails under a read-only
# .sif, so it is sent to /tmp. Add the ones your stack needs. Under the OSP run
# profile /tmp is private to the session but small (a tmpfs of about 64 MB):
# a cache that can grow large belongs under $TMPDIR, which the profile points
# at the job directory. Set such a path in entrypoint.sh, per session, not
# here. Interactive apps need not do it for HOME and XDG_CACHE_HOME:
# web/session-env.sh moves them off these defaults for each session.
ENV HOME=/tmp \
    XDG_CACHE_HOME=/tmp/.cache \
    MPLCONFIGDIR=/tmp/matplotlib

# --- interactive web / VNC apps only ---------------------------------------
# Delete this block for batch apps. See web/README.md for the full contract.
# The token gate needs nginx (with auth_request, for /healthz) and envsubst.
# A multi-process app sources web/supervise.sh, which needs bash >= 5.1:
# ubuntu:26.04 has it, and listing it keeps that true if the base changes.
# The check fails the build, not the session, if a package lacks either.
#
#     RUN apt-get update && apt-get install -y --no-install-recommends \
#             nginx-light gettext-base bash \
#         && rm -rf /var/lib/apt/lists/*
#     RUN nginx -V 2>&1 | grep -q http_auth_request_module \
#         && bash -c '(( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) ))'
#     COPY web/ /app/web/
#     RUN chmod 0755 /app/web/token-gate.sh /app/web/session-env.sh
#
# /etc/passwd and /etc/group group-writable, so web/session-env.sh can add an
# entry for the runtime uid under `docker run --user "$(id -u):0"`. Read-only
# under Apptainer, which supplies the entry itself. Safe only because the
# image has no setuid programs (see the end of this file).
#
#     RUN chmod g=u /etc/passwd /etc/group
#
# The app behind the gate listens on $OSP_APP_SOCK_DIR/app.sock, a Unix
# socket, so there is no upstream port to set (OSP_APP_UPSTREAM_PORT is
# retired). EXPOSE documents the single port; the real value comes from
# OSP_APP_PORT at run time. Must be >= 1024 -- the container runs unprivileged
# and the Satellite proxy refuses to proxy to privileged ports.
#
#     ENV OSP_APP_PORT=8080
#     EXPOSE 8080
#
# Do not add OSP_APP_TOKEN_NAME as an ENV: BuildKit's SecretsUsedInArgOrEnv
# check matches on the word TOKEN and warns, even though the value is only a
# parameter name. web/session-env.sh defaults it to `token` already.

# --- the app --------------------------------------------------------------
COPY entrypoint.sh /app/entrypoint.sh
# Explicit modes. COPY preserves the build context's permissions, so a checkout
# made under a restrictive umask yields 0600/0700 files that the runtime user --
# `docker run --user`, or any user at all under Apptainer -- cannot even read.
# Git only tracks the exec bit, so this is not something the repo can guarantee.
RUN chmod -R a+rX /app && chmod 0755 /app/entrypoint.sh
# COPY your source / binaries into /app here.

# Job inputs and outputs are staged into the working directory. Docker honors
# this; Apptainer uses the caller's directory instead. Either way the app must
# work off relative paths.
# No setuid or setgid programs. An interactive image makes /etc/passwd
# group-writable (above); under a plain `docker run` without
# no-new-privileges, that plus a setuid `su` is a way to root inside the
# container. Apptainer mounts the image nosuid anyway. Keep this after the
# last package install.
RUN find / -xdev -perm /6000 -type f -exec chmod a-s {} + || true

# /data is a mount point. Make it writable by whoever runs the container, so a
# run without a bind mount still works for a non-root user.
RUN mkdir -p /data && chmod 1777 /data

WORKDIR /data

ENTRYPOINT ["/app/entrypoint.sh"]
