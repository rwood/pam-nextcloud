#!/usr/bin/env python3
"""
PAM Nextcloud Sync Script

This script synchronizes users and groups from Nextcloud to the local Linux system.
It provisions local user accounts and syncs group memberships for groups that exist
on both Nextcloud and the local system.

Usage:
    sudo pam-nextcloud-sync --group GROUP_NAME
    sudo pam-nextcloud-sync --user USERNAME
    sudo pam-nextcloud-sync --sync-all-groups
    sudo pam-nextcloud-sync --config /path/to/config.conf
"""

import sys
import os
import getpass
import argparse
import subprocess
import requests
import configparser
import xml.etree.ElementTree as ET
import grp
from urllib.parse import urljoin
from typing import List, Optional

# Try to import pwd for user checking
try:
    import pwd
except ImportError:
    pwd = None

# Import GroupSync from pam_nextcloud_groups module
try:
    sys.path.insert(0, '/lib/security')
    from pam_nextcloud_groups import GroupSync
except ImportError:
    print("⚠️  WARNING: Could not import GroupSync from pam_nextcloud_groups.py")
    print("   Group synchronization will be limited")
    GroupSync = None


def get_config(config_path='/etc/security/pam_nextcloud.conf'):
    """Load configuration from file"""
    if not os.path.exists(config_path):
        print(f"❌ ERROR: Configuration file not found: {config_path}")
        print()
        print("Please create the configuration file with your Nextcloud settings.")
        print("Example:")
        print()
        print("  [nextcloud]")
        print("  url = https://cloud.example.com")
        print("  verify_ssl = true")
        print("  timeout = 10")
        return None
    
    config = configparser.ConfigParser()
    config.read(config_path)
    
    if 'nextcloud' not in config:
        print(f"❌ ERROR: [nextcloud] section not found in {config_path}")
        return None
    
    url = config.get('nextcloud', 'url', fallback=None)
    verify_ssl = config.getboolean('nextcloud', 'verify_ssl', fallback=True)
    timeout = config.getint('nextcloud', 'timeout', fallback=10)
    
    if not url:
        print(f"❌ ERROR: Nextcloud URL not configured in {config_path}")
        return None
    
    return {
        'url': url,
        'verify_ssl': verify_ssl,
        'timeout': timeout,
        'config_file': config_path
    }


def get_all_nextcloud_groups(admin_username, admin_password, config):
    """Get all groups from Nextcloud"""
    try:
        api_url = urljoin(config['url'], '/ocs/v2.php/cloud/groups')
        
        response = requests.get(
            api_url,
            auth=(admin_username, admin_password),
            headers={
                'OCS-APIRequest': 'true',
                'Accept': 'application/json'
            },
            verify=config['verify_ssl'],
            timeout=config['timeout']
        )
        
        if response.status_code == 200:
            try:
                data = response.json()
                if 'ocs' in data and 'data' in data['ocs']:
                    groups_data = data['ocs']['data'].get('groups', {})
                    
                    if isinstance(groups_data, dict) and 'element' in groups_data:
                        elements = groups_data['element']
                        return elements if isinstance(elements, list) else [elements]
                    elif isinstance(groups_data, list):
                        return groups_data
            except (ValueError, KeyError):
                # Try XML
                root = ET.fromstring(response.content)
                groups = []
                for element in root.findall('.//data/groups/element'):
                    if element.text:
                        groups.append(element.text)
                return groups
        
        return []
    except Exception as e:
        print(f"⚠️  Error getting Nextcloud groups: {e}")
        return []


def get_local_groups():
    """Get all local Linux groups"""
    try:
        groups = []
        for group in grp.getgrall():
            groups.append(group.gr_name)
        return groups
    except Exception:
        return []


def get_group_members(admin_username, admin_password, group_name, config):
    """Get list of users in a Nextcloud group"""
    try:
        api_url = urljoin(config['url'], f'/ocs/v2.php/cloud/groups/{group_name}/users')
        
        response = requests.get(
            api_url,
            auth=(admin_username, admin_password),
            headers={
                'OCS-APIRequest': 'true',
                'Accept': 'application/json'
            },
            verify=config['verify_ssl'],
            timeout=config['timeout']
        )
        
        if response.status_code == 200:
            users = None
            try:
                data = response.json()
                if 'ocs' in data and 'data' in data['ocs']:
                    users_data = data['ocs']['data'].get('users', {})
                    
                    if isinstance(users_data, list):
                        users = users_data
                    elif isinstance(users_data, dict) and 'element' in users_data:
                        element = users_data['element']
                        users = element if isinstance(element, list) else [element]
                    elif isinstance(users_data, str):
                        users = [users_data] if users_data else []
            except (ValueError, KeyError):
                pass
            
            if not users:
                root = ET.fromstring(response.content)
                users = []
                for element in root.findall('.//data/users/element'):
                    if element.text:
                        users.append(element.text)
            
            if users is not None:
                return users
            
            # Fallback: Get all users and check their groups
            api_url = urljoin(config['url'], '/ocs/v2.php/cloud/users')
            response = requests.get(
                api_url,
                auth=(admin_username, admin_password),
                headers={
                    'OCS-APIRequest': 'true',
                    'Accept': 'application/json'
                },
                verify=config['verify_ssl'],
                timeout=config['timeout']
            )
            
            if response.status_code == 200:
                all_users = []
                try:
                    data = response.json()
                    if 'ocs' in data and 'data' in data['ocs']:
                        users_data = data['ocs']['data'].get('users', {})
                        if isinstance(users_data, dict) and 'element' in users_data:
                            all_users = users_data['element'] if isinstance(users_data['element'], list) else [users_data['element']]
                        elif isinstance(users_data, list):
                            all_users = users_data
                except (ValueError, KeyError):
                    pass
                
                group_members = []
                for user in all_users:
                    user_groups = get_user_groups(admin_username, admin_password, user, config)
                    if user_groups and group_name in user_groups:
                        group_members.append(user)
                return group_members
        
        return []
    except Exception as e:
        print(f"⚠️  Error getting group members: {e}")
        return []


def get_user_details(admin_username, admin_password, username, config):
    """Get user details from Nextcloud including display name"""
    try:
        api_url = urljoin(config['url'], f'/ocs/v2.php/cloud/users/{username}')
        
        response = requests.get(
            api_url,
            auth=(admin_username, admin_password),
            headers={
                'OCS-APIRequest': 'true',
                'Accept': 'application/json'
            },
            verify=config['verify_ssl'],
            timeout=config['timeout']
        )
        
        if response.status_code == 200:
            try:
                data = response.json()
                # Debug: print the structure to understand it
                # The structure might be ocs.data.data.displayname or ocs.data.displayname
                if 'ocs' in data and 'data' in data['ocs']:
                    # Try different possible structures
                    user_data = data['ocs']['data']
                    
                    # Nextcloud might return data directly or nested under 'data'
                    if isinstance(user_data, dict):
                        # Check if there's a nested 'data' key
                        if 'data' in user_data and isinstance(user_data['data'], dict):
                            user_data = user_data['data']
                        
                        # Try to get display name (may be under different keys)
                        display_name = (
                            user_data.get('displayname') or
                            user_data.get('display-name') or
                            user_data.get('display_name') or
                            user_data.get('name') or
                            None
                        )
                        if display_name:
                            return {'display_name': display_name}
            except (ValueError, KeyError) as e:
                # Try XML parsing
                try:
                    root = ET.fromstring(response.content)
                    display_name_elem = root.find('.//displayname')
                    if display_name_elem is not None and display_name_elem.text:
                        return {'display_name': display_name_elem.text}
                except Exception:
                    pass
        
        return {}
    except Exception as e:
        # Silently fail - we'll just use the default
        return {}


def get_user_groups(admin_username, admin_password, username, config):
    """Get list of groups a user belongs to"""
    try:
        api_url = urljoin(config['url'], f'/ocs/v2.php/cloud/users/{username}/groups')
        
        response = requests.get(
            api_url,
            auth=(admin_username, admin_password),
            headers={
                'OCS-APIRequest': 'true',
                'Accept': 'application/json'
            },
            verify=config['verify_ssl'],
            timeout=config['timeout']
        )
        
        if response.status_code == 200:
            try:
                data = response.json()
                if 'ocs' in data and 'data' in data['ocs']:
                    groups = data['ocs']['data'].get('groups', {})
                    if isinstance(groups, dict) and 'element' in groups:
                        group_list = groups['element']
                        return group_list if isinstance(group_list, list) else [group_list]
                    elif isinstance(groups, list):
                        return groups
            except (ValueError, KeyError):
                root = ET.fromstring(response.content)
                groups = []
                for element in root.findall('.//data/groups/element'):
                    if element.text:
                        groups.append(element.text)
                return groups
        return []
    except Exception:
        return []


def get_local_group_members(group_name):
    """Get list of users in a local Linux group"""
    try:
        group_info = grp.getgrnam(group_name)
        return list(group_info.gr_mem)
    except KeyError:
        return []


def user_exists(username):
    """Check if a local user exists"""
    try:
        if pwd:
            pwd.getpwnam(username)
            return True
        else:
            result = subprocess.run(
                ['getent', 'passwd', username],
                capture_output=True,
                check=False
            )
            return result.returncode == 0
    except (KeyError, Exception):
        return False


def lock_local_password(username):
    """Lock local password for a user so they can only use Nextcloud authentication"""
    try:
        # Use passwd -l to lock the password (recommended method)
        result = subprocess.run(
            ['passwd', '-l', username],
            capture_output=True,
            text=True,
            check=False
        )
        
        if result.returncode == 0:
            return True
        else:
            # Fallback: use usermod -L
            result2 = subprocess.run(
                ['usermod', '-L', username],
                capture_output=True,
                text=True,
                check=False
            )
            return result2.returncode == 0
    except Exception:
        return False


def configure_gdm_user_list():
    """Configure GDM to show user list on login screen"""
    try:
        # Check if GDM is installed
        gdm_check = subprocess.run(
            ['systemctl', 'is-enabled', 'gdm'],
            capture_output=True,
            text=True,
            check=False
        )
        
        # Also check if gdm.service exists
        gdm_service_check = subprocess.run(
            ['systemctl', 'list-unit-files', 'gdm.service'],
            capture_output=True,
            text=True,
            check=False
        )
        
        # Check if dconf is available (needed for GDM config)
        dconf_check = subprocess.run(
            ['which', 'dconf'],
            capture_output=True,
            text=True,
            check=False
        )
        
        if dconf_check.returncode != 0:
            # dconf not available, skip GDM configuration
            return False
        
        # Create GDM configuration directory
        gdm_db_dir = '/etc/dconf/db/gdm.d'
        gdm_lock_dir = '/etc/dconf/db/gdm.d/locks'
        
        try:
            os.makedirs(gdm_db_dir, mode=0o755, exist_ok=True)
            os.makedirs(gdm_lock_dir, mode=0o755, exist_ok=True)
        except Exception:
            return False
        
        # Create configuration file
        config_file = os.path.join(gdm_db_dir, '00-show-user-list')
        try:
            with open(config_file, 'w') as f:
                f.write('[org/gnome/login-screen]\n')
                f.write('disable-user-list=false\n')
            os.chmod(config_file, 0o644)
        except Exception:
            return False
        
        # Create lock file to prevent user override
        lock_file = os.path.join(gdm_lock_dir, '00-show-user-list')
        try:
            with open(lock_file, 'w') as f:
                f.write('/org/gnome/login-screen/disable-user-list\n')
            os.chmod(lock_file, 0o644)
        except Exception:
            pass  # Lock file is optional
        
        # Update dconf database
        try:
            subprocess.run(
                ['dconf', 'update'],
                capture_output=True,
                text=True,
                check=False
            )
        except Exception:
            pass  # dconf update may fail, but config file is still created
        
        return True
    except Exception:
        return False


def ensure_accounts_service_entry(username, display_name=None):
    """Ensure user has an AccountsService entry so they appear in GDM"""
    try:
        accounts_dir = '/var/lib/AccountsService/users'
        
        # Create directory if it doesn't exist
        os.makedirs(accounts_dir, mode=0o755, exist_ok=True)
        
        user_file = os.path.join(accounts_dir, username)
        
        # Read existing config if it exists
        config = configparser.ConfigParser()
        if os.path.exists(user_file):
            config.read(user_file)
        
        # Set or update User section
        if 'User' not in config:
            config.add_section('User')
        
        # Ensure SystemAccount is false (so user appears in GDM)
        config.set('User', 'SystemAccount', 'false')
        
        # Set real name if provided
        if display_name:
            config.set('User', 'RealName', display_name)
        
        # Write the config file
        with open(user_file, 'w') as f:
            config.write(f)
        
        # Set proper permissions
        os.chmod(user_file, 0o644)
        try:
            os.chown(user_file, 0, 0)  # root:root
        except Exception:
            # chown may fail on some systems, but file is still created
            pass
        
        return True
    except Exception as e:
        # Don't fail silently - log the error
        print(f"  ⚠️  Warning: Could not create AccountsService entry for '{username}': {str(e)}")
        return False


def create_user(username, display_name=None, create_home=True):
    """Create a local Linux user account"""
    try:
        if user_exists(username):
            return True
        
        cmd = ['useradd']
        
        if create_home:
            cmd.append('-m')
        
        # Use display name if provided, otherwise fall back to generic comment
        comment = display_name if display_name else 'Nextcloud user'
        
        cmd.extend([
            '-s', '/bin/bash',
            '-c', comment,
            username
        ])
        
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
        
        if result.returncode == 0:
            # Create AccountsService entry so user appears in GDM
            ensure_accounts_service_entry(username, display_name)
            return True
        else:
            print(f"  ❌ Failed to create user '{username}': {result.stderr.strip()}")
            return False
            
    except Exception as e:
        print(f"  ❌ Error creating user '{username}': {str(e)}")
        return False


def sync_group_membership(group_name, nextcloud_members, config, group_sync):
    """Sync group membership to match Nextcloud"""
    if not group_sync:
        print(f"  ⚠️  GroupSync not available, skipping group sync")
        return False
    
    # Get mapped Linux group name(s) for this Nextcloud group
    linux_groups = group_sync._get_mapped_groups(group_name)
    
    if not linux_groups:
        # No mapping found, try the group name as-is
        if group_sync._group_exists(group_name):
            linux_groups = [group_name]
        else:
            print(f"  ⚠️  Group '{group_name}' does not exist locally (after mapping)")
            return False
    
    changes_made = False
    
    # Sync each mapped Linux group
    for linux_group in linux_groups:
        # Check if group exists locally
        if not group_sync._group_exists(linux_group):
            print(f"  ⚠️  Linux group '{linux_group}' does not exist, skipping")
            continue
        
        # Get local group members
        local_members = set(get_local_group_members(linux_group))
        nextcloud_members_set = set(nextcloud_members)
        
        # Find users to add and remove
        users_to_add = nextcloud_members_set - local_members
        users_to_remove = local_members - nextcloud_members_set
        
        # Add users to group
        for username in users_to_add:
            if not user_exists(username):
                print(f"  ⚠️  User '{username}' does not exist locally, skipping")
                continue
            
            if group_sync._add_user_to_group(username, linux_group):
                print(f"  ✅ Added '{username}' to group '{linux_group}'")
                changes_made = True
            else:
                print(f"  ❌ Failed to add '{username}' to group '{linux_group}'")
        
        # Remove users from group (only if they exist locally)
        for username in users_to_remove:
            if not user_exists(username):
                continue
            
            result = subprocess.run(
                ['gpasswd', '-d', username, linux_group],
                capture_output=True,
                text=True,
                check=False
            )
            
            if result.returncode == 0:
                print(f"  ✅ Removed '{username}' from group '{linux_group}'")
                changes_made = True
            else:
                print(f"  ⚠️  Failed to remove '{username}' from group '{linux_group}': {result.stderr.strip()}")
    
    return changes_made


def main():
    parser = argparse.ArgumentParser(
        description='Sync users and groups from Nextcloud to local Linux system'
    )
    parser.add_argument(
        '--config',
        default='/etc/security/pam_nextcloud.conf',
        help='Path to configuration file (default: /etc/security/pam_nextcloud.conf)'
    )
    parser.add_argument(
        '--group',
        help='Nextcloud group name to provision and sync (will prompt if not provided)'
    )
    parser.add_argument(
        '--user',
        help='Sync groups for a specific user only'
    )
    parser.add_argument(
        '--sync-all-groups',
        action='store_true',
        help='Sync all groups that exist on both Nextcloud and local system'
    )
    parser.add_argument(
        '--admin-user',
        help='Admin username (will prompt if not provided)'
    )
    parser.add_argument(
        '--no-create-home',
        action='store_true',
        help='Do not create home directories for new users'
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Show what would be done without actually making changes'
    )
    
    args = parser.parse_args()
    
    # Check if running as root
    if os.geteuid() != 0:
        print("❌ ERROR: This script must be run as root (use sudo)")
        print()
        print("User creation and group management require root privileges.")
        return 1
    
    print("=" * 70)
    print("PAM Nextcloud Sync")
    print("=" * 70)
    print()
    
    # Load configuration
    print(f"📁 Loading configuration from: {args.config}")
    config = get_config(args.config)
    if not config:
        return 1
    
    print(f"   Nextcloud URL: {config['url']}")
    print(f"   SSL Verification: {config['verify_ssl']}")
    print("✅ Configuration loaded")
    print()
    
    # Configure GDM to show user list if GDM is installed
    print("🔍 Checking for GDM (GNOME Display Manager)...")
    gdm_configured = configure_gdm_user_list()
    if gdm_configured:
        print("✅ GDM configured to show user list on login screen")
        print("   Configuration file: /etc/dconf/db/gdm.d/00-show-user-list")
        print("   ⚠️  You may need to restart GDM: sudo systemctl restart gdm")
    else:
        print("ℹ️  GDM configuration skipped (GDM may not be installed or dconf unavailable)")
    print()
    
    # Initialize GroupSync if available
    group_sync = None
    if GroupSync:
        try:
            group_sync = GroupSync(config['config_file'])
        except Exception as e:
            print(f"⚠️  WARNING: Could not initialize GroupSync: {e}")
    
    # Get admin credentials
    if args.admin_user:
        admin_username = args.admin_user
    else:
        admin_username = input("Nextcloud admin username: ").strip()
    
    if not admin_username:
        print("❌ ERROR: Admin username is required")
        return 1
    
    admin_password = getpass.getpass("Nextcloud admin password: ")
    if not admin_password:
        print("❌ ERROR: Admin password is required")
        return 1
    
    # Handle different sync modes
    if args.sync_all_groups:
        # Sync all groups that exist on both systems
        print()
        print("🔍 Retrieving groups from Nextcloud and local system...")
        print()
        
        nextcloud_groups = get_all_nextcloud_groups(admin_username, admin_password, config)
        local_groups = get_local_groups()
        local_groups_set = set(local_groups)
        
        if not group_sync:
            print("⚠️  WARNING: GroupSync not available, cannot sync groups")
            return 1
        
        # Find groups that exist on both systems (considering mapping)
        common_groups = []
        for nc_group in nextcloud_groups:
            # Get mapped Linux groups
            linux_groups = group_sync._get_mapped_groups(nc_group)
            
            # Check if any mapped group exists locally
            for linux_group in linux_groups:
                if linux_group in local_groups_set:
                    common_groups.append((nc_group, linux_group))
                    break
        
        if not common_groups:
            print("⚠️  No common groups found between Nextcloud and local system")
            return 0
        
        print(f"✅ Found {len(common_groups)} common group(s)")
        print()
        
        synced_count = 0
        for nc_group, linux_group in sorted(common_groups):
            print(f"Syncing group: {nc_group} -> {linux_group}")
            
            # Get members from Nextcloud
            nextcloud_members = get_group_members(admin_username, admin_password, nc_group, config)
            
            if args.dry_run:
                local_members = set(get_local_group_members(linux_group))
                nextcloud_members_set = set(nextcloud_members)
                users_to_add = nextcloud_members_set - local_members
                users_to_remove = local_members - nextcloud_members_set
                
                if users_to_add:
                    print(f"  [DRY RUN] Would add: {', '.join(sorted(users_to_add))}")
                if users_to_remove:
                    print(f"  [DRY RUN] Would remove: {', '.join(sorted(users_to_remove))}")
                if not users_to_add and not users_to_remove:
                    print(f"  [DRY RUN] Group membership already synchronized")
            else:
                if sync_group_membership(nc_group, nextcloud_members, config, group_sync):
                    synced_count += 1
            print()
        
        print("=" * 70)
        print("Summary")
        print("=" * 70)
        if args.dry_run:
            print(f"  [DRY RUN] Would sync {len(common_groups)} group(s)")
        else:
            print(f"  Synced: {synced_count}")
            print(f"  Total common groups: {len(common_groups)}")
        print()
        
        return 0
    
    elif args.user:
        # Sync groups for a specific user
        print(f"🔍 Syncing groups for user: {args.user}")
        print()
        
        if not user_exists(args.user):
            print(f"❌ ERROR: User '{args.user}' does not exist locally")
            return 1
        
        user_groups = get_user_groups(admin_username, admin_password, args.user, config)
        
        if not user_groups:
            print(f"⚠️  No groups found for user '{args.user}' in Nextcloud")
            return 0
        
        if args.dry_run:
            print(f"  [DRY RUN] Would sync groups: {', '.join(user_groups)}")
        elif group_sync:
            if group_sync.sync_groups(args.user, user_groups):
                print(f"✅ Synced groups for user '{args.user}'")
            else:
                print(f"⚠️  Some errors occurred while syncing groups")
        else:
            print(f"⚠️  GroupSync not available, cannot sync groups")
        
        return 0
    
    else:
        # Default mode: Provision users from a group, then sync all common groups
        if args.group:
            group_name = args.group
        else:
            group_name = input("Nextcloud group name: ").strip()
        
        if not group_name:
            print("❌ ERROR: Group name is required")
            return 1
        
        print()
        print(f"🔍 Retrieving members of group '{group_name}' from {config['url']}...")
        print()
        
        # Get group members
        group_members = get_group_members(admin_username, admin_password, group_name, config)
        
        if group_members is None:
            print("❌ Failed to retrieve group members")
            return 1
        
        if not group_members:
            print(f"⚠️  Group '{group_name}' has no members")
            return 0
        
        print(f"✅ Found {len(group_members)} member(s) in group '{group_name}':")
        print()
        
        # Provision users
        created_count = 0
        skipped_count = 0
        failed_count = 0
        
        for username in sorted(group_members):
            print(f"Processing: {username}")
            
            if user_exists(username):
                print(f"  ℹ️  User '{username}' already exists, skipping creation")
                # Lock local password if user exists (they should use Nextcloud auth)
                if not args.dry_run:
                    if lock_local_password(username):
                        print(f"  🔒 Locked local password for '{username}' (must use Nextcloud credentials)")
                    else:
                        print(f"  ⚠️  Warning: Could not lock local password for '{username}'")
                        print(f"     User may need to run 'passwd -l {username}' manually")
                    # Ensure AccountsService entry exists
                    ensure_accounts_service_entry(username)
                skipped_count += 1
            else:
                # Get user display name from Nextcloud
                display_name = None
                if not args.dry_run:
                    user_details = get_user_details(admin_username, admin_password, username, config)
                    display_name = user_details.get('display_name')
                    if display_name:
                        print(f"  📝 Found display name: {display_name}")
                    else:
                        print(f"  ⚠️  Could not retrieve display name for '{username}' (will use default)")
                
                if args.dry_run:
                    print(f"  [DRY RUN] Would create user '{username}'")
                    if display_name:
                        print(f"  [DRY RUN] Would use display name: {display_name}")
                    created_count += 1
                else:
                    if create_user(username, display_name=display_name, create_home=not args.no_create_home):
                        created_count += 1
                    else:
                        failed_count += 1
            print()
        
        # User provisioning summary
        print("=" * 70)
        print("User Provisioning Summary")
        print("=" * 70)
        print(f"  Total members in group: {len(group_members)}")
        if args.dry_run:
            print(f"  Would create: {created_count}")
        else:
            print(f"  Created: {created_count}")
        print(f"  Already existed: {skipped_count}")
        if not args.dry_run:
            print(f"  Failed: {failed_count}")
        print()
        
        if args.dry_run and created_count > 0:
            print("⚠️  This was a dry run - no users were actually created")
            print("   Run without --dry-run to create users and sync groups")
            return 0
        
        # Now sync all groups that exist on both systems
        if not group_sync:
            print("⚠️  WARNING: GroupSync not available, cannot sync groups")
            print()
            if created_count > 0:
                print("✅ User provisioning completed!")
                print()
                print("⚠️  IMPORTANT: Users were created without passwords.")
                print("   Users should authenticate using their Nextcloud credentials.")
                print("   Make sure PAM is configured to use pam_nextcloud for authentication.")
            return 0 if failed_count == 0 else 1
        
        print("=" * 70)
        print("Group Synchronization")
        print("=" * 70)
        print()
        print("🔍 Retrieving groups from Nextcloud and local system...")
        print()
        
        # Get all groups from both systems
        nextcloud_groups = get_all_nextcloud_groups(admin_username, admin_password, config)
        local_groups = get_local_groups()
        local_groups_set = set(local_groups)
        
        # Find groups that exist on both systems (considering mapping)
        common_groups = []
        for nc_group in nextcloud_groups:
            # Get mapped Linux groups
            linux_groups = group_sync._get_mapped_groups(nc_group)
            
            # Check if any mapped group exists locally
            for linux_group in linux_groups:
                if linux_group in local_groups_set:
                    common_groups.append((nc_group, linux_group))
                    break
        
        if not common_groups:
            print("⚠️  No common groups found between Nextcloud and local system")
            print()
            if created_count > 0:
                print("✅ User provisioning completed!")
                print()
                print("⚠️  IMPORTANT: Users were created without passwords.")
                print("   Users should authenticate using their Nextcloud credentials.")
                print("   Make sure PAM is configured to use pam_nextcloud for authentication.")
            return 0 if failed_count == 0 else 1
        
        print(f"✅ Found {len(common_groups)} common group(s)")
        print()
        
        # Sync each common group
        synced_count = 0
        total_added = 0
        total_removed = 0
        
        for nc_group, linux_group in sorted(common_groups):
            print(f"Syncing group: {nc_group} -> {linux_group}")
            
            # Get members from Nextcloud
            nextcloud_members = get_group_members(admin_username, admin_password, nc_group, config)
            
            # Get local group members
            local_members = set(get_local_group_members(linux_group))
            nextcloud_members_set = set(nextcloud_members)
            
            # Only sync users that exist on both systems
            # Filter to only users that exist locally
            nextcloud_members_local = {u for u in nextcloud_members_set if user_exists(u)}
            
            # Find users to add and remove
            users_to_add = nextcloud_members_local - local_members
            users_to_remove = local_members & {u for u in local_members if user_exists(u)} - nextcloud_members_local
            
            if args.dry_run:
                if users_to_add:
                    print(f"  [DRY RUN] Would add: {', '.join(sorted(users_to_add))}")
                if users_to_remove:
                    print(f"  [DRY RUN] Would remove: {', '.join(sorted(users_to_remove))}")
                if not users_to_add and not users_to_remove:
                    print(f"  [DRY RUN] Group membership already synchronized")
            else:
                changes_made = False
                
                # Add users to group
                for username in users_to_add:
                    if group_sync._add_user_to_group(username, linux_group):
                        print(f"  ✅ Added '{username}' to group '{linux_group}'")
                        total_added += 1
                        changes_made = True
                    else:
                        print(f"  ❌ Failed to add '{username}' to group '{linux_group}'")
                
                # Remove users from group
                for username in users_to_remove:
                    result = subprocess.run(
                        ['gpasswd', '-d', username, linux_group],
                        capture_output=True,
                        text=True,
                        check=False
                    )
                    
                    if result.returncode == 0:
                        print(f"  ✅ Removed '{username}' from group '{linux_group}'")
                        total_removed += 1
                        changes_made = True
                    else:
                        print(f"  ⚠️  Failed to remove '{username}' from group '{linux_group}': {result.stderr.strip()}")
                
                if changes_made:
                    synced_count += 1
                else:
                    print(f"  ℹ️  Group membership already synchronized")
            print()
        
        # Final summary
        print("=" * 70)
        print("Summary")
        print("=" * 70)
        print(f"  Users provisioned:")
        print(f"    Created: {created_count}")
        print(f"    Already existed: {skipped_count}")
        if not args.dry_run:
            print(f"    Failed: {failed_count}")
        print()
        print(f"  Group synchronization:")
        if args.dry_run:
            print(f"    [DRY RUN] Would sync {len(common_groups)} group(s)")
        else:
            print(f"    Synced: {synced_count} group(s)")
            print(f"    Users added to groups: {total_added}")
            print(f"    Users removed from groups: {total_removed}")
            print(f"    Total common groups: {len(common_groups)}")
        print()
        
        if args.dry_run:
            print("⚠️  This was a dry run - no changes were made")
            print("   Run without --dry-run to apply changes")
        elif created_count > 0:
            print("✅ User provisioning completed!")
            print()
            print("⚠️  IMPORTANT: Users were created without passwords.")
            print("   Users should authenticate using their Nextcloud credentials.")
            print("   Make sure PAM is configured to use pam_nextcloud for authentication.")
        
        return 0 if failed_count == 0 else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print()
        print("❌ Interrupted by user")
        sys.exit(130)
    except Exception as e:
        print(f"❌ FATAL ERROR: {type(e).__name__}: {str(e)}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

