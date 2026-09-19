"""Exercise cron quoting with legal but shell-sensitive directory names."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_keepalive import BASH, PS, ROOT


class DistributionSafetyTests(unittest.TestCase):
    def test_forks_require_their_own_codex_opt_in(self):
        cloud = (ROOT / 'cloud.env').read_text(encoding='utf-8')
        workflow = (ROOT / '.github/workflows/keepalive.yml').read_text(encoding='utf-8')
        windows = (ROOT / 'install/setup-cloud-windows.ps1').read_text(encoding='utf-8')
        unix = (ROOT / 'install/setup-cloud.sh').read_text(encoding='utf-8')

        self.assertIn('\nCLAUDE_ENABLED=false\n', cloud)
        self.assertIn('\nCODEX_ENABLED=false\n', cloud)
        self.assertIn('vars.L5H_CLAUDE_ENABLED', workflow)
        self.assertIn('vars.L5H_CODEX_ENABLED', workflow)
        self.assertIn('github.event.repository.private == true', workflow)
        self.assertNotIn('${{ inputs.force }}', workflow)
        self.assertNotIn('--force', workflow)
        self.assertIn('Legacy compatibility only; ignored', workflow)
        self.assertNotIn('${{ runner.temp }}', workflow)
        self.assertIn('node:22-bookworm-slim@sha256:', workflow)
        self.assertIn('set -euo pipefail', workflow)
        self.assertIn('Claude success timestamp did not advance.', workflow)
        self.assertIn('Codex success timestamp did not advance.', workflow)
        self.assertIn('\n  claude:\n', workflow)
        self.assertIn('\n  codex:\n', workflow)
        self.assertIn('\n  save:\n', workflow)
        self.assertIn('variable set L5H_CLAUDE_ENABLED --body true', windows)
        self.assertIn('variable set L5H_CLAUDE_ENABLED --body true', unix)
        self.assertIn('variable set L5H_CODEX_ENABLED --body true', windows)
        self.assertIn('variable set L5H_CODEX_ENABLED --body true', unix)
        self.assertIn("$visibility -ne 'PRIVATE'", windows)
        self.assertIn('[ "$visibility" = PRIVATE ]', unix)
        self.assertNotIn('continuing without Codex', windows)
        self.assertNotIn('continuing without Codex', unix)
        self.assertIn("Die \"No $authFile found.", windows)
        self.assertIn('die "No auth.json found in CODEX_HOME.', unix)

    def test_agent_instructions_stay_identical(self):
        self.assertEqual(
            (ROOT / 'AGENTS.md').read_bytes(),
            (ROOT / 'CLAUDE.md').read_bytes(),
        )


@unittest.skipUnless(PS, 'PowerShell unavailable')
class WindowsInstallerSafetyTests(unittest.TestCase):
    def test_without_opt_in_has_no_side_effects(self):
        with tempfile.TemporaryDirectory(prefix='keepalive opt-in ') as temp:
            repo = Path(temp)
            (repo / 'install').mkdir()
            installer = repo / 'install/install-windows.ps1'
            shutil.copy2(ROOT / 'install/install-windows.ps1', installer)
            result = subprocess.run([PS, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(installer)], capture_output=True, text=True, timeout=20)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Local automation is opt-in', result.stdout + result.stderr)
            self.assertEqual(sorted(p.relative_to(repo).as_posix() for p in repo.rglob('*')), ['install', 'install/install-windows.ps1'])


@unittest.skipUnless(BASH, 'Bash unavailable')
class UnixInstallerTests(unittest.TestCase):
    def test_cron_path_is_literal(self):
        with tempfile.TemporaryDirectory(prefix='keepalive installer ') as temp:
            base = Path(temp)
            repo = base / "repo ' `touch INJECTED` & %"
            shutil.copytree(ROOT / 'bin', repo / 'bin')
            shutil.copytree(ROOT / 'install', repo / 'install')
            (repo / 'config.env').write_text('CLAUDE_ENABLED=false\nCODEX_ENABLED=false\n', newline='\n')
            mockbin = base / 'mockbin'
            mockbin.mkdir()
            fakehome = base / 'home'
            fakehome.mkdir()
            scripts = {
                'uname': 'echo Linux',
                'claude': "echo '{\"loggedIn\":true}'",
                'codex': 'exit 0',
                'crontab': '[ "$1" != -l ] || exit 0\ncat > "$CRON_CAPTURE"',
            }
            for name, body in scripts.items():
                file = mockbin / name
                file.write_text('#!/usr/bin/env bash\n' + body + '\n', newline='\n')
                file.chmod(0o755)
            env = os.environ.copy()
            env['PATH'] = str(mockbin) + os.pathsep + env['PATH']
            env['HOME'] = fakehome.as_posix()
            env['CRON_CAPTURE'] = (base / 'cron.txt').as_posix()
            result = subprocess.run([BASH, str(repo / 'install/install-unix.sh')], cwd=base, env=env, capture_output=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((repo / 'logs').is_dir())
            line = (base / 'cron.txt').read_text()
            command = line.split(' * * * * ', 1)[1].replace('\\%', '%')
            result = subprocess.run([BASH, '-c', command], cwd=base, env=env, capture_output=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((base / 'INJECTED').exists())
