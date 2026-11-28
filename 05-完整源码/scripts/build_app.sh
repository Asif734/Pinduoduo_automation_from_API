#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
APP_PATH="$PROJECT_ROOT/outputs/拼多多AX读取器.app"
PROBE_APP_PATH="$PROJECT_ROOT/outputs/拼多多AX单次解析测试器.app"
AUTO_REPLY_APP_PATH="$PROJECT_ROOT/outputs/拼多多全自动客服.app"
AUTO_REPLY_INFO="$PROJECT_ROOT/Resources/AutoReplyInfo.plist"
CANDIDATE_APP_PATH="$PROJECT_ROOT/outputs/pinduodou_automation.app"
INSTALLED_APP_PATH="/Applications/${AUTO_REPLY_APP_PATH:t}"
SIGNING_IDENTITY="$($PROJECT_ROOT/scripts/select_codesign_identity.sh)"
PYTHON_RUNTIME_NAME="cpython-3.12.14+20260825-aarch64-apple-darwin-install_only_stripped.tar.gz"
PYTHON_RUNTIME_SHA256="8b0f1fa71eab7ca644e482c631807a1116fa848491051cd1c8d9429491de63a6"
PYTHON_RUNTIME_ROOT="$PROJECT_ROOT/Resources/ThirdParty/PythonRuntime"
SWIFT_SCRATCH_PATH="${PDD_SWIFT_SCRATCH_PATH:-/private/tmp/pdd-auto-reply-app-build}"
SWIFT_BUILD_ARGS=(--scratch-path "$SWIFT_SCRATCH_PATH")
SWIFT_UI_PLUGIN_ROOT="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
if [[ -f "$SWIFT_UI_PLUGIN_ROOT/libSwiftUIMacros.dylib" ]]; then
    SWIFT_BUILD_ARGS+=(--build-system native -Xswiftc -plugin-path -Xswiftc "$SWIFT_UI_PLUGIN_ROOT")
fi

sign_and_verify() {
    local app_path="$1"
    codesign --force --deep --options runtime --timestamp=none --sign "$SIGNING_IDENTITY" "$app_path"
    codesign --verify --deep --strict "$app_path"
    while IFS= read -r executable; do
        /usr/bin/file "$executable" | /usr/bin/grep -q 'Mach-O' || continue
        /usr/bin/lipo -archs "$executable" | /usr/bin/grep -qw arm64 || {
            print -u2 "原生依赖缺少 arm64：$executable"
            exit 1
        }
    done < <(/usr/bin/find "$app_path" -type f -perm -111)
}

copy_auto_reply_resources() {
    local destination_app="$1"
    ditto "$PROJECT_ROOT/Resources/FolderKnowledge" "$destination_app/Contents/Resources/FolderKnowledge"
    for optional_resource in WebOCR SenseVoice; do
        if [[ -d "$PROJECT_ROOT/Resources/$optional_resource" ]]; then
            ditto "$PROJECT_ROOT/Resources/$optional_resource" "$destination_app/Contents/Resources/$optional_resource"
        else
            print "$optional_resource not bundled; using native macOS fallback."
        fi
    done
    for resource in CustomerService V2Knowledge KnowledgeBase; do
        if [[ "$resource" != "CustomerService" && -f "$PROJECT_ROOT/Resources/FolderKnowledge/config.json" ]]; then
            continue
        fi
        local source_path="$PROJECT_ROOT/Resources/$resource"
        local destination_path="$destination_app/Contents/Resources/$resource"
        case "$destination_path" in
            "$destination_app"/Contents/Resources/*) ;;
            *) print -u2 "拒绝复制到意外资源路径：$destination_path"; exit 1 ;;
        esac
        test -e "$source_path" || { print -u2 "缺少自动客服资源：$source_path"; exit 1; }
        ditto "$source_path" "$destination_path"
    done
    "$PROJECT_ROOT/scripts/stage_python_runtime.sh" \
        "$PYTHON_RUNTIME_ROOT/$PYTHON_RUNTIME_NAME" \
        "$PYTHON_RUNTIME_SHA256" \
        "$destination_app/Contents/Resources/PythonRuntime"
    mkdir -p "$destination_app/Contents/Resources/ThirdPartyNotices"
    cp "$PYTHON_RUNTIME_ROOT/NOTICE.md" \
        "$destination_app/Contents/Resources/ThirdPartyNotices/PythonRuntime.md"
    if [[ -f "$PROJECT_ROOT/Resources/SenseVoice/NOTICE.md" ]]; then
        cp "$PROJECT_ROOT/Resources/SenseVoice/NOTICE.md" \
            "$destination_app/Contents/Resources/ThirdPartyNotices/SenseVoice.md"
    fi
}

case "$#:${1:-}" in
    0:|1:--install|1:--task-isolation-candidate) ;;
    *) print -u2 "用法：$0 [--install|--task-isolation-candidate]"; exit 64 ;;
esac

mkdir -p "$PROJECT_ROOT/outputs"
zmodload zsh/system
touch "$PROJECT_ROOT/outputs/.pdd-build.lock"
zsystem flock "$PROJECT_ROOT/outputs/.pdd-build.lock"
APP_STAGING_ROOT="$(/usr/bin/mktemp -d "$PROJECT_ROOT/outputs/.pdd-app-build.XXXXXX")"
trap '/bin/rm -rf -- "$APP_STAGING_ROOT"' EXIT

if [[ "${1:-}" == "--task-isolation-candidate" ]]; then
    case "$CANDIDATE_APP_PATH" in
        "$PROJECT_ROOT"/outputs/*.app) ;;
        *) print -u2 "拒绝替换意外路径：$CANDIDATE_APP_PATH"; exit 1 ;;
    esac
    cd "$PROJECT_ROOT"
    swift build "${SWIFT_BUILD_ARGS[@]}" -c release --product PDDAXReader
    BIN_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" -c release --show-bin-path)"
    staged_candidate="$APP_STAGING_ROOT/${CANDIDATE_APP_PATH:t}"
    mkdir -p "$staged_candidate/Contents/MacOS" "$staged_candidate/Contents/Resources"
    cp "$BIN_DIR/PDDAXReader" "$staged_candidate/Contents/MacOS/PDDTaskIsolationCandidate"
    cp "$PROJECT_ROOT/Resources/TaskIsolationCandidateInfo.plist" "$staged_candidate/Contents/Info.plist"
    cp "$PROJECT_ROOT/Resources/AppIcon/PDDLatest.icns" \
        "$staged_candidate/Contents/Resources/PDDLatest.icns"
    copy_auto_reply_resources "$staged_candidate"
    cmp "$PROJECT_ROOT/Resources/FolderKnowledge/serve_folder.py" \
        "$staged_candidate/Contents/Resources/FolderKnowledge/serve_folder.py"
    chmod 755 "$staged_candidate/Contents/MacOS/PDDTaskIsolationCandidate"
    sign_and_verify "$staged_candidate"
    /bin/zsh "$SCRIPT_DIR/replace_app_bundle.sh" "$staged_candidate" "$CANDIDATE_APP_PATH"
    print "$CANDIDATE_APP_PATH"
    exit 0
fi

case "$APP_PATH" in
    "$PROJECT_ROOT"/outputs/*.app) ;;
    *) print -u2 "拒绝清理意外路径：$APP_PATH"; exit 1 ;;
esac
case "$PROBE_APP_PATH" in
    "$PROJECT_ROOT"/outputs/*.app) ;;
    *) print -u2 "拒绝清理意外路径：$PROBE_APP_PATH"; exit 1 ;;
esac
case "$AUTO_REPLY_APP_PATH" in
    "$PROJECT_ROOT"/outputs/*.app) ;;
    *) print -u2 "拒绝清理意外路径：$AUTO_REPLY_APP_PATH"; exit 1 ;;
esac

cd "$PROJECT_ROOT"
swift build "${SWIFT_BUILD_ARGS[@]}" -c release --product PDDAXReader
BIN_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" -c release --show-bin-path)"

rm -rf -- "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_DIR/PDDAXReader" "$APP_PATH/Contents/MacOS/PDDAXReader"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
if [[ -d "$PROJECT_ROOT/Resources/WebOCR" ]]; then
    ditto "$PROJECT_ROOT/Resources/WebOCR" "$APP_PATH/Contents/Resources/WebOCR"
fi
ditto "$PROJECT_ROOT/Resources/FolderKnowledge" "$APP_PATH/Contents/Resources/FolderKnowledge"
ditto "$PROJECT_ROOT/Resources/CustomerService" "$APP_PATH/Contents/Resources/CustomerService"
chmod 755 "$APP_PATH/Contents/MacOS/PDDAXReader"

sign_and_verify "$APP_PATH"

rm -rf -- "$PROBE_APP_PATH"
mkdir -p "$PROBE_APP_PATH/Contents/MacOS" "$PROBE_APP_PATH/Contents/Resources"
cp "$BIN_DIR/PDDAXReader" "$PROBE_APP_PATH/Contents/MacOS/PDDAXSingleParseProbe"
cp "$PROJECT_ROOT/Resources/SingleParseInfo.plist" "$PROBE_APP_PATH/Contents/Info.plist"
if [[ -d "$PROJECT_ROOT/Resources/WebOCR" ]]; then
    ditto "$PROJECT_ROOT/Resources/WebOCR" "$PROBE_APP_PATH/Contents/Resources/WebOCR"
fi
chmod 755 "$PROBE_APP_PATH/Contents/MacOS/PDDAXSingleParseProbe"
sign_and_verify "$PROBE_APP_PATH"

staged_app="$APP_STAGING_ROOT/${AUTO_REPLY_APP_PATH:t}"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$BIN_DIR/PDDAXReader" "$staged_app/Contents/MacOS/PDDAutoReply"
staged_info="$staged_app/Contents/Info.plist"
cp -p "$AUTO_REPLY_INFO" "$staged_info"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$staged_info")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$staged_info")"
[[ "$version" == <->.<-> && "$build" == <-> ]] || {
    print -u2 "Expected a major.minor version and numeric build in $AUTO_REPLY_INFO"
    exit 1
}
next_version="${version%.*}.$(( ${version##*.} + 1 ))"
next_build="$(( build + 1 ))"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $next_version" \
    -c "Set :CFBundleVersion $next_build" "$staged_info"
copy_auto_reply_resources "$staged_app"
cmp "$PROJECT_ROOT/Resources/CustomerService/customer-reply-prompt.md" \
    "$staged_app/Contents/Resources/CustomerService/customer-reply-prompt.md"
if [[ -f "$PROJECT_ROOT/Resources/FolderKnowledge/config.json" ]]; then
    cmp "$PROJECT_ROOT/Resources/FolderKnowledge/serve_folder.py" \
        "$staged_app/Contents/Resources/FolderKnowledge/serve_folder.py"
else
    cmp "$PROJECT_ROOT/Resources/V2Knowledge/retrieve_top12.py" \
        "$staged_app/Contents/Resources/V2Knowledge/retrieve_top12.py"
    cmp "$PROJECT_ROOT/Resources/V2Knowledge/serve_top12.py" \
        "$staged_app/Contents/Resources/V2Knowledge/serve_top12.py"
    cmp "$PROJECT_ROOT/Resources/KnowledgeBase/Grozziie-China-KB-2026-08-24.zip" \
        "$staged_app/Contents/Resources/KnowledgeBase/Grozziie-China-KB-2026-08-24.zip"
fi
chmod 755 "$staged_app/Contents/MacOS/PDDAutoReply"
sign_and_verify "$staged_app"
# Persist the number before publishing so a retry cannot reuse a published version.
cp -p "$staged_info" "$APP_STAGING_ROOT/AutoReplyInfo.plist"
mv -f "$APP_STAGING_ROOT/AutoReplyInfo.plist" "$AUTO_REPLY_INFO"
/bin/zsh "$SCRIPT_DIR/replace_app_bundle.sh" "$staged_app" "$AUTO_REPLY_APP_PATH"
print "Auto-reply version $next_version (build $next_build)"

if [[ "${1:-}" == "--install" ]]; then
    /bin/zsh "$SCRIPT_DIR/replace_app_bundle.sh" "$staged_app" "$INSTALLED_APP_PATH"
    print "$INSTALLED_APP_PATH"
fi

print "$APP_PATH"
print "$PROBE_APP_PATH"
print "$AUTO_REPLY_APP_PATH"
