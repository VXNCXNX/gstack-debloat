"""Run against generated skills: python3 tests/test_codex_startup.py GSTACK_DIR.

Fixtures stay in the system temp directory for inspection.
"""

import ast
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


GSTACK = Path(sys.argv.pop(1)).resolve()
CONTENT = (GSTACK / '.agents/skills/gstack-investigate/SKILL.md').read_text()
BOOTSTRAP = re.search(r'## Preamble \(run first\)\s+```bash\n(.*?)\n```', CONTENT, re.S).group(1)


class StartupPatchCompatibilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Load only the patch function, without running the install mutation
        # code in the surrounding embedded Python script.
        script = (Path(__file__).resolve().parents[1] / 'strip-telemetry.sh').read_text()
        patcher = script.split("<< 'PYEOF'\n", 1)[1].split('\nPYEOF\n', 1)[0]
        function = next(node for node in ast.parse(patcher).body
                        if isinstance(node, ast.FunctionDef) and node.name == 'patch_startup_bootstrap')
        namespace = {'re': re}
        exec(compile(ast.Module(body=[function], type_ignores=[]), '<startup patch>', 'exec'), namespace)
        cls.patch = staticmethod(namespace['patch_startup_bootstrap'])

    def test_legacy_inline_runtime_is_unchanged(self):
        source = '''const runtimeRoot = `_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
GSTACK_ROOT="$HOME/${hostConfig.globalRoot}"
GSTACK_BIN="$GSTACK_ROOT/bin"
GSTACK_BROWSE="$GSTACK_ROOT/browse/dist"
GSTACK_DESIGN="$GSTACK_ROOT/design/dist"
`;
return `${runtimeRoot}_BRANCH=$(git branch --show-current 2>/dev/null)
echo "BRANCH: $_BRANCH"`;
'''
        # A mention in prose does not make an inline preamble helper-based.
        for prefix in ('', '// gstack-skill-start is used by newer versions.\n'):
            with self.subTest(prefix=prefix):
                self.assertEqual(self.patch(prefix + source), prefix + source)

    def test_current_helper_bootstrap_remains_idempotent(self):
        source = (GSTACK / 'scripts/resolvers/preamble/generate-preamble-bash.ts').read_text()
        self.assertEqual(self.patch(source), source)


class CodexStartupTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='gstack bootstrap '))
        self.home = self.root / 'user home'
        self.repo = self.root / 'project'
        self.repo.mkdir()
        commands = self.root / 'commands'
        commands.mkdir()
        git = commands / 'git'
        git.write_text('#!/bin/sh\nprintf "%s\\n" "$GSTACK_TEST_REPO"\n')
        git.chmod(0o755)
        self.env = dict(os.environ, GSTACK_TEST_HOME=str(self.home), GSTACK_TEST_REPO=str(self.repo))
        self.env['PATH'] = str(commands) + os.pathsep + self.env['PATH']

    def install(self, root, executable=True, succeeds=True):
        helper = root / 'bin/gstack-skill-start'
        helper.parent.mkdir(parents=True, exist_ok=True)
        helper.write_text('#!/bin/sh\necho "SKILL_START_PROTO: 1"\n' if succeeds else '#!/bin/sh\nexit 1\n')
        helper.chmod(0o755 if executable else 0o644)
        return root

    def run_bootstrap(self):
        # Keep the process HOME intact; substitute only this snippet's paths.
        script = BOOTSTRAP.replace('$HOME', '$GSTACK_TEST_HOME')
        script += '\nprintf "ROOT=%s\\nBIN=%s\\nBROWSE=%s\\nDESIGN=%s\\n" "$GSTACK_ROOT" "$GSTACK_BIN" "$GSTACK_BROWSE" "$GSTACK_DESIGN"\n'
        result = subprocess.run(['bash', '-c', script], cwd=self.repo, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        return result.stdout

    def assert_root(self, root):
        output = self.run_bootstrap()
        self.assertIn('SKILL_START_PROTO: 1\n', output)
        self.assertIn(f'ROOT={root}\nBIN={root}/bin\nBROWSE={root}/browse/dist\nDESIGN={root}/design/dist\n', output)

    def test_claude_shared_install(self):
        self.assert_root(self.install(self.home / '.claude/skills/gstack'))

    def test_agents_shared_install(self):
        self.assert_root(self.install(self.home / '.agents/skills/gstack'))

    def test_repo_runtime_wins_over_global(self):
        self.install(self.home / '.codex/skills/gstack')
        self.assert_root(self.install(self.repo / '.agents/skills/gstack'))

    def test_native_global_wins_over_shared(self):
        self.install(self.home / '.claude/skills/gstack')
        self.assert_root(self.install(self.home / '.codex/skills/gstack'))

    def test_stale_repo_directory_falls_back(self):
        (self.repo / '.agents/skills/gstack').mkdir(parents=True)
        self.assert_root(self.install(self.home / '.codex/skills/gstack'))

    def test_nonexecutable_native_helper_falls_back(self):
        self.install(self.home / '.codex/skills/gstack', executable=False)
        self.assert_root(self.install(self.home / '.claude/skills/gstack'))

    def test_missing_helper_degrades_without_shell_error_or_upgrade_prompt(self):
        output = self.run_bootstrap()
        self.assertTrue(output.startswith('SKILL_START: unavailable\n'), output)
        self.assertNotIn('SKILL_START_PROTO: 1', output)
        self.assertNotIn('/gstack-upgrade', output)

    def test_failed_helper_keeps_degraded_status(self):
        self.install(self.home / '.codex/skills/gstack', succeeds=False)
        self.assertTrue(self.run_bootstrap().startswith('SKILL_START: unavailable\n'))

    def test_codex_catalog_uses_compact_description(self):
        frontmatter = CONTENT.split('---', 2)[1]
        description = re.search(r'^description: (.+)$', frontmatter, re.M)
        self.assertIsNotNone(description, 'Codex still has a multiline routing description')
        self.assertLess(len(description.group(1)), 180)
        self.assertIn('Systematic debugging', description.group(1))
        self.assertIn('## When to invoke', CONTENT)


if __name__ == '__main__':
    unittest.main()
