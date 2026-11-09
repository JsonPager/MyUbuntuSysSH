#!/usr/bin/env python3
"""Exercise production ExecStart validation without changing users or SSH."""
from pathlib import Path
import subprocess

source = (Path(__file__).resolve().parents[1] / "setup-ssh-user.sh").read_text()
validation = source.split('exec_start=$(systemctl show', 1)[1]
validation = 'exec_start=$(systemctl show' + validation.split('\nenvironment_files=', 1)[0]
harness = '''set -Eeuo pipefail
sshd_options=()
service=ssh.service
systemctl() { printf '%s\\n' "$1" >/dev/null; printf '%s\\n' "$FIXTURE_EXEC_START"; }
die() { printf '%s\\n' "$*" >&2; exit 1; }
''' + validation + '\nfor option in "${sshd_options[@]}"; do printf "%s\\0" "$option"; done\n'

aws = ('/usr/sbin/sshd -D -o AuthorizedKeysCommand '
       '/usr/share/ec2-instance-connect/eic_run_authorized_keys %u %f '
       '-o AuthorizedKeysCommandUser ec2-instance-connect')
expected = [b'-o', b'AuthorizedKeysCommand /usr/share/ec2-instance-connect/eic_run_authorized_keys %u %f',
            b'-o', b'AuthorizedKeysCommandUser ec2-instance-connect']
cases = [('/usr/sbin/sshd -D', []), ('/usr/sbin/sshd -D $SSHD_OPTS', []),
         ('/usr/sbin/sshd -D -e', []), (aws, expected), (aws + ' $SSHD_OPTS', expected),
         (aws + ' -p 2222', None), (aws.replace('%u %f', '%u %k'), None),
         ('/usr/sbin/sshd -D -f /tmp/other.conf', None),
         ('/usr/sbin/sshd -D -o PasswordAuthentication=yes', None)]
import os
for args, wanted in cases:
    env = dict(os.environ, FIXTURE_EXEC_START=f'{{ path=/usr/sbin/sshd ; argv[]={args} ; ignore_errors=no ; }}')
    result = subprocess.run(['bash'], input=harness.encode(), env=env, capture_output=True)
    if wanted is None:
        assert result.returncode != 0, args
    else:
        assert result.returncode == 0, result.stderr.decode()
        assert result.stdout == b''.join(option + b'\0' for option in wanted), args
print(f'PASS: {len(cases)} service argument cases (including AWS options and rejected overrides)')
