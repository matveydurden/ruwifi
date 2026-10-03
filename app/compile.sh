#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/cache
: > .build/empty.modulemap
python3 - <<'PY'
import json,pathlib
root=pathlib.Path.cwd()
(root/'.build/overlay.json').write_text(json.dumps({'version':0,'roots':[{'type':'file','name':'/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap','external-contents':str(root/'.build/empty.modulemap')}]}))
PY
exec swiftc -vfsoverlay .build/overlay.json -Xcc -ivfsoverlay -Xcc .build/overlay.json -module-cache-path .build/cache "$@"
