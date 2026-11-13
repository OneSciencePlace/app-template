#!/bin/sh
# check-deps.sh - does this image have what the web/ files need? Run it once,
# at image build, after the packages are installed and web/ is in place:
#
#     RUN /app/web/check-deps.sh                 # session, gate and supervisor
#     RUN /app/web/check-deps.sh session         # only what session-env.sh needs
#
# Parts: session (session-env.sh, every interactive app), gate (token-gate.sh
# and nginx.conf.template), supervisor (supervise.sh). With no argument, all
# three: every interactive app uses all three. Prints one line per check and
# exits 1 if anything is missing, so the build fails with the reason rather
# than a session failing at start-up on a compute node.
#
# POSIX sh only, so it runs on any base image with a shell; it needs nothing
# it is checking for.

parts=${*:-session gate supervisor}
fail=0
ok()   { printf 'ok    %s\n' "$*"; }
bad()  { printf 'MISSING %s\n' "$*" >&2; fail=1; }
have() { command -v "$1" >/dev/null 2>&1; }

for part in $parts; do
    case "$part" in
    session)
        for c in id mkdir chmod mktemp od tr; do
            have "$c" && ok "session: $c" || bad "session: $c (coreutils or BusyBox)"
        done
        if have od && [ "$(od -An -tx1 -N4 /dev/urandom 2>/dev/null | tr -d ' \n' | wc -c)" -eq 8 ]; then
            ok "session: od -An -tx1 -N reads /dev/urandom"
        else
            bad "session: od -An -tx1 -N4 /dev/urandom (a token is made this way when none is passed)"
        fi
        if d=$(mktemp -d /tmp/osp-check-XXXXXXXX 2>/dev/null) && [ -d "$d" ]; then
            rmdir "$d"; ok "session: mktemp -d with a template"
        else
            bad "session: mktemp -d /tmp/osp-check-XXXXXXXX"
        fi
        [ -r /proc/self/stat ] && ok "session: /proc" || bad "session: /proc (Linux only)"
        ;;
    gate)
        if have nginx; then
            ok "gate: nginx ($(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p'))"
            nginx -V 2>&1 | grep -q http_auth_request_module \
                && ok "gate: nginx has http_auth_request_module" \
                || bad "gate: nginx built without http_auth_request_module (the gate's /healthz needs it)"
        else
            bad "gate: nginx (Ubuntu: nginx-light; Debian, RHEL family, Alpine: nginx)"
        fi
        # The restricted form: substitutes only the names given.
        # shellcheck disable=SC2016  # literal ${...} on purpose
        if have envsubst && [ "$(printf '%s' '${A} $b' | A=x envsubst '${A}' 2>/dev/null)" = 'x $b' ]; then
            ok "gate: envsubst"
        else
            bad "gate: envsubst with a variable list (Debian/Ubuntu: gettext-base; RHEL family: gettext; Alpine: gettext-envsubst)"
        fi
        have sed && ok "gate: sed" || bad "gate: sed"
        ;;
    supervisor)
        if have bash && bash -c '(( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) ))' 2>/dev/null; then
            ok "supervisor: bash $(bash -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')"
        elif have bash; then
            bad "supervisor: bash >= 5.1 for 'wait -n -p' (this is $(bash -c 'echo "$BASH_VERSION"'))"
        else
            bad "supervisor: bash >= 5.1"
        fi
        have setsid && ok "supervisor: setsid" || bad "supervisor: setsid (util-linux or BusyBox)"
        ;;
    *)
        bad "unknown part '$part' (session, gate, supervisor)"
        ;;
    esac
done

if [ "$fail" = 0 ]; then
    echo "[check-deps] everything web/ needs is here ($parts)"
else
    echo "[check-deps] this image lacks what web/ needs; see MISSING above" >&2
fi
exit "$fail"
