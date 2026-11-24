#!/bin/zsh
set -euo pipefail

if [[ $# -ne 2 ]]; then
    print -u2 "Usage: $0 <source.app> <destination.app>"
    exit 64
fi

source_app="$1"
destination_app="$2"
[[ "$source_app" == *.app && "$destination_app" == /*.app && -d "$source_app" ]] || {
    print -u2 "Invalid app bundle paths: $source_app -> $destination_app"
    exit 1
}
if [[ -L "$destination_app" || ( -e "$destination_app" && ! -d "$destination_app" ) ]]; then
    print -u2 "Cannot replace a non-bundle destination: $destination_app"
    exit 1
fi

staging_root="$(/usr/bin/mktemp -d "${destination_app:h}/.pdd-app-replacement.XXXXXX")"
trap '/bin/rm -rf -- "$staging_root"' EXIT
staged_app="$staging_root/${destination_app:t}"
/usr/bin/ditto --rsrc --extattr "$source_app" "$staged_app"
/usr/bin/codesign --verify --deep --strict "$staged_app"

# Both paths are on the destination volume. Swap the directories atomically
# on upgrades so the previous app remains intact until the new app is ready.
/usr/bin/osascript -l JavaScript - "$staged_app" "$destination_app" <<'JXA'
ObjC.bindFunction('renamex_np', ['int', ['char *', 'char *', 'unsigned int']])

function run([staged, destination]) {
    const files = $.NSFileManager.defaultManager
    const flags = files.fileExistsAtPath(destination) ? 0x02 : 0x04 // RENAME_SWAP, RENAME_EXCL
    if ($.renamex_np(staged, destination, flags) !== 0) {
        throw new Error('Could not replace the app bundle at ' + destination)
    }
}
JXA
