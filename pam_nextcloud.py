#!/usr/bin/env python3
"""
PAM Nextcloud Authentication Module

This PAM module authenticates users against a Nextcloud server using the
Nextcloud API. It verifies username and password credentials through HTTP
Basic Authentication against the Nextcloud OCS API.

Features:
    - User authentication against Nextcloud
    - Password change support (users can change their own passwords)
    - Offline authentication with secure password caching (7-day expiry)
    - SSL verification with configurable options
    - Timeout protection
    - Comprehensive syslog logging

Configuration:
    Create /etc/security/pam_nextcloud.conf with the following format:
    
    [nextcloud]
    url = https://cloud.example.com
    verify_ssl = true
    timeout = 10
    
Author: PAM-Nextcloud Module
License: MIT
"""

import sys
import syslog
import configparser
import requests
from urllib.parse import urljoin
import os
import hashlib
import json
import time
from datetime import datetime, timedelta
import pwd


class NextcloudAuth:
    """Handles authentication against Nextcloud server"""
    
    def __init__(self, config_path='/etc/security/pam_nextcloud.conf'):
        """
        Initialize Nextcloud authentication handler
        
        Args:
            config_path: Path to configuration file
        """
        self.config_path = config_path
        self.nextcloud_url = None
        self.verify_ssl = True
        self.timeout = 10
        self.enable_cache = False
        self.cache_expiry_days = 7
        self.cache_directory = '/var/cache/pam_nextcloud'
        self.load_config()
    
    def load_config(self):
        """Load configuration from file"""
        try:
            if not os.path.exists(self.config_path):
                syslog.syslog(syslog.LOG_ERR, 
                    f"pam_nextcloud: Config file not found: {self.config_path}")
                return False
            
            config = configparser.ConfigParser()
            config.read(self.config_path)
            
            if 'nextcloud' not in config:
                syslog.syslog(syslog.LOG_ERR,
                    "pam_nextcloud: [nextcloud] section not found in config")
                return False
            
            self.nextcloud_url = config.get('nextcloud', 'url', fallback=None)
            self.verify_ssl = config.getboolean('nextcloud', 'verify_ssl', fallback=True)
            self.timeout = config.getint('nextcloud', 'timeout', fallback=10)
            self.enable_cache = config.getboolean('nextcloud', 'enable_cache', fallback=False)
            self.cache_expiry_days = config.getint('nextcloud', 'cache_expiry_days', fallback=7)
            self.cache_directory = config.get('nextcloud', 'cache_directory', fallback='/var/cache/pam_nextcloud')
            
            if not self.nextcloud_url:
                syslog.syslog(syslog.LOG_ERR,
                    "pam_nextcloud: Nextcloud URL not configured")
                return False
            
            # Create cache directory if caching is enabled
            if self.enable_cache:
                self._ensure_cache_directory()
            
            syslog.syslog(syslog.LOG_INFO,
                f"pam_nextcloud: Loaded config - URL: {self.nextcloud_url}, Cache: {self.enable_cache}")
            return True
            
        except Exception as e:
            syslog.syslog(syslog.LOG_ERR,
                f"pam_nextcloud: Error loading config: {str(e)}")
            return False
    
    def _ensure_cache_directory(self):
        """Create cache directory with secure permissions if it doesn't exist"""
        try:
            if not os.path.exists(self.cache_directory):
                os.makedirs(self.cache_directory, mode=0o700)
                syslog.syslog(syslog.LOG_INFO,
                    f"pam_nextcloud: Created cache directory: {self.cache_directory}")
            
            # Ensure directory has correct permissions
            os.chmod(self.cache_directory, 0o700)
            
        except Exception as e:
            syslog.syslog(syslog.LOG_ERR,
                f"pam_nextcloud: Error creating cache directory: {str(e)}")
            self.enable_cache = False
    
    def _get_cache_file_path(self, username):
        """
        Get the cache file path for a username
        
        Args:
            username: Username
            
        Returns:
            str: Full path to cache file
        """
        # Use hash of username for filename to avoid path traversal issues
        username_hash = hashlib.sha256(username.encode()).hexdigest()
        return os.path.join(self.cache_directory, f"{username_hash}.cache")
    
    def _hash_password(self, password, salt):
        """
        Securely hash a password with salt using PBKDF2
        
        Args:
            password: Password to hash
            salt: Salt bytes
            
        Returns:
            str: Hex-encoded hash
        """
        # Use PBKDF2-HMAC-SHA256 with 100,000 iterations
        # This is computationally expensive to prevent brute force
        key = hashlib.pbkdf2_hmac('sha256', password.encode(), salt, 100000)
        return key.hex()
    
    def _cache_password(self, username, password):
        """
        Cache a hashed password for offline authentication
        
        Args:
            username: Username
            password: Password to cache (will be hashed)
        """
        if not self.enable_cache:
            return
        
        try:
            # Generate random salt
            salt = os.urandom(32)
            
            # Hash the password
            password_hash = self._hash_password(password, salt)
            
            # Create cache entry
            cache_data = {
                'username': username,
                'password_hash': password_hash,
                'salt': salt.hex(),
                'timestamp': time.time(),
                'created': datetime.now().isoformat()
            }
            
            # Write to cache file
            cache_file = self._get_cache_file_path(username)
            with open(cache_file, 'w') as f:
                json.dump(cache_data, f)
            
            # Set secure permissions (owner read/write only)
            os.chmod(cache_file, 0o600)
            
            syslog.syslog(syslog.LOG_DEBUG,
                f"pam_nextcloud: Cached credentials for user: {username}")
            
        except Exception as e:
            syslog.syslog(syslog.LOG_ERR,
                f"pam_nextcloud: Error caching password: {str(e)}")
    
    def _is_cache_expired(self, timestamp):
        """
        Check if a cache entry has expired
        
        Args:
            timestamp: Unix timestamp of cache creation
            
        Returns:
            bool: True if expired, False if still valid
        """
        if self.cache_expiry_days == 0:
            # 0 means never expire
            return False
        
        expiry_time = timestamp + (self.cache_expiry_days * 24 * 3600)
        return time.time() > expiry_time
    
    def _validate_cached_password(self, username, password):
        """
        Validate password against cached hash
        
        Args:
            username: Username
            password: Password to validate
            
        Returns:
            bool: True if password matches cache and not expired, False otherwise
        """
        if not self.enable_cache:
            return False
        
        try:
            cache_file = self._get_cache_file_path(username)
            
            if not os.path.exists(cache_file):
                return False
            
            # Read cache file
            with open(cache_file, 'r') as f:
                cache_data = json.load(f)
            
            # Check if cache has expired
            if self._is_cache_expired(cache_data['timestamp']):
                syslog.syslog(syslog.LOG_INFO,
                    f"pam_nextcloud: Cached credentials expired for user: {username}")
                # Delete expired cache
                os.remove(cache_file)
                return False
            
            # Verify username matches (extra security check)
            if cache_data['username'] != username:
                syslog.syslog(syslog.LOG_WARNING,
                    f"pam_nextcloud: Cache username mismatch for: {username}")
                return False
            
            # Hash the provided password with the stored salt
            salt = bytes.fromhex(cache_data['salt'])
            password_hash = self._hash_password(password, salt)
            
            # Compare hashes
            if password_hash == cache_data['password_hash']:
                cache_age_days = (time.time() - cache_data['timestamp']) / (24 * 3600)
                syslog.syslog(syslog.LOG_INFO,
                    f"pam_nextcloud: Cached authentication successful for user: {username} "
                    f"(cache age: {cache_age_days:.1f} days)")
                return True
            else:
                return False
                
        except Exception as e:
            syslog.syslog(syslog.LOG_ERR,
                f"pam_nextcloud: Error validating cached password: {str(e)}")
            return False
    
    def authenticate(self, username, password):
        """
        Authenticate user against Nextcloud server
        
        Args:
            username: Username to authenticate
            password: Password to verify
            
        Returns:
            bool: True if authentication successful, False otherwise
        """
        if not self.nextcloud_url:
            syslog.syslog(syslog.LOG_ERR,
                "pam_nextcloud: Cannot authenticate - not configured")
            return False
        
        if not username or not password:
            syslog.syslog(syslog.LOG_WARNING,
                "pam_nextcloud: Empty username or password")
            return False
        
        # Flag to track if we should try cache
        try_cache = False
        
        try:
            # Use Nextcloud OCS API self endpoint to verify credentials
            # This works with regular user credentials (no admin required)
            api_url = urljoin(self.nextcloud_url, '/ocs/v2.php/cloud/user')
            
            response = requests.get(
                api_url,
                auth=(username, password),
                headers={
                    'OCS-APIRequest': 'true',
                    'Accept': 'application/json'
                },
                verify=self.verify_ssl,
                timeout=self.timeout
            )
            
            # Nextcloud returns 200 OK with valid credentials
            # and 401 Unauthorized with invalid credentials
            if response.status_code == 200:
                syslog.syslog(syslog.LOG_INFO,
                    f"pam_nextcloud: Authentication successful for user: {username}")
                
                # Cache password on successful authentication
                if self.enable_cache:
                    self._cache_password(username, password)
                
                return True
            elif response.status_code == 401:
                syslog.syslog(syslog.LOG_WARNING,
                    f"pam_nextcloud: Authentication failed for user: {username}")
                # Don't try cache - password is wrong on server
                return False
            else:
                syslog.syslog(syslog.LOG_ERR,
                    f"pam_nextcloud: Unexpected response code {response.status_code} from self endpoint for user: {username}")
                # Server error - try cache
                try_cache = True
                
        except requests.exceptions.Timeout:
            syslog.syslog(syslog.LOG_WARNING,
                f"pam_nextcloud: Timeout connecting to {self.nextcloud_url}")
            # Server unavailable - try cache
            try_cache = True
        except requests.exceptions.SSLError as e:
            syslog.syslog(syslog.LOG_WARNING,
                f"pam_nextcloud: SSL error: {str(e)}")
            # Server unavailable - try cache
            try_cache = True
        except requests.exceptions.ConnectionError as e:
            syslog.syslog(syslog.LOG_WARNING,
                f"pam_nextcloud: Connection error: {str(e)}")
            # Server unavailable - try cache
            try_cache = True
        except Exception as e:
            syslog.syslog(syslog.LOG_ERR,
                f"pam_nextcloud: Unexpected error: {str(e)}")
            # Unknown error - try cache
            try_cache = True
        
        # Try cached authentication if Nextcloud is unavailable
        if try_cache and self.enable_cache:
            syslog.syslog(syslog.LOG_INFO,
                f"pam_nextcloud: Attempting cached authentication for user: {username}")
            if self._validate_cached_password(username, password):
                return True
            else:
                syslog.syslog(syslog.LOG_WARNING,
                    f"pam_nextcloud: Cached authentication failed for user: {username}")
        
        return False
    
    def change_password(self, username, old_password, new_password):
        """
        Change user password on Nextcloud server
        
        This method authenticates with the old password and updates to the new password.
        The user must successfully authenticate with the old password first.
        
        Args:
            username: Username whose password to change
            old_password: Current password (for authentication)
            new_password: New password to set
            
        Returns:
            bool: True if password change successful, False otherwise
        """
        if not self.nextcloud_url:
            syslog.syslog(syslog.LOG_ERR,
                "pam_nextcloud: Cannot change password - not configured")
            return False
        
        if not username or not old_password or not new_password:
            syslog.syslog(syslog.LOG_WARNING,
                "pam_nextcloud: Empty username or password")
            return False
        
        # First verify the old password
        if not self.authenticate(username, old_password):
            syslog.syslog(syslog.LOG_WARNING,
                f"pam_nextcloud: Password change failed - invalid old password for user: {username}")
            return False
        
        try:
            # Use Nextcloud OCS API to update password
            api_url = urljoin(self.nextcloud_url, '/ocs/v1.php/cloud/users')
            user_url = urljoin(api_url + '/', username)
            
            # Send PUT request to update user password
            # User authenticates with old password to change to new password
            response = requests.put(
                user_url,
                auth=(username, old_password),
                headers={
                    'OCS-APIRequest': 'true',
                    'Content-Type': 'application/x-www-form-urlencoded'
                },
                data={'key': 'password', 'value': new_password},
                verify=self.verify_ssl,
                timeout=self.timeout
            )
            
            # Nextcloud returns 200 OK on successful password change
            # But we need to check the OCS XML response for the actual status
            syslog.syslog(syslog.LOG_INFO,
                f"pam_nextcloud: Password change API response status: {response.status_code}")
            
            if response.status_code == 200:
                # Parse XML response to check actual status
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
                        
                        # Status code 100 means OK, anything else is failure
                        if status == 'ok' or statuscode == '100':
                            syslog.syslog(syslog.LOG_INFO,
                                f"pam_nextcloud: Password changed successfully for user: {username}")
                            
                            # Update cache with new password
                            if self.enable_cache:
                                self._cache_password(username, new_password)
                            
                            return True
                        else:
                            # Password change failed due to validation or other reason
                            error_msg = f"Password change failed: {message or f'Status code {statuscode}'}"
                            syslog.syslog(syslog.LOG_WARNING,
                                f"pam_nextcloud: {error_msg} for user: {username}")
                            syslog.syslog(syslog.LOG_INFO,
                                f"pam_nextcloud: XML response: {response.text[:500]}")
                            return False
                    else:
                        # No meta section found, assume success (some Nextcloud versions may not return XML)
                        syslog.syslog(syslog.LOG_INFO,
                            f"pam_nextcloud: Password changed successfully for user: {username}")
                        
                        # Update cache with new password
                        if self.enable_cache:
                            self._cache_password(username, new_password)
                        
                        return True
                except ET.ParseError as e:
                    # XML parsing failed - log the response and assume failure to be safe
                    syslog.syslog(syslog.LOG_WARNING,
                        f"pam_nextcloud: Could not parse XML response for password change: {username}")
                    syslog.syslog(syslog.LOG_INFO,
                        f"pam_nextcloud: XML parse error: {str(e)}")
                    syslog.syslog(syslog.LOG_INFO,
                        f"pam_nextcloud: Response body: {response.text[:500]}")
                    # Don't assume success - return False to be safe
                    return False
                except Exception as e:
                    # XML parsing had an unexpected error
                    syslog.syslog(syslog.LOG_ERR,
                        f"pam_nextcloud: Error parsing XML response: {str(e)}")
                    # Still return False to be safe
                    return False
            elif response.status_code == 401:
                syslog.syslog(syslog.LOG_WARNING,
                    f"pam_nextcloud: Password change unauthorized for user: {username}")
                return False
            elif response.status_code == 403:
                syslog.syslog(syslog.LOG_ERR,
                    f"pam_nextcloud: Password change forbidden - user may lack permission: {username}")
                return False
            elif response.status_code == 404:
                syslog.syslog(syslog.LOG_ERR,
                    f"pam_nextcloud: User not found on Nextcloud: {username}")
                return False
            else:
                syslog.syslog(syslog.LOG_ERR,
                    f"pam_nextcloud: Unexpected response code {response.status_code} for password change: {username}")
                return False
                
        except requests.exceptions.Timeout:
            syslog.syslog(syslog.LOG_ERR,
                f"pam_nextcloud: Timeout connecting to {self.nextcloud_url}")
            return False
        except requests.exceptions.SSLError as e:
            syslog.syslog(syslog.LOG_ERR,
                f"pam_nextcloud: SSL error during password change: {str(e)}")
            return False
        except requests.exceptions.ConnectionError as e:
            syslog.syslog(syslog.LOG_ERR,
                f"pam_nextcloud: Connection error during password change: {str(e)}")
            return False
        except Exception as e:
            syslog.syslog(syslog.LOG_ERR,
                f"pam_nextcloud: Unexpected error during password change: {str(e)}")
            return False
    
    def get_user_groups(self, username, password):
        """
        Get list of groups the user belongs to on Nextcloud
        
        Args:
            username: Username to query
            password: Password for authentication
            
        Returns:
            list: List of group names, or None on error
        """
        if not self.nextcloud_url:
            syslog.syslog(syslog.LOG_ERR,
                "pam_nextcloud: Cannot get groups - not configured")
            return None
        
        try:
            # Use Nextcloud OCS API to get user's groups
            api_url = urljoin(self.nextcloud_url, f'/ocs/v1.php/cloud/users/{username}/groups')
            
            response = requests.get(
                api_url,
                auth=(username, password),
                headers={'OCS-APIRequest': 'true'},
                verify=self.verify_ssl,
                timeout=self.timeout
            )
            
            if response.status_code == 200:
                # Parse XML or JSON response
                # Nextcloud returns XML by default, but we can request JSON
                try:
                    # Try JSON format
                    data = response.json()
                    if 'ocs' in data and 'data' in data['ocs']:
                        groups = data['ocs']['data'].get('groups', [])
                        syslog.syslog(syslog.LOG_INFO,
                            f"pam_nextcloud: Retrieved {len(groups)} groups for user: {username}")
                        return groups
                except (ValueError, KeyError):
                    # Try XML format
                    import xml.etree.ElementTree as ET
                    try:
                        root = ET.fromstring(response.content)
                        groups = []
                        for element in root.findall('.//data/groups/element'):
                            if element.text:
                                groups.append(element.text)
                        syslog.syslog(syslog.LOG_INFO,
                            f"pam_nextcloud: Retrieved {len(groups)} groups for user: {username}")
                        return groups
                    except ET.ParseError:
                        syslog.syslog(syslog.LOG_ERR,
                            "pam_nextcloud: Failed to parse groups response")
                        return None
            else:
                syslog.syslog(syslog.LOG_WARNING,
                    f"pam_nextcloud: Failed to get groups, status code: {response.status_code}")
                return None
                
        except requests.exceptions.Timeout:
            syslog.syslog(syslog.LOG_ERR,
                f"pam_nextcloud: Timeout getting groups from {self.nextcloud_url}")
            return None
        except Exception as e:
            syslog.syslog(syslog.LOG_ERR,
                f"pam_nextcloud: Error getting groups: {str(e)}")
            return None


# Global authenticator instance
_authenticator = None


def pam_sm_authenticate(pamh, flags, argv):
    """
    PAM authentication function
    
    This is called by PAM to authenticate a user.
    
    Args:
        pamh: PAM handle
        flags: PAM flags
        argv: Module arguments
        
    Returns:
        int: PAM_SUCCESS on success, PAM_AUTH_ERR on failure
    """
    global _authenticator
    
    try:
        # Initialize syslog
        syslog.openlog("pam_nextcloud", syslog.LOG_PID, syslog.LOG_AUTH)
        
        # Get username
        try:
            username = pamh.get_user(None)
        except pamh.exception as e:
            syslog.syslog(syslog.LOG_ERR,
                f"pam_nextcloud: Error getting username: {str(e)}")
            return pamh.PAM_USER_UNKNOWN
        
        if not username:
            syslog.syslog(syslog.LOG_ERR, "pam_nextcloud: No username provided")
            return pamh.PAM_USER_UNKNOWN
        
        # Get password
        try:
            password = pamh.authtok
            if password is None:
                # Prompt for password if not already provided
                message = pamh.Message(pamh.PAM_PROMPT_ECHO_OFF, "Password: ")
                response = pamh.conversation(message)
                password = response.resp
        except pamh.exception as e:
            syslog.syslog(syslog.LOG_ERR,
                f"pam_nextcloud: Error getting password: {str(e)}")
            return pamh.PAM_AUTH_ERR
        
        if not password:
            syslog.syslog(syslog.LOG_ERR, "pam_nextcloud: No password provided")
            return pamh.PAM_AUTH_ERR
        
        # Parse module arguments for custom config path
        config_path = '/etc/security/pam_nextcloud.conf'
        for arg in argv:
            if arg.startswith('config='):
                config_path = arg.split('=', 1)[1]
        
        # Initialize authenticator
        if _authenticator is None or _authenticator.config_path != config_path:
            _authenticator = NextcloudAuth(config_path)
        
        # Authenticate
        if _authenticator.authenticate(username, password):
            return pamh.PAM_SUCCESS
        else:
            return pamh.PAM_AUTH_ERR
            
    except Exception as e:
        syslog.syslog(syslog.LOG_ERR,
            f"pam_nextcloud: Unexpected error in pam_sm_authenticate: {str(e)}")
        return pamh.PAM_AUTH_ERR
    finally:
        syslog.closelog()


def pam_sm_setcred(pamh, flags, argv):
    """
    PAM credential setting function
    
    This is called to establish/delete/reinitialize credentials.
    We don't need to do anything here for Nextcloud authentication.
    
    Args:
        pamh: PAM handle
        flags: PAM flags
        argv: Module arguments
        
    Returns:
        int: PAM_SUCCESS
    """
    return pamh.PAM_SUCCESS


def pam_sm_acct_mgmt(pamh, flags, argv):
    """
    PAM account management function
    
    This is called to determine if the user's account is valid.
    We accept all authenticated users.
    
    Args:
        pamh: PAM handle
        flags: PAM flags
        argv: Module arguments
        
    Returns:
        int: PAM_SUCCESS
    """
    return pamh.PAM_SUCCESS


def pam_sm_open_session(pamh, flags, argv):
    """
    PAM session opening function
    
    Ensures home directory permissions are correct
    
    Args:
        pamh: PAM handle
        flags: PAM flags
        argv: Module arguments
        
    Returns:
        int: PAM_SUCCESS
    """
    try:
        # Initialize syslog
        syslog.openlog("pam_nextcloud", syslog.LOG_PID, syslog.LOG_AUTH)
        
        # Get username
        try:
            username = pamh.get_user(None)
        except pamh.exception:
            return pamh.PAM_SUCCESS
        
        if not username:
            return pamh.PAM_SUCCESS
        
        # Ensure home directory has correct permissions (safeguard)
        # Note: /etc/skel should handle directory creation for new users
        # This is just a fallback to fix permissions if needed
        try:
            user_info = pwd.getpwnam(username)
            home_dir = user_info.pw_dir
            uid = user_info.pw_uid
            gid = user_info.pw_gid
            
            # Ensure home directory has correct ownership and permissions
            if os.path.exists(home_dir):
                os.chown(home_dir, uid, gid)
                os.chmod(home_dir, 0o755)
                
                # Fix permissions on standard directories if they exist
                # (they should have been created from /etc/skel)
                standard_dirs = [
                    '.config',
                    '.cache',
                    '.local',
                    '.local/share',
                    '.local/state'
                ]
                
                for dir_name in standard_dirs:
                    dir_path = os.path.join(home_dir, dir_name)
                    if os.path.exists(dir_path):
                        os.chown(dir_path, uid, gid)
                        os.chmod(dir_path, 0o755)
        except Exception as e:
            syslog.syslog(syslog.LOG_WARNING,
                f"pam_nextcloud: Could not fix home directory permissions: {str(e)}")
        
    except Exception as e:
        syslog.syslog(syslog.LOG_ERR,
            f"pam_nextcloud: Session error: {str(e)}")
    finally:
        syslog.closelog()
    
    return pamh.PAM_SUCCESS


def pam_sm_close_session(pamh, flags, argv):
    """
    PAM session closing function
    
    Args:
        pamh: PAM handle
        flags: PAM flags
        argv: Module arguments
        
    Returns:
        int: PAM_SUCCESS
    """
    return pamh.PAM_SUCCESS


def pam_sm_chauthtok(pamh, flags, argv):
    """
    PAM password changing function
    
    This function handles password changes by updating the password
    on the Nextcloud server. Users authenticate with their old password
    and set a new one.
    
    PAM calls this function twice:
    1. PAM_PRELIM_CHECK - verify old password and check permissions
    2. PAM_UPDATE_AUTHTOK - actually change the password
    
    Args:
        pamh: PAM handle
        flags: PAM flags (includes PAM_PRELIM_CHECK or PAM_UPDATE_AUTHTOK)
        argv: Module arguments
        
    Returns:
        int: PAM_SUCCESS on success, error code on failure
    """
    global _authenticator
    
    try:
        # Initialize syslog
        syslog.openlog("pam_nextcloud", syslog.LOG_PID, syslog.LOG_AUTH)
        
        # Get username
        try:
            username = pamh.get_user(None)
        except pamh.exception as e:
            syslog.syslog(syslog.LOG_ERR,
                f"pam_nextcloud: Error getting username for password change: {str(e)}")
            return pamh.PAM_USER_UNKNOWN
        
        if not username:
            syslog.syslog(syslog.LOG_ERR,
                "pam_nextcloud: No username provided for password change")
            return pamh.PAM_USER_UNKNOWN
        
        # Parse module arguments for custom config path
        config_path = '/etc/security/pam_nextcloud.conf'
        for arg in argv:
            if arg.startswith('config='):
                config_path = arg.split('=', 1)[1]
        
        # Initialize authenticator
        if _authenticator is None or _authenticator.config_path != config_path:
            _authenticator = NextcloudAuth(config_path)
        
        # PAM_PRELIM_CHECK: Verify old password
        if flags & pamh.PAM_PRELIM_CHECK:
            syslog.syslog(syslog.LOG_INFO,
                f"pam_nextcloud: PAM_PRELIM_CHECK called for user: {username}")
            try:
                # Get old password
                old_password = pamh.authtok
                if old_password is None:
                    # Prompt for old password
                    message = pamh.Message(pamh.PAM_PROMPT_ECHO_OFF, 
                                         "(current) Password: ")
                    response = pamh.conversation(message)
                    old_password = response.resp
                
                if not old_password:
                    syslog.syslog(syslog.LOG_ERR,
                        f"pam_nextcloud: No old password provided for user: {username}")
                    return pamh.PAM_AUTHTOK_ERR
                
                # Verify old password
                if _authenticator.authenticate(username, old_password):
                    # Store old password for UPDATE phase
                    # Try to set oldauthtok directly (if supported by PAM)
                    try:
                        pamh.oldauthtok = old_password
                        syslog.syslog(syslog.LOG_INFO,
                            f"pam_nextcloud: Stored old password in oldauthtok for user: {username}")
                    except AttributeError:
                        # Fallback: store in a temporary file if direct assignment not supported
                        try:
                            import pwd
                            import os
                            user_info = pwd.getpwnam(username)
                            run_dir = f"/run/pam-nextcloud/{user_info.pw_uid}"
                            os.makedirs(run_dir, mode=0o700, exist_ok=True)
                            old_pass_file = os.path.join(run_dir, 'old_password')
                            with open(old_pass_file, 'w') as f:
                                f.write(old_password)
                            os.chmod(old_pass_file, 0o600)
                            syslog.syslog(syslog.LOG_INFO,
                                f"pam_nextcloud: Stored old password in file for user: {username}")
                        except Exception as e:
                            syslog.syslog(syslog.LOG_WARNING,
                                f"pam_nextcloud: Could not store old password: {str(e)}")
                    
                    return pamh.PAM_SUCCESS
                else:
                    syslog.syslog(syslog.LOG_WARNING,
                        f"pam_nextcloud: Old password verification failed for user: {username}")
                    return pamh.PAM_AUTHTOK_ERR
                    
            except pamh.exception as e:
                syslog.syslog(syslog.LOG_ERR,
                    f"pam_nextcloud: Error in prelim check: {str(e)}")
                return pamh.PAM_AUTHTOK_ERR
        
        # PAM_UPDATE_AUTHTOK: Actually change the password
        elif flags & pamh.PAM_UPDATE_AUTHTOK:
            syslog.syslog(syslog.LOG_INFO,
                f"pam_nextcloud: PAM_UPDATE_AUTHTOK called for user: {username}")
            try:
                # Get old password - try multiple sources
                old_password = None
                
                # Try to get from oldauthtok first
                try:
                    old_password = pamh.oldauthtok
                    if old_password:
                        syslog.syslog(syslog.LOG_INFO,
                            f"pam_nextcloud: Retrieved old password from oldauthtok for user: {username}")
                except AttributeError:
                    pass
                
                # If not available, try to read from temporary storage
                if old_password is None:
                    try:
                        import pwd
                        import os
                        user_info = pwd.getpwnam(username)
                        run_dir = f"/run/pam-nextcloud/{user_info.pw_uid}"
                        old_pass_file = os.path.join(run_dir, 'old_password')
                        if os.path.exists(old_pass_file):
                            with open(old_pass_file, 'r') as f:
                                old_password = f.read().strip()
                            # Remove file after reading for security
                            try:
                                os.remove(old_pass_file)
                            except Exception:
                                pass
                            syslog.syslog(syslog.LOG_INFO,
                                f"pam_nextcloud: Retrieved old password from file for user: {username}")
                    except Exception as e:
                        syslog.syslog(syslog.LOG_DEBUG,
                            f"pam_nextcloud: Could not read stored old password: {str(e)}")
                
                if not old_password:
                    syslog.syslog(syslog.LOG_ERR,
                        f"pam_nextcloud: No old password available for user: {username}")
                    return pamh.PAM_AUTHTOK_ERR
                
                # Get new password
                new_password = pamh.authtok
                if new_password is None:
                    # Prompt for new password (with confirmation)
                    message1 = pamh.Message(pamh.PAM_PROMPT_ECHO_OFF, 
                                          "New password: ")
                    response1 = pamh.conversation(message1)
                    new_password = response1.resp
                    
                    message2 = pamh.Message(pamh.PAM_PROMPT_ECHO_OFF,
                                          "Retype new password: ")
                    response2 = pamh.conversation(message2)
                    new_password_confirm = response2.resp
                    
                    if new_password != new_password_confirm:
                        syslog.syslog(syslog.LOG_WARNING,
                            f"pam_nextcloud: Password mismatch for user: {username}")
                        return pamh.PAM_AUTHTOK_ERR
                
                if not new_password:
                    syslog.syslog(syslog.LOG_ERR,
                        f"pam_nextcloud: No new password provided for user: {username}")
                    return pamh.PAM_AUTHTOK_ERR
                
                syslog.syslog(syslog.LOG_INFO,
                    f"pam_nextcloud: Calling change_password API for user: {username}")
                
                # Change password on Nextcloud
                if _authenticator.change_password(username, old_password, new_password):
                    syslog.syslog(syslog.LOG_INFO,
                        f"pam_nextcloud: Password changed successfully for user: {username}")
                    return pamh.PAM_SUCCESS
                else:
                    syslog.syslog(syslog.LOG_ERR,
                        f"pam_nextcloud: Password change failed for user: {username}")
                    return pamh.PAM_AUTHTOK_ERR
                    
            except pamh.exception as e:
                syslog.syslog(syslog.LOG_ERR,
                    f"pam_nextcloud: Error in password update: {str(e)}")
                return pamh.PAM_AUTHTOK_ERR
        
        # Unknown flag
        else:
            syslog.syslog(syslog.LOG_ERR,
                f"pam_nextcloud: Unknown flag in chauthtok: {flags}")
            return pamh.PAM_SERVICE_ERR
            
    except Exception as e:
        syslog.syslog(syslog.LOG_ERR,
            f"pam_nextcloud: Unexpected error in pam_sm_chauthtok: {str(e)}")
        return pamh.PAM_AUTHTOK_ERR
    finally:
        syslog.closelog()


# For testing purposes
if __name__ == "__main__":
    print("PAM Nextcloud Module")
    print("=" * 50)
    print("\nThis module is designed to be loaded by PAM.")
    print("\nFeatures:")
    print("  - Authentication against Nextcloud")
    print("  - Password change support")
    print("  - Offline authentication with secure password caching")
    print("  - Group synchronization (manage sudo access from Nextcloud)")
    print("\nFor testing, you can use the NextcloudAuth class directly:")
    print("\n  auth = NextcloudAuth('/path/to/config')")
    print("  result = auth.authenticate('username', 'password')")
    print("  result = auth.change_password('username', 'old_pass', 'new_pass')")
    print("\nOr use the test script:")
    print("  python3 test_nextcloud_auth.py --username YOUR_USERNAME")
    print("\nSee README.md for installation and configuration instructions.")

