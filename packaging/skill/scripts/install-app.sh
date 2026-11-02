#!/bin/zsh
set -euo pipefail
skill_root="${0:A:h:h}"
role=""
destination="$HOME/Applications"
dry_run=false
while (( $# )); do
    case "$1" in
        --role) role="${2:?missing role}"; shift 2 ;;
        --destination) destination="${2:?missing directory}"; shift 2 ;;
        --dry-run) dry_run=true; shift ;;
        *) print -u2 'Usage: install-app.sh --role sender|receiver [--destination directory] [--dry-run]'; exit 2 ;;
    esac
done
case "$role" in
    sender) app_name='远控听写'; identifier='org.remotedictation.bridge' ;;
    receiver) app_name='远控直输接收端'; identifier='org.remotedictation.bridge.Receiver' ;;
    *) print -u2 'Choose --role sender or --role receiver'; exit 2 ;;
esac
source_app="$skill_root/assets/apps/$app_name.app"
target_app="$destination/$app_name.app"
[[ -d "$source_app" ]] || { print -u2 'Bundled application is missing'; exit 1; }
codesign --verify --deep --strict "$source_app"
actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")
[[ "$actual" == "$identifier" ]] || { print -u2 'Unexpected application identity'; exit 1; }
if [[ -e "$target_app" ]]; then
    existing=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target_app/Contents/Info.plist")
    [[ "$existing" == "$identifier" ]] || { print -u2 'A different application already uses this name. Choose a different destination.'; exit 1; }
    if pgrep -f "$target_app/Contents/MacOS/DoubaoVoiceBridge" >/dev/null; then
        print -u2 'Quit the existing application before updating.'
        exit 1
    fi
fi
if $dry_run; then
    print "Verified installation plan: $source_app -> $target_app"
    exit 0
fi
mkdir -p "$destination"
if [[ -e "$target_app" ]]; then
    backup_dir=$(mktemp -d "$HOME/.Trash/remote-dictation-backup.XXXXXX")
    mv "$target_app" "$backup_dir/$app_name.app"
fi
ditto "$source_app" "$target_app"
codesign --verify --deep --strict "$target_app"
print "Installed: $target_app"
print 'Open the app, then configure your own port and new pairing code.'
