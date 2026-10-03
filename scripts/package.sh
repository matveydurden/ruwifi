#!/bin/bash
set -euo pipefail
export LC_ALL=C LANG=C
cd "$(dirname "$0")/.."
./app/build.sh
/usr/bin/ditto -c -k --sequesterRsrc --keepParent 'dist/RU напрямую.app' dist/ruwifi-macos-arm64.zip
python3 - <<'PY'
import hashlib, pathlib, re
root = pathlib.Path.cwd()
archive = root / 'dist/ruwifi-macos-arm64.zip'
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
installer = root / 'install.sh'
text, count = re.subn(r"^SHA256='[^']*'$", "SHA256='" + digest + "'", installer.read_text(), flags=re.M)
assert count == 1
installer.write_text(text)
(root / 'dist/SHA256SUMS').write_text(digest + '  ' + archive.name + '\n')
print('Packaged release with SHA256:', digest)
PY
