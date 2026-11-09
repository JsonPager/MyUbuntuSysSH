#!/usr/bin/env python3
"""Run the actual service preflight against adapters; never touch host SSH."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'setup-ssh-user.sh').read_text()
preflight = source.split('# /run is volatile;', 1)[1].split("\nread -r -p '新用户名", 1)[0]
preflight = '# /run is volatile;' + preflight
aws = ('/usr/sbin/sshd -D -o AuthorizedKeysCommand '
       '/usr/share/ec2-instance-connect/eic_run_authorized_keys %u %f '
       '-o AuthorizedKeysCommandUser ec2-instance-connect $SSHD_OPTS')
expected_options = ['-o', 'AuthorizedKeysCommand /usr/share/ec2-instance-connect/eic_run_authorized_keys %u %f',
                    '-o', 'AuthorizedKeysCommandUser ec2-instance-connect']


def check(label, *, active=True, socket=False, args=aws, syntax=True, start=True,
          env='', env_file='SSHD_OPTS=""\n', symlink=False, success=True):
    with tempfile.TemporaryDirectory(prefix='ssh-preflight-') as temporary:
        path = Path(temporary)
        (path / 'default-ssh').write_text(env_file)
        if symlink:
            (path / 'sshd').symlink_to(path / 'elsewhere')
        code = preflight.replace('/run/sshd', str(path / 'sshd')).replace('/etc/default/ssh', str(path / 'default-ssh'))
        # Replace only executable calls, leaving the production argv allowlist intact.
        code = code.replace('/usr/sbin/sshd "${sshd_options[@]}"', 'sshd_fixture "${sshd_options[@]}"')
        harness = '''set -Eeuo pipefail
service=; service_needs_start=0; sshd_options=(); CONFIG=/etc/ssh/sshd_config
die() { printf '%s\\n' "$*" >&2; exit 1; }
info() { printf '%s\\n' "$*"; }
systemctl() {
    printf '%s\\n' "$*" >> "$FIXTURE_LOG"
    case $1 in
        is-active)
            case ${*: -1} in
                ssh.service) [[ $FIXTURE_ACTIVE == yes || -e $FIXTURE_STARTED ]] ;;
                ssh.socket) [[ $FIXTURE_SOCKET == yes ]] ;;
                *) return 1 ;;
            esac ;;
        show)
            case $* in
                *ExecStart*) printf '{ argv[]=%s ; ignore_errors=no ; }\\n' "$FIXTURE_ARGS" ;;
                *EnvironmentFiles*) printf '%s (ignore_errors=yes)\\n' "$FIXTURE_ENVFILE" ;;
                *Environment*) printf '%s\\n' "$FIXTURE_ENV" ;;
            esac ;;
        start) [[ $FIXTURE_START == yes ]] && touch "$FIXTURE_STARTED" ;;
        *) return 99 ;;
    esac
}
sshd_fixture() {
    printf '%s\\0' "$@" > "$FIXTURE_OPTIONS"
    [[ $FIXTURE_SYNTAX == yes ]]
}
''' + code + '\nprintf "%s\\n" READY\n'
        environment = dict(os.environ, FIXTURE_LOG=str(path / 'calls'), FIXTURE_STARTED=str(path / 'started'),
                           FIXTURE_OPTIONS=str(path / 'options'), FIXTURE_ARGS=args, FIXTURE_ENV=env,
                           FIXTURE_ENVFILE=str(path / 'default-ssh'),
                           FIXTURE_ACTIVE='yes' if active else 'no', FIXTURE_SOCKET='yes' if socket else 'no',
                           FIXTURE_START='yes' if start else 'no', FIXTURE_SYNTAX='yes' if syntax else 'no')
        result = subprocess.run(['bash'], input=harness.encode(), capture_output=True, env=environment)
        assert (result.returncode == 0) == success, (label, result.stdout, result.stderr)
        calls = (path / 'calls').read_text() if (path / 'calls').exists() else ''
        if success:
            assert (path / 'sshd').is_dir(), label
            assert (path / 'sshd').stat().st_mode & 0o777 == 0o755, label
            assert (path / 'started').exists() == (not active and socket), label
            options = (path / 'options').read_bytes().split(b'\0')[:-1]
            expected = expected_options if 'AuthorizedKeysCommand' in args else []
            assert options == [item.encode() for item in expected + ['-t', '-f', '/etc/ssh/sshd_config']], label
        else:
            assert not (path / 'started').exists(), label
        assert 'restart' not in calls and 'stop' not in calls and 'enable' not in calls, label
        print('PASS:', label)


check('AWS active service; create missing runtime directory')
check('AWS socket-only; validate options then start service', active=False, socket=True)
check('standard active service', args='/usr/sbin/sshd -D $SSHD_OPTS')
check('standard socket-only service', args='/usr/sbin/sshd -D', active=False, socket=True)
check('no active SSH listener', active=False, success=False)
check('socket service start failure', active=False, socket=True, start=False, success=False)
check('invalid config never starts service', active=False, socket=True, syntax=False, success=False)
check('extra port override refused', args=aws + ' -p 2222', success=False)
check('nonempty SSHD_OPTS refused', env_file='SSHD_OPTS="-p 2222"\n', success=False)
check('systemd environment override refused', env='SSHD_OPTS=-p2222', success=False)
check('runtime symlink refused', symlink=True, success=False)
print('ALL 11 PREFLIGHT CASES PASSED')
