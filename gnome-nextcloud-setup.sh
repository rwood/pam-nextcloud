#!/bin/bash
#
# GNOME Nextcloud Auto-Setup Script
#
# This script runs at GNOME session startup to complete Nextcloud
# integration setup if a setup marker exists.
#
# Install: Copy to /etc/xdg/autostart/gnome-nextcloud-setup.desktop
#

MARKER_DIR="$HOME/.config/goa-1.0"

# Check if marker files exist
if [ ! -d "$MARKER_DIR" ]; then
    exit 0
fi

# Look for setup marker
for marker in "$MARKER_DIR"/.nextcloud-setup-*; do
    if [ ! -f "$marker" ]; then
        continue
    fi
    
    # Read marker data
    SERVER=$(jq -r '.server' "$marker" 2>/dev/null)
    USERNAME=$(jq -r '.username' "$marker" 2>/dev/null)
    
    if [ -z "$SERVER" ] || [ -z "$USERNAME" ]; then
        continue
    fi
    
    # Notify user to complete setup
    notify-send "Nextcloud Setup" \
        "Please complete your Nextcloud setup in Settings > Online Accounts" \
        --icon=nextcloud \
        --app-name="Nextcloud Integration" \
        --urgency=normal
    
    # Open GNOME Settings to Online Accounts
    # User can click to complete the setup
    if command -v gnome-control-center &> /dev/null; then
        # Don't auto-open, just notify
        # gnome-control-center online-accounts &
        :
    fi
    
    # Remove marker after notifying
    rm -f "$marker"
    
    break
done

