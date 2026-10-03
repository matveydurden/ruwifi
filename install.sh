#!/bin/bash
# Download the private, pinned release; never install as root from a pipe.
set -euo pipefail
export LC_ALL=C LANG=C
REPOSITORY='matveydurden/ruwifi'
VERSION='v1.0.1'
ARCHIVE='ruwifi-macos-arm64.zip'
SHA256='658acd3bfd3b832f2a65989e543003c33cb77400e441edec5b0a20c7105f8313'

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
command -v gh >/dev/null 2>&1 || fail 'Установите GitHub CLI: brew install gh; затем gh auth login.'
gh auth status --hostname github.com >/dev/null 2>&1 || fail 'Войдите в GitHub: gh auth login --hostname github.com'

# The root helper must read from outside privacy-protected Documents/Downloads.
cache="$HOME/Library/Caches"
[ -d "$cache" ] && [ ! -L "$cache" ] || fail 'Недоступен пользовательский Library/Caches.'
staging="$(/usr/bin/mktemp -d "$cache/RUWiFi-install.XXXXXX")"
trap '/bin/rm -rf "$staging"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'Скачиваю RUWiFi %s из приватного репозитория…\n' "$VERSION"
gh release download "$VERSION" --repo "$REPOSITORY" --pattern "$ARCHIVE" --output "$staging/$ARCHIVE" || fail 'Не удалось скачать релиз. Проверьте сеть и доступ к приватному репозиторию.'
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
[ -r /dev/tty ] && [ -w /dev/tty ] || fail 'Запустите команду в обычном Terminal: нужен ввод пароля администратора.'
"$bundle/Contents/MacOS/RUWiFi" --prepare-install
printf '%s\n' 'Введите пароль администратора Mac, если sudo его запросит (символы не отображаются).'
/usr/bin/sudo "$bundle/Contents/Helpers/RUWiFiHelper" --install "$user_id" </dev/tty || fail 'Служба не установлена. Подробности ошибки приведены выше.'
"$bundle/Contents/MacOS/RUWiFi" --finish-install
/usr/bin/open '/Applications/RU напрямую.app'
printf '%s\n' 'Установлено. Автозапуск настроен; прежнее состояние Вкл/Выкл сохранено.' 'После первой установки один раз полностью перезапустите Chrome.'
