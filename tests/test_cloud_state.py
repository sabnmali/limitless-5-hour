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
