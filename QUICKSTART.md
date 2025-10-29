# Quick Start Guide

Get up and running with PAM Nextcloud authentication in 5 minutes!

## Prerequisites

- A running Nextcloud server (with valid HTTPS certificate recommended)
- Root access to a Linux system
- Basic knowledge of SSH and command line

## Installation Steps

### 1. Quick Install (Automated)

```bash
# Clone or download this repository
cd PAM-Test

# Run the installation script
sudo ./install.sh
```

The script will:
- Install required system packages (pam_python)
- Install Python dependencies (requests)
- Copy the module to `/lib/security/`
- Create a config file template at `/etc/security/pam_nextcloud.conf`

### 2. Configure Your Nextcloud Server

Edit the configuration file:

```bash
sudo nano /etc/security/pam_nextcloud.conf
```

Update with your server details:

```ini
[nextcloud]
url = https://cloud.example.com
verify_ssl = true
timeout = 10
```

**Replace `cloud.example.com` with your actual Nextcloud server URL!**

**Optional - Enable offline authentication caching:**

To allow authentication when Nextcloud is unavailable, enable caching:

```ini
[nextcloud]
url = https://cloud.example.com
verify_ssl = true
timeout = 10

# Enable offline authentication (optional but recommended)
enable_cache = true
cache_expiry_days = 7
```

Then create the cache directory:

```bash
sudo mkdir -p /var/cache/pam_nextcloud
sudo chmod 700 /var/cache/pam_nextcloud
```

### 3. Test Authentication

Before configuring PAM, test that it works:

```bash
test-pam-nextcloud --username your-nextcloud-username
```

Or:

```bash
python3 test_nextcloud_auth.py --username your-nextcloud-username
```

Enter your Nextcloud password when prompted. You should see:

```
✅ SUCCESS: Authentication successful!
```

If you see an error, check:
- Is the Nextcloud URL correct?
- Can you access the URL in a browser?
- Are your credentials correct?
- Is the Nextcloud OCS API enabled?

### 4. Configure PAM for SSH (Most Common Use Case)

**⚠️ WARNING: Keep your current SSH session open! Open a second terminal to test.**

Edit the SSH PAM configuration:

```bash
sudo nano /etc/pam.d/sshd
```

Add this line at the **beginning** of the `auth` section (before other auth lines):

```
auth    sufficient  pam_python.so /lib/security/pam_nextcloud.py
```

Your file might look like this:

```
# PAM configuration for sshd

# Nextcloud authentication (try first)
auth    sufficient  pam_python.so /lib/security/pam_nextcloud.py

# Standard Unix authentication (fallback)
@include common-auth

# ... rest of the file ...
```

Save and exit (Ctrl+O, Enter, Ctrl+X in nano).

### 5. Configure SSH Daemon

Edit SSH server config:

```bash
sudo nano /etc/ssh/sshd_config
```

Ensure these settings are present and uncommented:

```
ChallengeResponseAuthentication yes
UsePAM yes
PasswordAuthentication yes
```

### 6. Restart SSH Service

```bash
sudo systemctl restart sshd
# or on older systems:
sudo service ssh restart
```

### 7. Test SSH Authentication

**Keep your current SSH session open!** In a new terminal:

```bash
ssh your-nextcloud-username@your-server-ip
```

Enter your Nextcloud password. If it works, you're done! 🎉

### 8. Check Logs (If Issues Occur)

```bash
# View authentication logs
sudo tail -100 /var/log/auth.log | grep pam_nextcloud

# Real-time monitoring
sudo tail -f /var/log/auth.log | grep pam_nextcloud
```

## Common Issues

### "Module not found" error

Install pam_python:

```bash
# Debian/Ubuntu
sudo apt-get install libpam-python

# Fedora/RHEL
sudo dnf install pam_python

# Arch Linux
sudo pacman -S python-pam
```

### "Authentication failed" but credentials are correct

1. Test the API manually:

```bash
curl -u username:password -H "OCS-APIRequest: true" \
  https://your-nextcloud-server.com/ocs/v1.php/cloud/users/username
```

2. Check Nextcloud settings:
   - Is the user enabled in Nextcloud?
   - Is the OCS API accessible?
   - Check Nextcloud logs: Settings → Logging

### SSL Certificate Errors

If using self-signed certificates (not recommended for production):

```ini
[nextcloud]
url = https://cloud.example.com
verify_ssl = false  # Only for testing!
```

### Locked Out?

If PAM configuration prevents login:

1. Boot into recovery/single-user mode
2. Edit `/etc/pam.d/sshd` to remove the pam_nextcloud line
3. Restart SSH service
4. Debug the issue with test scripts

## Security Checklist

- [ ] Using HTTPS (not HTTP) for Nextcloud URL
- [ ] SSL certificate is valid (or verify_ssl is appropriately set)
- [ ] Config file has restrictive permissions (600, owned by root)
- [ ] Tested authentication before fully deploying
- [ ] Kept a fallback authentication method (local Unix users)
- [ ] Documented which users can access the system

## Next Steps

Once everything works:

1. **Create local user accounts** for Nextcloud users who should access the system:
   ```bash
   sudo useradd -m username
   ```

2. **Enable password changes** (optional - see `pam-config-examples/passwd`):
   ```bash
   # Test password change
   test-pam-nextcloud --username your-username --change-password
   
   # After configuring /etc/pam.d/passwd, users can run:
   passwd
   ```

3. **Configure sudo** if needed (sudo uses `common-auth` automatically)

4. **Set up access restrictions** using groups or PAM listfile

5. **Monitor logs** regularly for unauthorized access attempts

6. **Test failure scenarios**: What happens if Nextcloud is down?

7. **Optional - Enable group synchronization** (manage sudo from Nextcloud):
   ```ini
   # In /etc/security/pam_nextcloud.conf
   enable_group_sync = true
   
   [group_mapping]
   admins = sudo
   ```
   See `GROUP_SYNC.md` for details

8. **Optional - Enable desktop integration** (for GNOME/KDE desktop users):
   ```ini
   # In /etc/security/pam_nextcloud.conf
   enable_desktop_integration = true
   ```
   Desktop integration is configured automatically via `common-session` when you run `install.sh`.

## Need Help?

- Check the full [README.md](README.md) for detailed documentation
- Review `pam-config-examples/common-auth` and `pam-config-examples/passwd` for configuration examples
- Test with `test-pam-nextcloud` or `test_nextcloud_auth.py`
- Check logs: `sudo grep pam_nextcloud /var/log/auth.log`

## Uninstall

To remove the module:

```bash
sudo ./install.sh --uninstall
```

Then remove the pam_nextcloud lines from your PAM configuration files.

---

**Happy authenticating! 🔐**

