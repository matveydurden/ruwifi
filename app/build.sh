#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
./compile.sh Core.swift CoreTests.swift -o .build/core-tests
.build/core-tests .build/config-test.json
./compile.sh Core.swift Storage.swift StorageTests.swift -o .build/storage-tests
.build/storage-tests
./compile.sh Core.swift Storage.swift System.swift InstallTests.swift -o .build/install-tests
.build/install-tests
./compile.sh Core.swift Storage.swift System.swift RoutingHealthTests.swift -o .build/health-tests
.build/health-tests
./compile.sh Core.swift Storage.swift InterfaceRuntime.swift InterfaceRuntimeTests.swift -o .build/interface-tests
.build/interface-tests
./build-engine.sh
engine="$PWD/.build/sing-box"
"$engine" check -c .build/config-test.json
python3 integration_test.py "$engine"
./compile.sh Core.swift Storage.swift System.swift Service.swift -o .build/RUWiFiHelper
./compile.sh Core.swift Storage.swift System.swift InterfaceRuntime.swift App.swift -o .build/RUWiFi
app='../dist/RU напрямую.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
cp .build/RUWiFi "$app/Contents/MacOS/RUWiFi"
cp .build/RUWiFiHelper "$app/Contents/Helpers/RUWiFiHelper"
cp "$engine" "$app/Contents/Helpers/sing-box"
cp ../vendor/sing-box/LICENSE "$app/Contents/Resources/LICENSE.sing-box"
cp ../LICENSE "$app/Contents/Resources/LICENSE"
cp ../COPYING "$app/Contents/Resources/COPYING"
codesign --force --sign - "$app/Contents/Helpers/sing-box"
codesign --force --sign - "$app/Contents/Helpers/RUWiFiHelper"
python3 - <<'PY'
import hashlib,json,pathlib
root=pathlib.Path('../dist/RU напрямую.app/Contents')
manifest={key:hashlib.sha256((root/'Helpers'/name).read_bytes()).hexdigest() for key,name in [('helper','RUWiFiHelper'),('engine','sing-box')]}
(root/'Resources/manifest.json').write_text(json.dumps(manifest))
PY
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo 'Built and verified RU напрямую.app'
