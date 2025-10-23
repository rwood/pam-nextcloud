# PAM Nextcloud Authentication Module

A PAM (Pluggable Authentication Modules) module that authenticates Linux users against a Nextcloud server using the pam_python framework.

## Features

- ✅ Authenticate Linux users against Nextcloud credentials
- ✅ Supports SSH, sudo, and system login authentication
- ✅ **Password change support** - Users can change their Nextcloud password via `passwd` command
- ✅ **Offline authentication** - Secure password caching for up to 7 days when Nextcloud is unavailable
- ✅ **Group synchronization** - Automatically sync user groups from Nextcloud (manage sudo access centrally!)
- ✅ **Desktop integration** - Automatically configure GNOME Online Accounts and KDE accounts
- ✅ Configurable SSL verification
- ✅ Timeout protection
- ✅ Comprehensive logging via syslog
- ✅ Fallback to local authentication
- ✅ Secure PBKDF2 password hashing for cached credentials

## Requirements

### System Requirements
- Linux system with PAM support
- Python 3.6 or higher
- pam_python module

### Python Dependencies
- requests (for HTTP API calls)

## Installation

### Step 1: Install System Dependencies

#### Debian/Ubuntu
```bash
sudo apt-get update
sudo apt-get install libpam-python python3 python3-pip
```

#### Fedora/RHEL/CentOS
```bash
sudo dnf install pam_python python3 python3-pip
```

#### Arch Linux
```bash
sudo pacman -S python-pam python python-pip
```

### Step 2: Install Python Dependencies

```bash
sudo pip3 install -r requirements.txt
```

Or install manually:
```bash
sudo pip3 install requests
```

### Step 3: Install the PAM Module

```bash
# Copy the module to PAM Python modules directory
sudo mkdir -p /lib/security
sudo cp pam_nextcloud.py /lib/security/

# Set proper permissions
sudo chmod 644 /lib/security/pam_nextcloud.py
sudo chown root:root /lib/security/pam_nextcloud.py
```

### Step 4: Configure Nextcloud Settings

```bash
# Copy the configuration file
sudo cp pam_nextcloud.conf.example /etc/security/pam_nextcloud.conf

# Edit with your Nextcloud server details
sudo nano /etc/security/pam_nextcloud.conf

# Set secure permissions
sudo chmod 600 /etc/security/pam_nextcloud.conf
sudo chown root:root /etc/security/pam_nextcloud.conf
```

Edit `/etc/security/pam_nextcloud.conf`:
```ini
[nextcloud]
url = https://your-nextcloud-server.com
verify_ssl = true
timeout = 10
```

### Step 5: Configure PAM

**⚠️ WARNING**: Incorrect PAM configuration can lock you out of your system! Always keep a root shell open and test thoroughly before closing all sessions.

#### Option A: SSH Authentication

Edit `/etc/pam.d/sshd`:
```bash
# Add at the beginning of the auth section
auth    sufficient  pam_python.so /lib/security/pam_nextcloud.py

# Keep existing auth lines as fallback
auth    sufficient  pam_unix.so nullok_secure try_first_pass
```

Also configure `/etc/ssh/sshd_config`:
```bash
ChallengeResponseAuthentication yes
UsePAM yes
PasswordAuthentication yes
```

Then restart SSH:
```bash
sudo systemctl restart sshd
```

#### Option B: System Login (Console/TTY)

Edit `/etc/pam.d/login`:
```bash
auth    sufficient  pam_python.so /lib/security/pam_nextcloud.py
auth    sufficient  pam_unix.so nullok_secure try_first_pass
```

#### Option C: sudo Authentication

Edit `/etc/pam.d/sudo`:
```bash
auth    sufficient  pam_python.so /lib/security/pam_nextcloud.py
auth    sufficient  pam_unix.so try_first_pass
```

See the `pam-config-examples/` directory for complete configuration examples.

## Configuration Options

### Nextcloud Configuration File

The configuration file (`/etc/security/pam_nextcloud.conf`) supports the following options:

| Option | Required | Default | Description |
|--------|----------|---------|-------------|
| `url` | Yes | - | URL of your Nextcloud server (include protocol) |
| `verify_ssl` | No | `true` | Enable/disable SSL certificate verification |
| `timeout` | No | `10` | Connection timeout in seconds |
| `enable_cache` | No | `false` | Enable offline authentication with password caching |
| `cache_expiry_days` | No | `7` | Number of days before cached credentials expire (0 = never) |
| `cache_directory` | No | `/var/cache/pam_nextcloud` | Directory to store cached credentials |
| `enable_desktop_integration` | No | `false` | Automatically configure desktop environment Nextcloud integration |
| `force_desktop_type` | No | auto-detect | Force desktop type: `gnome`, `kde`, or blank for auto-detect |
| `enable_group_sync` | No | `false` | Automatically synchronize user groups from Nextcloud to Linux |

### PAM Module Arguments

You can pass a custom configuration file path as a module argument:

```bash
auth sufficient pam_python.so /lib/security/pam_nextcloud.py config=/path/to/custom/config.conf
```

## How It Works

1. When a user attempts to authenticate, PAM calls the `pam_sm_authenticate` function
2. The module extracts the username and password from the PAM conversation
3. It connects to the Nextcloud OCS API using HTTP Basic Authentication
4. If the API returns 200 OK, authentication succeeds
5. If the API returns 401 Unauthorized, authentication fails
6. Any errors (timeouts, connection issues) result in authentication failure

The module uses the Nextcloud OCS User Provisioning API endpoint:
```
GET /ocs/v1.php/cloud/users/{username}
```

This endpoint requires valid credentials to access, making it perfect for authentication verification.

## Offline Authentication (Password Caching)

The module supports offline authentication by caching securely hashed passwords. When Nextcloud is unavailable (network issues, server down, etc.), users can still authenticate using cached credentials.

### How Password Caching Works

1. **On Successful Authentication**: When a user successfully authenticates against Nextcloud, their password is:
   - Hashed using PBKDF2-HMAC-SHA256 with 100,000 iterations
   - Salted with a unique 32-byte random salt
   - Stored in `/var/cache/pam_nextcloud/` with root-only permissions (600)
   - Tagged with a timestamp for expiry tracking

2. **On Authentication Attempt**: The module tries:
   - First: Authenticate directly with Nextcloud (normal operation)
   - If Nextcloud is unavailable: Fall back to cached credentials
   - If password is wrong on Nextcloud (401): Don't try cache (prevents outdated cache use)

3. **Cache Expiry**: Cached credentials expire after 7 days (configurable)
   - Expired cache entries are automatically deleted
   - Users must authenticate with Nextcloud to refresh the cache

### Configuring Password Caching

Edit `/etc/security/pam_nextcloud.conf`:

```ini
[nextcloud]
url = https://cloud.example.com
verify_ssl = true
timeout = 10

# Enable offline authentication
enable_cache = true

# Cache expiry in days (default: 7)
cache_expiry_days = 7

# Cache directory (default: /var/cache/pam_nextcloud)
cache_directory = /var/cache/pam_nextcloud
```

Create the cache directory:

```bash
sudo mkdir -p /var/cache/pam_nextcloud
sudo chmod 700 /var/cache/pam_nextcloud
sudo chown root:root /var/cache/pam_nextcloud
```

### When Offline Authentication Triggers

Cached credentials are used **only** when Nextcloud is unreachable:

- ✅ Connection timeout
- ✅ Connection refused (server down)
- ✅ SSL/TLS errors (certificate issues)
- ✅ Network unreachable
- ✅ Server error (500, 502, 503, etc.)

Cached credentials are **not** used when:

- ❌ Wrong password (401 Unauthorized from Nextcloud)
- ❌ User doesn't exist (404 Not Found)
- ❌ Cache has expired (> 7 days old)
- ❌ No cached credentials exist

### Security Considerations

**Hashing Algorithm:**
- Uses PBKDF2-HMAC-SHA256 with 100,000 iterations
- Each password has a unique 32-byte random salt
- Computationally expensive to prevent brute force attacks
- Cache files are stored with 600 permissions (root only)

**Cache Location:**
- Default: `/var/cache/pam_nextcloud/`
- Directory permissions: 700 (rwx for root only)
- File permissions: 600 (rw for root only)
- Filenames are SHA-256 hashes of usernames (prevents path traversal)

**Important Security Notes:**

1. **Password Divergence**: If a user changes their password in Nextcloud (not via this PAM module), the cache won't update until they authenticate again
   - Risk: User could still authenticate with old password if Nextcloud is down
   - Mitigation: Cache expires after 7 days, forcing Nextcloud re-authentication

2. **Cache Compromise**: If the cache directory is compromised, attackers would need to:
   - Crack PBKDF2 hashes (computationally expensive)
   - Wait for Nextcloud to become unavailable
   - Use correct username

3. **Audit Trail**: All cached authentications are logged to syslog:
   ```
   pam_nextcloud: Cached authentication successful for user: john (cache age: 3.2 days)
   ```

4. **Recommended Settings**:
   - Set `cache_expiry_days = 7` (default) for balance between security and availability
   - Monitor logs for cached authentication attempts
   - Consider disabling cache for high-security environments
   - Set `cache_expiry_days = 0` for indefinite caching (not recommended)

### Cache Management

**View cached users:**
```bash
sudo ls -lh /var/cache/pam_nextcloud/
```

**Check cache for specific user:**
```bash
# Note: Files are named using SHA-256 hash of username
sudo find /var/cache/pam_nextcloud/ -type f -exec stat -c "%y %n" {} \;
```

**Clear all cached credentials:**
```bash
sudo rm -rf /var/cache/pam_nextcloud/*
```

**Clear cache for specific user:**
```bash
# You'll need to identify the correct hash file or clear all
```

**Disable caching:**

Edit `/etc/security/pam_nextcloud.conf`:
```ini
enable_cache = false
```

## Password Changes

The module supports user self-service password changes through the standard Linux `passwd` command. When a user changes their password, it is updated on the Nextcloud server.

### How Password Changes Work

1. User runs the `passwd` command
2. PAM prompts for the current password (for verification)
3. The module authenticates the user with their current password
4. PAM prompts for the new password (twice for confirmation)
5. The module sends a PUT request to Nextcloud to update the password
6. If successful, the password is changed on Nextcloud
7. User can immediately use the new password for authentication

The password change uses the Nextcloud OCS User Provisioning API endpoint:
```
PUT /ocs/v1.php/cloud/users/{username}
```

### Configuring Password Changes

To enable password changes via the `passwd` command, edit `/etc/pam.d/passwd`:

```bash
# Password change authentication
auth    sufficient  pam_python.so /lib/security/pam_nextcloud.py

# Account management
account sufficient  pam_python.so /lib/security/pam_nextcloud.py

# Password changing
password sufficient pam_python.so /lib/security/pam_nextcloud.py

# Fallback to local Unix password change
password sufficient pam_unix.so use_authtok
```

See `pam-config-examples/passwd` for a complete example.

### Testing Password Changes

Test password change functionality:

```bash
# Using the test script
test-pam-nextcloud --username your-username --change-password

# Or directly
python3 test_nextcloud_auth.py --username your-username --change-password
```

Once PAM is configured, users can change their password:

```bash
passwd
```

The user will be prompted for:
1. Current password (for authentication)
2. New password
3. New password confirmation (retype)

### Password Change Behavior

- ✅ Users authenticate with their **current** password before changing
- ✅ New password is immediately active on Nextcloud
- ✅ Password policies are enforced by Nextcloud (minimum length, complexity, etc.)
- ✅ All password changes are logged to syslog
- ✅ If Nextcloud is unavailable, password change fails (no local-only changes)

### Important Notes

- Password changes require valid current password (no admin override)
- If Nextcloud has password policy requirements (minimum length, special characters, etc.), those will be enforced
- The password change is immediate - no email confirmation required
- Local Linux password remains unchanged (only Nextcloud password is updated)
- If using both Nextcloud and local authentication, consider the implications of diverging passwords

## Desktop Integration

The module can automatically configure desktop environment integration with Nextcloud, including:
- **GNOME Online Accounts** - Integrates with GNOME Files, Calendar, Contacts
- **KDE Accounts** - Integrates with KDE applications
- **Nextcloud Desktop Client** - Pre-fills server configuration

### Quick Setup

Enable in `/etc/security/pam_nextcloud.conf`:

```ini
[nextcloud]
url = https://cloud.example.com

# Enable desktop integration
enable_desktop_integration = true
```

Configure PAM session hook in `/etc/pam.d/common-session` or `/etc/pam.d/lightdm`:

```
session optional pam_python.so /lib/security/pam_nextcloud.py
```

### User Experience

When enabled:
1. User logs into desktop session
2. Integration markers are created automatically
3. User receives notification to complete setup
4. User opens Settings > Online Accounts
5. Server URL and username are pre-filled
6. User enters password
7. Desktop integration complete!

### What Gets Integrated

**GNOME:**
- Files (Nextcloud appears in file browser)
- Calendar (events sync with GNOME Calendar)
- Contacts (contacts sync with GNOME Contacts)
- Documents (access Nextcloud documents)

**KDE Plasma:**
- KIO integration (access via `nextcloud://`)
- Calendar (KOrganizer integration)
- Contacts (KAddressBook integration)
- Purpose framework integration

**All Desktops:**
- Nextcloud Desktop Client receives server hints
- Simplified first-run configuration

### Security

Desktop integration is secure:
- ✅ No passwords are stored
- ✅ Only server URL and username are pre-filled
- ✅ User must manually authenticate in desktop settings
- ✅ Supports Nextcloud app passwords
- ✅ Uses standard desktop authentication flows

For detailed setup and troubleshooting, see **[DESKTOP_INTEGRATION.md](DESKTOP_INTEGRATION.md)**.

## Group Synchronization

The module can automatically synchronize user groups from Nextcloud to Linux, enabling centralized group management and sudo access control.

### Quick Setup

Enable in `/etc/security/pam_nextcloud.conf`:

```ini
[nextcloud]
url = https://cloud.example.com

# Enable group synchronization
enable_group_sync = true

[group_sync]
# Automatically map admin groups to sudo
enable_sudo_mapping = true

[group_mapping]
# Map Nextcloud groups to Linux groups
admins = sudo
developers = docker, sudo
staff = users
```

### How It Works

1. User logs in via PAM
2. Module fetches user's groups from Nextcloud API
3. Creates Linux groups if they don't exist
4. Adds user to mapped groups
5. Groups are available immediately in the session

### Common Use Cases

**Centralized Sudo Management:**
- Add user to "admins" group in Nextcloud
- User automatically gets sudo access on all Linux systems
- Remove from "admins" → sudo access removed on next login

**Department Groups:**
- "developers" → `docker`, `sudo` groups
- "qa-team" → `docker` group
- "staff" → `users` group

**Automatic Group Creation:**
- Nextcloud group "project-alpha" → Linux group `nc-project-alpha`
- No manual group management needed

### Security

Group synchronization is secure:
- ✅ Groups synced on every login (up-to-date membership)
- ✅ Explicit mapping for sudo access (no surprises)
- ✅ Automatic admin mapping (configurable)
- ✅ Comprehensive audit logging
- ✅ Can disable auto-creation (whitelist mode)

For detailed configuration, mapping examples, and troubleshooting, see **[GROUP_SYNC.md](GROUP_SYNC.md)**.

## Testing

### Test the Configuration

Before configuring PAM, you can test the Nextcloud connection:

```python
python3 << EOF
import sys
sys.path.insert(0, '/lib/security')
from pam_nextcloud import NextcloudAuth

auth = NextcloudAuth('/etc/security/pam_nextcloud.conf')
result = auth.authenticate('your-username', 'your-password')
print(f"Authentication result: {result}")
EOF
```

### Test PAM Integration

Test SSH authentication (from another terminal while keeping a session open):
```bash
ssh username@localhost
```

Check authentication logs:
```bash
sudo tail -f /var/log/auth.log  # Debian/Ubuntu
sudo tail -f /var/log/secure     # RHEL/CentOS
sudo journalctl -f -u sshd       # systemd systems
```

## Troubleshooting

### Check Logs

All authentication attempts are logged to syslog under the `pam_nextcloud` identifier:

```bash
# View recent authentication logs
sudo grep pam_nextcloud /var/log/auth.log

# Real-time monitoring
sudo tail -f /var/log/auth.log | grep pam_nextcloud
```

### Common Issues

#### 1. Module Not Found
**Error**: `PAM unable to dlopen(/lib/security/pam_python.so)`

**Solution**: Install pam_python:
```bash
sudo apt-get install libpam-python  # Debian/Ubuntu
sudo dnf install pam_python         # Fedora/RHEL
```

#### 2. Config File Not Found
**Error**: `pam_nextcloud: Config file not found`

**Solution**: Ensure config file exists and has correct permissions:
```bash
sudo ls -la /etc/security/pam_nextcloud.conf
sudo chmod 600 /etc/security/pam_nextcloud.conf
```

#### 3. SSL Certificate Errors
**Error**: `pam_nextcloud: SSL error`

**Solution**: If using self-signed certificates, set `verify_ssl = false` in config (not recommended for production), or install the CA certificate:
```bash
sudo cp your-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
```

#### 4. Connection Timeout
**Error**: `pam_nextcloud: Timeout connecting to`

**Solution**: 
- Check network connectivity to Nextcloud server
- Increase timeout value in config file
- Verify Nextcloud URL is correct

#### 5. Authentication Always Fails
**Troubleshooting steps**:
1. Test credentials directly in Nextcloud web interface
2. Check Nextcloud logs for API access
3. Verify Nextcloud OCS API is enabled
4. Test with curl:
```bash
curl -u username:password -H "OCS-APIRequest: true" \
  https://your-nextcloud-server.com/ocs/v1.php/cloud/users/username
```

#### 6. Locked Out of System
**Prevention**: Always keep a root shell open when testing PAM configuration

**Recovery**: Boot into single-user mode or recovery mode and fix PAM configuration

## Security Considerations

1. **Configuration File Security**: The config file should be readable only by root (mode 600)

2. **SSL/TLS**: Always use HTTPS for production deployments

3. **Fallback Authentication**: Consider keeping local Unix authentication as fallback

4. **Account Management**: Ensure user accounts exist locally on the Linux system (use `useradd` or similar)

5. **Password Policy**: Password policies are enforced by Nextcloud, not PAM

6. **Audit Logging**: All authentication attempts are logged to syslog

## Advanced Configuration

### Multiple Nextcloud Servers

You can create multiple configuration files and specify them per service:

```bash
# /etc/pam.d/service1
auth sufficient pam_python.so /lib/security/pam_nextcloud.py config=/etc/security/nextcloud1.conf

# /etc/pam.d/service2
auth sufficient pam_python.so /lib/security/pam_nextcloud.py config=/etc/security/nextcloud2.conf
```

### User Mapping

Currently, the module uses the same username for both Linux and Nextcloud. For custom mapping, modify the `pam_sm_authenticate` function to implement your mapping logic.

### Group Restrictions

To restrict which Nextcloud users can authenticate, you can:
1. Use PAM's `pam_listfile` module
2. Modify the module to check Nextcloud group membership via the Groups API

Example with `pam_listfile`:
```bash
auth required pam_listfile.so item=user sense=allow file=/etc/security/nextcloud-users.list
auth sufficient pam_python.so /lib/security/pam_nextcloud.py
```

## API Reference

### NextcloudAuth Class

```python
class NextcloudAuth:
    def __init__(self, config_path='/etc/security/pam_nextcloud.conf'):
        """Initialize with configuration file path"""
        
    def load_config(self):
        """Load configuration from file"""
        
    def authenticate(self, username, password):
        """Authenticate user against Nextcloud
        
        Returns:
            bool: True if authentication successful, False otherwise
        """
```

### PAM Functions

The module implements the following PAM service module functions:

- `pam_sm_authenticate`: Performs authentication
- `pam_sm_setcred`: Credential management (no-op)
- `pam_sm_acct_mgmt`: Account validation
- `pam_sm_open_session`: Session initialization (no-op)
- `pam_sm_close_session`: Session cleanup (no-op)
- `pam_sm_chauthtok`: Password change (not supported)

## Contributing

Contributions are welcome! Please consider:

- Adding unit tests
- Implementing group-based access control
- Supporting additional Nextcloud features
- Improving error handling
- Adding support for 2FA/TOTP

## License

MIT License - See LICENSE file for details

## Nextcloud API Documentation

This module uses the Nextcloud OCS API:
- [User Provisioning API](https://docs.nextcloud.com/server/latest/admin_manual/configuration_user/user_provisioning_api.html)
- [OCS Share API](https://docs.nextcloud.com/server/latest/developer_manual/client_apis/OCS/ocs-api-overview.html)

## Support

For issues related to:
- **This module**: Check logs and open an issue
- **pam_python**: Consult pam_python documentation
- **Nextcloud API**: Refer to Nextcloud documentation
- **PAM configuration**: Consult your Linux distribution's documentation

## Changelog

### Version 1.0.0
- Initial release
- Basic authentication against Nextcloud OCS API
- Configuration file support
- Comprehensive logging
- SSL verification options
- Timeout handling

## Acknowledgments

- Built on the excellent [pam_python](https://github.com/cernekee/pam_python) framework
- Uses the Nextcloud OCS API
- Inspired by other PAM authentication modules in the community

