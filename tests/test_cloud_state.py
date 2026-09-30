"""Run the real workflow save step against two conflicting local Git clones."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_keepalive import BASH, ROOT


def save_script():
    workflow = (ROOT / '.github/workflows/keepalive.yml').read_text(encoding='utf-8')
    step = workflow.split('      - name: Save the new state', 1)[1].split('      - name:', 1)[0]
    script = step.split('        run: |\n', 1)[1]
    return '\n'.join(line[10:] for line in script.splitlines())


@unittest.skipUnless(BASH and shutil.which('git'), 'Bash/Git unavailable')
class CloudStateTests(unittest.TestCase):
    def git_env(self, **extra):
        env = os.environ.copy()
        env.update(GIT_AUTHOR_NAME='Keepalive Tests', GIT_COMMITTER_NAME='Keepalive Tests',
                   GIT_AUTHOR_EMAIL='tests@example.invalid', GIT_COMMITTER_EMAIL='tests@example.invalid',
                   GITHUB_REF_NAME='main', GITHUB_TOKEN='offline-test-token', GIT_TERMINAL_PROMPT='0')
        env.update(extra)
        return env

    def test_quota_deferral_is_saved_with_next_due(self):
        env = self.git_env(ENABLED='claude codex', CLAUDE_NEW='10000', CODEX_RETRY_NEW='90000')
        with tempfile.TemporaryDirectory(prefix='keepalive git ') as temp:
            base = Path(temp)

            def git(cwd, *args):
                return subprocess.run(['git', *args], cwd=cwd, env=env, capture_output=True, check=True).stdout

            git(base, 'init', '--bare', '--initial-branch=main', 'remote.git')
            git(base, 'clone', str(base / 'remote.git'), 'runner')
            runner = base / 'runner'
            (runner / 'state').mkdir()
            (runner / 'state/cloud-state.env').write_text('CLAUDE_LAST=0\nCODEX_LAST=5\nCLAUDE_RETRY=777\n', newline='\n')
            (runner / 'cloud.env').write_text('INTERVAL_MINUTES=301\n', newline='\n')
            git(runner, 'add', '.')
            git(runner, 'commit', '-m', 'initial')
            git(runner, 'push', '-u', 'origin', 'main')
            result = subprocess.run([BASH, '-c', save_script()], cwd=runner, env=env, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            saved = git(base, '--git-dir=remote.git', 'show', 'main:state/cloud-state.env').decode()
            # A successful ping clears that provider's retry time.
            self.assertIn('CLAUDE_LAST=10000\n', saved)
            self.assertIn('CLAUDE_RETRY=0\n', saved)
            self.assertIn('CODEX_LAST=5\n', saved)
            self.assertIn('CODEX_RETRY=90000\n', saved)
            # min(claude 10000 + 301 min, codex retry 90000)
            self.assertIn(f'NEXT_DUE={min(10000 + 301 * 60, 90000)}\n', saved)

    def test_conflict_keeps_both_providers_newest_ping(self):
        env = self.git_env()
        with tempfile.TemporaryDirectory(prefix='keepalive git ') as temp:
            base = Path(temp)

            def git(cwd, *args):
                return subprocess.run(['git', *args], cwd=cwd, env=env, capture_output=True, check=True).stdout

            git(base, 'init', '--bare', '--initial-branch=main', 'remote.git')
            git(base, 'clone', str(base / 'remote.git'), 'runner')
            runner = base / 'runner'
            (runner / 'state').mkdir()
            state = runner / 'state/cloud-state.env'
            state.write_text('CLAUDE_LAST=0\nCODEX_LAST=0\n', newline='\n')
            git(runner, 'add', '.')
            git(runner, 'commit', '-m', 'initial')
            git(runner, 'push', '-u', 'origin', 'main')
            git(base, 'clone', str(base / 'remote.git'), 'other')
            other = base / 'other'
            (other / 'state/cloud-state.env').write_text('CLAUDE_LAST=0\nCODEX_LAST=200\n', newline='\n')
            git(other, 'commit', '-am', 'other provider ping')
            git(other, 'push')
            state.write_text('CLAUDE_LAST=100\nCODEX_LAST=0\n', newline='\n')
            result = subprocess.run([BASH, '-c', save_script()], cwd=runner, env=env, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            saved = git(base, '--git-dir=remote.git', 'show', 'main:state/cloud-state.env')
            self.assertIn(b'CLAUDE_LAST=100', saved)
            self.assertIn(b'CODEX_LAST=200', saved)

    def run_save(self, initial, **extra):
        env = self.git_env(**extra)
        with tempfile.TemporaryDirectory(prefix='keepalive git ') as temp:
            base = Path(temp)

            def git(cwd, *args):
                return subprocess.run(['git', *args], cwd=cwd, env=env, capture_output=True, check=True).stdout

            git(base, 'init', '--bare', '--initial-branch=main', 'remote.git')
            git(base, 'clone', str(base / 'remote.git'), 'runner')
            runner = base / 'runner'
            (runner / 'state').mkdir()
            (runner / 'state/cloud-state.env').write_text(initial, newline='\n')
            (runner / 'cloud.env').write_text('INTERVAL_MINUTES=301\n', newline='\n')
            git(runner, 'add', '.')
            git(runner, 'commit', '-m', 'initial')
            git(runner, 'push', '-u', 'origin', 'main')
            result = subprocess.run([BASH, '-c', save_script()], cwd=runner, env=env, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return git(base, '--git-dir=remote.git', 'show', 'main:state/cloud-state.env').decode()

    def test_provider_due_now_keeps_next_due_at_zero(self):
        # Claude has never pinged, so it is due now: NEXT_DUE must not move
        # out to Codex's later time, or the dispatcher skips Claude.
        saved = self.run_save('CLAUDE_LAST=0\nCODEX_LAST=5\n', ENABLED='claude codex', CODEX_NEW='10000')
        self.assertIn('NEXT_DUE=0\n', saved)

    def test_failure_backoff_is_saved_and_cleared(self):
        saved = self.run_save('CLAUDE_LAST=100\n', ENABLED='claude', CLAUDE_RETRY_NEW='50000', CLAUDE_FAILS_NEW='2')
        self.assertIn('CLAUDE_RETRY=50000\n', saved)
        self.assertIn('CLAUDE_FAILS=2\n', saved)
        self.assertIn('NEXT_DUE=50000\n', saved)
        saved = self.run_save('CLAUDE_LAST=100\nCLAUDE_RETRY=50000\nCLAUDE_FAILS=2\n', ENABLED='claude', CLAUDE_NEW='60000')
        self.assertIn('CLAUDE_RETRY=0\n', saved)
        self.assertIn('CLAUDE_FAILS=0\n', saved)

    def test_conflict_does_not_revive_a_cleared_failure_count(self):
        env = self.git_env(ENABLED='claude codex', CLAUDE_NEW='60000')
        with tempfile.TemporaryDirectory(prefix='keepalive git ') as temp:
            base = Path(temp)

            def git(cwd, *args):
                return subprocess.run(['git', *args], cwd=cwd, env=env, capture_output=True, check=True).stdout

            git(base, 'init', '--bare', '--initial-branch=main', 'remote.git')
            git(base, 'clone', str(base / 'remote.git'), 'runner')
            runner = base / 'runner'
            (runner / 'state').mkdir()
            start = 'CLAUDE_LAST=100\nCODEX_LAST=0\nCLAUDE_RETRY=50000\nCODEX_RETRY=0\nCLAUDE_FAILS=4\nCODEX_FAILS=0\n'
            (runner / 'state/cloud-state.env').write_text(start, newline='\n')
            (runner / 'cloud.env').write_text('INTERVAL_MINUTES=301\n', newline='\n')
            git(runner, 'add', '.')
            git(runner, 'commit', '-m', 'initial')
            git(runner, 'push', '-u', 'origin', 'main')
            git(base, 'clone', str(base / 'remote.git'), 'other')
            other = base / 'other'
            (other / 'state/cloud-state.env').write_text(start.replace('CODEX_LAST=0', 'CODEX_LAST=200'), newline='\n')
            git(other, 'commit', '-am', 'other provider ping')
            git(other, 'push')
            result = subprocess.run([BASH, '-c', save_script()], cwd=runner, env=env, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            saved = git(base, '--git-dir=remote.git', 'show', 'main:state/cloud-state.env').decode()
            self.assertIn('CLAUDE_LAST=60000\n', saved)
            self.assertIn('CLAUDE_RETRY=0\n', saved)
            self.assertIn('CLAUDE_FAILS=0\n', saved)
            self.assertIn('CODEX_LAST=200\n', saved)
