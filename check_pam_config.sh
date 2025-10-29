#!/bin/bash
#
# PAM Configuration Diagnostic Script
#
# This script checks your PAM configuration to ensure pam_nextcloud
# is properly configured to take precedence over local authentication.
#

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

check_pam_file() {
    local pam_file="$1"
    local service_name="$2"
    
    if [[ ! -f "$pam_file" ]]; then
        return
    fi
    
    echo ""
    print_header "Checking $service_name ($pam_file)"
    
    # Check if pam_nextcloud is configured
    if grep -q "pam_nextcloud" "$pam_file"; then
        print_success "pam_nextcloud is configured"
        
        # Check the auth section
        echo ""
        print_info "Auth configuration:"
        grep "^auth" "$pam_file" | grep -E "(pam_nextcloud|pam_unix)" | head -5
        
        # Check if pam_nextcloud comes before pam_unix
        local nextcloud_line=$(grep -n "^auth.*pam_nextcloud" "$pam_file" | head -1 | cut -d: -f1)
        local unix_line=$(grep -n "^auth.*pam_unix" "$pam_file" | head -1 | cut -d: -f1)
        
        if [[ -n "$nextcloud_line" && -n "$unix_line" ]]; then
            if [[ $nextcloud_line -lt $unix_line ]]; then
                print_success "pam_nextcloud comes before pam_unix (correct order)"
            else
                print_error "pam_nextcloud comes AFTER pam_unix (should be first!)"
            fi
        fi
        
        # Check if pam_nextcloud uses 'sufficient'
        if grep -q "^auth.*sufficient.*pam_nextcloud" "$pam_file"; then
            print_success "pam_nextcloud uses 'sufficient' control flag (correct)"
        else
            print_warning "pam_nextcloud may not use 'sufficient' control flag"
            print_info "It should be: auth sufficient pam_python.so /lib/security/pam_nextcloud.py"
        fi
        
        # Check if pam_unix uses 'required' (which could cause issues)
        if grep -q "^auth.*required.*pam_unix" "$pam_file"; then
            print_warning "pam_unix uses 'required' - this may cause local password checks even after Nextcloud succeeds"
            print_info "Consider changing to 'sufficient' for pam_unix.so"
            print_info "Example: auth sufficient pam_unix.so nullok_secure try_first_pass"
        elif grep -q "^auth.*sufficient.*pam_unix" "$pam_file"; then
            print_success "pam_unix uses 'sufficient' (good for fallback)"
        fi
        
    else
        print_info "pam_nextcloud is not configured in this file"
    fi
}

print_header "PAM Configuration Diagnostic Tool"

echo "This script checks your PAM configuration files to ensure pam_nextcloud"
echo "is properly configured to take precedence over local authentication."
echo ""

# Check common PAM files
check_pam_file "/etc/pam.d/common-auth" "Common Auth"
check_pam_file "/etc/pam.d/sshd" "SSH"
check_pam_file "/etc/pam.d/lightdm" "LightDM"
check_pam_file "/etc/pam.d/gdm-password" "GDM"
check_pam_file "/etc/pam.d/gdm" "GDM (legacy)"
check_pam_file "/etc/pam.d/sddm" "SDDM"
check_pam_file "/etc/pam.d/sudo" "Sudo"

echo ""
print_header "Summary and Recommendations"

echo "If pam_nextcloud authentication succeeds but you're still seeing"
echo "'unix_chkpwd: password check failed' errors, your PAM configuration"
echo "likely needs adjustment."
echo ""
echo "The correct configuration should be:"
echo ""
echo "  auth sufficient pam_python.so /lib/security/pam_nextcloud.py"
echo "  auth sufficient pam_unix.so nullok_secure try_first_pass"
echo "  auth requisite   pam_deny.so"
echo "  auth required    pam_permit.so"
echo ""
echo "Key points:"
echo "  1. pam_nextcloud must come FIRST"
echo "  2. pam_nextcloud must use 'sufficient'"
echo "  3. pam_unix should use 'sufficient' (not 'required')"
echo ""
print_warning "Always backup your PAM config files before modifying them!"
print_warning "Incorrect PAM configuration can lock you out of your system!"

