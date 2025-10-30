#!/bin/bash
# Configure GDM to show user list on login screen

set -e

echo "======================================================================"
echo "GDM User List Configuration"
echo "======================================================================"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "❌ ERROR: This script must be run as root (use sudo)"
    exit 1
fi

# Check if dconf is available
if ! command -v dconf &> /dev/null; then
    echo "⚠️  WARNING: dconf not found. GDM configuration may not be available."
    echo "   This is normal on some systems where GDM uses different configuration."
    exit 0
fi

# Check if gdm directory exists
GDM_DB_DIR="/etc/dconf/db/gdm.d"
GDM_LOCK_DIR="/etc/dconf/db/gdm.d/locks"

echo "📁 Configuring GDM to show user list..."
echo ""

# Create directories if they don't exist
mkdir -p "$GDM_DB_DIR"
mkdir -p "$GDM_LOCK_DIR"

# Create configuration file
CONFIG_FILE="$GDM_DB_DIR/00-show-user-list"
echo "[org/gnome/login-screen]" > "$CONFIG_FILE"
echo "disable-user-list=false" >> "$CONFIG_FILE"

# Create lock file to prevent user override
LOCK_FILE="$GDM_LOCK_DIR/00-show-user-list"
echo "/org/gnome/login-screen/disable-user-list" > "$LOCK_FILE"

echo "✅ Created GDM configuration file: $CONFIG_FILE"
echo "✅ Created GDM lock file: $LOCK_FILE"
echo ""

# Update dconf database
echo "🔄 Updating dconf database..."
dconf update

if [ $? -eq 0 ]; then
    echo "✅ dconf database updated successfully"
else
    echo "⚠️  WARNING: dconf update failed (this may be normal on some systems)"
fi

echo ""
echo "======================================================================"
echo "Configuration Complete"
echo "======================================================================"
echo ""
echo "✅ GDM is now configured to show user list on login screen"
echo ""
echo "📝 Note: You may need to:"
echo "   1. Restart GDM: sudo systemctl restart gdm"
echo "   2. Or reboot the system"
echo ""
echo "⚠️  If users still don't appear:"
echo "   - Ensure AccountsService entries exist: /var/lib/AccountsService/users/"
echo "   - Check that users have valid shells: /bin/bash"
echo "   - Verify SystemAccount=false in AccountsService files"
echo ""

