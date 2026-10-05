"""Installer failure paths must stop before any privileged/user setup."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class InstallerTests(unittest.TestCase):
    def run_installer(self, fake_curl):
        with tempfile.TemporaryDirectory(prefix='ruwifi-installer-test-') as folder:
            curl = Path(folder) / 'curl'
            curl.write_text('#!/bin/bash\nset -eu\n' + fake_curl)
            curl.chmod(0o755)
            gh = Path(folder) / 'gh'
            gh.write_text('#!/bin/bash\necho "GitHub authentication must not be required" >&2\nexit 77\n')
            gh.chmod(0o755)
            env = dict(os.environ, PATH=folder + ':' + os.environ['PATH'])
            return subprocess.run(['/bin/bash', str(ROOT / 'install.sh'), '--check'],
                                  env=env, text=True, capture_output=True, timeout=30)

    def test_download_failure(self):
        result = self.run_installer('exit 42\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Не удалось скачать', result.stderr)

    def test_corrupt_archive(self):
        result = self.run_installer('''
[[ "$*" = *"https://github.com/matveydurden/ruwifi/releases/download/v1.0.2/ruwifi-macos-arm64.zip"* ]] || exit 43
while [ "$#" -gt 0 ]; do
    if [ "$1" = --output ]; then printf 'corrupt' > "$2"; exit 0; fi
    shift
done
exit 1
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Контрольная сумма', result.stderr)
        self.assertNotIn('Установлено', result.stdout)

if __name__ == '__main__':
    unittest.main()
