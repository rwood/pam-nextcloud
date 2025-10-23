# Group Synchronization Guide

This guide explains how to set up automatic group synchronization from Nextcloud to Linux, enabling centralized group management through Nextcloud.

## Overview

The group synchronization feature automatically:
- Fetches user's groups from Nextcloud during login
- Creates Linux groups that don't exist
- Adds users to their Nextcloud groups
- Maps Nextcloud groups to Linux groups (e.g., "admins" → "sudo")
- Manages sudo/wheel access through Nextcloud groups

## Use Cases

### 1. Centralized User Management
Manage all user permissions in Nextcloud:
- Add user to "developers" group in Nextcloud
- User automatically gets added to `nc-developers` group on Linux
- Works across all systems using PAM Nextcloud

### 2. Sudo Access Management
Control sudo access from Nextcloud:
- Add user to "admins" group in Nextcloud
- User automatically gets added to "sudo" group on Linux
- Remove from "admins" → automatically removed from "sudo" (on next login)

### 3. Multi-System Consistency
Ensure consistent group membership across systems:
- Same groups on all Linux machines
- Centrally managed from Nextcloud
- No manual group management needed

## How It Works

```
User Logs In
    ↓
PAM Authentication Succeeds
    ↓
PAM Session Opens
    ↓
Fetch Groups from Nextcloud API
    ↓
For Each Group:
  - Check if mapped (e.g., "admins" → "sudo")
  - Create group if doesn't exist
  - Add user to group
    ↓
Groups Available in Session
```

## Configuration

### Step 1: Enable Group Synchronization

Edit `/etc/security/pam_nextcloud.conf`:

```ini
[nextcloud]
url = https://cloud.example.com

# Enable group synchronization
enable_group_sync = true
```

### Step 2: Configure Group Settings

```ini
[group_sync]
# Prefix for managed groups (default: nc-)
# Groups from Nextcloud will be created as: prefix + groupname
prefix = nc-

# Enable automatic sudo mapping (default: true)
# Automatically maps admin groups to sudo/wheel/admin
enable_sudo_mapping = true

# Create missing groups (default: true)
# Automatically create groups that don't exist
create_missing_groups = true
```

### Step 3: Configure Group Mapping (Optional)

Map Nextcloud groups to specific Linux groups:

```ini
[group_mapping]
# Format: nextcloud_group = linux_group1, linux_group2

# Map Nextcloud admins to local sudo group
admins = sudo

# Map developers to multiple groups
developers = docker, sudo

# Map staff to standard users group
staff = users

# Map students to users group
students = users
```

### Step 4: Install Group Sync Module

```bash
# Copy group sync script
sudo cp pam_nextcloud_groups.py /lib/security/
sudo chmod 644 /lib/security/pam_nextcloud_groups.py
sudo chown root:root /lib/security/pam_nextcloud_groups.py
```

### Step 5: Configure PAM Session

Ensure session hook is configured in PAM (e.g., `/etc/pam.d/common-session` or display manager config):

```
session optional pam_python.so /lib/security/pam_nextcloud.py
```

**Note**: Use `optional` not `required` to prevent login failures if group sync fails.

## Group Mapping

### Automatic Admin Mapping

When `enable_sudo_mapping = true`, these Nextcloud groups are automatically mapped:

| Nextcloud Group | Maps To Linux |
|----------------|---------------|
| `admin` | `sudo` (or `wheel` on RHEL, or `admin` on some systems) |
| `admins` | Same as above |
| `administrators` | Same as above |

The module automatically detects which sudo group exists on your system.

### Custom Mapping

Define custom mappings in `[group_mapping]` section:

```ini
[group_mapping]
# One-to-one mapping
nextcloud_devs = developers

# One-to-many mapping
power_users = sudo, docker, libvirt

# Multiple Nextcloud groups to same Linux group
staff = users
employees = users
```

### Unmapped Groups

Groups without explicit mapping are created with the prefix:
- Nextcloud group: `developers`
- Linux group: `nc-developers` (with default prefix `nc-`)

## Security Considerations

### Sudo Access

**Important**: Be careful with sudo mapping!

```ini
# RECOMMENDED: Explicit mapping
[group_mapping]
admins = sudo

# Or use auto-mapping (enabled by default)
[group_sync]
enable_sudo_mapping = true
```

**Best Practices**:
1. Create a dedicated "linux-admins" group in Nextcloud for sudo access
2. Use explicit mapping for security-sensitive groups
3. Audit Nextcloud group membership regularly
4. Consider disabling auto-creation for production:
   ```ini
   create_missing_groups = false
   ```

### Group Creation

By default, any group from Nextcloud will create a Linux group. To prevent this:

```ini
[group_sync]
create_missing_groups = false
```

With this setting, only pre-existing Linux groups (or mapped groups) will be used.

### Permission Requirements

Group synchronization requires root privileges to:
- Create groups (`groupadd`)
- Add users to groups (`gpasswd`)

The PAM module runs as root, so this is handled automatically.

## Examples

### Example 1: Simple Setup

**Nextcloud groups:**
- admins
- users

**Configuration:**
```ini
[nextcloud]
enable_group_sync = true

[group_sync]
enable_sudo_mapping = true
```

**Result:**
- User in "admins" → added to `sudo` group
- User in "users" → added to `nc-users` group

### Example 2: Corporate Environment

**Nextcloud groups:**
- it-admins
- developers
- qa-team
- regular-users

**Configuration:**
```ini
[nextcloud]
enable_group_sync = true

[group_sync]
prefix = company-
enable_sudo_mapping = false
create_missing_groups = true

[group_mapping]
it-admins = sudo, docker
developers = docker
qa-team = docker
regular-users = users
```

**Result:**
- it-admins → `sudo`, `docker`
- developers → `docker`
- qa-team → `docker`
- regular-users → `users`

### Example 3: University

**Nextcloud groups:**
- faculty
- staff  
- students

**Configuration:**
```ini
[nextcloud]
enable_group_sync = true

[group_sync]
prefix = uni-
enable_sudo_mapping = false

[group_mapping]
faculty = sudo, users
staff = users
students = users, restricted
```

**Result:**
- faculty → `sudo`, `users`
- staff → `users`
- students → `users`, `restricted`

## Testing

### Test Group Synchronization

```bash
# As root, test the group sync script directly
sudo PAM_USER=testuser NEXTCLOUD_GROUPS="admins,developers" \
  python3 /lib/security/pam_nextcloud_groups.py testuser "admins,developers"

# Check user's groups
groups testuser

# Check group membership
getent group sudo
getent group nc-developers
```

### Test Full Flow

1. Create test user in Nextcloud
2. Add to some groups in Nextcloud
3. Log in via SSH or desktop
4. Check groups:
   ```bash
   groups
   id
   ```

### Check Logs

```bash
# View group sync logs
sudo grep "pam_nextcloud_groups" /var/log/auth.log

# View all PAM Nextcloud logs
sudo grep "pam_nextcloud" /var/log/auth.log
```

## Troubleshooting

### Groups Not Being Created

**Check if group sync is enabled:**
```bash
grep enable_group_sync /etc/security/pam_nextcloud.conf
```

**Check if script exists:**
```bash
ls -la /lib/security/pam_nextcloud_groups.py
```

**Check PAM configuration:**
```bash
grep pam_nextcloud /etc/pam.d/common-session
# Should have session line
```

**Check logs:**
```bash
sudo grep "Group synchronization" /var/log/auth.log
```

### User Not Added to Sudo Group

**Check mapping:**
```bash
# Should show mapping or auto-mapping enabled
grep -A 5 "\[group_mapping\]" /etc/security/pam_nextcloud.conf
grep enable_sudo_mapping /etc/security/pam_nextcloud.conf
```

**Verify user is in admin group on Nextcloud:**
- Log into Nextcloud as admin
- Check user's group membership

**Check which sudo group exists:**
```bash
# Should return one of these
getent group sudo
getent group wheel  
getent group admin
```

### Groups Created But User Not Added

**Check permissions:**
```bash
# Group sync needs root privileges
ls -la /lib/security/pam_nextcloud_groups.py
```

**Test manually:**
```bash
sudo gpasswd -a testuser test-group
groups testuser
```

**Check gpasswd availability:**
```bash
which gpasswd
```

### Password Not Available for Group Sync

**Error in logs:**
```
pam_nextcloud: Password not available for group sync
```

**Cause**: PAM doesn't always pass password to session phase.

**Solution**: Ensure `session` line comes after `auth` in PAM config:
```
auth    sufficient  pam_python.so /lib/security/pam_nextcloud.py
session optional    pam_python.so /lib/security/pam_nextcloud.py
```

### Groups Not Taking Effect Immediately

**Explanation**: User must log out and back in for new group membership to take effect.

**Workaround**: Use `newgrp` command:
```bash
newgrp groupname
```

Or start a new login session.

## Advanced Configuration

### Conditional Group Sync

Only sync for specific PAM services:

**/etc/pam.d/sshd** (enable for SSH):
```
session optional pam_python.so /lib/security/pam_nextcloud.py
```

**/etc/pam.d/su** (disable for su):
```
# No session line = no group sync
```

### Custom Group Prefix

Use organization-specific prefix:

```ini
[group_sync]
prefix = mycompany-
```

Result: `mycompany-developers`, `mycompany-qa`, etc.

### Disable Auto-Creation (Whitelist Mode)

Only allow pre-defined groups:

```ini
[group_sync]
create_missing_groups = false

[group_mapping]
# Only these groups will be synced
admins = sudo
developers = docker
staff = users
```

Result: Only mapped groups are synced, others are ignored.

## Limitations

1. **One-Way Sync**: Groups sync FROM Nextcloud TO Linux only
   - Changes made locally are not synced back to Nextcloud
   - Next login will re-sync from Nextcloud (overwriting local changes)

2. **No Group Removal**: Users are added to groups, but not removed
   - If user is removed from Nextcloud group, they stay in Linux group until manually removed
   - Workaround: Use automated scripts or NSS module (future enhancement)

3. **Login Required**: Group sync happens during login
   - Groups don't update automatically
   - User must log out/in to get new groups

4. **Password Required**: Group sync needs password to query Nextcloud
   - If password isn't available (some PAM scenarios), group sync is skipped
   - Cached passwords don't help (need real password for API)

5. **No Nested Groups**: Linux groups don't support nesting
   - Nextcloud group hierarchies are flattened

## Best Practices

### 1. Use Explicit Mapping for Critical Groups

```ini
[group_mapping]
linux-admins = sudo
```

Don't rely on auto-mapping for production sudo access.

### 2. Use Descriptive Group Names

**Good**:
- `linux-admins`
- `dev-team`
- `qa-engineers`

**Avoid**:
- `admin` (confusing with system admin)
- `test` (generic)

### 3. Document Your Mapping

Add comments in config:

```ini
[group_mapping]
# IT administrators - full sudo access
it-admins = sudo

# Developers - Docker access only
developers = docker

# QA Team - Docker for testing
qa-team = docker
```

### 4. Audit Regularly

```bash
# List all managed groups
getent group | grep "^nc-"

# Check sudo group members
getent group sudo
```

### 5. Test Before Production

Test on non-critical systems first:
1. Set up test Nextcloud instance
2. Configure group sync
3. Verify behavior
4. Roll out to production

## API Reference

### Nextcloud Groups API

The module uses this Nextcloud API endpoint:

```
GET /ocs/v1.php/cloud/users/{userid}/groups
Authorization: Basic <username:password>
Headers: OCS-APIRequest: true
```

**Response (XML)**:
```xml
<?xml version="1.0"?>
<ocs>
  <meta>
    <status>ok</status>
  </meta>
  <data>
    <groups>
      <element>admin</element>
      <element>developers</element>
    </groups>
  </data>
</ocs>
```

### GroupSync Class Methods

```python
class GroupSync:
    def sync_groups(username, nextcloud_groups) -> bool
    def _create_group(groupname) -> bool
    def _add_user_to_group(username, groupname) -> bool
    def _get_mapped_groups(nextcloud_group) -> List[str]
```

## See Also

- Main [README.md](README.md) for PAM module configuration
- [DESKTOP_INTEGRATION.md](DESKTOP_INTEGRATION.md) for desktop integration
- [Nextcloud User Provisioning API](https://docs.nextcloud.com/server/latest/admin_manual/configuration_user/user_provisioning_api.html)
- Linux `groups(1)` and `groupadd(8)` man pages

## Future Enhancements

Potential improvements:
- NSS module for real-time group lookups
- Group removal on Nextcloud membership changes
- Nested group support
- Role-based access control (RBAC) integration
- Audit logging to separate file

---

**Note**: Group synchronization is optional and disabled by default. The PAM authentication module works perfectly without it!

