#!/usr/bin/env bash
# Namespace-only integration tests. Requires root, util-linux, iproute2,
# Python 3, OpenSSH client/server. Never runs the fixture on the host /etc.
set -Eeuo pipefail
[[ $EUID == 0 ]] || { echo 'Run with sudo bash tests/run-isolated.sh [sshd-path]'; exit 1; }
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
sshd=${1:-/usr/sbin/sshd}
[[ -x $sshd ]] || { echo "sshd not executable: $sshd"; exit 1; }
scratch=$(mktemp -d /tmp/serverman-tests.XXXXXXXX)
trap 'rm -rf -- "$scratch"' EXIT
chmod 700 "$scratch"
cp -a /etc "$scratch/etc"
cat > "$scratch/systemctl" <<EOF
#!/bin/bash
set -eu
case \$1 in
    is-active)
        if [[ -e /run/socket-only ]]; then
            [[ \${*: -1} == ssh.socket || -e /run/service-started ]]
        else
            kill -0 "\$(cat /run/test-daemon-pid)"
        fi ;;
    show)
        case \$* in
            *ExecStart*) printf '%s\n' '{ path=$sshd ; argv[]=$sshd -D -o AuthorizedKeysCommand /etc/ssh/eic-helper %u %f -o AuthorizedKeysCommandUser ec2-instance-connect \$SSHD_OPTS ; ignore_errors=no ; }' ;;
            *) printf '\n' ;;
        esac ;;
    start) touch /run/service-started ;;
    reload)
        if [[ -e /run/fail-next-reload ]]; then rm /run/fail-next-reload; exit 1; fi
        kill -HUP "\$(cat /run/test-daemon-pid)"
        sleep 0.2 ;;
    *) exit 1 ;;
esac
EOF
chmod 700 "$scratch/systemctl"
cp -- "$(command -v chpasswd)" "$scratch/chpasswd.real"
cat > "$scratch/chpasswd" <<EOF
#!/bin/bash
set -eu
if [[ -e /run/fail-next-password ]]; then
    rm /run/fail-next-password
    exit 1
fi
exec "$scratch/chpasswd.real" "\$@"
EOF
chmod 700 "$scratch/chpasswd"
export SERVERMAN_TEST_ROOT="$root" SERVERMAN_TEST_SSHD="$sshd" SERVERMAN_TEST_SCRATCH="$scratch"
unshare --mount --pid --net --fork bash -c '
    set -Eeuo pipefail
    mount --make-rprivate /
    mount -t proc proc /proc
    mount --bind "$SERVERMAN_TEST_SCRATCH/etc" /etc
    mount --bind "$SERVERMAN_TEST_SCRATCH/systemctl" /usr/bin/systemctl
    mount --bind "$SERVERMAN_TEST_SCRATCH/chpasswd" /usr/sbin/chpasswd
    mount -t tmpfs -o mode=755 tmpfs /home
    mount -t tmpfs -o mode=755 tmpfs /run
    mount -t tmpfs -o mode=755 tmpfs /var
    ip link set lo up
    export SERVERMAN_ISOLATED=1
    python3 "$SERVERMAN_TEST_ROOT/tests/integration.py" "$SERVERMAN_TEST_ROOT" "$SERVERMAN_TEST_SSHD"
    exit 0
'
