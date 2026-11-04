"""Local HTTP API/PTY integration tests; never starts Docker containers."""
import base64
import json
import os
from pathlib import Path
import pty
import secrets
import select
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'deploy-portainer-stack.sh'
TOKEN = 'eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyIjoxfQ.' + secrets.token_hex(24)
PASSWORD = ' ' + secrets.token_urlsafe(20) + ' "quoted" \\ $ end '
YAML = 'version: "3"\nservices:\n  test:\n    image: busybox\n    command: ["echo", "a \\\"quote\\\"", "line\\nvalue"]\n'
SHA = 'a' * 40
STATE = {}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, data):
        data = json.dumps(data).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        STATE['requests'].append(('GET', self.path))
        if self.path.startswith('/github/'):
            assert self.headers.get('X-API-Key') is None, 'credential leaked to GitHub'
            assert self.headers.get('Authorization') is None, 'JWT leaked to GitHub'
            if '/contents/stacks?' in self.path:
                if STATE['case'] == 'empty-templates':
                    return self.reply(200, [])
                return self.reply(200, [{'name': 'bark.yml', 'path': 'stacks/bark.yml', 'type': 'file', 'sha': SHA, 'size': len(YAML)}])
            if '/git/blobs/' in self.path:
                encoded = base64.encodebytes(YAML.encode()).decode()
                return self.reply(200, {'sha': SHA, 'encoding': 'base64', 'content': encoded})
            return self.reply(404, {})
        assert self.headers.get('Authorization') == 'Bearer ' + TOKEN, 'missing/wrong API authentication header'
        assert self.headers.get('X-API-Key') is None
        if STATE['case'] == 'expired' and STATE['auth_calls'] == 0:
            return self.reply(401, {'message': 'JWT expired'})
        if STATE['case'] == 'unauthorized':
            return self.reply(401, {'message': 'unauthorized'})
        if STATE['case'] == 'redirect':
            self.send_response(302)
            self.send_header('Location', '/untrusted-redirect')
            self.end_headers()
            return
        if self.path.startswith('/api/endpoints?'):
            if STATE['case'] == 'single-env':
                return self.reply(200, [{'Id': 42, 'Name': 'target', 'Type': 1}])
            return self.reply(200, [{'Id': 7, 'Name': 'other', 'Type': 1}, {'Id': 42, 'Name': 'target', 'Type': 2}, {'Id': 99, 'Name': 'not-docker', 'Type': 5}])
        if self.path == '/api/endpoints/42/docker/info':
            return self.reply(200, {'ServerVersion': '27.5.0', 'Swarm': {'LocalNodeState': 'active' if STATE['case'] == 'swarm' else 'inactive'}})
        if self.path == '/api/stacks':
            # Same name in a different environment must not block target ID 42.
            return self.reply(200, [{'Id': 2, 'Name': 'bark', 'EndpointId': 42 if STATE['case'] == 'duplicate' else 7}])
        if self.path == '/api/stacks/88':
            STATE['polls'] += 1
            status = 4 if STATE['case'] == 'async-error' else 2 if STATE['case'] == 'inactive' else 3 if STATE['case'] == 'async' and STATE['polls'] == 1 else 1
            return self.reply(200, {'Id': 88, 'Name': 'bark', 'EndpointId': 42, 'Status': status})
        if self.path == '/api/stacks/88/file':
            return self.reply(200, {'StackFileContent': YAML + ('# changed\n' if STATE['case'] == 'mismatched-file' else '')})
        return self.reply(404, {})

    def do_POST(self):
        STATE['requests'].append(('POST', self.path))
        payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if self.path == '/api/auth':
            STATE['auth_calls'] += 1
            assert self.headers.get('Authorization') is None
            assert self.headers.get('X-API-Key') is None
            assert payload['username'] == 'admin'
            if STATE['case'] == 'bad-password':
                assert payload['password'] == 'incorrect'
                return self.reply(422, {'message': 'Invalid credentials'})
            assert payload['password'] == PASSWORD, 'password spaces/quotes changed'
            return self.reply(200, {'jwt': 'invalid\nheader' if STATE['case'] == 'invalid-jwt' else TOKEN})
        assert self.headers.get('Authorization') == 'Bearer ' + TOKEN
        assert self.path == '/api/stacks/create/standalone/string?endpointId=42'
        assert payload == {'Name': 'bark', 'StackFileContent': YAML, 'Env': []}, 'YAML quoting/newlines changed'
        STATE['posts'] += 1
        if STATE['case'] == 'create-error':
            return self.reply(500, {'message': 'deployment failed'})
        return self.reply(201, {'Id': 88, 'Name': 'bark', 'EndpointId': 42, 'Status': 3 if STATE['case'] == 'async' else 1})


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_address[1]
with tempfile.TemporaryDirectory(prefix='portainer-api-test-') as temporary:
    directory = Path(temporary)
    call_log = directory / 'curl-calls'
    wrapper = directory / 'curl'
    wrapper.write_text('''#!/usr/bin/python3
import json,os,sys
from pathlib import Path
a=sys.argv[1:]
for i,x in enumerate(a):
    if x.startswith('https://api.github.com/'):
        a[i]='http://127.0.0.1:'+os.environ['FAKE_PORT']+'/github/'+x.split('https://api.github.com/',1)[1]
        if '--proto' in a: a[a.index('--proto')+1]='=http,https'
with open(os.environ['CURL_CALL_LOG'],'a') as f: f.write(json.dumps(a)+'\\n')
for i,x in enumerate(a):
    if x=='--header' and a[i+1].startswith('@'):
        path=Path(a[i+1][1:])
        assert path.stat().st_mode & 0o777 == 0o600
        assert path.parent.stat().st_mode & 0o777 == 0o700
os.execv('/usr/bin/curl',['curl']+a)
''')
    wrapper.chmod(0o700)
    jq_path = ROOT / 'test-tools/extracted/usr/bin'
    lib_path = ROOT / 'test-tools/extracted/usr/lib/x86_64-linux-gnu'
    env = dict(os.environ, PATH=f'{directory}:{jq_path}:/usr/sbin:/usr/bin:/sbin:/bin',
               LD_LIBRARY_PATH=str(lib_path), FAKE_PORT=str(port), CURL_CALL_LOG=str(call_log))

    def execute(case, expect, posts, session=None, reuse=False, reauth=False):
        STATE.clear()
        STATE.update(case=case, requests=[], polls=0, posts=0, auth_calls=0)
        call_log.unlink(missing_ok=True)
        master, slave = pty.openpty()
        process_env = dict(env)
        process_env.pop('SYSENV_PORTAINER_SESSION_DIR', None)
        if session is not None:
            process_env['SYSENV_PORTAINER_SESSION_DIR'] = str(session)
        proc = subprocess.Popen(['bash', str(SCRIPT)], stdin=slave, stdout=slave, stderr=slave, env=process_env, start_new_session=True)
        os.close(slave)
        transcript = b''
        steps = [('请选择 [1-1', '0' if case == 'cancel-template' else '1'), ('Stack 名称', ''),
                 ('Portainer 地址', 'http://example.com:9000' if case == 'remote-http' else f'http://127.0.0.1:{port}'),
                 ('Portainer 用户名', ''), ('Portainer 登录密码', 'incorrect' if case == 'bad-password' else PASSWORD),
                 ('请选择 [1-2', '2'),
                 ('确认创建并部署', 'n' if case == 'cancel-deploy' else 'y')]
        if case == 'single-env':
            steps = [step for step in steps if step[0] != '请选择 [1-2']
        if reuse:
            steps = [step for step in steps if step[0] != 'Portainer 地址']
            if not reauth:
                steps = [step for step in steps if step[0] not in ('Portainer 用户名', 'Portainer 登录密码')]
        index = 0
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                transcript += chunk
            if index < len(steps) and steps[index][0].encode() in transcript:
                os.write(master, (steps[index][1] + '\n').encode())
                index += 1
            if proc.poll() is not None:
                continue
        if proc.poll() is None:
            proc.kill()
            raise AssertionError('Timed out: ' + transcript.decode(errors='replace'))
        os.close(master)
        assert TOKEN.encode() not in transcript, 'token appeared in terminal output'
        assert PASSWORD.encode() not in transcript, 'password appeared in terminal output'
        assert (proc.returncode == 0) == expect, transcript.decode(errors='replace')
        if reuse and not reauth:
            assert 'Portainer 登录密码'.encode() not in transcript and 'Portainer 用户名 ['.encode() not in transcript
            assert '复用本次会话'.encode() in transcript
        assert STATE['posts'] == posts, STATE
        if call_log.exists():
            assert TOKEN not in call_log.read_text(), 'token appeared in curl arguments'
            assert PASSWORD not in call_log.read_text(), 'password appeared in curl arguments'
            for line in call_log.read_text().splitlines():
                args = json.loads(line)
                for i, argument in enumerate(args):
                    if argument == '--header' and args[i + 1].startswith('@'):
                        assert not Path(args[i + 1][1:]).exists(), 'temporary token file not removed'
                    if argument == '--data-binary':
                        assert not Path(args[i + 1][1:]).exists(), 'temporary request file not removed'
        print('PASS:', case)
        return STATE['auth_calls']

    try:
        execute('success', True, 1)
        execute('async', True, 1)
        execute('single-env', True, 1)
        execute('duplicate', False, 0)
        execute('cancel-template', True, 0)
        execute('cancel-deploy', True, 0)
        execute('unauthorized', False, 0)
        execute('bad-password', False, 0)
        execute('invalid-jwt', False, 0)
        execute('redirect', False, 0)
        assert not any(path == '/untrusted-redirect' for _, path in STATE['requests'])
        execute('swarm', False, 0)
        execute('remote-http', False, 0)
        execute('empty-templates', False, 0)
        execute('create-error', False, 1)
        execute('async-error', False, 1)
        execute('inactive', False, 1)
        execute('mismatched-file', False, 1)
        with tempfile.TemporaryDirectory(prefix='sysenv-portainer-session.', dir='/run') as cache:
            cache = Path(cache)
            assert execute('cache-first', True, 1, session=cache) == 1
            assert (cache / 'auth.header').stat().st_mode & 0o777 == 0o600
            assert PASSWORD not in (cache / 'login.json').read_text()
            assert execute('cache-second', True, 1, session=cache, reuse=True) == 0
            assert execute('cache-third', True, 1, session=cache, reuse=True) == 0
            assert execute('expired', True, 1, session=cache, reuse=True, reauth=True) == 1
            print('PASS: three deployments only log in once; expired cache requests a fresh login')
        menu = subprocess.run(['bash', '-c', 'source "$1"; apt-get() { echo UNEXPECTED_APT; return 99; }; run_remote_script() { echo "SCRIPT_CALLED:$1"; }; main', 'check', str(ROOT / 'sysenv.sh')],
                              input='2\n6\n0\n0\n', text=True, capture_output=True, env=env, timeout=5)
        assert menu.returncode == 0 and 'deploy-portainer-stack.sh' in menu.stdout and 'UNEXPECTED_APT' not in menu.stdout, menu
        print('PASS: Docker menu option 6 dispatch, return navigation and no automatic update')
        trace = directory / 'parent-cache-paths'
        parent_script = '''source "$1"
run_remote_script() {
    [[ $(bash -c 'printf "%s" "$SYSENV_PORTAINER_SESSION_DIR"') == "$SYSENV_PORTAINER_SESSION_DIR" ]] || exit 99
    printf '%s\\n' "$SYSENV_PORTAINER_SESSION_DIR" >> "$SESSION_TRACE"
    printf 'fixture-only\\n' > "$SYSENV_PORTAINER_SESSION_DIR/auth.header"
}
main
'''
        parent_env = dict(env, SESSION_TRACE=str(trace))
        parent = subprocess.run(['bash', '-c', parent_script, 'check', str(ROOT / 'sysenv.sh')],
                                input='2\n6\n6\n0\n0\n', text=True, capture_output=True, env=parent_env, timeout=5)
        assert parent.returncode == 0, parent
        paths = trace.read_text().splitlines()
        assert len(paths) == 2 and paths[0] == paths[1] and not Path(paths[0]).exists()
        trace.unlink()
        parent = subprocess.run(['bash', '-c', parent_script, 'check', str(ROOT / 'sysenv.sh')],
                                input='2\n6\n', text=True, capture_output=True, env=parent_env, timeout=5)
        assert parent.returncode == 0 and not Path(trace.read_text().strip()).exists()
        assert trace.read_text().strip() != paths[0], 'separate sysenv runs shared credentials'
        trace.unlink()
        parent = subprocess.Popen(['bash', '-c', parent_script, 'check', str(ROOT / 'sysenv.sh')],
                                  stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=parent_env)
        parent.stdin.write(b'2\n6\n')
        parent.stdin.flush()
        deadline = time.monotonic() + 5
        while not trace.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert trace.exists(), 'parent never created session'
        import signal
        parent.send_signal(signal.SIGTERM)
        parent.wait(timeout=5)
        parent.stdin.close()
        assert not Path(trace.read_text().strip()).exists(), 'signal exit left JWT cache'
        print('PASS: parent reuses one private session directory; exit, EOF, TERM clean it; runs remain isolated')
        print('ALL LOCAL HTTP API CHECKS PASSED; no live Portainer or Docker resources touched')
    finally:
        server.shutdown()
