#!/usr/bin/env python3
"""Destructive fixtures: ONLY run through run-isolated.sh (mount/PID/net namespaces)."""
import hashlib
import os
from pathlib import Path
import pty
import secrets
import select
import shutil
import signal
import subprocess
import sys
import time

if os.environ.get("SERVERMAN_ISOLATED") != "1" or Path("/proc/1/comm").read_text().strip() != "bash":
    sys.exit("Use run-isolated.sh; never run fixtures on a real server.")

root = Path(sys.argv[1])
sshd = sys.argv[2]
script = root / "setup-ssh-user.sh"
config = Path("/etc/ssh/sshd_config")
password = secrets.token_urlsafe(30)
run = lambda *args, **kw: subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kw)
Path("/run/sshd").mkdir(parents=True, exist_ok=True)
Path("/var/log").mkdir(parents=True, exist_ok=True)
Path("/var/mail").mkdir(parents=True, exist_ok=True)
Path("/etc/default/ssh").write_text('SSHD_OPTS=""\n')
if not shutil.which("sshd") and not Path(sshd).is_file():
    sys.exit("sshd binary missing")
if subprocess.run(["getent", "passwd", "sshd"], stdout=subprocess.DEVNULL).returncode:
    run("useradd", "-r", "-M", "-d", "/run/sshd", "-s", "/usr/sbin/nologin", "sshd")
for user in ("ubuntu", "aiadmin"):
    subprocess.run(["userdel", "-r", user], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
run("useradd", "-m", "-U", "-s", "/bin/bash", "ubuntu")
run("chpasswd", input=f"ubuntu:{secrets.token_urlsafe(30)}\n".encode())
if subprocess.run(["getent", "passwd", "ec2-instance-connect"], stdout=subprocess.DEVNULL).returncode:
    run("useradd", "-r", "-M", "-s", "/usr/sbin/nologin", "ec2-instance-connect")
run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", "/run/hostkey")
run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", "/run/clientkey")
auth = Path("/home/ubuntu/.ssh")
auth.mkdir(mode=0o700)
shutil.copy("/run/clientkey.pub", auth / "authorized_keys")
os.chmod(auth / "authorized_keys", 0o600)
run("chown", "-R", "ubuntu:ubuntu", "/home/ubuntu/.ssh")
key_hash = hashlib.sha256((auth / "authorized_keys").read_bytes()).hexdigest()
helper = Path('/etc/ssh/eic-helper')
helper.write_text('#!/bin/sh\ncat /etc/ssh/eic-test-key.pub\n')
helper.chmod(0o755)
shutil.copy('/run/clientkey.pub', '/etc/ssh/eic-test-key.pub')
os.chmod('/etc/ssh/eic-test-key.pub', 0o644)
shadow_before = run("getent", "shadow", "ubuntu").stdout
base = """Port 22222
ListenAddress 127.0.0.1
HostKey /run/hostkey
PidFile /run/fixture-sshd.pid
UsePAM no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AuthorizedKeysFile none
"""
config.write_text(base)
daemon_log = open("/run/sshd-test.log", "wb")
daemon = subprocess.Popen([sshd, "-D", "-e", "-f", str(config),
                           '-o', 'AuthorizedKeysCommand /etc/ssh/eic-helper %u %f',
                           '-o', 'AuthorizedKeysCommandUser ec2-instance-connect'],
                          stdout=daemon_log, stderr=daemon_log)
Path("/run/test-daemon-pid").write_text(str(daemon.pid))
time.sleep(0.4)
assert daemon.poll() is None, Path("/run/sshd-test.log").read_text()

# The production script retains its fixed system paths. Only the test copy uses
# the extracted OpenSSH binary; the namespace binds a service adapter over systemctl.
test_script = Path("/run/setup-under-test.sh")
test_script.write_text(script.read_text().replace("/usr/sbin/sshd", sshd).replace(
    '/usr/share/ec2-instance-connect/eic_run_authorized_keys', '/etc/ssh/eic-helper'))


def execute(extra="", sudo=False, expect=True, mismatch=False, interrupt=False, socket_only=False):
    Path('/etc/sudoers.d/99-setup-ssh-user-aiadmin').unlink(missing_ok=True)
    Path('/run/service-started').unlink(missing_ok=True)
    Path('/run/socket-only').unlink(missing_ok=True)
    if socket_only:
        Path('/run/socket-only').touch()
        shutil.rmtree('/run/sshd')
    config.write_text(base + extra)
    original = config.read_bytes()
    master, slave = pty.openpty()
    env = dict(os.environ, SUDO_USER='ubuntu', SSH_CONNECTION="127.0.0.1 50000 127.0.0.1 22222")
    proc = subprocess.Popen(["bash", str(test_script)], stdin=slave, stdout=slave, stderr=slave,
                            env=env, start_new_session=True)
    os.close(slave)
    output = b""
    steps = [("新用户名", "aiadmin"),
             ("新用户密码", password), ("再次输入", "different" if mismatch else password)]
    deadline = time.monotonic() + 25
    index = 0
    while time.monotonic() < deadline:
        if select.select([master], [], [], 0.1)[0]:
            try:
                block = os.read(master, 65536)
            except OSError:
                break
            if not block:
                break
            output += block
        if index < len(steps) and steps[index][0].encode() in output:
            if interrupt and index == 1:
                os.kill(proc.pid, signal.SIGTERM)
                index = len(steps)
            else:
                os.write(master, (steps[index][1] + "\n").encode())
                index += 1
        if proc.poll() is not None:
            # Drain any trailing output before validating secret redaction.
            continue
    if proc.poll() is None:
        proc.kill()
        raise AssertionError("interactive script timed out")
    os.close(master)
    assert password.encode() not in output, "password leaked to terminal"
    assert (proc.returncode == 0) == expect, output.decode(errors="replace")
    if not expect:
        assert config.read_bytes() == original, "configuration not restored"
        assert subprocess.run(["getent", "passwd", "aiadmin"], stdout=subprocess.DEVNULL).returncode != 0
        assert not Path('/etc/sudoers.d/99-setup-ssh-user-aiadmin').exists(), 'sudo rule not rolled back'
    elif socket_only:
        assert Path('/run/sshd').is_dir() and Path('/run/service-started').exists()
    if expect:
        snapshots = list(Path('/var/backups/setup-ssh-user').glob('*/global.after'))
        latest = max(snapshots, key=lambda item: item.stat().st_mtime_ns)
        effective_config = latest.read_text()
        assert 'authorizedkeyscommand /etc/ssh/eic-helper %u %f' in effective_config
        assert 'authorizedkeyscommanduser ec2-instance-connect' in effective_config
    assert run("getent", "shadow", "ubuntu").stdout == shadow_before
    assert hashlib.sha256((auth / "authorized_keys").read_bytes()).hexdigest() == key_hash
    return output


def ssh(user, key=False):
    args = ["ssh", "-p", "22222", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=5"]
    env = dict(os.environ)
    if key:
        args += ["-i", "/run/clientkey", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                 "-o", "PreferredAuthentications=publickey"]
    else:
        # The helper contains no password. The test-only random secret is in its
        # environment, never in argv, output reports or persisted test scripts.
        helper = Path("/run/askpass")
        helper.write_text('#!/bin/sh\nprintf "%s\\n" "$FIXTURE_PASSWORD"\n')
        helper.chmod(0o700)
        env.update(SSH_ASKPASS=str(helper), SSH_ASKPASS_REQUIRE="force", DISPLAY=":test", FIXTURE_PASSWORD=password)
        args += ["-o", "PubkeyAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
                 "-o", "PreferredAuthentications=password", "-o", "NumberOfPasswordPrompts=1"]
    return run(*args, f"{user}@127.0.0.1", "id -un", env=env, start_new_session=True).stdout.strip()


try:
    assert ssh("ubuntu", key=True) == b"ubuntu"
    execute(sudo=True, socket_only=True)
    time.sleep(0.4)
    assert ssh("aiadmin") == b"aiadmin"
    assert ssh("ubuntu", key=True) == b"ubuntu"
    assert "sudo" in run("id", "-nG", "aiadmin").stdout.decode().split()
    print("PASS: missing runtime directory + socket start + real password / command-provided key login + sudo")
    # Existing-user execution must not ask for a password or change config.
    before = config.read_bytes()
    master, slave = pty.openpty()
    proc = subprocess.Popen(["bash", str(test_script)], stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    time.sleep(0.2)
    os.write(master, b"aiadmin\n")
    proc.wait(timeout=10)
    os.close(master)
    assert proc.returncode != 0 and config.read_bytes() == before
    assert config.read_text().count("# BEGIN setup-ssh-user: aiadmin") == 1
    run("userdel", "-r", "aiadmin")
    print("PASS: existing user / repeat execution does not change password or append blocks")
    for label, extra in [
        ("AllowUsers rejection", "AllowUsers ubuntu\n"),
        ("DenyUsers all entries", "DenyUsers unrelated aiadmin\n"),
        ("AllowGroups rejection", "AllowGroups root\n"),
        ("DenyGroups rejection", "DenyGroups aiadmin\n"),
        ("host-qualified rule refuses approximation", "AllowUsers ubuntu aiadmin@127.0.0.1\n"),
        ("multi-factor restriction", "AuthenticationMethods publickey,password\n"),
        ("earlier Match override", "Match User aiadmin\n PasswordAuthentication no\n"),
        ("forced command restriction", "Match User aiadmin\n ForceCommand internal-sftp\n"),
        ("syntax failure before mutation", "NotARealDirective yes\n"),
    ]:
        execute(extra, expect=False)
        print("PASS:", label)
    execute(expect=False, mismatch=True)
    print("PASS: password mismatch has no side effects")
    Path("/run/fail-next-password").touch()
    execute(expect=False)
    print("PASS: password-setting failure removes newly created account")
    execute(expect=False, interrupt=True)
    print("PASS: termination before password has no side effects")
    # Force one reload failure; the adapter then permits restoration reload.
    Path("/run/fail-next-reload").touch()
    execute(expect=False)
    print("PASS: reload failure restores config, reloads original and removes new user")
    execute("AllowUsers ubuntu aiadmin\nAllowGroups ubuntu aiadmin\n")
    time.sleep(0.4)
    assert ssh("aiadmin") == b"aiadmin" and ssh("ubuntu", key=True) == b"ubuntu"
    run("userdel", "-r", "aiadmin")
    print("PASS: compatible access lists retained + real logins")
    print("ALL TESTS PASSED")
finally:
    daemon.terminate()
    daemon.wait(timeout=5)
    daemon_log.close()
