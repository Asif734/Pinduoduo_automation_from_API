#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h:h}"
MANUAL="$ROOT/Packaging/00-把这个文件交给Codex/完整接管、安装、配置与Debug手册.md"
INSTALLER="$ROOT/scripts/installer/PDDInstaller.applescript"
BUILD="$ROOT/scripts/build_delivery_package.sh"
MAINTENANCE_INSTALLER="$ROOT/Packaging/自动维护/安装每日自动清理.command"

test -s "$MANUAL"
test -s "$INSTALLER"
test -x "$BUILD"
test -x "$MAINTENANCE_INSTALLER"

for phrase in \
  "辅助功能" \
  "屏幕录制" \
  "语音识别" \
  "客服 ID" \
  "兼容性检查" \
  "30 天" \
  "10 GB" \
  "8 GB" \
  "禁止导出客户消息" \
  "Codex"; do
  grep -Fq "$phrase" "$MANUAL"
done

grep -Fq '02-正式程序/pinduodou_automation.app' "$INSTALLER"
grep -Fq '05-完整源码/scripts/replace_app_bundle.sh' "$INSTALLER"
grep -Fq '/Applications' "$INSTALLER"
grep -Fq '完整源码' "$BUILD"
grep -Fq 'SHA-256' "$BUILD"
grep -Fq 'Library/Application Support/PDDAutoReplyMaintenance' "$MAINTENANCE_INSTALLER"

print "同事交付合同测试通过"

test_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pdd-bundle-replacement-test.XXXXXX")"
trap '/bin/rm -rf -- "$test_root"' EXIT
source_app="$test_root/Source.app"
installed_app="$test_root/客服 Test.app"
replace_app="$ROOT/scripts/replace_app_bundle.sh"
mkdir -p "$source_app/Contents/MacOS" "$source_app/Contents/Resources"
cp /usr/bin/true "$source_app/Contents/MacOS/PDDAutoReply"
cp "$ROOT/Resources/AutoReplyInfo.plist" "$source_app/Contents/Info.plist"
touch "$source_app/Contents/Resources/obsolete"
/usr/bin/codesign --force --sign - "$source_app"
/bin/zsh "$replace_app" "$source_app" "$installed_app"
test -f "$installed_app/Contents/Resources/obsolete"

rm "$source_app/Contents/Resources/obsolete"
if /bin/zsh "$replace_app" "$source_app" "$installed_app" 2>/dev/null; then
    print -u2 "A bundle with an invalid signature replaced the installed app."
    exit 1
fi
/usr/bin/codesign --verify --deep --strict "$installed_app"
test -f "$installed_app/Contents/Resources/obsolete"

/usr/bin/codesign --force --sign - "$source_app"
/bin/zsh "$replace_app" "$source_app" "$installed_app"
/usr/bin/codesign --verify --deep --strict "$installed_app"
test ! -e "$installed_app/Contents/Resources/obsolete"
test -z "$(find "$test_root" -maxdepth 1 -name '.pdd-app-replacement.*' -print)"
print "App bundle replacement test passed."
