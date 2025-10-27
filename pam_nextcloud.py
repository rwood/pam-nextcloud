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
    - Group synchronization from Nextcloud (centralized group management)
    - Desktop integration (GNOME Online Accounts, KDE Accounts)
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
import re
import hashlib
import json
import time
import subprocess
from datetime import datetime, timedelta
import pwd
import grp

MODULE_VERSION = "0.3.0"


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


# ---------------------
# Provisioning helpers
# ---------------------

def _load_provisioning_config(config_path):
    """Load provisioning settings from config file."""
    cfg = {
        'enable_user_provisioning': False,
        'create_home': True,
        'home_base_dir': '/home',
        'default_shell': '/bin/bash',
        'skel_dir': '/etc/skel',
        'primary_group': None,
        'extra_groups': []
    }

    try:
        if not os.path.exists(config_path):
            return cfg
        parser = configparser.ConfigParser()
        parser.read(config_path)
        if 'provisioning' in parser:
            section = parser['provisioning']
            cfg['enable_user_provisioning'] = section.getboolean('enable_user_provisioning', fallback=False)
            cfg['create_home'] = section.getboolean('create_home', fallback=True)
            cfg['home_base_dir'] = section.get('home_base_dir', fallback='/home')
            cfg['default_shell'] = section.get('default_shell', fallback='/bin/bash')
            cfg['skel_dir'] = section.get('skel_dir', fallback='/etc/skel')
            # Optional values
            primary_group = section.get('primary_group', fallback='').strip()
            cfg['primary_group'] = primary_group if primary_group else None
            extra_groups = section.get('extra_groups', fallback='').strip()
            if extra_groups:
                cfg['extra_groups'] = [g.strip() for g in extra_groups.split(',') if g.strip()]
    except Exception as e:
        syslog.syslog(syslog.LOG_WARNING,
            f"pam_nextcloud: Failed to read provisioning config: {str(e)}")
    return cfg


def _is_valid_username(username):
    """Basic POSIX username validation."""
    # Start with a letter or underscore; then letters, digits, underscores, hyphens
    return bool(re.fullmatch(r'[a-z_][a-z0-9_-]*\$?', username))


def _user_exists(username):
    try:
        pwd.getpwnam(username)
        return True
    except KeyError:
        return False


def _group_exists(group_name):
    try:
        grp.getgrnam(group_name)
        return True
    except KeyError:
        return False


def _ensure_group(group_name):
    """Ensure a group exists; create if missing."""
    try:
        if _group_exists(group_name):
            return True
        subprocess.run(['groupadd', group_name], check=True, timeout=5)
        syslog.syslog(syslog.LOG_INFO,
            f"pam_nextcloud: Created group '{group_name}' for provisioning")
        return True
    except Exception as e:
        syslog.syslog(syslog.LOG_WARNING,
            f"pam_nextcloud: Failed to ensure group '{group_name}': {str(e)}")
        return False


def _create_local_user(username, prov_cfg):
    """Create a local user account according to provisioning config."""
    if not _is_valid_username(username):
        syslog.syslog(syslog.LOG_WARNING,
            f"pam_nextcloud: Refusing to provision invalid username: {username}")
        return False

    try:
        # Build useradd command
        home_dir = os.path.join(prov_cfg['home_base_dir'].rstrip('/'), username)
        cmd = ['useradd']

        if prov_cfg.get('create_home', True):
            cmd.append('-m')
        cmd.extend(['-d', home_dir])
        cmd.extend(['-s', prov_cfg.get('default_shell', '/bin/bash')])

        skel_dir = prov_cfg.get('skel_dir')
        if skel_dir and os.path.isdir(skel_dir):
            cmd.extend(['-k', skel_dir])

        primary_group = prov_cfg.get('primary_group')
        if primary_group:
            if _ensure_group(primary_group):
                cmd.extend(['-g', primary_group])

        extra_groups = prov_cfg.get('extra_groups') or []
        valid_groups = []
        for g in extra_groups:
            if _group_exists(g) or _ensure_group(g):
                valid_groups.append(g)
        if valid_groups:
            cmd.extend(['-G', ','.join(valid_groups)])

        cmd.append(username)

        # Ensure base home directory exists
        try:
            os.makedirs(prov_cfg['home_base_dir'], mode=0o755, exist_ok=True)
        except Exception:
            pass

        subprocess.run(cmd, check=True, timeout=10)
        syslog.syslog(syslog.LOG_INFO,
            f"pam_nextcloud: Provisioned local user '{username}' with home '{home_dir}'")
        return True
    except subprocess.CalledProcessError as e:
        syslog.syslog(syslog.LOG_ERR,
            f"pam_nextcloud: useradd failed for '{username}': {str(e)}")
        return False
    except Exception as e:
        syslog.syslog(syslog.LOG_ERR,
            f"pam_nextcloud: Unexpected error creating user '{username}': {str(e)}")
        return False


def _ensure_home_directory(username, prov_cfg):
    """Ensure the user's home directory exists and has correct ownership."""
    if not prov_cfg.get('create_home', True):
        return True
    try:
        user_info = pwd.getpwnam(username)
        home_dir = user_info.pw_dir
        if not home_dir:
            home_dir = os.path.join(prov_cfg['home_base_dir'].rstrip('/'), username)
        if not os.path.isdir(home_dir):
            os.makedirs(home_dir, mode=0o700, exist_ok=True)
            try:
                # Populate from skeleton if available
                skel_dir = prov_cfg.get('skel_dir')
                if skel_dir and os.path.isdir(skel_dir):
                    subprocess.run(['cp', '-aT', skel_dir, home_dir], check=False, timeout=10)
            except Exception:
                pass
        # Ensure ownership
        try:
            os.chown(home_dir, user_info.pw_uid, user_info.pw_gid)
        except Exception:
            pass
        return True
    except KeyError:
        # User does not exist yet
        return False
    except Exception as e:
        syslog.syslog(syslog.LOG_WARNING,
            f"pam_nextcloud: Failed ensuring home for '{username}': {str(e)}")
        return False
    
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
            if response.status_code == 200:
                syslog.syslog(syslog.LOG_INFO,
                    f"pam_nextcloud: Password changed successfully for user: {username}")
                
                # Update cache with new password
                if self.enable_cache:
                    self._cache_password(username, new_password)
                
                return True
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
        try:
            syslog.syslog(syslog.LOG_INFO,
                f"pam_nextcloud: module {__file__} version {MODULE_VERSION}")
        except Exception:
            pass
        
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
        if not hasattr(_authenticator, 'authenticate'):
            syslog.syslog(syslog.LOG_ERR,
                "pam_nextcloud: Authenticator missing 'authenticate' method; check module version/install")
            return pamh.PAM_AUTH_ERR

        if _authenticator.authenticate(username, password):
            # Provision local account if enabled and user missing
            try:
                user_missing = False
                try:
                    pwd.getpwnam(username)
                except KeyError:
                    user_missing = True
                if user_missing:
                    prov_cfg = _load_provisioning_config(config_path)
                    if prov_cfg.get('enable_user_provisioning'):
                        if _create_local_user(username, prov_cfg):
                            # Attempt to ensure home as well
                            _ensure_home_directory(username, prov_cfg)
                        else:
                            syslog.syslog(syslog.LOG_WARNING,
                                f"pam_nextcloud: Provisioning failed for user: {username}")
            except Exception as e:
                syslog.syslog(syslog.LOG_WARNING,
                    f"pam_nextcloud: Provisioning error for user {username}: {str(e)}")
            # Attempt to capture groups for use in session phase
            try:
                groups = _authenticator.get_user_groups(username, password)
                if groups:
                    try:
                        user_info = pwd.getpwnam(username)
                        run_dir = f"/run/pam-nextcloud/{user_info.pw_uid}"
                        os.makedirs(run_dir, mode=0o700, exist_ok=True)
                        groups_file = os.path.join(run_dir, 'groups.json')
                        with open(groups_file, 'w') as f:
                            json.dump({'groups': groups}, f)
                        os.chmod(groups_file, 0o600)
                    except Exception as e:
                        syslog.syslog(syslog.LOG_DEBUG,
                            f"pam_nextcloud: Unable to persist groups for session: {str(e)}")
            except Exception as e:
                syslog.syslog(syslog.LOG_DEBUG,
                    f"pam_nextcloud: Unable to retrieve groups at auth phase: {str(e)}")
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
    
    Optionally sets up desktop integration for Nextcloud
    
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
        
        # Parse module arguments for custom config path
        config_path = '/etc/security/pam_nextcloud.conf'
        for arg in argv:
            if arg.startswith('config='):
                config_path = arg.split('=', 1)[1]
        
        # Check if desktop integration is enabled
        if not os.path.exists(config_path):
            return pamh.PAM_SUCCESS
        
        config = configparser.ConfigParser()
        config.read(config_path)
        
        enable_desktop = config.getboolean('nextcloud', 'enable_desktop_integration', fallback=False)
        enable_group_sync = config.getboolean('nextcloud', 'enable_group_sync', fallback=False)
        
        # Get username
        try:
            username = pamh.get_user(None)
        except pamh.exception:
            return pamh.PAM_SUCCESS
        
        if not username:
            return pamh.PAM_SUCCESS
        
        # Ensure home directory exists if provisioning is enabled
        try:
            prov_cfg = _load_provisioning_config(config_path)
            if prov_cfg.get('enable_user_provisioning'):
                _ensure_home_directory(username, prov_cfg)
        except Exception as e:
            syslog.syslog(syslog.LOG_DEBUG,
                f"pam_nextcloud: ensure home error for {username}: {str(e)}")

        # Run desktop integration script
        desktop_script = '/lib/security/pam_nextcloud_desktop.py'
        if os.path.exists(desktop_script):
            try:
                # Run in background to avoid delaying login
                env = os.environ.copy()
                env['PAM_USER'] = username
                
                # Fork and run in child process
                pid = os.fork()
                if pid == 0:
                    # Child process
                    try:
                        subprocess.run(
                            [sys.executable, desktop_script, username],
                            env=env,
                            timeout=5,
                            capture_output=True
                        )
                    except Exception:
                        pass
                    finally:
                        os._exit(0)
                else:
                    # Parent process - don't wait
                    pass
                
                syslog.syslog(syslog.LOG_INFO,
                    f"pam_nextcloud: Desktop integration initiated for user: {username}")
            except Exception as e:
                syslog.syslog(syslog.LOG_WARNING,
                    f"pam_nextcloud: Desktop integration error: {str(e)}")
        
        # Group synchronization
        if enable_group_sync:
            try:
                # Initialize authenticator
                global _authenticator
                if _authenticator is None or _authenticator.config_path != config_path:
                    _authenticator = NextcloudAuth(config_path)
                
                # Get username (already retrieved above)
                if not username:
                    username = pamh.get_user(None)
                
                if not username:
                    return pamh.PAM_SUCCESS
                
                # Try to get password from authtok
                # Note: Password may not be available in session phase
                password = None
                try:
                    password = pamh.authtok
                except:
                    pass
                
                nextcloud_groups = None
                
                if password:
                    # Fetch groups from Nextcloud directly if password is available
                    nextcloud_groups = _authenticator.get_user_groups(username, password)
                else:
                    # Fallback: try to read groups captured during auth phase
                    try:
                        user_info = pwd.getpwnam(username)
                        run_dir = f"/run/pam-nextcloud/{user_info.pw_uid}"
                        groups_file = os.path.join(run_dir, 'groups.json')
                        if os.path.exists(groups_file):
                            with open(groups_file, 'r') as f:
                                data = json.load(f)
                                nextcloud_groups = data.get('groups', [])
                            # Remove file after reading to avoid reuse
                            try:
                                os.remove(groups_file)
                            except Exception:
                                pass
                    except Exception:
                        pass
                
                if nextcloud_groups is not None and len(nextcloud_groups) > 0:
                    # Run group sync script
                    group_script = '/lib/security/pam_nextcloud_groups.py'
                    if os.path.exists(group_script):
                        try:
                            # Fork and run in child process
                            pid = os.fork()
                            if pid == 0:
                                # Child process
                                try:
                                    env = os.environ.copy()
                                    env['PAM_USER'] = username
                                    env['NEXTCLOUD_GROUPS'] = ','.join(nextcloud_groups)
                                    
                                    subprocess.run(
                                        [sys.executable, group_script, username, ','.join(nextcloud_groups)],
                                        env=env,
                                        timeout=10,
                                        capture_output=True
                                    )
                                except Exception:
                                    pass
                                finally:
                                    os._exit(0)
                            else:
                                # Parent process - wait briefly for group sync
                                # This is important so groups are available in the session
                                import time
                                time.sleep(0.5)
                            
                            syslog.syslog(syslog.LOG_INFO,
                                f"pam_nextcloud: Group synchronization initiated for user: {username}")
                        except Exception as e:
                            syslog.syslog(syslog.LOG_WARNING,
                                f"pam_nextcloud: Group synchronization error: {str(e)}")
                elif nextcloud_groups is not None:
                    syslog.syslog(syslog.LOG_INFO,
                        f"pam_nextcloud: User {username} has no groups on Nextcloud")
                
            except Exception as e:
                syslog.syslog(syslog.LOG_WARNING,
                    f"pam_nextcloud: Group sync error: {str(e)}")
        
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
                    # Store old password for UPDATE phase (PAM will handle this)
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
            try:
                # Get old password (should be available from PRELIM_CHECK)
                old_password = pamh.oldauthtok
                if old_password is None:
                    old_password = pamh.authtok
                
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
    print("  - Desktop integration (GNOME/KDE)")
    print("\nFor testing, you can use the NextcloudAuth class directly:")
    print("\n  auth = NextcloudAuth('/path/to/config')")
    print("  result = auth.authenticate('username', 'password')")
    print("  result = auth.change_password('username', 'old_pass', 'new_pass')")
    print("\nOr use the test script:")
    print("  python3 test_nextcloud_auth.py --username YOUR_USERNAME")
    print("\nSee README.md for installation and configuration instructions.")

