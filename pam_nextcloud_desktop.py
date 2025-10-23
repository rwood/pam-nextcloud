#!/usr/bin/env python3
"""
PAM Nextcloud Desktop Integration Module

This script automatically configures GNOME Online Accounts (GOA) and KDE
account integration for Nextcloud after successful PAM authentication.

This runs during the PAM session phase to set up desktop integration.
"""

import os
import sys
import subprocess
import json
import configparser
from pathlib import Path


class DesktopIntegration:
    """Handles desktop environment integration for Nextcloud"""
    
    def __init__(self, username, nextcloud_url):
        """
        Initialize desktop integration
        
        Args:
            username: Username to configure
            nextcloud_url: Nextcloud server URL
        """
        self.username = username
        self.nextcloud_url = nextcloud_url.rstrip('/')
        self.home_dir = self._get_home_directory()
        
    def _get_home_directory(self):
        """Get user's home directory"""
        import pwd
        try:
            return pwd.getpwnam(self.username).pw_dir
        except KeyError:
            return f"/home/{self.username}"
    
    def _detect_desktop_environment(self):
        """
        Detect which desktop environment is running
        
        Returns:
            str: 'gnome', 'kde', 'other', or None
        """
        # Check environment variables
        desktop = os.environ.get('XDG_CURRENT_DESKTOP', '').lower()
        session = os.environ.get('DESKTOP_SESSION', '').lower()
        
        if 'gnome' in desktop or 'gnome' in session:
            return 'gnome'
        elif 'kde' in desktop or 'plasma' in desktop or 'kde' in session:
            return 'kde'
        elif desktop or session:
            return 'other'
        
        return None
    
    def setup_gnome_online_accounts(self):
        """
        Configure GNOME Online Accounts for Nextcloud
        
        Note: This creates a basic configuration. The user will need to
        complete authentication in GNOME Settings.
        
        Returns:
            bool: True if successful, False otherwise
        """
        try:
            # GOA configuration directory
            goa_dir = Path(self.home_dir) / '.config' / 'goa-1.0'
            goa_dir.mkdir(parents=True, exist_ok=True)
            
            accounts_file = goa_dir / 'accounts.conf'
            
            # Generate account ID
            import hashlib
            account_id = hashlib.md5(
                f"{self.username}@{self.nextcloud_url}".encode()
            ).hexdigest()[:16]
            
            # Check if account already exists
            if accounts_file.exists():
                config = configparser.ConfigParser()
                config.read(accounts_file)
                
                # Check if Nextcloud account already configured
                for section in config.sections():
                    if section.startswith('Account '):
                        provider = config.get(section, 'Provider', fallback='')
                        uri = config.get(section, 'Uri', fallback='')
                        if provider == 'owncloud' and self.nextcloud_url in uri:
                            print(f"GNOME Online Account already configured for {self.nextcloud_url}")
                            return True
            
            # Create marker file for session script to complete setup
            marker_file = goa_dir / f'.nextcloud-setup-{account_id}'
            with open(marker_file, 'w') as f:
                json.dump({
                    'username': self.username,
                    'server': self.nextcloud_url,
                    'account_id': account_id
                }, f)
            
            os.chmod(marker_file, 0o600)
            
            # Change ownership to user
            import pwd
            pw = pwd.getpwnam(self.username)
            os.chown(goa_dir, pw.pw_uid, pw.pw_gid)
            os.chown(marker_file, pw.pw_uid, pw.pw_gid)
            
            print(f"GNOME Online Accounts: Setup marker created")
            print(f"User should complete setup in GNOME Settings > Online Accounts")
            
            return True
            
        except Exception as e:
            print(f"Error setting up GNOME Online Accounts: {e}", file=sys.stderr)
            return False
    
    def setup_kde_accounts(self):
        """
        Configure KDE accounts for Nextcloud
        
        Returns:
            bool: True if successful, False otherwise
        """
        try:
            # KDE accounts directory
            kde_dir = Path(self.home_dir) / '.local' / 'share' / 'kaccounts'
            kde_dir.mkdir(parents=True, exist_ok=True)
            
            # Create marker file for user to complete setup
            marker_file = kde_dir / '.nextcloud-setup'
            with open(marker_file, 'w') as f:
                json.dump({
                    'username': self.username,
                    'server': self.nextcloud_url,
                    'type': 'nextcloud'
                }, f)
            
            os.chmod(marker_file, 0o600)
            
            # Change ownership to user
            import pwd
            pw = pwd.getpwnam(self.username)
            os.chown(kde_dir, pw.pw_uid, pw.pw_gid)
            os.chown(marker_file, pw.pw_uid, pw.pw_gid)
            
            print(f"KDE Accounts: Setup marker created")
            print(f"User should complete setup in System Settings > Online Accounts")
            
            return True
            
        except Exception as e:
            print(f"Error setting up KDE accounts: {e}", file=sys.stderr)
            return False
    
    def setup_nextcloud_client_config(self):
        """
        Create configuration hint for Nextcloud desktop client
        
        This creates a configuration that the Nextcloud client can detect
        to simplify first-time setup.
        
        Returns:
            bool: True if successful, False otherwise
        """
        try:
            # Nextcloud client config directory
            nc_dir = Path(self.home_dir) / '.config' / 'Nextcloud'
            nc_dir.mkdir(parents=True, exist_ok=True)
            
            hint_file = nc_dir / 'sync-hint.json'
            
            # Don't overwrite existing configuration
            if hint_file.exists():
                print(f"Nextcloud client configuration already exists")
                return True
            
            # Create hint file
            hint_data = {
                'server': self.nextcloud_url,
                'user': self.username,
                'configured_via': 'pam_nextcloud',
                'note': 'This server was auto-detected from PAM authentication'
            }
            
            with open(hint_file, 'w') as f:
                json.dump(hint_data, f, indent=2)
            
            os.chmod(hint_file, 0o600)
            
            # Change ownership to user
            import pwd
            pw = pwd.getpwnam(self.username)
            os.chown(nc_dir, pw.pw_uid, pw.pw_gid)
            os.chown(hint_file, pw.pw_uid, pw.pw_gid)
            
            print(f"Nextcloud client: Server hint created")
            
            return True
            
        except Exception as e:
            print(f"Error creating Nextcloud client hint: {e}", file=sys.stderr)
            return False
    
    def setup_integration(self, desktop_env=None):
        """
        Setup desktop integration based on detected or specified desktop
        
        Args:
            desktop_env: Force specific desktop ('gnome', 'kde', or None for auto-detect)
            
        Returns:
            bool: True if any integration succeeded
        """
        if desktop_env is None:
            desktop_env = self._detect_desktop_environment()
        
        success = False
        
        # Always create Nextcloud client hint
        if self.setup_nextcloud_client_config():
            success = True
        
        # Setup desktop-specific integration
        if desktop_env == 'gnome':
            print(f"Detected GNOME desktop environment")
            if self.setup_gnome_online_accounts():
                success = True
        elif desktop_env == 'kde':
            print(f"Detected KDE desktop environment")
            if self.setup_kde_accounts():
                success = True
        else:
            print(f"Desktop environment: {desktop_env or 'unknown'}")
            print(f"Nextcloud desktop client will still detect server configuration")
        
        return success


def main():
    """Main entry point for desktop integration"""
    
    # Get configuration
    config_path = '/etc/security/pam_nextcloud.conf'
    
    # Check if integration is enabled
    config = configparser.ConfigParser()
    config.read(config_path)
    
    if not config.getboolean('nextcloud', 'enable_desktop_integration', fallback=False):
        print("Desktop integration is disabled in configuration")
        return 0
    
    # Get username from environment or argument
    username = os.environ.get('PAM_USER') or (sys.argv[1] if len(sys.argv) > 1 else None)
    
    if not username:
        print("Error: No username provided", file=sys.stderr)
        return 1
    
    # Get Nextcloud URL from config
    nextcloud_url = config.get('nextcloud', 'url', fallback=None)
    
    if not nextcloud_url:
        print("Error: Nextcloud URL not configured", file=sys.stderr)
        return 1
    
    # Setup integration
    integration = DesktopIntegration(username, nextcloud_url)
    
    # Force desktop environment if specified
    force_desktop = config.get('nextcloud', 'force_desktop_type', fallback=None)
    
    if integration.setup_integration(desktop_env=force_desktop):
        print(f"Desktop integration setup completed for {username}")
        return 0
    else:
        print(f"Desktop integration setup had errors", file=sys.stderr)
        return 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as e:
        print(f"Fatal error: {e}", file=sys.stderr)
        sys.exit(1)

