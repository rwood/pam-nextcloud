#!/usr/bin/env python3
"""
Test script for PAM Nextcloud authentication module

This script allows you to test the Nextcloud authentication
without configuring PAM, useful for debugging and verification.

Usage:
    python3 test_nextcloud_auth.py
    python3 test_nextcloud_auth.py --config /path/to/config.conf
    python3 test_nextcloud_auth.py --username john --config /etc/security/pam_nextcloud.conf
"""

import sys
import os
import getpass
import argparse
from pam_nextcloud import NextcloudAuth


def main():
    parser = argparse.ArgumentParser(
        description='Test Nextcloud authentication module'
    )
    parser.add_argument(
        '--config',
        default='/etc/security/pam_nextcloud.conf',
        help='Path to configuration file (default: /etc/security/pam_nextcloud.conf)'
    )
    parser.add_argument(
        '--username',
        help='Username to test (will prompt if not provided)'
    )
    parser.add_argument(
        '--password',
        help='Password to test (NOT RECOMMENDED - will prompt if not provided)'
    )
    parser.add_argument(
        '--verbose',
        action='store_true',
        help='Show detailed configuration information'
    )
    parser.add_argument(
        '--change-password',
        action='store_true',
        help='Test password change functionality'
    )
    parser.add_argument(
        '--new-password',
        help='New password for password change test (NOT RECOMMENDED - will prompt if not provided)'
    )
    
    args = parser.parse_args()
    
    # Print header
    print("=" * 70)
    print("PAM Nextcloud Authentication Test")
    print("=" * 70)
    print()
    
    # Check if config file exists
    if not os.path.exists(args.config):
        print(f"❌ ERROR: Configuration file not found: {args.config}")
        print()
        print("Please create the configuration file with your Nextcloud settings.")
        print("Example:")
        print()
        print("  [nextcloud]")
        print("  url = https://cloud.example.com")
        print("  verify_ssl = true")
        print("  timeout = 10")
        print()
        return 1
    
    # Initialize authenticator
    print(f"📁 Loading configuration from: {args.config}")
    auth = NextcloudAuth(args.config)
    
    if args.verbose:
        print(f"   Nextcloud URL: {auth.nextcloud_url}")
        print(f"   SSL Verification: {auth.verify_ssl}")
        print(f"   Timeout: {auth.timeout}s")
    
    if not auth.nextcloud_url:
        print("❌ ERROR: Failed to load configuration")
        return 1
    
    print("✅ Configuration loaded successfully")
    print()
    
    # Get username
    if args.username:
        username = args.username
    else:
        username = input("Username: ")
    
    if not username:
        print("❌ ERROR: Username is required")
        return 1
    
    # Get password
    if args.password:
        password = args.password
        print("⚠️  WARNING: Providing password via command line is insecure!")
    else:
        password = getpass.getpass("Password: ")
    
    if not password:
        print("❌ ERROR: Password is required")
        return 1
    
    print()
    print(f"🔐 Testing authentication for user: {username}")
    print(f"🌐 Connecting to: {auth.nextcloud_url}")
    print()
    
    # Authenticate or change password
    try:
        if args.change_password:
            # Test password change
            print(f"🔄 Testing password change for user: {username}")
            print()
            
            # Get new password
            if args.new_password:
                new_password = args.new_password
                print("⚠️  WARNING: Providing new password via command line is insecure!")
            else:
                new_password = getpass.getpass("New password: ")
                new_password_confirm = getpass.getpass("Retype new password: ")
                
                if new_password != new_password_confirm:
                    print("❌ ERROR: Passwords do not match")
                    return 1
            
            if not new_password:
                print("❌ ERROR: New password is required")
                return 1
            
            print()
            print(f"🌐 Connecting to: {auth.nextcloud_url}")
            print()
            
            result = auth.change_password(username, password, new_password)
            
            if result:
                print("✅ SUCCESS: Password changed successfully!")
                print()
                print(f"Password for user '{username}' has been updated on Nextcloud.")
                print()
                print("⚠️  IMPORTANT: Remember to update your password in any saved locations!")
                return 0
            else:
                print("❌ FAILED: Password change failed")
                print()
                print("Possible reasons:")
                print("  • Incorrect old password")
                print("  • New password doesn't meet Nextcloud's password policy")
                print("  • User doesn't have permission to change password")
                print("  • Nextcloud API access is restricted")
                print()
                print("Check logs for more details")
                return 1
        else:
            # Test authentication
            result = auth.authenticate(username, password)
            
            if result:
                print("✅ SUCCESS: Authentication successful!")
                print()
                print(f"User '{username}' authenticated successfully against Nextcloud.")
                print("The credentials are valid and can be used for PAM authentication.")
                return 0
            else:
                print("❌ FAILED: Authentication failed")
                print()
                print("Possible reasons:")
                print("  • Incorrect username or password")
                print("  • User does not exist in Nextcloud")
                print("  • User account is disabled")
                print("  • Nextcloud API access is restricted")
                print()
                print("Please verify:")
                print(f"  1. Can you login to {auth.nextcloud_url} with these credentials?")
                print("  2. Is the OCS API enabled in Nextcloud?")
                print("  3. Check Nextcloud logs for more details")
                return 1
            
    except KeyboardInterrupt:
        print()
        print("❌ Test interrupted by user")
        return 130
    except Exception as e:
        print(f"❌ ERROR: Unexpected error during authentication")
        print(f"   {type(e).__name__}: {str(e)}")
        print()
        print("This might indicate a problem with:")
        print("  • Network connectivity")
        print("  • SSL certificates")
        print("  • Nextcloud server configuration")
        print("  • Python dependencies (requests library)")
        return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print(f"❌ FATAL ERROR: {type(e).__name__}: {str(e)}")
        sys.exit(1)

