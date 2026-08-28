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
# Anything that writes a cache into $HOME or the install tree must be sent to
# /tmp, or it will fail under Apptainer. Add the ones your stack needs.
ENV HOME=/tmp \
    XDG_CACHE_HOME=/tmp/.cache \
    MPLCONFIGDIR=/tmp/matplotlib

# --- interactive web / VNC apps only ---------------------------------------
# Delete this block for batch apps. See web/README.md for the full contract.
# The token gate needs nginx and envsubst; nothing else here is app-specific.
#
#     RUN apt-get update && apt-get install -y --no-install-recommends \
#             nginx-light gettext-base \
#         && rm -rf /var/lib/apt/lists/*
#     COPY web/ /app/web/
#     RUN chmod 0755 /app/web/token-gate.sh /app/web/session-env.sh
#
# EXPOSE documents the single port; the real value comes from OSP_APP_PORT at run
# time. Must be >= 1024 -- the container runs unprivileged and Satellite
# refuses to proxy to privileged ports.
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

# Job inputs and outputs are staged into the working directory. Docker honours
# this; Apptainer uses the caller's directory instead. Either way the app must
# work off relative paths.
# /data is a mount point. Make it writable by whoever runs the container, so a
# run without a bind mount still works for a non-root user.
RUN mkdir -p /data && chmod 1777 /data

WORKDIR /data

ENTRYPOINT ["/app/entrypoint.sh"]
