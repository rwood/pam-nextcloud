#!/usr/bin/env python3
"""
Nextcloud Group User Provisioning Script

This script connects to Nextcloud as an admin user, retrieves members of a group,
and creates local Linux user accounts for any members that don't already exist.

Usage:
    sudo ./provision-nextcloud-users.py
    sudo ./provision-nextcloud-users.py --group GROUP_NAME
    sudo ./provision-nextcloud-users.py --config /path/to/config.conf
"""

import sys
import os
import getpass
import argparse
import subprocess
import requests
import configparser
import xml.etree.ElementTree as ET
from urllib.parse import urljoin

# Try to import pwd for user checking
try:
    import pwd
except ImportError:
    pwd = None


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
        'timeout': timeout
    }


def get_group_members(admin_username, admin_password, group_name, config):
    """
    Get list of users in a Nextcloud group using admin API
    
    Args:
        admin_username: Admin username for authentication
        admin_password: Admin password
        group_name: Name of the group
        config: Configuration dict with url, verify_ssl, timeout
        
    Returns:
        list: List of usernames in the group, or None on error
    """
    try:
        # Nextcloud Admin API endpoint for group members
        # Use /ocs/v2.php/cloud/groups/{groupid}/users endpoint
        api_url = urljoin(config['url'], f'/ocs/v2.php/cloud/groups/{group_name}/users')
        
        # Request JSON format
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
                # Try JSON format first
                data = response.json()
                if 'ocs' in data and 'data' in data['ocs']:
                    users_data = data['ocs']['data'].get('users', {})
                    
                    # Handle different response formats
                    if isinstance(users_data, list):
                        users = users_data
                    elif isinstance(users_data, dict) and 'element' in users_data:
                        element = users_data['element']
                        users = element if isinstance(element, list) else [element]
                    elif isinstance(users_data, str):
                        users = [users_data] if users_data else []
            except (ValueError, KeyError):
                pass
            
            # Try XML format if JSON didn't work
            if not users:
                try:
                    root = ET.fromstring(response.content)
                    users = []
                    # Look for users in the response
                    for element in root.findall('.//data/users/element'):
                        if element.text:
                            users.append(element.text)
                except ET.ParseError:
                    pass
            
            # If we successfully parsed users, return them
            if users is not None:
                return users
            
            # If we got here, we couldn't parse the response
            # Try fallback method
            print(f"  ⚠️  Could not parse group members response, trying alternative method...")
            use_fallback = True
        else:
            # Non-200 status code, use fallback
            use_fallback = True
            print(f"  ⚠️  Direct group endpoint failed (status {response.status_code}), trying alternative method...")
        
        # Fallback: Get all users and check their groups
        if use_fallback:
            
            # Get all users
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
                # Get all users and filter by group membership
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
                
                # Check each user's groups
                group_members = []
                print(f"  ℹ️  Checking {len(all_users)} users for group membership...")
                for user in all_users:
                    user_groups = get_user_groups(admin_username, admin_password, user, config)
                    if user_groups and group_name in user_groups:
                        group_members.append(user)
                return group_members
        
        elif response.status_code == 404:
            print(f"❌ ERROR: Group '{group_name}' not found on Nextcloud")
            return None
        elif response.status_code == 401:
            print(f"❌ ERROR: Authentication failed - check admin credentials")
            return None
        elif response.status_code == 403:
            print(f"❌ ERROR: Admin user does not have permission to access groups")
            return None
        else:
            print(f"❌ ERROR: Unexpected response code {response.status_code}")
            print(f"   Response: {response.text[:200]}")
            return None
            
    except requests.exceptions.Timeout:
        print(f"❌ ERROR: Timeout connecting to {config['url']}")
        return None
    except requests.exceptions.SSLError as e:
        print(f"❌ ERROR: SSL error: {str(e)}")
        return None
    except requests.exceptions.ConnectionError as e:
        print(f"❌ ERROR: Connection error: {str(e)}")
        return None
    except Exception as e:
        print(f"❌ ERROR: Unexpected error: {str(e)}")
        import traceback
        traceback.print_exc()
        return None


def get_user_groups(admin_username, admin_password, username, config):
    """
    Get list of groups a user belongs to using admin API
    
    Args:
        admin_username: Admin username for authentication
        admin_password: Admin password
        username: Username to query
        config: Configuration dict
        
    Returns:
        list: List of group names, or None on error
    """
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
                # Try XML
                root = ET.fromstring(response.content)
                groups = []
                for element in root.findall('.//data/groups/element'):
                    if element.text:
                        groups.append(element.text)
                return groups
        return []
    except Exception:
        return []


def user_exists(username):
    """Check if a local user exists"""
    try:
        if pwd:
            pwd.getpwnam(username)
            return True
        else:
            # Fallback: use getent
            result = subprocess.run(
                ['getent', 'passwd', username],
                capture_output=True,
                check=False
            )
            return result.returncode == 0
    except KeyError:
        return False
    except Exception:
        return False


def create_user(username, create_home=True):
    """
    Create a local Linux user account
    
    Args:
        username: Username to create
        create_home: Whether to create home directory
        
    Returns:
        bool: True if successful, False otherwise
    """
    try:
        # Check if user already exists
        if user_exists(username):
            print(f"  ℹ️  User '{username}' already exists, skipping")
            return True
        
        # Build useradd command
        cmd = ['useradd']
        
        if create_home:
            cmd.append('-m')  # Create home directory
        
        cmd.extend([
            '-s', '/bin/bash',  # Default shell
            '-c', f'Nextcloud user: {username}',  # Comment
            username
        ])
        
        # Run useradd
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
        
        if result.returncode == 0:
            print(f"  ✅ Created user '{username}'")
            if create_home:
                print(f"     Home directory: /home/{username}")
            return True
        else:
            print(f"  ❌ Failed to create user '{username}': {result.stderr.strip()}")
            return False
            
    except Exception as e:
        print(f"  ❌ Error creating user '{username}': {str(e)}")
        return False


def main():
    parser = argparse.ArgumentParser(
        description='Provision local Linux users from Nextcloud group members'
    )
    parser.add_argument(
        '--config',
        default='/etc/security/pam_nextcloud.conf',
        help='Path to configuration file (default: /etc/security/pam_nextcloud.conf)'
    )
    parser.add_argument(
        '--group',
        help='Nextcloud group name (will prompt if not provided)'
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
        help='Show what would be done without actually creating users'
    )
    
    args = parser.parse_args()
    
    # Check if running as root
    if os.geteuid() != 0:
        print("❌ ERROR: This script must be run as root (use sudo)")
        print()
        print("User creation requires root privileges.")
        return 1
    
    print("=" * 70)
    print("Nextcloud Group User Provisioning")
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
    
    # Get group name
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
    
    # Process each user
    created_count = 0
    skipped_count = 0
    failed_count = 0
    
    for username in sorted(group_members):
        print(f"Processing: {username}")
        
        if user_exists(username):
            print(f"  ℹ️  User '{username}' already exists, skipping")
            skipped_count += 1
        else:
            if args.dry_run:
                print(f"  [DRY RUN] Would create user '{username}'")
                if not args.no_create_home:
                    print(f"  [DRY RUN] Would create home directory: /home/{username}")
                created_count += 1
            else:
                if create_user(username, create_home=not args.no_create_home):
                    created_count += 1
                else:
                    failed_count += 1
        print()
    
    # Summary
    print("=" * 70)
    print("Summary")
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
    
    if args.dry_run:
        print("⚠️  This was a dry run - no users were actually created")
        print("   Run without --dry-run to create users")
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

