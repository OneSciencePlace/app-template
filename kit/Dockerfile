# app-kit - the shared interactive-session files, web/, as an image other
# app-* images copy from. It holds files only: there is nothing to run.
#
# In an app's Dockerfile, before its own FROM:
#
#   FROM ghcr.io/onescienceplace/app-kit:<version>@sha256:<digest> AS kit
#
# and then, in the app's stage:
#
#   COPY --from=kit /app/web/ /app/web/
#
# The files arrive with their modes set (the scripts that are executed 0755,
# the rest 0644), owned by root, so the app's Dockerfile need not chmod them.
# Then, once the app's packages are installed:
#
#   RUN /app/web/check-deps.sh       # fails the build if the image lacks what web/ needs
#
# Built by .github/workflows/kit.yml from this repository's web/, and versioned
# with the template: git tag v1.1.0 publishes app-kit:1.1.0. Build it locally
# from the repository root:
#
#   docker build -f kit/Dockerfile -t app-kit:dev .
FROM scratch
COPY --chmod=0755 web/session-env.sh web/token-gate.sh web/check-deps.sh /app/web/
COPY --chmod=0644 web/supervise.sh web/nginx.conf.template web/README.md /app/web/
