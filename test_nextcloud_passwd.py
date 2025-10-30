#!/usr/bin/env python3
#
# Test script for Nextcloud password change API
#
# This script tests the password change functionality directly against the Nextcloud server
# to help debug issues with password changes not updating on the server.
#
# Usage:
#   python3 test_nextcloud_passwd.py
#   python3 test_nextcloud_passwd.py --username USERNAME --old-password OLD --new-password NEW
#   python3 test_nextcloud_passwd.py --url https://nextcloud.example.com

import sys
import getpass
import argparse
import requests
from urllib.parse import urljoin
import configparser

def load_config(config_path='/etc/security/pam_nextcloud.conf'):
    """Load configuration from PAM config file"""
    config = configparser.ConfigParser()
    try:
        with open(config_path, 'r') as f:
            config.read_file(f)
    except FileNotFoundError:
        print(f"⚠️  Config file not found: {config_path}")
        return None
    except Exception as e:
        print(f"❌ Error reading config: {e}")
        return None
    
    if 'nextcloud' not in config:
        print("❌ No [nextcloud] section in config file")
        return None
    
    return config

def change_password_api(nextcloud_url, username, old_password, new_password, verify_ssl=True, timeout=10):
    """
    Test password change using Nextcloud OCS API
    
    Args:
        nextcloud_url: Base URL of Nextcloud server
        username: Username whose password to change
        old_password: Current password (for authentication)
        new_password: New password to set
        
    Returns:
        tuple: (success: bool, message: str, response: requests.Response or None)
    """
    if not nextcloud_url or not username or not old_password or not new_password:
        return False, "Missing required parameters", None
    
    try:
        # First verify the old password
        print(f"\n🔍 Step 1: Verifying old password...")
        auth_url = urljoin(nextcloud_url, '/ocs/v1.php/cloud/users')
        check_url = urljoin(auth_url + '/', username)
        
        check_response = requests.get(
            check_url,
            auth=(username, old_password),
            headers={'OCS-APIRequest': 'true'},
            verify=verify_ssl,
            timeout=timeout
        )
        
        print(f"   Status code: {check_response.status_code}")
        if check_response.status_code == 200:
            print("   ✅ Old password verified successfully")
        elif check_response.status_code == 401:
            return False, "Old password verification failed (401 Unauthorized)", check_response
        else:
            print(f"   ⚠️  Warning: Unexpected status {check_response.status_code}")
            print(f"   Response: {check_response.text[:200]}")
        
        # Now change the password
        print(f"\n🔧 Step 2: Changing password...")
        api_url = urljoin(nextcloud_url, '/ocs/v1.php/cloud/users')
        user_url = urljoin(api_url + '/', username)
        
        print(f"   URL: {user_url}")
        print(f"   Method: PUT")
        print(f"   Auth: {username} / {'*' * len(old_password)}")
        print(f"   Data: key=password, value={'*' * len(new_password)}")
        
        # Send PUT request to update user password
        response = requests.put(
            user_url,
            auth=(username, old_password),
            headers={
                'OCS-APIRequest': 'true',
                'Content-Type': 'application/x-www-form-urlencoded'
            },
            data={'key': 'password', 'value': new_password},
            verify=verify_ssl,
            timeout=timeout
        )
        
        print(f"\n📊 Response Details:")
        print(f"   Status Code: {response.status_code}")
        print(f"   Headers: {dict(response.headers)}")
        print(f"   Content-Type: {response.headers.get('Content-Type', 'unknown')}")
        
        # Check response
        if response.status_code == 200:
            # Parse XML response to check actual OCS status
            try:
                import xml.etree.ElementTree as ET
                root = ET.fromstring(response.content)
                
                # Find status in meta section
                meta = root.find('meta')
                if meta is not None:
                    status_elem = meta.find('status')
                    statuscode_elem = meta.find('statuscode')
                    message_elem = meta.find('message')
                    
                    status = status_elem.text if status_elem is not None else None
                    statuscode = statuscode_elem.text if statuscode_elem is not None else None
                    message = message_elem.text if message_elem is not None else None
                    
                    print(f"\n📋 OCS XML Response:")
                    print(f"   Status: {status}")
                    print(f"   Status Code: {statuscode}")
                    if message:
                        print(f"   Message: {message}")
                    
                    # Status code 100 means OK, anything else is failure
                    if status == 'ok' or statuscode == '100':
                        print(f"\n✅ SUCCESS: Password changed successfully!")
                        return True, "Password changed successfully", response
                    else:
                        print(f"\n❌ FAILED: Password change rejected by Nextcloud")
                        print(f"   Reason: {message or f'Status code {statuscode}'}")
                        return False, f"Password change failed: {message or f'Status code {statuscode}'}", response
                else:
                    print(f"\n⚠️  WARNING: No meta section in XML response")
                    print(f"   Assuming success (some Nextcloud versions may not return XML)")
                    print(f"\n✅ SUCCESS: Password changed successfully!")
                    return True, "Password changed successfully", response
            except ET.ParseError as e:
                print(f"\n⚠️  WARNING: Could not parse XML response: {e}")
                print(f"   Response body: {response.text[:500]}")
                print(f"   Assuming success since HTTP status is 200")
                print(f"\n✅ SUCCESS: Password changed successfully!")
                return True, "Password changed successfully", response
            except Exception as e:
                print(f"\n❌ ERROR: Unexpected error parsing XML: {e}")
                return False, f"Error parsing XML response: {str(e)}", response
        elif response.status_code == 401:
            print(f"\n❌ FAILED: Unauthorized (401)")
            print(f"   Response: {response.text[:500]}")
            return False, "Password change unauthorized - old password may be incorrect", response
        elif response.status_code == 403:
            print(f"\n❌ FAILED: Forbidden (403)")
            print(f"   Response: {response.text[:500]}")
            return False, "Password change forbidden - user may lack permission", response
        elif response.status_code == 404:
            print(f"\n❌ FAILED: User not found (404)")
            print(f"   Response: {response.text[:500]}")
            return False, "User not found on Nextcloud", response
        else:
            print(f"\n❌ FAILED: Unexpected status code {response.status_code}")
            print(f"   Response: {response.text[:500]}")
            return False, f"Unexpected response code {response.status_code}", response
            
    except requests.exceptions.Timeout:
        return False, f"Timeout connecting to {nextcloud_url}", None
    except requests.exceptions.SSLError as e:
        return False, f"SSL error: {str(e)}", None
    except requests.exceptions.ConnectionError as e:
        return False, f"Connection error: {str(e)}", None
    except Exception as e:
        return False, f"Unexpected error: {str(e)}", None

def main():
    parser = argparse.ArgumentParser(
        description='Test Nextcloud password change API',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Interactive mode
  python3 test_nextcloud_passwd.py

  # With parameters
  python3 test_nextcloud_passwd.py --username alice --old-password oldpass --new-password newpass

  # Custom URL
  python3 test_nextcloud_passwd.py --url https://nextcloud.example.com --username alice
        """
    )
    
    parser.add_argument('--url', help='Nextcloud server URL')
    parser.add_argument('--username', '-u', help='Username to test')
    parser.add_argument('--old-password', help='Current password (not recommended - use prompt)')
    parser.add_argument('--new-password', help='New password (not recommended - use prompt)')
    parser.add_argument('--config', '-c', default='/etc/security/pam_nextcloud.conf',
                       help='Path to PAM config file (default: /etc/security/pam_nextcloud.conf)')
    parser.add_argument('--no-ssl-verify', action='store_true',
                       help='Disable SSL certificate verification')
    parser.add_argument('--timeout', type=int, default=10,
                       help='Request timeout in seconds (default: 10)')
    
    args = parser.parse_args()
    
    print("=" * 70)
    print("Nextcloud Password Change API Test")
    print("=" * 70)
    
    # Load configuration
    config = load_config(args.config)
    
    # Get Nextcloud URL
    nextcloud_url = args.url
    if not nextcloud_url and config:
        nextcloud_url = config.get('nextcloud', 'url', fallback=None)
    
    if not nextcloud_url:
        nextcloud_url = input("Nextcloud server URL: ").strip()
    
    if not nextcloud_url:
        print("❌ Nextcloud URL is required")
        sys.exit(1)
    
    # Ensure URL has protocol
    if not nextcloud_url.startswith(('http://', 'https://')):
        nextcloud_url = 'https://' + nextcloud_url
    
    print(f"\n📁 Server URL: {nextcloud_url}")
    
    # Get SSL verification setting
    verify_ssl = not args.no_ssl_verify
    if config and config.has_option('nextcloud', 'verify_ssl'):
        verify_ssl = config.getboolean('nextcloud', 'verify_ssl')
    
    if not verify_ssl:
        print("⚠️  SSL verification disabled")
    
    # Get username
    username = args.username
    if not username:
        username = input("Username: ").strip()
    
    if not username:
        print("❌ Username is required")
        sys.exit(1)
    
    print(f"👤 Username: {username}")
    
    # Get old password
    old_password = args.old_password
    if not old_password:
        old_password = getpass.getpass("Current password: ")
    
    if not old_password:
        print("❌ Old password is required")
        sys.exit(1)
    
    # Get new password
    new_password = args.new_password
    if not new_password:
        new_password = getpass.getpass("New password: ")
    
    if not new_password:
        print("❌ New password is required")
        sys.exit(1)
    
    # Confirm new password
    if not args.new_password:
        new_password_confirm = getpass.getpass("Retype new password: ")
        if new_password != new_password_confirm:
            print("❌ Passwords do not match")
            sys.exit(1)
    
    # Get timeout
    timeout = args.timeout
    if config and config.has_option('nextcloud', 'timeout'):
        timeout = config.getint('nextcloud', 'timeout', fallback=timeout)
    
    print(f"\n🔐 Testing password change...")
    print(f"   Old password length: {len(old_password)}")
    print(f"   New password length: {len(new_password)}")
    
    # Test password change
    success, message, response = change_password_api(
        nextcloud_url, username, old_password, new_password,
        verify_ssl=verify_ssl, timeout=timeout
    )
    
    print("\n" + "=" * 70)
    if success:
        print("✅ TEST PASSED")
        print(f"   {message}")
    else:
        print("❌ TEST FAILED")
        print(f"   {message}")
        if response is not None:
            print(f"\n💡 Troubleshooting:")
            print(f"   • Check if the user has permission to change their own password")
            print(f"   • Verify the Nextcloud server supports password changes via OCS API")
            print(f"   • Check Nextcloud server logs for more details")
            print(f"   • Ensure the user account is not disabled")
    print("=" * 70)
    
    sys.exit(0 if success else 1)

if __name__ == '__main__':
    main()

