#!/usr/bin/env python3
"""Run under Linux/WSL. All Bark and shutdown operations are intercepted."""
import contextlib
import copy
import datetime as dt
import io
import json
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

SOURCE = Path(__file__).resolve().parents[1] / 'sysenv.sh'
SCRIPT = SOURCE.read_text(encoding='utf-8')
RUNNER = SCRIPT.split("<<'PYTHON_RUNNER'\n", 1)[1].split('\nPYTHON_RUNNER\n', 1)[0]
guard = types.ModuleType('traffic_guard')
exec(compile(RUNNER, str(SOURCE) + ':embedded-python', 'exec'), guard.__dict__)


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)
        self.cfg = dict(interface='ens5', threshold_bytes=900_000_000_000,
                        bark_url='https://bark.invalid/private-test-key',
                        offset_bytes=0, offset_month='2026-11')
        self.now = dt.datetime(2026, 11, 9, 0, 0, 0, tzinfo=dt.timezone.utc)
        self.fixture = dict(jsonversion='2', interfaces=[dict(
            name='ens5', updated=dict(date=dict(year=2026, month=11, day=9),
                                     time=dict(hour=0, minute=0)),
            traffic=dict(month=[dict(date=dict(year=2026, month=11),
                                     rx=400_000_000_000, tx=499_999_999_999)]))])
        self.config_file = base / 'config.json'
        self.config_file.write_text(json.dumps(self.cfg))
        uptime_file = base / 'uptime'
        uptime_file.write_text('600.00 0.00')
        patches = [patch.object(guard, 'CONFIG', self.config_file),
                   patch.object(guard, 'LOCK', base / 'guard.lock'),
                   patch.object(guard, 'STATE', base / 'state'),
                   patch.object(guard, 'UPTIME', uptime_file),
                   patch.object(guard, 'notify', return_value=True),
                   patch.object(guard.dt, 'datetime', wraps=dt.datetime),
                   patch.object(guard, 'run', side_effect=self.fake_run)]
        self.mocks = [p.start() for p in patches]
        for p in patches:
            self.addCleanup(p.stop)
        self.mocks[-2].now.return_value = self.now
        self.run_mock = self.mocks[-1]
        self.notify_mock = self.mocks[-3]

    def fake_run(self, args):
        if args[0] == 'vnstat':
            return subprocess.CompletedProcess(args, 0, json.dumps(self.fixture), '')
        if args == ['systemctl', '--no-block', 'poweroff']:
            return subprocess.CompletedProcess(args, 0, '', '')
        raise AssertionError('Unexpected external operation: ' + repr(args))

    def execute(self, command='check'):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return guard.main(command)

    def shutdown_calls(self):
        return [c for c in self.run_mock.call_args_list if c.args[0][0] == 'systemctl']

    def at_threshold(self):
        self.fixture['interfaces'][0]['traffic']['month'][0]['tx'] += 1

    def test_below_threshold_does_nothing(self):
        self.assertEqual(self.execute(), 0)
        self.assertFalse(self.shutdown_calls())
        self.notify_mock.assert_not_called()

    def test_exact_threshold_notifies_then_powers_off(self):
        self.at_threshold()
        self.assertEqual(self.execute(), 0)
        self.notify_mock.assert_called_once()
        self.assertEqual(len(self.shutdown_calls()), 1)

    def test_over_threshold(self):
        self.fixture['interfaces'][0]['traffic']['month'][0]['tx'] += 20_000_000_000
        self.execute()
        self.assertEqual(len(self.shutdown_calls()), 1)

    def test_notification_failure_still_powers_off_and_retries(self):
        self.at_threshold()
        self.notify_mock.return_value = False
        self.execute()
        self.execute()
        self.assertEqual(self.notify_mock.call_count, 2)
        self.assertEqual(len(self.shutdown_calls()), 2)

    def test_notification_exception_still_powers_off(self):
        self.at_threshold()
        self.notify_mock.side_effect = OSError('simulated')
        self.execute()
        self.assertEqual(len(self.shutdown_calls()), 1)

    def test_reboot_same_month_still_powers_off_without_duplicate_notification(self):
        self.at_threshold()
        self.execute()
        self.execute()
        self.notify_mock.assert_called_once()
        self.assertEqual(len(self.shutdown_calls()), 2)

    def test_boot_grace_prevents_shutdown_even_above_threshold(self):
        self.at_threshold()
        for uptime in ('0.00', '15.00', '299.99'):
            with self.subTest(uptime=uptime):
                guard.UPTIME.write_text(uptime + ' 0.00')
                self.assertEqual(self.execute(), 0)
        self.notify_mock.assert_not_called()
        self.run_mock.assert_not_called()

    def test_grace_expires_at_five_minutes(self):
        self.at_threshold()
        guard.UPTIME.write_text('300.00 0.00')
        self.execute()
        self.assertEqual(len(self.shutdown_calls()), 1)

    def test_reboot_gets_grace_again_with_prior_notification_marker(self):
        self.at_threshold()
        self.execute()
        guard.UPTIME.write_text('20.00 0.00')
        self.execute()
        self.assertEqual(len(self.shutdown_calls()), 1)
        guard.UPTIME.write_text('301.00 0.00')
        self.execute()
        self.assertEqual(len(self.shutdown_calls()), 2)
        self.notify_mock.assert_called_once()

    def test_status_reports_remaining_grace(self):
        guard.UPTIME.write_text('200.50 0.00')
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(guard.main('status'), 0)
        self.assertIn('还剩 100 秒', output.getvalue())
        self.assertFalse(self.shutdown_calls())

    def test_unknown_uptime_does_not_trigger_shutdown(self):
        self.at_threshold()
        for value in ('bad', 'nan', '-1', 'inf'):
            with self.subTest(value=value):
                guard.UPTIME.write_text(value)
                with self.assertRaises(ValueError):
                    self.execute()
        self.assertFalse(self.shutdown_calls())

    def test_status_above_threshold_is_read_only(self):
        self.at_threshold()
        self.execute('status')
        self.notify_mock.assert_not_called()
        self.assertFalse(self.shutdown_calls())

    def test_offset_counts_only_in_its_month(self):
        self.cfg['offset_bytes'] = 1
        self.assertEqual(guard.usage(self.cfg, self.now), 900_000_000_000)
        self.cfg['offset_month'] = '2026-10'
        self.assertEqual(guard.usage(self.cfg, self.now), 899_999_999_999)

    def test_new_month_uses_new_month_row(self):
        self.fixture['interfaces'][0]['traffic']['month'].append(
            dict(date=dict(year=2026, month=10), rx=2_000_000_000_000, tx=0))
        self.assertEqual(guard.usage(self.cfg, self.now), 899_999_999_999)

    def test_stale_database_is_rejected(self):
        self.fixture['interfaces'][0]['updated']['date']['day'] = 8
        with self.assertRaises(ValueError):
            self.execute()
        self.assertFalse(self.shutdown_calls())

    def test_missing_current_month_is_not_treated_as_zero(self):
        self.fixture['interfaces'][0]['traffic']['month'][0]['date']['month'] = 10
        with self.assertRaises(ValueError):
            self.execute()

    def test_wrong_interface_and_version_are_rejected(self):
        for field in ('interface', 'version'):
            with self.subTest(field=field):
                fixture = copy.deepcopy(self.fixture)
                if field == 'interface':
                    fixture['interfaces'][0]['name'] = 'docker0'
                else:
                    fixture['jsonversion'] = '1'
                with patch.object(guard, 'run', return_value=Mock(stdout=json.dumps(fixture))):
                    with self.assertRaises(ValueError):
                        self.execute()

    def test_test_bark_never_queries_usage_or_shuts_down(self):
        self.execute('test-bark')
        self.notify_mock.assert_called_once()
        self.run_mock.assert_not_called()

    def test_failed_notification_does_not_log_secret(self):
        opener = Mock()
        opener.open.side_effect = RuntimeError(self.cfg['bark_url'])
        stream = io.StringIO()
        # Bypass the setUp mock to test the real function without a network call.
        real = types.ModuleType('notification_test')
        exec(compile(RUNNER, '<embedded>', 'exec'), real.__dict__)
        with patch.object(real.urllib.request, 'build_opener', return_value=opener), \
                contextlib.redirect_stderr(stream):
            self.assertFalse(real.notify(self.cfg, '标题', '正文'))
        self.assertNotIn('private-test-key', stream.getvalue())
        self.assertEqual(opener.open.call_args.kwargs['timeout'], 5)

    def test_lock_prevents_concurrent_shutdown(self):
        import fcntl
        self.at_threshold()
        with guard.LOCK.open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.execute(), 1)
        self.assertFalse(self.shutdown_calls())


class MenuTests(unittest.TestCase):
    def shell(self, code, choices):
        result = subprocess.run(['bash', '-c', 'source "$1"; ' + code, '--', str(SOURCE)],
                                input=choices, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_monitor_menu_dispatches_all_operations(self):
        output = self.shell('traffic_monitor() { printf "CALLED:%s\\n" "$1"; }; '
                            'traffic_monitor_menu', '1\n2\n3\n4\n5\n0\n')
        for command in ('install', 'status', 'test-bark', 'disable', 'enable'):
            self.assertIn('CALLED:' + command, output)

    def test_system_settings_routes_to_monitor_menu(self):
        output = self.shell('traffic_monitor_menu() { printf "MONITOR-MENU\\n"; }; '
                            'system_settings_menu', '8\n0\n')
        self.assertIn('MONITOR-MENU', output)

    def test_operation_failure_returns_to_menu(self):
        output = self.shell('traffic_monitor() { return 3; }; '
                            'traffic_monitor_menu', '1\n0\n')
        self.assertIn('返回系统设置', output)


if __name__ == '__main__':
    unittest.main(verbosity=2)

