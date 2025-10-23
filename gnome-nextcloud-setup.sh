#!/bin/bash
#
# GNOME Nextcloud Auto-Setup Script
#
# This script runs at GNOME session startup to complete Nextcloud
# integration setup if a setup marker exists.
#
# Install: Copy to /etc/xdg/autostart/gnome-nextcloud-setup.desktop
#

# Wait a bit for desktop to fully load
sleep 3

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
    
    # Read marker data (without requiring jq)
    if [ -f "$marker" ]; then
        SERVER=$(grep -oP '"server":\s*"\K[^"]+' "$marker" 2>/dev/null)
        USERNAME=$(grep -oP '"username":\s*"\K[^"]+' "$marker" 2>/dev/null)
    fi
    
    # Fallback values if parsing failed
    if [ -z "$SERVER" ]; then
        SERVER="your Nextcloud server"
    fi
    if [ -z "$USERNAME" ]; then
        USERNAME="your username"
    fi
    
    # Notify user to complete setup
    # Try multiple notification methods
    if command -v notify-send &> /dev/null; then
        notify-send "Nextcloud Setup Available" \
            "Server: $SERVER\nUser: $USERNAME\n\nComplete setup in Settings → Online Accounts" \
            --icon=cloud \
            --urgency=normal \
            --expire-time=30000
    elif command -v zenity &> /dev/null; then
        zenity --info \
            --title="Nextcloud Setup Available" \
            --text="Server: $SERVER\nUser: $USERNAME\n\nPlease complete your Nextcloud setup in Settings > Online Accounts" \
            --timeout=30 &
    fi
    
    # Remove marker after notifying
    rm -f "$marker"
    
    break
done

