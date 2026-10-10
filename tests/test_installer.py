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
[[ "$*" = *"https://github.com/matveydurden/ruwifi/releases/download/v1.0.7/ruwifi-macos-arm64.zip"* ]] || exit 43
while [ "$#" -gt 0 ]; do
    if [ "$1" = --output ]; then printf 'corrupt' > "$2"; exit 0; fi
    shift
done
exit 1
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Контрольная сумма', result.stderr)
        self.assertNotIn('Установлено', result.stdout)

    def test_install_uses_native_admin_dialog_without_terminal_sudo(self):
        installer = (ROOT / 'install.sh').read_text()
        self.assertNotIn('/usr/bin/sudo', installer)
        self.assertNotIn('administrator privileges', installer.split('if "$check_only"', 1)[0])
        self.assertIn('/usr/bin/osascript', installer)
        self.assertIn('osascript - "$bundle/Contents/Helpers/RUWiFiHelper" "$user_id"', installer)
        self.assertIn('with administrator privileges', installer)
        self.assertIn('quoted form of', installer)
        self.assertIn("fail 'Установка службы отменена", installer)

    def run_install_tail(self, authorization_result):
        """Run the real post-verification install tail with safe command stubs."""
        with tempfile.TemporaryDirectory(prefix='ruwifi-installer-tail-') as folder:
            root = Path(folder)
            bundle = root / 'RU напрямую.app'
            (bundle / 'Contents' / 'MacOS').mkdir(parents=True)
            (bundle / 'Contents' / 'Helpers').mkdir()
            log = root / 'events.log'
            for name, event in [('RUWiFi', 'ui'), ('RUWiFiHelper', 'helper')]:
                command = bundle / 'Contents' / ('MacOS' if name == 'RUWiFi' else 'Helpers') / name
                if name == 'RUWiFi':
                    command.write_text(
                        '#!/bin/bash\n'
                        'case "$1" in\n'
                        '  --prepare-install) event=prepare ;;\n'
                        '  --finish-install) event=finish ;;\n'
                        '  *) event=ui ;;\n'
                        'esac\n'
                        'printf "%s\\n" "$event $*" >> "' + str(log) + '"\n'
                    )
                else:
                    command.write_text('#!/bin/bash\nprintf "%s\\n" "' + event + ' $*" >> "' + str(log) + '"\n')
                command.chmod(0o755)
            osascript = root / 'osascript'
            osascript.write_text(
                '#!/bin/bash\n'
                'cat >/dev/null\n'
                'printf "%s\\n" "auth $*" >> "' + str(log) + '"\n'
                'exit "${OSASCRIPT_RESULT:-1}"\n'
            )
            osascript.chmod(0o755)
            opener = root / 'open'
            opener.write_text('#!/bin/bash\nprintf "%s\\n" "open $*" >> "' + str(log) + '"\n')
            opener.chmod(0o755)

            tail = (ROOT / 'install.sh').read_text().split('if "$check_only"; then', 1)[1]
            tail = tail.replace('/usr/bin/osascript', str(osascript))
            tail = tail.replace("/usr/bin/open", str(opener))
            harness = root / 'tail.sh'
            harness.write_text(
                '#!/bin/bash\nset -euo pipefail\n'
                'fail() { printf "Ошибка: %s\\n" "$*" >&2; exit 1; }\n'
                'check_only=false\n'
                'bundle="' + str(bundle) + '"\n'
                'user_id=501\n'
                + 'if "$check_only"; then' + tail
            )
            harness.chmod(0o755)
            return subprocess.run(
                ['/bin/bash', str(harness)],
                env=dict(os.environ, OSASCRIPT_RESULT=str(authorization_result)),
                text=True, capture_output=True, timeout=10,
            ), log.read_text().splitlines() if log.exists() else []

    def test_cancelled_admin_dialog_stops_before_finish_and_open(self):
        result, events = self.run_install_tail(1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(events), 2)
        self.assertEqual(events[0].split(' ', 1)[0], 'prepare')
        self.assertTrue(events[1].startswith('auth - '))
        self.assertFalse(any(event.startswith('open ') for event in events))
        self.assertNotIn('Установлено', result.stdout)
        self.assertIn('отменена', result.stderr)

    def test_accepted_admin_dialog_finishes_and_opens(self):
        result, events = self.run_install_tail(0)
        self.assertEqual(result.returncode, 0)
        self.assertEqual([event.split(' ', 1)[0] for event in events], ['prepare', 'auth', 'finish', 'open'])
        self.assertIn('Установлено', result.stdout)

if __name__ == '__main__':
    unittest.main()
