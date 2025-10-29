#!/bin/bash
#
# Fix PAM Configuration Script
#
# This script fixes PAM configuration files to ensure pam_nextcloud
# takes precedence over local authentication and prevents unix_chkpwd
# from being called after Nextcloud authentication succeeds.
#
# Usage:
#   sudo ./fix_pam_config.sh [service]
#   Example: sudo ./fix_pam_config.sh sddm
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root (use sudo)"
    exit 1
fi

fix_pam_file() {
    local pam_file="$1"
    local service_name="$2"
    
    if [[ ! -f "$pam_file" ]]; then
        print_info "File does not exist: $pam_file"
        return 1
    fi
    
    print_header "Fixing $service_name ($pam_file)"
    
    # Backup the file
    local backup_file="${pam_file}.backup-$(date +%Y%m%d-%H%M%S)"
    cp "$pam_file" "$backup_file"
    print_success "Backed up to: $backup_file"
    
    # Check if pam_nextcloud is already configured
    if ! grep -q "pam_nextcloud" "$pam_file"; then
        print_warning "pam_nextcloud not found in this file"
        print_info "Add it manually or use install.sh to configure PAM"
        return 1
    fi
    
    # Create a temporary file for the new configuration
    local temp_file=$(mktemp)
    
    # Process the file line by line
    local in_auth_section=0
    local nextcloud_added=0
    local unix_found=0
    
    while IFS= read -r line; do
        # Check if we're entering the auth section
        if [[ "$line" =~ ^auth[[:space:]] ]]; then
            in_auth_section=1
            
            # If this is pam_nextcloud, ensure it's first and uses 'sufficient'
            if [[ "$line" =~ pam_nextcloud ]]; then
                if [[ ! "$line" =~ sufficient ]]; then
                    # Replace with sufficient
                    echo "auth    sufficient  pam_python.so /lib/security/pam_nextcloud.py" >> "$temp_file"
                    nextcloud_added=1
                    print_info "Fixed pam_nextcloud to use 'sufficient'"
                    continue
                else
                    # Already correct, but ensure it's first
                    if [[ $unix_found -eq 0 ]]; then
                        echo "$line" >> "$temp_file"
                        nextcloud_added=1
                        print_info "pam_nextcloud already correctly configured"
                        continue
                    fi
                fi
            fi
            
            # If this is pam_unix and pam_nextcloud hasn't been added yet
            if [[ "$line" =~ pam_unix ]] && [[ $nextcloud_added -eq 0 ]]; then
                # Add pam_nextcloud first
                echo "auth    sufficient  pam_python.so /lib/security/pam_nextcloud.py" >> "$temp_file"
                nextcloud_added=1
                print_info "Added pam_nextcloud before pam_unix"
            fi
            
            # Fix pam_unix to use 'sufficient' instead of 'required'
            if [[ "$line" =~ pam_unix ]] && [[ "$line" =~ required ]]; then
                # Replace 'required' with 'sufficient'
                modified_line=$(echo "$line" | sed 's/required/sufficient/')
                echo "$modified_line" >> "$temp_file"
                unix_found=1
                print_success "Changed pam_unix from 'required' to 'sufficient'"
                continue
            fi
            
            # If this is pam_unix with sufficient, keep it
            if [[ "$line" =~ pam_unix ]] && [[ "$line" =~ sufficient ]]; then
                echo "$line" >> "$temp_file"
                unix_found=1
                continue
            fi
        else
            # Not an auth line, check if we're leaving auth section
            if [[ "$line" =~ ^(account|session|password|@include) ]] && [[ $in_auth_section -eq 1 ]]; then
                in_auth_section=0
                # If pam_nextcloud wasn't added yet, add it now
                if [[ $nextcloud_added -eq 0 ]]; then
                    echo "auth    sufficient  pam_python.so /lib/security/pam_nextcloud.py" >> "$temp_file"
                    nextcloud_added=1
                    print_info "Added pam_nextcloud at end of auth section"
                fi
            fi
        fi
        
        # Write the line as-is
        echo "$line" >> "$temp_file"
    done < "$pam_file"
    
    # If we're still in auth section and pam_nextcloud wasn't added, add it
    if [[ $in_auth_section -eq 1 ]] && [[ $nextcloud_added -eq 0 ]]; then
        echo "auth    sufficient  pam_python.so /lib/security/pam_nextcloud.py" >> "$temp_file"
        nextcloud_added=1
    fi
    
    # Replace the original file
    mv "$temp_file" "$pam_file"
    
    echo ""
    print_info "Updated configuration:"
    grep "^auth" "$pam_file" | grep -E "(pam_nextcloud|pam_unix)" | head -5
    
    print_success "Fixed $service_name configuration"
    return 0
}

# Main execution
print_header "PAM Configuration Fix Script"

if [[ $# -gt 0 ]]; then
    # Fix specific service
    service="$1"
    case "$service" in
        sddm)
            fix_pam_file "/etc/pam.d/sddm" "SDDM"
            ;;
        gdm|gdm-password)
            fix_pam_file "/etc/pam.d/gdm-password" "GDM"
            ;;
        gdm3)
            fix_pam_file "/etc/pam.d/gdm3" "GDM3"
            ;;
        lightdm)
            fix_pam_file "/etc/pam.d/lightdm" "LightDM"
            ;;
        sshd)
            fix_pam_file "/etc/pam.d/sshd" "SSH"
            ;;
        sudo)
            fix_pam_file "/etc/pam.d/sudo" "Sudo"
            ;;
        common-auth)
            fix_pam_file "/etc/pam.d/common-auth" "Common Auth"
            ;;
        *)
            print_error "Unknown service: $service"
            echo "Supported services: sddm, gdm, gdm-password, lightdm, sshd, sudo, common-auth"
            exit 1
            ;;
    esac
else
    # Interactive mode - detect and fix common files
    print_info "No service specified. Checking common PAM files..."
    echo ""
    
    # Detect display manager
    if [[ -f /etc/pam.d/sddm ]]; then
        echo "Detected SDDM. Would you like to fix it? (y/N)"
        read -t 5 -r response || response="n"
        if [[ "$response" =~ ^[Yy]$ ]]; then
            fix_pam_file "/etc/pam.d/sddm" "SDDM"
        fi
    fi
    
    if [[ -f /etc/pam.d/gdm-password ]]; then
        echo "Detected GDM. Would you like to fix it? (y/N)"
        read -t 5 -r response || response="n"
        if [[ "$response" =~ ^[Yy]$ ]]; then
            fix_pam_file "/etc/pam.d/gdm-password" "GDM"
        fi
    fi
    
    if [[ -f /etc/pam.d/lightdm ]]; then
        echo "Detected LightDM. Would you like to fix it? (y/N)"
        read -t 5 -r response || response="n"
        if [[ "$response" =~ ^[Yy]$ ]]; then
            fix_pam_file "/etc/pam.d/lightdm" "LightDM"
        fi
    fi
    
    if [[ -f /etc/pam.d/common-auth ]]; then
        echo "Detected common-auth. Would you like to fix it? (y/N)"
        print_warning "Fixing common-auth affects ALL services - be careful!"
        read -t 5 -r response || response="n"
        if [[ "$response" =~ ^[Yy]$ ]]; then
            fix_pam_file "/etc/pam.d/common-auth" "Common Auth"
        fi
    fi
fi

echo ""
print_header "Summary"
print_success "PAM configuration fix complete!"
echo ""
print_warning "IMPORTANT:"
echo "  1. Test login in a separate terminal/session before closing this one"
echo "  2. Keep a root shell open in case you need to revert"
echo "  3. Backup files are saved with .backup-YYYYMMDD-HHMMSS extension"
echo ""
print_info "To revert changes:"
echo "  sudo cp /etc/pam.d/SERVICE.backup-* /etc/pam.d/SERVICE"

