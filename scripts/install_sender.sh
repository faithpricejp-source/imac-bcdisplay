#!/bin/bash
# Run on the Apple Silicon Mac (sender). Installs ~/Applications/BCDSender.app and a LaunchAgent.
# After every rebuild the ad-hoc signature changes: re-add BCDSender under
# System Settings > Privacy & Security > Screen & System Audio Recording (use "+").
set -euo pipefail
cd "$(dirname "$0")/.."
U=$(id -u); L=dev.bcdisplay.sender; P=~/Library/LaunchAgents/$L.plist
launchctl disable gui/$U/$L 2>/dev/null || true
launchctl bootout gui/$U/$L 2>/dev/null || true
pkill -x bcd-sender || true; sleep 1
mkdir -p ~/Applications ~/Library/LaunchAgents ~/Library/Logs/bcdisplay
ditto build/BCDSender.app ~/Applications/BCDSender.app
sed "s|__HOME__|$HOME|g" launchd/sender.plist.template > "$P"
launchctl enable gui/$U/$L
launchctl bootstrap gui/$U "$P"
echo "installed; log: ~/Library/Logs/bcdisplay/sender.log"
