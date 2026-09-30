"""Offline regression tests: fake CLIs, disposable state, no subscriptions."""
import json
from datetime import datetime
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash') or (r'C:\Program Files\Git\bin\bash.exe' if os.name == 'nt' else None)
PS = shutil.which('powershell') or shutil.which('pwsh')


class KeepaliveTests:
    platform = ''

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='keepalive tests ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copytree(ROOT / 'bin', self.root / 'bin')
        (self.root / 'state').mkdir()
        self.env = os.environ.copy()
        self.env['FAKE_MODE'] = 'ok'
        self.env['FAKE_COUNT'] = str(self.root / 'calls.txt')
        self.env.pop('L5H_STATE_FILE', None)
        self.env.pop('L5H_CONFIG', None)
        for name in ('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY'):
            self.env.pop(name, None)
        self.mock = self.root / ('fake.ps1' if self.platform == 'ps' else 'fake.sh')
        if self.platform == 'ps':
            self.mock.write_text('''Add-Content -LiteralPath $env:FAKE_COUNT -Value call
if ($env:FAKE_MODE -eq 'slow') { Start-Sleep -Seconds 2 }
$global:LASTEXITCODE = 0
if ($env:FAKE_MODE -eq 'exit') { $global:LASTEXITCODE = 7; Write-Output 'secret-test-123'; return }
if ($env:FAKE_MODE -eq 'invalid') { Write-Output '{}'; return }
if ($env:FAKE_MODE -eq 'zero') { Write-Output '{"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":1,"output_tokens":0}}'; return }
if ($env:FAKE_MODE -eq 'codex') { Write-Output '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'; return }
if ($env:FAKE_MODE -eq 'limit') { $global:LASTEXITCODE = 1; Write-Output '{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached"}'; return }
if ($env:FAKE_MODE -eq 'weeklylimit') { $global:LASTEXITCODE = 1; Write-Output 'Weekly limit reached - resets Oct 3, 9am'; return }
if ($env:FAKE_MODE -eq 'diskquota') { $global:LASTEXITCODE = 1; Write-Output 'error: Disk quota exceeded (HTTP 429 from cache)'; return }
if ($env:FAKE_MODE -eq 'codexlimit') { $global:LASTEXITCODE = 1; Write-Output '{"type":"turn.failed","error":{"message":"You have hit your usage limit. Try again in 2 days 3 hours 0 minutes."}}'; return }
Write-Output '{"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":1,"output_tokens":1}}'
''')
        else:
            self.mock.write_text('''#!/usr/bin/env bash
echo call >> "$FAKE_COUNT"
[ "$FAKE_MODE" != slow ] || sleep 2
[ "$FAKE_MODE" != trapzero ] || { trap 'exit 0' TERM; sleep 20; }
case "$FAKE_MODE" in
exit) echo secret-test-123; exit 7 ;;
invalid) echo '{}' ;;
zero) echo '{"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":1,"output_tokens":0}}' ;;
codex) echo '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}' ;;
limit) echo '{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached"}'; exit 1 ;;
weeklylimit) echo 'Weekly limit reached - resets Oct 3, 9am'; exit 1 ;;
diskquota) echo 'error: Disk quota exceeded (HTTP 429 from cache)'; exit 1 ;;
codexlimit) echo '{"type":"turn.failed","error":{"message":"You have hit your usage limit. Try again in 2 days 3 hours 0 minutes."}}'; exit 1 ;;
*) echo '{"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":1,"output_tokens":1}}' ;;
esac
''', newline='\n')
            self.mock.chmod(0o755)
        self.config()

    def config(self, extra='', codex=False):
        self.cfg = self.root / 'config.env'
        self.cfg.write_text(f'CLAUDE_ENABLED={str(not codex).lower()}\nCODEX_ENABLED={str(codex).lower()}\nCLAUDE_BIN={self.mock.as_posix()}\nCODEX_BIN={self.mock.as_posix()}\n' + extra, encoding='utf-8')

    def command(self, *args):
        if self.platform == 'ps':
            mapping = {'--force': '-Force', '--dry-run': '-DryRun', '--status': '-Status', '--config': '-ConfigPath'}
            return [PS, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(self.root / 'bin/keepalive.ps1'), *[mapping.get(a, a) for a in args]]
        return [BASH, str(self.root / 'bin/keepalive.sh'), *args]

    def run_cli(self, *args):
        return subprocess.run(self.command(*args), env=self.env, capture_output=True, text=True, timeout=35)

    def calls(self):
        p = self.root / 'calls.txt'
        return len(p.read_text(encoding='utf-8-sig').splitlines()) if p.exists() else 0

    def test_success_then_skip(self):
        first = self.run_cli()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertEqual(self.run_cli().returncode, 0)
        self.assertEqual(self.calls(), 1)

    def test_success_time_is_recorded_after_the_cli_returns(self):
        self.env['FAKE_MODE'] = 'slow'
        started = time.time()
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        if self.platform == 'ps':
            saved = json.loads((self.root / 'state/state.json').read_text(encoding='utf-8-sig'))
            success = datetime.fromisoformat(saved['claude']['lastSuccessUtc']).timestamp()
        else:
            values = dict(line.split('=', 1) for line in (self.root / 'state/state.env').read_text().splitlines() if '=' in line)
            success = int(values['CLAUDE_LAST'])
        self.assertGreaterEqual(success, started + 1)

    def test_invalid_output_is_not_success(self):
        self.env['FAKE_MODE'] = 'invalid'
        self.assertEqual(self.run_cli().returncode, 1)
        self.assertEqual(self.run_cli().returncode, 1)
        self.assertEqual(self.calls(), 2)

    def test_existing_state_is_replaced(self):
        self.assertEqual(self.run_cli().returncode, 0)
        result = self.run_cli('--force')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.run_cli().returncode, 0)
        self.assertEqual(self.calls(), 2)

    def test_zero_output_is_not_a_successful_ping(self):
        self.env['FAKE_MODE'] = 'zero'
        self.assertEqual(self.run_cli().returncode, 1)
        self.assertEqual(self.run_cli().returncode, 1)
        self.assertEqual(self.calls(), 2)

    def test_failed_cli_does_not_leak_output(self):
        self.env['FAKE_MODE'] = 'exit'
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('secret-test-123', result.stdout + result.stderr)
        self.assertNotIn('secret-test-123', ''.join(p.read_text(encoding='utf-8-sig') for p in (self.root / 'logs').glob('*.log')))

    def test_codex_needs_completed_turn(self):
        self.config(codex=True)
        self.env['FAKE_MODE'] = 'invalid'
        self.assertEqual(self.run_cli().returncode, 1)
        self.env['FAKE_MODE'] = 'codex'
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def retry_after(self, provider):
        if self.platform == 'ps':
            saved = json.loads((self.root / 'state/state.json').read_text(encoding='utf-8-sig'))
            # ToString('o') on a UTC time: 2026-09-25T18:00:00.1234567Z
            return datetime.fromisoformat(saved[provider]['retryAfterUtc'][:19] + '+00:00').timestamp()
        values = dict(line.split('=', 1) for line in (self.root / 'state/state.env').read_text().splitlines() if '=' in line)
        return int(values[f'{provider.upper()}_RETRY'])

    def test_usage_limit_defers_instead_of_failing(self):
        self.env['FAKE_MODE'] = 'limit'
        started = time.time()
        first = self.run_cli()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertIn('usage limit reached', first.stdout)
        self.assertAlmostEqual(self.retry_after('claude'), started + 3600, delta=120)
        second = self.run_cli()
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual(self.calls(), 1)
        self.assertIn('usage limit reached', self.run_cli('--status').stdout)
        self.env['FAKE_MODE'] = 'ok'
        self.assertEqual(self.run_cli('--force').returncode, 0)
        self.assertEqual(self.calls(), 2)
        self.assertEqual(self.run_cli().returncode, 0)
        self.assertEqual(self.calls(), 2)

    def test_weekly_or_session_limit_wording_defers(self):
        self.env['FAKE_MODE'] = 'weeklylimit'
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('usage limit reached', result.stdout)

    def test_unknown_failure_reports_only_a_fixed_class(self):
        self.env['FAKE_MODE'] = 'exit'
        result = self.run_cli()
        self.assertIn('class=provider_error', result.stdout + result.stderr)
        self.assertNotIn('secret-test-123', result.stdout + result.stderr)

    def test_unrelated_quota_error_is_a_real_failure(self):
        for codex in (False, True):
            self.config(codex=codex)
            self.env['FAKE_MODE'] = 'diskquota'
            result = self.run_cli()
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertNotIn('usage limit reached', result.stdout)

    def test_codex_reset_hint_sets_retry_time(self):
        self.config(codex=True)
        self.env['FAKE_MODE'] = 'codexlimit'
        started = time.time()
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('Try again', result.stdout + result.stderr)
        self.assertAlmostEqual(self.retry_after('codex'), started + (2 * 1440 + 180) * 60, delta=120)

    def test_dry_run_never_calls_cli(self):
        self.assertEqual(self.run_cli('--dry-run', '--force').returncode, 0)
        self.assertEqual(self.calls(), 0)

    def test_api_credentials_are_rejected(self):
        self.env['ANTHROPIC_API_KEY'] = 'do-not-use-this-test-key'
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.calls(), 0)
        self.assertNotIn('do-not-use-this-test-key', result.stdout + result.stderr)

    def test_hung_cli_is_bounded(self):
        self.env['FAKE_MODE'] = 'slow'
        helper = self.root / 'bin' / ('run-cli.ps1' if self.platform == 'ps' else 'run-cli.sh')
        helper.write_text(helper.read_text().replace('-Timeout 120', '-Timeout 2').replace('sleep 120', 'sleep 2'), newline='\n')
        self.mock.write_text(self.mock.read_text().replace('Seconds 2', 'Seconds 20').replace('sleep 2', 'sleep 20'), newline='\n')
        start = time.monotonic()
        result = self.run_cli()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertLess(time.monotonic() - start, 12)

    def test_missing_explicit_config_fails(self):
        self.assertEqual(self.run_cli('--config', str(self.root / 'missing.env')).returncode, 2)
        self.assertEqual(self.calls(), 0)

    def test_bom_floor_and_allowlist(self):
        self.config('INTERVAL_MINUTES=1\nPATH=bad\nStateFile=bad\n')
        self.cfg.write_text('\ufeff' + self.cfg.read_text(), encoding='utf-8')
        result = self.run_cli('--status')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('300 minutes', result.stdout)

    def test_concurrent_runs_only_ping_once(self):
        self.env['FAKE_MODE'] = 'slow'
        first = subprocess.Popen(self.command(), env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 12
            while self.calls() == 0 and time.monotonic() < deadline:
                time.sleep(.1)
            second = self.run_cli()
            out, err = first.communicate(timeout=30)
            self.assertEqual(first.returncode, 0, (out, err))
            self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
            self.assertEqual(self.calls(), 1)
        finally:
            if first.poll() is None:
                first.kill()
                first.communicate()


@unittest.skipUnless(BASH, 'Bash unavailable')
class BashTests(KeepaliveTests, unittest.TestCase):
    platform = 'bash'

    def test_timeout_cannot_be_reported_as_success(self):
        self.env['FAKE_MODE'] = 'trapzero'
        helper = self.root / 'bin/run-cli.sh'
        helper.write_text(helper.read_text().replace('sleep 120', 'sleep 2'), newline='\n')
        result = self.run_cli()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('timed out', result.stdout + result.stderr)

    def test_due_has_no_side_effects(self):
        self.assertEqual(self.run_cli('--due').returncode, 0)
        self.assertEqual(self.calls(), 0)
        self.assertEqual(self.run_cli().returncode, 0)
        self.assertEqual(self.run_cli('--due').returncode, 3)

    def test_due_respects_quota_deferral(self):
        self.env['FAKE_MODE'] = 'limit'
        self.assertEqual(self.run_cli().returncode, 0)
        due = self.run_cli('--due')
        self.assertEqual(due.returncode, 3, due.stdout)

    def test_missing_config_argument(self):
        self.assertEqual(self.run_cli('--config').returncode, 2)


@unittest.skipUnless(PS, 'PowerShell unavailable')
class PowerShellTests(KeepaliveTests, unittest.TestCase):
    platform = 'ps'

    def test_failed_state_write_returns_failure(self):
        (self.root / 'state/state.json').mkdir()
        result = self.run_cli()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
