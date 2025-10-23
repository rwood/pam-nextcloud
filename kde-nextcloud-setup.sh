#!/bin/bash
#
# KDE Nextcloud Auto-Setup Script
#
# This script runs at KDE Plasma session startup to complete Nextcloud
# integration setup if a setup marker exists.
#
# Install: Copy to ~/.config/autostart-scripts/kde-nextcloud-setup.sh
#

MARKER_FILE="$HOME/.local/share/kaccounts/.nextcloud-setup"

# Check if marker exists
if [ ! -f "$MARKER_FILE" ]; then
    exit 0
fi

# Read marker data
SERVER=$(jq -r '.server' "$MARKER_FILE" 2>/dev/null)
USERNAME=$(jq -r '.username' "$MARKER_FILE" 2>/dev/null)

if [ -z "$SERVER" ] || [ -z "$USERNAME" ]; then
    exit 0
fi

# Notify user to complete setup
kdialog --title "Nextcloud Setup" \
    --passivepopup "Please complete your Nextcloud setup in System Settings > Online Accounts\n\nServer: $SERVER\nUsername: $USERNAME" 10 \
    2>/dev/null || \
notify-send "Nextcloud Setup" \
    "Please complete your Nextcloud setup in System Settings > Online Accounts" \
    --icon=nextcloud \
    --app-name="Nextcloud Integration"

# Remove marker after notifying
rm -f "$MARKER_FILE"

