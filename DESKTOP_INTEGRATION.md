# Desktop Integration Guide

This guide explains how to set up automatic Nextcloud desktop integration with GNOME and KDE after PAM authentication.

## Overview

When enabled, the PAM module automatically configures:
- **GNOME Online Accounts (GOA)** for GNOME desktop
- **KDE Accounts** for KDE Plasma desktop
- **Nextcloud Desktop Client** server hints (all desktops)

This means users who authenticate via PAM will have their Nextcloud account pre-configured in their desktop environment, making it easy to:
- Sync files with Nextcloud Desktop Client
- Access Nextcloud calendar and contacts in desktop apps
- Integrate with desktop email clients
- Access Nextcloud from file managers

## How It Works

```
User Logs In via PAM
    ↓
PAM Authentication Succeeds
    ↓
PAM Session Opens
    ↓
Desktop Integration Script Runs
    ↓
Creates configuration markers
    ↓
User Desktop Session Starts
    ↓
Autostart scripts notify user
    ↓
User completes setup in desktop settings
```

## Configuration

### Step 1: Enable Desktop Integration

Edit `/etc/security/pam_nextcloud.conf`:

```ini
[nextcloud]
url = https://cloud.example.com
verify_ssl = true

# Enable desktop integration
enable_desktop_integration = true

# Optional: Force specific desktop type
# Leave blank for auto-detection
force_desktop_type =
```

### Step 2: Install Desktop Integration Script

The installation script handles this automatically, but if installing manually:

```bash
# Copy desktop integration script
sudo cp pam_nextcloud_desktop.py /lib/security/
sudo chmod 644 /lib/security/pam_nextcloud_desktop.py
sudo chown root:root /lib/security/pam_nextcloud_desktop.py
```

### Step 3: Configure PAM Session Hook

Edit your PAM configuration files (e.g., `/etc/pam.d/sshd`, `/etc/pam.d/common-session`) to include:

```
# Session management with Nextcloud integration
session optional pam_python.so /lib/security/pam_nextcloud.py
```

**Note**: Use `optional` not `required` to prevent login failures if integration fails.

### Step 4: Install Desktop Autostart Scripts (Optional)

For GNOME, create `/usr/share/applications/gnome-nextcloud-setup.desktop`:

```desktop
[Desktop Entry]
Type=Application
Name=Nextcloud Integration Setup
Exec=/usr/local/bin/gnome-nextcloud-setup.sh
Hidden=true
NoDisplay=true
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Phase=Initialization
```

For KDE, users can place `kde-nextcloud-setup.sh` in:
- `~/.config/autostart-scripts/` (per-user)
- `/etc/xdg/autostart/` (system-wide)

### Step 5: Test the Integration

```bash
# As root, run the desktop integration script manually
sudo PAM_USER=testuser /lib/security/pam_nextcloud_desktop.py testuser

# Check for marker files
sudo ls -la /home/testuser/.config/goa-1.0/.nextcloud-setup-*
sudo ls -la /home/testuser/.config/Nextcloud/sync-hint.json
```

## Desktop Environment Support

### GNOME (GNOME Online Accounts)

**What gets configured:**
- Server URL hint
- Username hint
- Marker file for user to complete setup

**User experience:**
1. User logs in
2. Notification appears: "Please complete your Nextcloud setup in Settings"
3. User opens Settings > Online Accounts
4. Adds Nextcloud account with pre-filled server URL
5. Enters password or app password
6. Integration complete!

**Features enabled:**
- Files integration (GNOME Files shows Nextcloud)
- Calendar integration (GNOME Calendar)
- Contacts integration (GNOME Contacts)
- Documents integration

**Testing:**
```bash
# Check GOA accounts
gsettings list-recursively org.gnome.online-accounts

# View GOA configuration
cat ~/.config/goa-1.0/accounts.conf
```

### KDE Plasma (KAccounts)

**What gets configured:**
- Server URL hint
- Username hint  
- Account type hint

**User experience:**
1. User logs in
2. Notification appears: "Please complete your Nextcloud setup in System Settings"
3. User opens System Settings > Online Accounts
4. Adds Nextcloud account
5. Enters credentials
6. Integration complete!

**Features enabled:**
- Purpose framework integration
- KIO integration (access via `nextcloud://`)
- Calendar integration (KOrganizer)
- Contacts integration (KAddressBook)

**Testing:**
```bash
# Check KAccounts
kaccounts-providers

# View accounts
ls ~/.local/share/kaccounts/
```

### Other Desktops / Nextcloud Desktop Client

For desktops without native Nextcloud integration, the module creates a hint file for the Nextcloud Desktop Client:

**File created:** `~/.config/Nextcloud/sync-hint.json`

**Content:**
```json
{
  "server": "https://cloud.example.com",
  "user": "username",
  "configured_via": "pam_nextcloud",
  "note": "This server was auto-detected from PAM authentication"
}
```

The Nextcloud Desktop Client can read this file to pre-fill the server URL during first-run setup.

## Security Considerations

### No Password Storage

**Important:** The desktop integration does **not** store or transmit passwords. It only:
- Creates configuration hints (server URL, username)
- Sets up marker files
- Users must still enter their password in desktop settings

### Why This is Secure

1. **No credentials in files**: Only server URL and username are stored
2. **User confirmation required**: Users must manually complete setup
3. **Standard desktop auth**: Uses normal GNOME/KDE authentication flow
4. **Supports app passwords**: Users can use Nextcloud app passwords

### Recommended: Use App Passwords

For better security, users should create app passwords in Nextcloud:

1. Log into Nextcloud web interface
2. Settings > Security > Devices & sessions
3. Create new app password
4. Use app password instead of main password in desktop integration

## Troubleshooting

### Desktop Integration Not Working

**Check if enabled:**
```bash
grep enable_desktop_integration /etc/security/pam_nextcloud.conf
```

**Check PAM configuration:**
```bash
grep pam_nextcloud /etc/pam.d/common-session
# or
grep pam_nextcloud /etc/pam.d/sshd
```

**Check script exists:**
```bash
ls -la /lib/security/pam_nextcloud_desktop.py
```

**Check logs:**
```bash
sudo grep "Desktop integration" /var/log/auth.log
```

### Desktop Environment Not Detected

Set `force_desktop_type` in config:

```ini
[nextcloud]
# For GNOME
force_desktop_type = gnome

# For KDE
force_desktop_type = kde
```

### Marker Files Not Created

**Check permissions:**
```bash
# User's home directory must be writable
ls -ld /home/username

# Desktop integration script must be executable
ls -la /lib/security/pam_nextcloud_desktop.py
```

**Run manually to see errors:**
```bash
sudo PAM_USER=username python3 /lib/security/pam_nextcloud_desktop.py username
```

### User Not Getting Notifications

**GNOME:**
- Ensure `notify-send` is installed: `sudo apt install libnotify-bin`
- Check autostart: `ls /usr/share/applications/*nextcloud*.desktop`

**KDE:**
- Ensure `kdialog` or `notify-send` is installed
- Check autostart: `ls ~/.config/autostart-scripts/`

### Integration Already Exists

The scripts are smart and won't overwrite existing configurations:
- Checks if Nextcloud account already configured
- Skips if server URL already in accounts
- Creates marker only if needed

## Advanced Configuration

### Per-Service Desktop Integration

You can enable desktop integration only for specific PAM services:

**/etc/pam.d/lightdm** (display manager - enable):
```
session optional pam_python.so /lib/security/pam_nextcloud.py
```

**/etc/pam.d/sshd** (SSH - disable):
```
# No session line = no desktop integration for SSH
```

### Custom Integration Script

Create your own integration script and configure PAM to call it:

```bash
# /usr/local/bin/custom-nextcloud-setup.sh
#!/bin/bash
# Your custom integration logic
```

Update `/lib/security/pam_nextcloud_desktop.py` or create wrapper.

### Integration for Multiple Nextcloud Servers

The integration supports multiple Nextcloud servers by checking existing accounts:
- Won't duplicate if server already configured
- Can add multiple servers to same desktop

## Integration Examples

### Example 1: Corporate Desktop Setup

**Scenario:** Company wants all employees' desktops auto-configured

1. Deploy PAM configuration via Ansible/Puppet
2. Enable `enable_desktop_integration = true`
3. Users log in once
4. Desktops automatically configured
5. Users enter company password or app password

### Example 2: University Computer Labs

**Scenario:** Students should have Nextcloud available

1. Configure PAM on all lab machines
2. Enable desktop integration
3. Students log in with university credentials
4. Nextcloud integration available
5. Syncs when they connect

### Example 3: Home User with Laptop

**Scenario:** Personal laptop with Nextcloud

1. Install PAM module
2. Enable desktop integration
3. Works offline via cache
4. Desktop stays in sync

## Comparison with Manual Setup

### Manual Setup (Traditional)
1. User logs in
2. Opens Nextcloud Desktop Client or Settings
3. Manually enters server URL
4. Types username
5. Enters password
6. Configures sync folders
7. **Time**: 5-10 minutes

### Automatic Setup (This Module)
1. User logs in
2. Gets notification
3. Opens Settings (URL pre-filled)
4. Enters password
5. **Time**: 2 minutes

**Saved per user**: 3-8 minutes  
**Reduced errors**: No typos in server URL

## Limitations

1. **User must complete setup**: Authentication still required in desktop settings
2. **No automatic password entry**: Users must enter password (security feature)
3. **Desktop session required**: Only works for graphical logins
4. **First login only**: Integration markers created on first successful login
5. **No remote sessions**: SSH users won't get desktop integration (by design)

## Future Enhancements

Potential improvements for future versions:

- OAuth2 token generation for passwordless integration
- Automatic sync folder configuration
- Integration with Nextcloud Hub features
- Support for additional desktop environments (XFCE, MATE, etc.)
- Web browser profile configuration (bookmarks, etc.)

## See Also

- [GNOME Online Accounts Documentation](https://wiki.gnome.org/Projects/GnomeOnlineAccounts)
- [Nextcloud Desktop Client Documentation](https://docs.nextcloud.com/desktop/)
- [KDE Accounts Documentation](https://community.kde.org/KTp/KAccounts)
- Main README.md for PAM module configuration
- QUICKSTART.md for quick setup guide

## Support

For issues with desktop integration:
1. Check this guide's troubleshooting section
2. Check PAM logs: `sudo grep pam_nextcloud /var/log/auth.log`
3. Test desktop integration script manually
4. Verify desktop environment detection
5. Check marker files are being created

---

**Note**: Desktop integration is optional and disabled by default. The PAM authentication module works perfectly without it!

