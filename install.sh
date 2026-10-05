#!/bin/bash
# Download the public, pinned release; never install as root from a pipe.
set -euo pipefail
export LC_ALL=C LANG=C
REPOSITORY='matveydurden/ruwifi'
VERSION='v1.0.3'
ARCHIVE='ruwifi-macos-arm64.zip'
SHA256='8f64a59897a2baa26af90b519c95af4bede807030cc3f8471be7342975efe0d7'

fail() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
check_only=false
case "${1:-}" in
    '') ;;
    --check) check_only=true ;;
    -h|--help) printf '%s\n' 'RUWiFi: ./install.sh [--check]' 'Без аргументов — установка; --check — только скачать и проверить.'; exit 0 ;;
    *) fail 'Неизвестный аргумент. Используйте --check или запускайте без аргументов.' ;;
esac
[ "$#" -le 1 ] || fail 'Слишком много аргументов.'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'Нужна macOS 15 или новее.'
[ "$(/usr/bin/uname -m)" = arm64 ] || fail 'Эта сборка рассчитана на Apple Silicon. Откройте Terminal без Rosetta.'
os_version="$(/usr/bin/sw_vers -productVersion)"
[ "${os_version%%.*}" -ge 15 ] || fail 'Нужна macOS 15 или новее.'
user_id="$(/usr/bin/id -u)"
[ "$user_id" -ge 501 ] || fail 'Запустите установщик обычным пользователем, без sudo.'
command -v curl >/dev/null 2>&1 || fail 'Не найден curl, входящий в состав macOS.'

# The root helper must read from outside privacy-protected Documents/Downloads.
cache="$HOME/Library/Caches"
[ -d "$cache" ] && [ ! -L "$cache" ] || fail 'Недоступен пользовательский Library/Caches.'
staging="$(/usr/bin/mktemp -d "$cache/RUWiFi-install.XXXXXX")"
trap '/bin/rm -rf "$staging"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'Скачиваю RUWiFi %s…\n' "$VERSION"
curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 20 --max-time 300 \
    "https://github.com/$REPOSITORY/releases/download/$VERSION/$ARCHIVE" --output "$staging/$ARCHIVE" || fail 'Не удалось скачать релиз. Проверьте подключение к GitHub и повторите команду.'
actual="$(/usr/bin/shasum -a 256 "$staging/$ARCHIVE")"
[ "${actual%% *}" = "$SHA256" ] || fail 'Контрольная сумма архива не совпала. Установка остановлена.'
/usr/bin/ditto -x -k "$staging/$ARCHIVE" "$staging/unpacked"
bundle="$staging/unpacked/RU напрямую.app"
[ -d "$bundle" ] && [ ! -L "$bundle" ] || fail 'В архиве нет приложения.'
/usr/bin/codesign --verify --deep --strict "$bundle" || fail 'Проверка подписи приложения не прошла.'
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")"
[ "$identifier" = local.matvey.RUWiFi ] || fail 'Неверный идентификатор приложения.'
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")"
[ "v$version" = "$VERSION" ] || fail 'Версия приложения не совпала с релизом.'
if "$check_only"; then
    printf 'Проверено: %s, SHA256 и подпись. Установка и изменение сети не выполнялись.\n' "$VERSION"
    exit 0
fi
"$bundle/Contents/MacOS/RUWiFi" --prepare-install
printf '%s\n' 'Откроется системное окно macOS для подтверждения установки службы.'
if ! /usr/bin/osascript - "$bundle/Contents/Helpers/RUWiFiHelper" "$user_id" <<'APPLESCRIPT'
on run argv
    set helperPath to item 1 of argv
    set userId to item 2 of argv
    set commandLine to quoted form of helperPath & " --install " & quoted form of userId
    do shell script commandLine with administrator privileges
end run
APPLESCRIPT
then
    fail 'Установка службы отменена или не выполнена. Повторите команду и подтвердите запрос macOS.'
fi
"$bundle/Contents/MacOS/RUWiFi" --finish-install
/usr/bin/open '/Applications/RU напрямую.app'
printf '%s\n' 'Установлено. Автозапуск настроен; прежнее состояние Вкл/Выкл сохранено.' 'После первой установки один раз полностью перезапустите Chrome.'
