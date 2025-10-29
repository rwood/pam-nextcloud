#!/bin/bash
#
# Update script for PAM Nextcloud module
#
# This script updates all installed components of the PAM Nextcloud integration
# while preserving user configuration and settings.
#
# Usage:
#   git pull && ./update.sh                    # Update to latest version
#   ./update.sh --interactive                  # Interactive mode with prompts
#

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
MODULE_NAME="pam_nextcloud.py"
CONFIG_NAME="pam_nextcloud.conf"
MODULE_DIR="/lib/security"
CONFIG_DIR="/etc/security"
TEST_SCRIPT="test_nextcloud_auth.py"

# Default values
INTERACTIVE_MODE=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --interactive|-i)
            INTERACTIVE_MODE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --interactive, -i  Interactive mode with prompts"
            echo "  -h, --help         Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Helper functions
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

# Normalize line endings to LF for a given file
normalize_line_endings() {
    local target_file="$1"
    if [[ -z "$target_file" || ! -f "$target_file" ]]; then
        return
    fi
    if command -v dos2unix >/dev/null 2>&1; then
        dos2unix -q "$target_file" || true
    else
        # Fallback: strip CR characters at EOL
        sed -i 's/\r$//' "$target_file" || true
    fi
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_warning "This script needs root privileges for updating system files."
        print_info "Attempting to use sudo..."
        exec sudo bash "$0" "$@"
    fi
}

# Check if installation exists
check_installation() {
    if [[ ! -f "$MODULE_DIR/$MODULE_NAME" ]]; then
        print_error "PAM Nextcloud module not found at $MODULE_DIR/$MODULE_NAME"
        print_info "Please run ./install.sh first to install the module"
        exit 1
    fi
    print_success "Found existing installation"
}

# Check if required source files exist
check_source_files() {
    local missing_files=()
    
    if [[ ! -f "$MODULE_NAME" ]]; then
        missing_files+=("$MODULE_NAME")
    fi
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        print_error "Required source files not found: ${missing_files[*]}"
        print_info "Please run this script from the PAM-Nextcloud directory"
        exit 1
    fi
}

# Detect Linux distribution
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO=$ID
        DISTRO_VERSION=$VERSION_ID
    else
        print_warning "Cannot detect Linux distribution, assuming generic Linux"
        DISTRO="unknown"
    fi
}

# Update Python dependencies
update_python_dependencies() {
    print_info "Updating Python dependencies..."
    
    detect_distro
    
    # Try to use system package manager first (for Debian/Ubuntu)
    if [[ "$DISTRO" == "ubuntu" ]] || [[ "$DISTRO" == "debian" ]]; then
        # Check if python3-requests package exists
        if apt-cache show python3-requests &>/dev/null; then
            print_info "Using system package manager to install python3-requests..."
            apt-get update
            apt-get install -y --only-upgrade python3-requests 2>/dev/null || apt-get install -y python3-requests
            print_success "Python dependencies updated via apt"
            return 0
        fi
    fi
    
    # Fallback to pip3 with --break-system-packages if needed
    if [[ -f "requirements.txt" ]]; then
        # Try without --break-system-packages first
        if pip3 install --upgrade -r requirements.txt 2>/dev/null; then
            print_success "Python dependencies updated"
        else
            # If that fails, try with --break-system-packages
            print_warning "System Python is externally managed, using --break-system-packages"
            pip3 install --upgrade --break-system-packages -r requirements.txt
            print_success "Python dependencies updated"
        fi
    else
        # Fallback: install requests if requirements.txt doesn't exist
        if pip3 install --upgrade requests 2>/dev/null; then
            print_success "Python dependencies updated (requests)"
        else
            print_warning "System Python is externally managed, using --break-system-packages"
            pip3 install --upgrade --break-system-packages requests
            print_success "Python dependencies updated (requests)"
        fi
    fi
}

# Update module files
update_modules() {
    print_info "Updating PAM module files..."
    
    # Update main module
    if [[ -f "$MODULE_NAME" ]]; then
        cp "$MODULE_NAME" "$MODULE_DIR/$MODULE_NAME"
        chmod 644 "$MODULE_DIR/$MODULE_NAME"
        chown root:root "$MODULE_DIR/$MODULE_NAME"
        normalize_line_endings "$MODULE_DIR/$MODULE_NAME"
        print_success "Updated: $MODULE_DIR/$MODULE_NAME"
    fi
    
    # Update desktop integration module
    if [[ -f "pam_nextcloud_desktop.py" ]]; then
        cp pam_nextcloud_desktop.py "$MODULE_DIR/pam_nextcloud_desktop.py"
        chmod 644 "$MODULE_DIR/pam_nextcloud_desktop.py"
        chown root:root "$MODULE_DIR/pam_nextcloud_desktop.py"
        normalize_line_endings "$MODULE_DIR/pam_nextcloud_desktop.py"
        print_success "Updated: $MODULE_DIR/pam_nextcloud_desktop.py"
    fi
    
    # Update group synchronization module
    if [[ -f "pam_nextcloud_groups.py" ]]; then
        cp pam_nextcloud_groups.py "$MODULE_DIR/pam_nextcloud_groups.py"
        chmod 644 "$MODULE_DIR/pam_nextcloud_groups.py"
        chown root:root "$MODULE_DIR/pam_nextcloud_groups.py"
        normalize_line_endings "$MODULE_DIR/pam_nextcloud_groups.py"
        print_success "Updated: $MODULE_DIR/pam_nextcloud_groups.py"
    fi
}

# Update test script
update_test_script() {
    if [[ -f "$TEST_SCRIPT" ]]; then
        cp "$TEST_SCRIPT" /usr/local/bin/test-pam-nextcloud
        chmod 755 /usr/local/bin/test-pam-nextcloud
        normalize_line_endings /usr/local/bin/test-pam-nextcloud
        print_success "Updated test script: /usr/local/bin/test-pam-nextcloud"
    fi
    
    # Update user provisioning script
    if [[ -f "provision-nextcloud-users.py" ]]; then
        cp provision-nextcloud-users.py /usr/local/bin/provision-nextcloud-users
        chmod 755 /usr/local/bin/provision-nextcloud-users
        normalize_line_endings /usr/local/bin/provision-nextcloud-users
        print_success "Updated provisioning script: /usr/local/bin/provision-nextcloud-users"
    fi
}

# Update desktop integration scripts
update_desktop_scripts() {
    print_info "Updating desktop integration scripts..."
    
    # Update GNOME setup script
    if [[ -f "gnome-nextcloud-setup.sh" ]]; then
        cp gnome-nextcloud-setup.sh /usr/local/bin/
        chmod 755 /usr/local/bin/gnome-nextcloud-setup.sh
        normalize_line_endings /usr/local/bin/gnome-nextcloud-setup.sh
        print_success "Updated: /usr/local/bin/gnome-nextcloud-setup.sh"
    fi
    
    # Update KDE setup script
    if [[ -f "kde-nextcloud-setup.sh" ]]; then
        cp kde-nextcloud-setup.sh /usr/local/bin/
        chmod 755 /usr/local/bin/kde-nextcloud-setup.sh
        normalize_line_endings /usr/local/bin/kde-nextcloud-setup.sh
        print_success "Updated: /usr/local/bin/kde-nextcloud-setup.sh"
    fi
}

# Update desktop autostart files
update_autostart_files() {
    print_info "Updating desktop autostart configurations..."
    
    # Update KDE autostart desktop file if script exists
    if [[ -f "kde-nextcloud-setup.sh" ]]; then
        mkdir -p /etc/xdg/autostart
        
        cat > /etc/xdg/autostart/kde-nextcloud-setup.desktop << 'DESKTOP_EOF'
[Desktop Entry]
Type=Application
Name=Nextcloud Integration Setup
Comment=Complete Nextcloud setup in System Settings (Online Accounts)
Exec=/usr/local/bin/kde-nextcloud-setup.sh
Hidden=false
NoDisplay=false
X-KDE-autostart-after=panel
DESKTOP_EOF
        
        chmod 644 /etc/xdg/autostart/kde-nextcloud-setup.desktop
        normalize_line_endings /etc/xdg/autostart/kde-nextcloud-setup.desktop
        print_success "Updated: /etc/xdg/autostart/kde-nextcloud-setup.desktop"
    fi
    
    # Update GNOME autostart desktop file if script exists
    if [[ -f "gnome-nextcloud-setup.sh" ]]; then
        mkdir -p /etc/xdg/autostart
        
        cat > /etc/xdg/autostart/gnome-nextcloud-setup.desktop << 'DESKTOP_EOF'
[Desktop Entry]
Type=Application
Name=Nextcloud Integration Setup
Comment=Complete Nextcloud setup in GNOME Settings
Exec=/usr/local/bin/gnome-nextcloud-setup.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Phase=Applications
DESKTOP_EOF
        
        chmod 644 /etc/xdg/autostart/gnome-nextcloud-setup.desktop
        normalize_line_endings /etc/xdg/autostart/gnome-nextcloud-setup.desktop
        print_success "Updated: /etc/xdg/autostart/gnome-nextcloud-setup.desktop"
    fi
}

# Handle configuration file update
update_config_file() {
    if [[ ! -f "$CONFIG_DIR/$CONFIG_NAME" ]]; then
        # Config doesn't exist, copy from example
        if [[ -f "pam_nextcloud.conf.example" ]]; then
            print_info "Creating configuration file from example..."
            cp pam_nextcloud.conf.example "$CONFIG_DIR/$CONFIG_NAME"
            chmod 644 "$CONFIG_DIR/$CONFIG_NAME"
            chown root:root "$CONFIG_DIR/$CONFIG_NAME"
            normalize_line_endings "$CONFIG_DIR/$CONFIG_NAME"
            print_success "Created: $CONFIG_DIR/$CONFIG_NAME"
            print_warning "Please edit $CONFIG_DIR/$CONFIG_NAME with your Nextcloud server details"
        fi
        return
    fi
    
    # Config exists - ask about updating
    if [[ "$INTERACTIVE_MODE" == true ]]; then
        echo ""
        print_warning "Configuration file exists: $CONFIG_DIR/$CONFIG_NAME"
        read -p "Update config file from example? This will overwrite your settings! (y/N): " update_config
        if [[ "$update_config" =~ ^[Yy]$ ]]; then
            if [[ -f "pam_nextcloud.conf.example" ]]; then
                # Backup existing config
                local backup_file="${CONFIG_DIR}/${CONFIG_NAME}.backup-$(date +%Y%m%d-%H%M%S)"
                cp "$CONFIG_DIR/$CONFIG_NAME" "$backup_file"
                print_success "Backed up existing config to: $backup_file"
                
                # Copy new config
                cp pam_nextcloud.conf.example "$CONFIG_DIR/$CONFIG_NAME"
                chmod 644 "$CONFIG_DIR/$CONFIG_NAME"
                chown root:root "$CONFIG_DIR/$CONFIG_NAME"
                normalize_line_endings "$CONFIG_DIR/$CONFIG_NAME"
                print_success "Configuration file updated"
                print_warning "Please review and update $CONFIG_DIR/$CONFIG_NAME with your settings"
            fi
        else
            print_info "Keeping existing configuration file"
        fi
    else
        # Non-interactive: preserve existing config
        print_info "Configuration file exists and will be preserved: $CONFIG_DIR/$CONFIG_NAME"
        if [[ -f "pam_nextcloud.conf.example" ]]; then
            print_info "If you want to update it, run: ./update.sh --interactive"
        fi
    fi
}

# Ensure cache directory exists
ensure_cache_directory() {
    if [[ ! -d "/var/cache/pam_nextcloud" ]]; then
        print_info "Creating cache directory..."
        mkdir -p /var/cache/pam_nextcloud
        chmod 700 /var/cache/pam_nextcloud
        chown root:root /var/cache/pam_nextcloud
        print_success "Cache directory ready: /var/cache/pam_nextcloud"
    else
        print_info "Cache directory exists: /var/cache/pam_nextcloud"
    fi
}

# Fix PAM configuration file to prevent local password checks after Nextcloud succeeds
fix_pam_file() {
    local pam_file="$1"
    local service_name="$2"
    
    if [[ ! -f "$pam_file" ]]; then
        return 1
    fi
    
    # Check if pam_nextcloud is configured in this file OR if it includes common-auth
    # (common-auth might have pam_nextcloud configured)
    local has_pam_nextcloud=false
    local includes_common_auth=false
    
    if grep -q "pam_nextcloud" "$pam_file"; then
        has_pam_nextcloud=true
    fi
    
    if grep -q "^@include[[:space:]]+common-auth" "$pam_file"; then
        # Check if common-auth has pam_nextcloud
        if [[ -f "/etc/pam.d/common-auth" ]] && grep -q "pam_nextcloud" "/etc/pam.d/common-auth"; then
            has_pam_nextcloud=true
            includes_common_auth=true
        fi
    fi
    
    # Only process if pam_nextcloud is configured (directly or via common-auth)
    if [[ "$has_pam_nextcloud" == false ]]; then
        return 1  # Not configured, skip
    fi
    
    # Backup the file
    local backup_file="${pam_file}.backup-$(date +%Y%m%d-%H%M%S)"
    cp "$pam_file" "$backup_file"
    
    # Create temporary file for new configuration
    local temp_file=$(mktemp)
    local changes_made=0
    local in_auth_section=0
    local nextcloud_added=0
    local nextcloud_line_num=0
    local unix_line_num=0
    
    # Process the file line by line
    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$((line_num + 1))
        
        # Check if we're entering the auth section
        if [[ "$line" =~ ^auth[[:space:]] ]]; then
            in_auth_section=1
            
            # Check for duplicate pam_nextcloud entries
            if [[ "$line" =~ pam_nextcloud ]] && [[ $nextcloud_added -eq 1 ]]; then
                print_info "Removing duplicate pam_nextcloud entry in $service_name"
                changes_made=1
                continue
            fi
            
            # Track first pam_nextcloud entry
            if [[ "$line" =~ pam_nextcloud ]]; then
                echo "$line" >> "$temp_file"
                nextcloud_added=1
                nextcloud_line_num=$line_num
                continue
            fi
            
            # Track pam_unix line
            if [[ "$line" =~ pam_unix ]]; then
                unix_line_num=$line_num
            fi
            
            # Fix pam_unix from 'required' to 'sufficient' if needed
            if [[ "$line" =~ pam_unix ]] && [[ "$line" =~ required ]] && [[ ! "$line" =~ sufficient ]]; then
                local modified_line=$(echo "$line" | sed 's/\brequired\b/sufficient/')
                echo "$modified_line" >> "$temp_file"
                print_info "Changed pam_unix from 'required' to 'sufficient' in $service_name"
                changes_made=1
                continue
            fi
            
            # Keep other auth entries as-is
            echo "$line" >> "$temp_file"
            continue
        fi
        
        # Check for @include common-auth in auth section - ALWAYS replace this!
        # Even if common-auth has pam_nextcloud, including it causes issues
        if [[ "$line" =~ ^@include[[:space:]]+common-auth ]] && [[ $in_auth_section -eq 1 ]]; then
            # If common-auth has pam_nextcloud but this file doesn't, add it now
            if [[ "$includes_common_auth" == true ]] && [[ "$nextcloud_added" != 1 ]]; then
                echo "auth    sufficient  pam_python.so /lib/security/pam_nextcloud.py" >> "$temp_file"
                nextcloud_added=1
                changes_made=1
                print_info "Added pam_nextcloud directly to $service_name"
            fi
            print_info "Replacing @include common-auth with proper fallback in $service_name"
            # Replace with proper fallback that won't force password check
            echo "auth    sufficient  pam_unix.so nullok_secure try_first_pass" >> "$temp_file"
            echo "auth    requisite   pam_deny.so" >> "$temp_file"
            echo "auth    required    pam_permit.so" >> "$temp_file"
            changes_made=1
            continue
        fi
        
        # Check if we're leaving auth section
        if [[ "$line" =~ ^(account|session|password|@include) ]] && [[ $in_auth_section -eq 1 ]]; then
            in_auth_section=0
        fi
        
        # Write all other lines as-is
        echo "$line" >> "$temp_file"
    done < "$pam_file"
    
    # If we made changes, replace the file
    if [[ $changes_made -eq 1 ]]; then
        mv "$temp_file" "$pam_file"
        print_success "Fixed PAM configuration: $service_name"
        return 0
    else
        rm -f "$temp_file"
        rm -f "$backup_file"  # No changes, remove backup
        return 1
    fi
}

# Fix PAM configurations for all services
fix_pam_configurations() {
    print_header "Checking and Fixing PAM Configurations"
    
    local services_fixed=0
    local services_checked=0
    
    # List of PAM service files to check
    local pam_services=(
        "/etc/pam.d/sddm:SDDM"
        "/etc/pam.d/gdm-password:GDM"
        "/etc/pam.d/gdm3:GDM3"
        "/etc/pam.d/lightdm:LightDM"
        "/etc/pam.d/sshd:SSH"
        "/etc/pam.d/sudo:Sudo"
        "/etc/pam.d/common-auth:Common Auth"
    )
    
    for service_entry in "${pam_services[@]}"; do
        local pam_file="${service_entry%%:*}"
        local service_name="${service_entry##*:}"
        
        if [[ -f "$pam_file" ]]; then
            services_checked=$((services_checked + 1))
            
            # Check if pam_nextcloud is configured
            if grep -q "pam_nextcloud" "$pam_file"; then
                # Already configured, just fix any issues
                if fix_pam_file "$pam_file" "$service_name"; then
                    services_fixed=$((services_fixed + 1))
                fi
            else
                # Not configured yet - offer to add it
                print_info "$service_name PAM file exists but pam_nextcloud is not configured"
                if [[ "$INTERACTIVE_MODE" == true ]]; then
                    read -p "Add pam_nextcloud to $service_name? (y/N): " add_pam
                    if [[ "$add_pam" =~ ^[Yy]$ ]]; then
                        add_pam_nextcloud_to_file "$pam_file" "$service_name"
                        services_fixed=$((services_fixed + 1))
                    fi
                else
                    print_info "Run with --interactive to add pam_nextcloud to $service_name"
                fi
            fi
        fi
    done
    
    if [[ $services_fixed -gt 0 ]]; then
        echo ""
        print_success "Fixed PAM configurations for $services_fixed service(s)"
        print_warning "Backups created with .backup-YYYYMMDD-HHMMSS extension"
        echo ""
        print_warning "IMPORTANT:"
        echo "  • Test login in a separate terminal/session before closing this one"
        echo "  • Keep a root shell open in case you need to revert"
        echo "  • Backup files are in /etc/pam.d/*.backup-*"
    elif [[ $services_checked -gt 0 ]]; then
        print_info "All PAM configurations are already correct"
    else
        print_info "No PAM service files found with pam_nextcloud configured"
    fi
    echo ""
}

# Add pam_nextcloud to a PAM file that doesn't have it yet
add_pam_nextcloud_to_file() {
    local pam_file="$1"
    local service_name="$2"
    
    # Backup the file
    local backup_file="${pam_file}.backup-$(date +%Y%m%d-%H%M%S)"
    cp "$pam_file" "$backup_file"
    
    # Add pam_nextcloud at the beginning of auth section
    if ! grep -q "auth\s\+.*pam_nextcloud\.py" "$pam_file"; then
        # Insert after the first auth line or at the beginning of auth section
        if grep -q "^auth" "$pam_file"; then
            sed -i "/^auth.*/ a auth    sufficient  pam_python.so /lib/security/pam_nextcloud.py" "$pam_file" || {
                # If sed fails, prepend to file
                echo "auth    sufficient  pam_python.so /lib/security/pam_nextcloud.py" | cat - "$pam_file" > "${pam_file}.tmp" && mv "${pam_file}.tmp" "$pam_file"
            }
        else
            # No auth section, add at beginning
            echo "auth    sufficient  pam_python.so /lib/security/pam_nextcloud.py" | cat - "$pam_file" > "${pam_file}.tmp" && mv "${pam_file}.tmp" "$pam_file"
        fi
        print_success "Added pam_nextcloud to $service_name"
        
        # Now fix any issues (like @include common-auth)
        fix_pam_file "$pam_file" "$service_name" > /dev/null 2>&1
        return 0
    fi
    
    return 1
}

# Main update function
update() {
    print_header "Updating PAM Nextcloud Module"
    
    # Verify installation exists
    check_installation
    
    # Verify source files exist
    check_source_files
    
    # Update Python dependencies
    update_python_dependencies
    
    # Update module files
    update_modules
    
    # Update test script
    update_test_script
    
    # Update desktop integration scripts
    update_desktop_scripts
    
    # Update desktop autostart files
    update_autostart_files
    
    # Handle configuration file
    update_config_file
    
    # Ensure cache directory exists
    ensure_cache_directory
    
    # Fix PAM configurations
    fix_pam_configurations
    
    echo ""
    print_success "Update complete!"
    echo ""
    
    print_info "Updated components:"
    echo "  • PAM module files in $MODULE_DIR"
    echo "  • Test script: /usr/local/bin/test-pam-nextcloud"
    echo "  • Desktop integration scripts"
    echo "  • Desktop autostart configurations"
    echo "  • Python dependencies"
    echo "  • PAM configuration files (fixed common issues)"
    echo ""
    
    print_warning "IMPORTANT NOTES:"
    echo "  • Configuration file preserved (run with --interactive to update)"
    echo "  • PAM configurations were checked and fixed if needed"
    echo "  • If you updated from a version with breaking changes, check:"
    echo "    - $CONFIG_DIR/$CONFIG_NAME for new options"
    echo "    - README.md for migration notes"
    echo ""
    
    print_info "You may want to test authentication:"
    echo "  test-pam-nextcloud --username YOUR_USERNAME"
    echo ""
}

# Main execution
check_root "$@"
update

echo ""
print_info "For more information, see README.md"

