#!/usr/bin/env python3
"""
PAM Nextcloud Group Synchronization Module

This module synchronizes user group membership from Nextcloud to the local
Linux system. It creates groups if they don't exist and adds users to them.

Features:
- Automatic group creation
- Group name mapping (e.g., Nextcloud "admins" -> Linux "sudo")
- Safe operation (doesn't remove existing groups)
- Comprehensive logging
"""

import os
import sys
import subprocess
import syslog
import grp
import configparser
from typing import List, Dict, Optional


class GroupSync:
    """Handles group synchronization from Nextcloud to Linux"""
    
    def __init__(self, config_path='/etc/security/pam_nextcloud.conf'):
        """
        Initialize group synchronization
        
        Args:
            config_path: Path to configuration file
        """
        self.config_path = config_path
        self.group_mapping = {}
        self.managed_groups_prefix = ''  # No prefix by default
        self.enable_sudo_mapping = False  # Disabled by default
        self.create_missing_groups = True
        self.load_config()
    
    def load_config(self):
        """Load group synchronization configuration"""
        try:
            if not os.path.exists(self.config_path):
                return
            
            config = configparser.ConfigParser()
            config.read(self.config_path)
            
            # Load group mapping
            if config.has_section('group_mapping'):
                for nextcloud_group, linux_groups in config.items('group_mapping'):
                    # Support multiple Linux groups separated by comma
                    self.group_mapping[nextcloud_group] = [g.strip() for g in linux_groups.split(',')]
            
            # Load other settings
            if config.has_section('group_sync'):
                self.managed_groups_prefix = config.get('group_sync', 'prefix', fallback='')  # Empty by default
                self.enable_sudo_mapping = config.getboolean('group_sync', 'enable_sudo_mapping', fallback=False)  # Disabled by default
                self.create_missing_groups = config.getboolean('group_sync', 'create_missing_groups', fallback=True)
            
        except Exception as e:
            syslog.syslog(syslog.LOG_ERR,
                f"pam_nextcloud_groups: Error loading config: {str(e)}")
    
    def _group_exists(self, groupname: str) -> bool:
        """Check if a group exists on the system"""
        try:
            grp.getgrnam(groupname)
            return True
        except KeyError:
            return False
    
    def _create_group(self, groupname: str) -> bool:
        """
        Create a new group on the system
        
        Args:
            groupname: Name of group to create
            
        Returns:
            bool: True if successful, False otherwise
        """
        try:
            # Use groupadd command
            result = subprocess.run(
                ['groupadd', '--system', groupname],
                capture_output=True,
                text=True,
                timeout=5
            )
            
            if result.returncode == 0:
                syslog.syslog(syslog.LOG_INFO,
                    f"pam_nextcloud_groups: Created group: {groupname}")
                return True
            else:
                syslog.syslog(syslog.LOG_ERR,
                    f"pam_nextcloud_groups: Failed to create group {groupname}: {result.stderr}")
                return False
                
        except subprocess.TimeoutExpired:
            syslog.syslog(syslog.LOG_ERR,
                f"pam_nextcloud_groups: Timeout creating group: {groupname}")
            return False
        except Exception as e:
            syslog.syslog(syslog.LOG_ERR,
                f"pam_nextcloud_groups: Error creating group {groupname}: {str(e)}")
            return False
    
    def _user_in_group(self, username: str, groupname: str) -> bool:
        """Check if user is already in a group"""
        try:
            group = grp.getgrnam(groupname)
            return username in group.gr_mem
        except KeyError:
            return False
    
    def _add_user_to_group(self, username: str, groupname: str) -> bool:
        """
        Add user to a group
        
        Args:
            username: Username to add
            groupname: Group name
            
        Returns:
            bool: True if successful, False otherwise
        """
        try:
            # Use usermod or gpasswd
            # gpasswd is more reliable for adding to groups
            result = subprocess.run(
                ['gpasswd', '-a', username, groupname],
                capture_output=True,
                text=True,
                timeout=5
            )
            
            if result.returncode == 0:
                syslog.syslog(syslog.LOG_INFO,
                    f"pam_nextcloud_groups: Added user {username} to group: {groupname}")
                return True
            else:
                syslog.syslog(syslog.LOG_WARNING,
                    f"pam_nextcloud_groups: Failed to add user {username} to group {groupname}: {result.stderr}")
                return False
                
        except subprocess.TimeoutExpired:
            syslog.syslog(syslog.LOG_ERR,
                f"pam_nextcloud_groups: Timeout adding user to group: {groupname}")
            return False
        except Exception as e:
            syslog.syslog(syslog.LOG_ERR,
                f"pam_nextcloud_groups: Error adding user to group {groupname}: {str(e)}")
            return False
    
    def _normalize_group_name(self, nextcloud_group: str) -> str:
        """
        Normalize Nextcloud group name for Linux
        
        Converts group names to Linux-compatible format
        
        Args:
            nextcloud_group: Nextcloud group name
            
        Returns:
            str: Normalized group name
        """
        # Remove special characters, convert to lowercase
        normalized = ''.join(c if c.isalnum() or c in '-_' else '_' for c in nextcloud_group)
        normalized = normalized.lower().strip('_')
        
        # Add prefix only if configured (empty by default)
        if self.managed_groups_prefix and not normalized.startswith(self.managed_groups_prefix):
            normalized = self.managed_groups_prefix + normalized
        
        return normalized
    
    def _get_mapped_groups(self, nextcloud_group: str) -> List[str]:
        """
        Get mapped Linux groups for a Nextcloud group
        
        Args:
            nextcloud_group: Nextcloud group name
            
        Returns:
            list: List of Linux group names to use
        """
        # Check explicit mapping first
        if nextcloud_group in self.group_mapping:
            return self.group_mapping[nextcloud_group]
        
        # Check for common sudo/admin mappings
        if self.enable_sudo_mapping:
            nextcloud_lower = nextcloud_group.lower()
            if nextcloud_lower in ['admin', 'admins', 'administrators']:
                # Try sudo first, fallback to wheel or admin
                if self._group_exists('sudo'):
                    return ['sudo']
                elif self._group_exists('wheel'):
                    return ['wheel']
                elif self._group_exists('admin'):
                    return ['admin']
        
        # Use normalized name
        return [self._normalize_group_name(nextcloud_group)]
    
    def sync_groups(self, username: str, nextcloud_groups: List[str]) -> bool:
        """
        Synchronize user's groups from Nextcloud to Linux
        
        Args:
            username: Username to sync
            nextcloud_groups: List of Nextcloud group names
            
        Returns:
            bool: True if successful, False if any errors occurred
        """
        if not nextcloud_groups:
            syslog.syslog(syslog.LOG_INFO,
                f"pam_nextcloud_groups: No groups to sync for user: {username}")
            return True
        
        success = True
        synced_groups = []
        
        for nc_group in nextcloud_groups:
            # Get mapped Linux groups
            linux_groups = self._get_mapped_groups(nc_group)
            
            for linux_group in linux_groups:
                # Skip if already a member
                if self._user_in_group(username, linux_group):
                    syslog.syslog(syslog.LOG_DEBUG,
                        f"pam_nextcloud_groups: User {username} already in group: {linux_group}")
                    synced_groups.append(linux_group)
                    continue
                
                # Create group if it doesn't exist
                if not self._group_exists(linux_group):
                    if self.create_missing_groups:
                        if not self._create_group(linux_group):
                            syslog.syslog(syslog.LOG_ERR,
                                f"pam_nextcloud_groups: Failed to create group: {linux_group}")
                            success = False
                            continue
                    else:
                        syslog.syslog(syslog.LOG_WARNING,
                            f"pam_nextcloud_groups: Group {linux_group} doesn't exist and auto-creation is disabled")
                        continue
                
                # Add user to group
                if self._add_user_to_group(username, linux_group):
                    synced_groups.append(linux_group)
                else:
                    success = False
        
        if synced_groups:
            syslog.syslog(syslog.LOG_INFO,
                f"pam_nextcloud_groups: Synced groups for {username}: {', '.join(synced_groups)}")
        
        return success


def main():
    """Main entry point for group synchronization"""
    
    # Get configuration
    config_path = '/etc/security/pam_nextcloud.conf'
    
    # Check if group sync is enabled
    config = configparser.ConfigParser()
    config.read(config_path)
    
    if not config.getboolean('nextcloud', 'enable_group_sync', fallback=False):
        print("Group synchronization is disabled in configuration")
        return 0
    
    # Get username from environment or argument
    username = os.environ.get('PAM_USER') or (sys.argv[1] if len(sys.argv) > 1 else None)
    
    if not username:
        print("Error: No username provided", file=sys.stderr)
        return 1
    
    # Get groups from argument or environment
    # Groups should be passed as comma-separated string
    groups_str = os.environ.get('NEXTCLOUD_GROUPS') or (sys.argv[2] if len(sys.argv) > 2 else None)
    
    if not groups_str:
        print("Error: No groups provided", file=sys.stderr)
        return 1
    
    nextcloud_groups = [g.strip() for g in groups_str.split(',') if g.strip()]
    
    # Sync groups
    group_sync = GroupSync(config_path)
    
    if group_sync.sync_groups(username, nextcloud_groups):
        print(f"Group synchronization completed for {username}")
        return 0
    else:
        print(f"Group synchronization had errors", file=sys.stderr)
        return 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as e:
        print(f"Fatal error: {e}", file=sys.stderr)
        sys.exit(1)

