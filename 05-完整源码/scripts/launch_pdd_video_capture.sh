#!/bin/zsh
set -euo pipefail

app="/Applications/拼多多商家版.app"
executable="$app/Contents/MacOS/拼多多商家版"
log_dir="$HOME/Library/Application Support/PDDAutoReplyShared/video-network"
log_file="$log_dir/netlog.json"

if [[ ! -x "$executable" ]]; then
    print -u2 "Pinduoduo Merchant is missing from /Applications."
    exit 1
fi
if /usr/bin/pgrep -f '^/Applications/拼多多商家版\.app/Contents/MacOS/拼多多商家版( |$)' >/dev/null; then
    print -u2 "Quit Pinduoduo Merchant first, then run this launcher again."
    exit 1
fi

umask 077
mkdir -p "$log_dir"
if [[ -L "$log_dir" || -L "$log_file" || ( -e "$log_file" && ! -f "$log_file" ) ]]; then
    print -u2 "The network log path is not a regular private location."
    exit 1
fi
chmod 700 "$log_dir"
if [[ -e "$log_file" ]]; then
    chmod 600 "$log_file"
fi
: > "$log_file"
/usr/bin/open -a "$app" --args --force-renderer-accessibility "--log-net-log=$log_file" --net-log-capture-mode=Default
print "Pinduoduo is starting with video network capture. Quit Pinduoduo to stop logging."
