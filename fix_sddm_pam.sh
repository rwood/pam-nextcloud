#!/bin/bash
#
# Fix SDDM PAM Configuration
#
# This script fixes the specific issue in /etc/pam.d/sddm where
# @include common-auth causes unix_chkpwd to run even after Nextcloud succeeds.
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

PAM_FILE="/etc/pam.d/sddm"

if [[ ! -f "$PAM_FILE" ]]; then
    print_error "PAM file not found: $PAM_FILE"
    exit 1
fi

print_header "Fixing SDDM PAM Configuration"

# Backup the file
backup_file="${PAM_FILE}.backup-$(date +%Y%m%d-%H%M%S)"
cp "$PAM_FILE" "$backup_file"
print_success "Backed up to: $backup_file"

# Create fixed version
temp_file=$(mktemp)

# Process the file line by line
in_auth_section=0
nextcloud_added=0

while IFS= read -r line || [[ -n "$line" ]]; do
    # Check if we're entering the auth section
    if [[ "$line" =~ ^auth[[:space:]] ]]; then
        in_auth_section=1
        
        # Skip duplicate pam_nextcloud entries (keep only the first one)
        if [[ "$line" =~ pam_nextcloud ]] && [[ $nextcloud_added -eq 1 ]]; then
            print_info "Removing duplicate pam_nextcloud entry"
            continue
        fi
        
        # Mark first pam_nextcloud entry
        if [[ "$line" =~ pam_nextcloud ]]; then
            echo "$line" >> "$temp_file"
            nextcloud_added=1
            continue
        fi
        
        # Keep other auth entries
        echo "$line" >> "$temp_file"
        continue
    fi
    
    # Check for @include common-auth - this is the problem!
    if [[ "$line" =~ ^@include[[:space:]]+common-auth ]] && [[ $in_auth_section -eq 1 ]]; then
        print_warning "Replacing @include common-auth with proper fallback configuration"
        # Replace with proper fallback that won't force password check
        echo "auth    sufficient  pam_unix.so nullok_secure try_first_pass" >> "$temp_file"
        echo "auth    requisite   pam_deny.so" >> "$temp_file"
        echo "auth    required    pam_permit.so" >> "$temp_file"
        continue
    fi
    
    # Check if we're leaving auth section
    if [[ "$line" =~ ^(account|session|password|@include) ]] && [[ $in_auth_section -eq 1 ]]; then
        in_auth_section=0
    fi
    
    # Write all other lines as-is
    echo "$line" >> "$temp_file"
done < "$PAM_FILE"

# Replace the original file
mv "$temp_file" "$PAM_FILE"

print_success "Fixed SDDM PAM configuration"
echo ""
print_info "Changes made:"
echo "  • Removed duplicate pam_nextcloud entry"
echo "  • Replaced @include common-auth with proper fallback (sufficient pam_unix)"
echo ""
print_info "Updated auth section:"
grep "^auth" "$PAM_FILE" | head -10

echo ""
print_warning "IMPORTANT:"
echo "  1. Test login in a separate terminal/session before closing this one"
echo "  2. Keep a root shell open in case you need to revert"
echo "  3. Backup saved to: $backup_file"
echo ""
print_info "To revert changes:"
echo "  sudo cp $backup_file $PAM_FILE"

