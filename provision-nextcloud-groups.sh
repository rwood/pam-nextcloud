#!/bin/bash
#
# Nextcloud Group Synchronization Script
#
# This script synchronizes user group memberships from Nextcloud to the local
# Linux system. It can sync groups for all users or for users in a specific group.
#
# Usage:
#   sudo ./provision-nextcloud-groups.sh
#   sudo ./provision-nextcloud-groups.sh --group GROUP_NAME
#   sudo ./provision-nextcloud-groups.sh --user USERNAME
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/etc/security/pam_nextcloud.conf"
GROUP_SYNC_SCRIPT="/lib/security/pam_nextcloud_groups.py"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo ""
    echo "======================================================================"
    echo "$1"
    echo "======================================================================"
}

print_info() {
    echo -e "${BLUE}ℹ  $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

# Load configuration
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
    
    # Read Nextcloud URL
    NEXTCLOUD_URL=$(awk -F'=' '/^url[ \t]*=/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}' "$CONFIG_FILE" | head -1)
    if [[ -z "$NEXTCLOUD_URL" ]]; then
        print_error "Nextcloud URL not configured in $CONFIG_FILE"
        exit 1
    fi
    
    # Read SSL verification setting
    VERIFY_SSL=$(awk -F'=' '/^verify_ssl[ \t]*=/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}' "$CONFIG_FILE" | head -1)
    VERIFY_SSL=${VERIFY_SSL:-true}
    
    # Read timeout
    TIMEOUT=$(awk -F'=' '/^timeout[ \t]*=/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}' "$CONFIG_FILE" | head -1)
    TIMEOUT=${TIMEOUT:-10}
    
    print_info "Nextcloud URL: $NEXTCLOUD_URL"
    print_info "SSL Verification: $VERIFY_SSL"
}

# Get user's groups from Nextcloud
get_user_groups() {
    local username="$1"
    local admin_user="$2"
    local admin_pass="$3"
    
    local api_url="${NEXTCLOUD_URL}/ocs/v2.php/cloud/users/${username}/groups"
    local verify_flag=""
    
    if [[ "$VERIFY_SSL" == "false" ]] || [[ "$VERIFY_SSL" == "0" ]]; then
        verify_flag="-k"
    fi
    
    local response=$(curl -s $verify_flag \
        -u "${admin_user}:${admin_pass}" \
        -H "OCS-APIRequest: true" \
        -H "Accept: application/json" \
        "${api_url}" 2>/dev/null || echo "")
    
    if [[ -z "$response" ]]; then
        return 1
    fi
    
    # Parse JSON response
    echo "$response" | python3 -c "
import sys
import json
try:
    data = json.load(sys.stdin)
    if 'ocs' in data and 'data' in data['ocs']:
        groups = data['ocs']['data'].get('groups', [])
        print(' '.join(groups))
except:
    pass
" 2>/dev/null || return 1
}

# Sync groups for a user using the group sync script
sync_user_groups() {
    local username="$1"
    local groups="$2"
    
    if [[ -z "$groups" ]]; then
        print_info "No groups found for user: $username"
        return 0
    fi
    
    # Check if group sync script exists
    if [[ ! -f "$GROUP_SYNC_SCRIPT" ]]; then
        print_warning "Group sync script not found: $GROUP_SYNC_SCRIPT"
        print_info "Groups will not be synced (group sync may not be installed)"
        return 0
    fi
    
    # Run group sync script
    if python3 "$GROUP_SYNC_SCRIPT" "$username" "$groups" >/dev/null 2>&1; then
        print_success "Synced groups for $username: $(echo $groups | tr ' ' ',')"
        return 0
    else
        print_warning "Failed to sync groups for $username"
        return 1
    fi
}

# Get members of a group
get_group_members() {
    local group_name="$1"
    local admin_user="$2"
    local admin_pass="$3"
    
    local api_url="${NEXTCLOUD_URL}/ocs/v2.php/cloud/groups/${group_name}/users"
    local verify_flag=""
    
    if [[ "$VERIFY_SSL" == "false" ]] || [[ "$VERIFY_SSL" == "0" ]]; then
        verify_flag="-k"
    fi
    
    local response=$(curl -s $verify_flag \
        -u "${admin_user}:${admin_pass}" \
        -H "OCS-APIRequest: true" \
        -H "Accept: application/json" \
        "${api_url}" 2>/dev/null || echo "")
    
    if [[ -z "$response" ]]; then
        return 1
    fi
    
    # Parse JSON response
    echo "$response" | python3 -c "
import sys
import json
try:
    data = json.load(sys.stdin)
    if 'ocs' in data and 'data' in data['ocs']:
        users = data['ocs']['data'].get('users', [])
        print(' '.join(users))
except:
    pass
" 2>/dev/null || return 1
}

# Main sync function
main() {
    check_root
    
    print_header "Nextcloud Group Synchronization"
    
    # Load configuration
    load_config
    
    # Parse arguments
    TARGET_GROUP=""
    TARGET_USER=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --group)
                TARGET_GROUP="$2"
                shift 2
                ;;
            --user)
                TARGET_USER="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [--group GROUP_NAME] [--user USERNAME]"
                echo ""
                echo "Options:"
                echo "  --group GROUP_NAME  Sync groups for all users in this Nextcloud group"
                echo "  --user USERNAME     Sync groups for a specific user"
                echo "  --help, -h          Show this help message"
                echo ""
                echo "If no options are provided, syncs groups for all local users found in Nextcloud"
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
    
    # Prompt for admin credentials
    echo ""
    read -p "Nextcloud admin username: " ADMIN_USER
    read -sp "Nextcloud admin password: " ADMIN_PASS
    echo ""
    
    if [[ -z "$ADMIN_USER" ]] || [[ -z "$ADMIN_PASS" ]]; then
        print_error "Admin credentials are required"
        exit 1
    fi
    
    # Determine which users to sync
    if [[ -n "$TARGET_USER" ]]; then
        # Sync specific user
        print_info "Syncing groups for user: $TARGET_USER"
        USER_LIST="$TARGET_USER"
    elif [[ -n "$TARGET_GROUP" ]]; then
        # Sync users in specific group
        print_info "Retrieving members of group: $TARGET_GROUP"
        USER_LIST=$(get_group_members "$TARGET_GROUP" "$ADMIN_USER" "$ADMIN_PASS")
        
        if [[ -z "$USER_LIST" ]]; then
            print_error "Failed to retrieve group members or group is empty"
            exit 1
        fi
        
        print_success "Found $(echo $USER_LIST | wc -w) user(s) in group '$TARGET_GROUP'"
    else
        # Sync all local users (check against Nextcloud)
        print_info "Syncing groups for all local users..."
        
        # Get list of local users (UID >= 1000, excluding system users)
        USER_LIST=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' | tr '\n' ' ')
        
        if [[ -z "$USER_LIST" ]]; then
            print_warning "No local users found"
            exit 0
        fi
        
        print_info "Found $(echo $USER_LIST | wc -w) local user(s)"
    fi
    
    # Sync groups for each user
    local synced_count=0
    local failed_count=0
    local skipped_count=0
    
    echo ""
    print_info "Syncing groups..."
    echo ""
    
    for username in $USER_LIST; do
        # Check if user exists locally
        if ! getent passwd "$username" >/dev/null 2>&1; then
            print_warning "User '$username' does not exist locally, skipping"
            skipped_count=$((skipped_count + 1))
            continue
        fi
        
        # Get user's groups from Nextcloud
        print_info "Processing: $username"
        user_groups=$(get_user_groups "$username" "$ADMIN_USER" "$ADMIN_PASS")
        
        if [[ -z "$user_groups" ]]; then
            print_warning "  No groups found for user '$username' in Nextcloud"
            skipped_count=$((skipped_count + 1))
            continue
        fi
        
        # Sync groups
        if sync_user_groups "$username" "$user_groups"; then
            synced_count=$((synced_count + 1))
        else
            failed_count=$((failed_count + 1))
        fi
    done
    
    # Summary
    echo ""
    print_header "Summary"
    echo "  Synced: $synced_count"
    echo "  Failed: $failed_count"
    echo "  Skipped: $skipped_count"
    echo ""
}

# Run main function
main "$@"

