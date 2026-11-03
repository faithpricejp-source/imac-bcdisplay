#!/bin/bash
# Run on the old iMac (receiver) after copying build/BCDReceiver.app and launchd/ next to this script's parent.
set -euo pipefail
cd "$(dirname "$0")/.."
U=$(id -u); L=dev.bcdisplay.receiver; P=~/Library/LaunchAgents/$L.plist
launchctl disable gui/$U/$L 2>/dev/null || true
launchctl bootout gui/$U/$L 2>/dev/null || true
pkill -x bcd-receiver || true; sleep 1
mkdir -p ~/Applications ~/Library/LaunchAgents ~/Library/Logs/bcdisplay
ditto build/BCDReceiver.app ~/Applications/BCDReceiver.app
sed "s|__HOME__|$HOME|g" launchd/receiver.plist.template > "$P"
launchctl enable gui/$U/$L
launchctl bootstrap gui/$U "$P"
echo "installed; log: ~/Library/Logs/bcdisplay/receiver.log"
