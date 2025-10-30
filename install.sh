#!/bin/bash
#
# Installation script for PAM Nextcloud module
#
# This script automates the installation of the PAM Nextcloud authentication module.
# It can be run with or without sudo - it will prompt for elevation when needed.
#
# Usage:
#   ./install.sh                    # Interactive installation
#   ./install.sh --auto             # Non-interactive (assumes defaults)
#   ./install.sh --uninstall        # Remove the module
#

# Self-normalize line endings if this file has CRLF endings
# This allows the script to run even if checked out with Windows line endings
if command -v dos2unix >/dev/null 2>&1; then
    dos2unix -q "$0" 2>/dev/null || true
elif command -v sed >/dev/null 2>&1; then
    # Fallback: strip CR characters
    sed -i 's/\r$//' "$0" 2>/dev/null || true
fi

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
AUTO_MODE=false
UNINSTALL_MODE=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --auto)
            AUTO_MODE=true
            shift
            ;;
        --uninstall)
            UNINSTALL_MODE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --auto        Non-interactive installation"
            echo "  --uninstall   Remove the PAM Nextcloud module"
            echo "  -h, --help    Show this help message"
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
        print_warning "This script needs root privileges for installation."
        print_info "Attempting to use sudo..."
        exec sudo bash "$0" "$@"
    fi
}

# Detect Linux distribution
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO=$ID
        DISTRO_VERSION=$VERSION_ID
    else
        print_error "Cannot detect Linux distribution"
        exit 1
    fi
}

# Install system dependencies
install_dependencies() {
    print_info "Installing system dependencies..."
    
    case $DISTRO in
        ubuntu|debian)
            apt-get update
            apt-get install -y libpam-python python3 python3-pip libnotify-bin
            # Try to install python3-requests via apt first
            if apt-cache show python3-requests &>/dev/null; then
                apt-get install -y python3-requests || {
                    # Fallback to pip3
                    print_warning "python3-requests not available via apt, using pip3"
                    pip3 install --break-system-packages requests || pip3 install requests
                }
            else
                # Fallback to pip3
                print_info "Installing requests via pip3..."
                pip3 install --break-system-packages requests 2>/dev/null || pip3 install requests
            fi
            ;;
        fedora|rhel|centos)
            dnf install -y pam_python python3 python3-pip libnotify
            # Install Python dependencies
            pip3 install --break-system-packages requests 2>/dev/null || pip3 install requests
            ;;
        arch|manjaro)
            pacman -S --noconfirm python-pam python python-pip libnotify
            # Install Python dependencies
            pip3 install requests
            ;;
        *)
            print_warning "Unsupported distribution: $DISTRO"
            print_info "Please install pam_python, Python 3, and libnotify manually"
            # Try to install requests anyway
            pip3 install --break-system-packages requests 2>/dev/null || pip3 install requests || true
            return 1
            ;;
    esac
    
    print_success "Dependencies installed"
}

# Uninstall function
uninstall() {
    print_header "Uninstalling PAM Nextcloud Module"
    
    # Remove module
    if [[ -f "$MODULE_DIR/$MODULE_NAME" ]]; then
        rm -f "$MODULE_DIR/$MODULE_NAME"
        print_success "Removed module: $MODULE_DIR/$MODULE_NAME"
    fi
    
    
    if [[ -f "$MODULE_DIR/pam_nextcloud_groups.py" ]]; then
        rm -f "$MODULE_DIR/pam_nextcloud_groups.py"
        print_success "Removed: $MODULE_DIR/pam_nextcloud_groups.py"
    fi
    
    if [[ -f "/usr/local/bin/gnome-nextcloud-setup.sh" ]]; then
        rm -f /usr/local/bin/gnome-nextcloud-setup.sh
        print_success "Removed: /usr/local/bin/gnome-nextcloud-setup.sh"
    fi
    
    if [[ -f "/usr/local/bin/kde-nextcloud-setup.sh" ]]; then
        rm -f /usr/local/bin/kde-nextcloud-setup.sh
        print_success "Removed: /usr/local/bin/kde-nextcloud-setup.sh"
    fi
    
    # Remove sync script
    if [[ -f "/usr/local/bin/pam-nextcloud-sync" ]]; then
        rm -f /usr/local/bin/pam-nextcloud-sync
        print_success "Removed: /usr/local/bin/pam-nextcloud-sync"
    fi
    
    # Remove old scripts if they exist
    if [[ -f "/usr/local/bin/provision-nextcloud-users" ]]; then
        rm -f /usr/local/bin/provision-nextcloud-users
        print_success "Removed: /usr/local/bin/provision-nextcloud-users"
    fi
    
    if [[ -f "/usr/local/bin/provision-nextcloud-groups" ]]; then
        rm -f /usr/local/bin/provision-nextcloud-groups
        print_success "Removed: /usr/local/bin/provision-nextcloud-groups"
    fi
    
    
    # Ask about config file
    if [[ -f "$CONFIG_DIR/$CONFIG_NAME" ]]; then
        if [[ "$AUTO_MODE" == false ]]; then
            read -p "Remove configuration file? (y/N): " remove_config
            if [[ "$remove_config" =~ ^[Yy]$ ]]; then
                rm -f "$CONFIG_DIR/$CONFIG_NAME"
                print_success "Removed configuration: $CONFIG_DIR/$CONFIG_NAME"
            fi
        else
            print_info "Keeping configuration file: $CONFIG_DIR/$CONFIG_NAME"
        fi
    fi
    
    # Ask about cache directory
    if [[ -d "/var/cache/pam_nextcloud" ]]; then
        if [[ "$AUTO_MODE" == false ]]; then
            read -p "Remove cached credentials? (y/N): " remove_cache
            if [[ "$remove_cache" =~ ^[Yy]$ ]]; then
                rm -rf /var/cache/pam_nextcloud
                print_success "Removed cache directory: /var/cache/pam_nextcloud"
            fi
        else
            print_info "Keeping cache directory: /var/cache/pam_nextcloud"
        fi
    fi
    
    print_success "Uninstallation complete"
    print_warning "Don't forget to remove pam_nextcloud from your PAM configuration!"
}

# Fix PAM configuration file to prevent local password checks after Nextcloud succeeds
fix_pam_file() {
    local pam_file="$1"
    local service_name="$2"
    
    if [[ ! -f "$pam_file" ]]; then
        return 1
    fi
    
    # Check if pam_nextcloud is configured in this file OR if it includes common-auth/common-password
    # (common-auth/common-password might have pam_nextcloud configured)
    local has_pam_nextcloud=false
    local includes_common_auth=false
    local includes_common_password=false
    
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
    
    if grep -q "^@include[[:space:]]+common-password" "$pam_file"; then
        # Check if common-password has pam_nextcloud
        if [[ -f "/etc/pam.d/common-password" ]] && grep -q "pam_nextcloud" "/etc/pam.d/common-password"; then
            has_pam_nextcloud=true
            includes_common_password=true
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
    local in_password_section=0
    local nextcloud_added=0
    local nextcloud_password_added=0
    
    # If file includes common-auth and common-auth has pam_nextcloud,
    # we need to add pam_nextcloud directly to this file and replace the include
    if [[ "$includes_common_auth" == true ]] && ! grep -q "auth\s\+.*pam_nextcloud\.py" "$pam_file"; then
        # We'll add pam_nextcloud when we encounter the @include line
        # Mark that we need to add it
        nextcloud_added=-1  # Special flag: needs to be added before @include
    fi
    
    # Process the file line by line
    while IFS= read -r line || [[ -n "$line" ]]; do
        # If we need to add pam_nextcloud before @include common-auth
        if [[ "$nextcloud_added" == -1 ]] && [[ "$line" =~ ^@include[[:space:]]+common-auth ]] && [[ $in_auth_section -eq 1 ]]; then
            # Add pam_nextcloud before this include
            echo "auth    sufficient  pam_python.so /lib/security/pam_nextcloud.py" >> "$temp_file"
            nextcloud_added=1
            changes_made=1
            print_info "Added pam_nextcloud directly to $service_name (replacing common-auth include)"
            # Now replace the include
            print_info "Replacing @include common-auth with proper fallback in $service_name"
            echo "auth    sufficient  pam_unix.so nullok_secure try_first_pass" >> "$temp_file"
            echo "auth    requisite   pam_deny.so" >> "$temp_file"
            echo "auth    required    pam_permit.so" >> "$temp_file"
            changes_made=1
            continue
        fi
        
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
                continue
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
            # If we haven't added pam_nextcloud yet, add it now
            if [[ "$nextcloud_added" != 1 ]]; then
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
        
        # Check if we're entering password section
        if [[ "$line" =~ ^password[[:space:]] ]]; then
            in_password_section=1
            
            # Check for duplicate pam_nextcloud password entries
            if [[ "$line" =~ pam_nextcloud ]] && [[ $nextcloud_password_added -eq 1 ]]; then
                print_info "Removing duplicate pam_nextcloud password entry in $service_name"
                changes_made=1
                continue
            fi
            
            # Track first pam_nextcloud password entry
            if [[ "$line" =~ pam_nextcloud ]]; then
                echo "$line" >> "$temp_file"
                nextcloud_password_added=1
                continue
            fi
            
            # If pam_unix comes before pam_nextcloud, we need to reorder
            if [[ "$line" =~ pam_unix ]] && [[ $nextcloud_password_added -eq 0 ]]; then
                # Add pam_nextcloud before pam_unix
                echo "password sufficient pam_python.so /lib/security/pam_nextcloud.py" >> "$temp_file"
                nextcloud_password_added=1
                changes_made=1
                print_info "Added pam_nextcloud before pam_unix in password section: $service_name"
            fi
            
            # Keep password entry as-is
            echo "$line" >> "$temp_file"
            continue
        fi
        
        # Check for @include common-password in password section - handle similar to common-auth
        if [[ "$line" =~ ^@include[[:space:]]+common-password ]] && [[ $in_password_section -eq 1 ]]; then
            # If we haven't added pam_nextcloud password yet, add it now
            if [[ "$nextcloud_password_added" != 1 ]]; then
                echo "password sufficient pam_python.so /lib/security/pam_nextcloud.py" >> "$temp_file"
                nextcloud_password_added=1
                changes_made=1
                print_info "Added pam_nextcloud directly to $service_name password section"
            fi
            print_info "Replacing @include common-password with proper fallback in $service_name"
            # Replace with proper fallback
            echo "password sufficient pam_unix.so use_authtok" >> "$temp_file"
            changes_made=1
            continue
        fi
        
        # Check if we're leaving auth or password sections
        if [[ "$line" =~ ^(account|session|@include) ]]; then
            if [[ $in_auth_section -eq 1 ]]; then
                in_auth_section=0
            fi
            if [[ $in_password_section -eq 1 ]]; then
                in_password_section=0
            fi
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
    
    # First, check and fix common-auth (the main configuration)
    if [[ -f "/etc/pam.d/common-auth" ]]; then
        if grep -q "pam_nextcloud" "/etc/pam.d/common-auth"; then
            if fix_pam_file "/etc/pam.d/common-auth" "Common Auth"; then
                services_fixed=$((services_fixed + 1))
            fi
            services_checked=$((services_checked + 1))
        fi
    fi
    
    # Check and fix common-password (for password changes)
    if [[ -f "/etc/pam.d/common-password" ]]; then
        if grep -q "pam_nextcloud" "/etc/pam.d/common-password"; then
            if fix_pam_file "/etc/pam.d/common-password" "Common Password"; then
                services_fixed=$((services_fixed + 1))
            fi
            services_checked=$((services_checked + 1))
        fi
    fi
    
        # List of PAM service files that might include common-auth or common-password
        # We fix any issues with @include directives, but don't add pam_nextcloud directly to these
        local pam_services=(
            "/etc/pam.d/passwd:Passwd"
            "/etc/pam.d/sddm:SDDM"
            "/etc/pam.d/gdm-password:GDM"
            "/etc/pam.d/gdm3:GDM3"
            "/etc/pam.d/lightdm:LightDM"
            "/etc/pam.d/sshd:SSH"
            "/etc/pam.d/sudo:Sudo"
        )
        
        # Check if common-auth or common-password has pam_nextcloud configured
        local common_auth_has_pam_nextcloud=false
        local common_password_has_pam_nextcloud=false
        if [[ -f "/etc/pam.d/common-auth" ]] && grep -q "pam_nextcloud" "/etc/pam.d/common-auth"; then
            common_auth_has_pam_nextcloud=true
        fi
        if [[ -f "/etc/pam.d/common-password" ]] && grep -q "pam_nextcloud" "/etc/pam.d/common-password"; then
            common_password_has_pam_nextcloud=true
        fi
        
        # Only fix services if common-auth or common-password is configured
        if [[ "$common_auth_has_pam_nextcloud" == true ]] || [[ "$common_password_has_pam_nextcloud" == true ]]; then
            for service_entry in "${pam_services[@]}"; do
                local pam_file="${service_entry%%:*}"
                local service_name="${service_entry##*:}"
                
                if [[ -f "$pam_file" ]]; then
                    services_checked=$((services_checked + 1))
                    
                    # If service includes common-auth or common-password, fix any issues
                    if grep -q "^@include[[:space:]]+common-auth" "$pam_file" || grep -q "^@include[[:space:]]+common-password" "$pam_file"; then
                        # Fix any issues (like replacing @include with proper fallback if needed)
                        if fix_pam_file "$pam_file" "$service_name"; then
                            services_fixed=$((services_fixed + 1))
                        fi
                    elif grep -q "pam_nextcloud" "$pam_file"; then
                        # Service has pam_nextcloud directly configured, fix any issues
                        if fix_pam_file "$pam_file" "$service_name"; then
                            services_fixed=$((services_fixed + 1))
                        fi
                    fi
                fi
            done
        fi
    
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

# Main installation function
install() {
    print_header "Installing PAM Nextcloud Module"
    
    # Check if files exist
    if [[ ! -f "$MODULE_NAME" ]]; then
        print_error "Module file not found: $MODULE_NAME"
        print_info "Please run this script from the PAM-Nextcloud directory"
        exit 1
    fi
    
    # Install dependencies
    if [[ "$AUTO_MODE" == false ]]; then
        read -p "Install system dependencies? (Y/n): " install_deps
        if [[ ! "$install_deps" =~ ^[Nn]$ ]]; then
            detect_distro
            install_dependencies || print_warning "Failed to install dependencies automatically"
        fi
    else
        detect_distro
        install_dependencies || print_warning "Failed to install dependencies automatically"
    fi
    
    # Create directories if they don't exist
    mkdir -p "$MODULE_DIR"
    mkdir -p "$CONFIG_DIR"
    
    # Install module
    print_info "Installing PAM module..."
    cp "$MODULE_NAME" "$MODULE_DIR/$MODULE_NAME"
    chmod 644 "$MODULE_DIR/$MODULE_NAME"
    chown root:root "$MODULE_DIR/$MODULE_NAME"
    print_success "Installed: $MODULE_DIR/$MODULE_NAME"
    
    
    # Install group synchronization module
    if [[ -f "pam_nextcloud_groups.py" ]]; then
        cp pam_nextcloud_groups.py "$MODULE_DIR/pam_nextcloud_groups.py"
        chmod 644 "$MODULE_DIR/pam_nextcloud_groups.py"
        chown root:root "$MODULE_DIR/pam_nextcloud_groups.py"
        print_success "Installed: $MODULE_DIR/pam_nextcloud_groups.py"
    fi
    
    # Install test script
    if [[ -f "$TEST_SCRIPT" ]]; then
        cp "$TEST_SCRIPT" /usr/local/bin/test-pam-nextcloud
        chmod 755 /usr/local/bin/test-pam-nextcloud
        normalize_line_endings /usr/local/bin/test-pam-nextcloud
        print_success "Installed test script: /usr/local/bin/test-pam-nextcloud"
    fi
    
    # Install sync script
    if [[ -f "pam-nextcloud-sync.py" ]]; then
        cp pam-nextcloud-sync.py /usr/local/bin/pam-nextcloud-sync
        chmod 755 /usr/local/bin/pam-nextcloud-sync
        normalize_line_endings /usr/local/bin/pam-nextcloud-sync
        print_success "Installed sync script: /usr/local/bin/pam-nextcloud-sync"
    fi
    
    
    # Handle configuration file
    if [[ -f "$CONFIG_DIR/$CONFIG_NAME" ]]; then
        print_warning "Configuration file already exists: $CONFIG_DIR/$CONFIG_NAME"
        if [[ "$AUTO_MODE" == false ]]; then
            read -p "Overwrite? (y/N): " overwrite
            if [[ "$overwrite" =~ ^[Yy]$ ]]; then
                cp pam_nextcloud.conf.example "$CONFIG_DIR/$CONFIG_NAME"
                chmod 644 "$CONFIG_DIR/$CONFIG_NAME"
                chown root:root "$CONFIG_DIR/$CONFIG_NAME"
                # Ensure Linux line endings
                normalize_line_endings "$CONFIG_DIR/$CONFIG_NAME"
                print_success "Configuration file overwritten"
            fi
        fi
    else
        print_info "Installing configuration file..."
        cp pam_nextcloud.conf.example "$CONFIG_DIR/$CONFIG_NAME"
        # Make readable by all (but writable only by root) so desktop integration works
        chmod 644 "$CONFIG_DIR/$CONFIG_NAME"
        chown root:root "$CONFIG_DIR/$CONFIG_NAME"
        # Ensure Linux line endings
        normalize_line_endings "$CONFIG_DIR/$CONFIG_NAME"
        print_success "Installed: $CONFIG_DIR/$CONFIG_NAME"
    fi

    # Prompt for Nextcloud server URL and update config
    if [[ -f "$CONFIG_DIR/$CONFIG_NAME" ]] && [[ "$AUTO_MODE" == false ]]; then
        prompt_nextcloud_url
    fi
    
    # Create cache directory (if it doesn't exist)
    print_info "Creating cache directory..."
    mkdir -p /var/cache/pam_nextcloud
    chmod 700 /var/cache/pam_nextcloud
    chown root:root /var/cache/pam_nextcloud
    print_success "Cache directory ready: /var/cache/pam_nextcloud"
    
    # Ensure /etc/skel has standard directories for new users
    print_info "Setting up /etc/skel for new user home directories..."
    setup_skel_directory
    print_success "User skeleton directory configured"
    
    print_success "Installation complete!"
    echo ""
    
    # Offer to configure PAM
    if [[ "$AUTO_MODE" == false ]]; then
        echo ""
        print_warning "PAM CONFIGURATION"
        print_warning "Incorrect PAM configuration can lock you out of your system!"
        print_warning "Make sure you understand what you're doing and keep a root shell open."
        echo ""
        read -p "Would you like to configure PAM now? (y/N): " configure_pam
        
        if [[ "$configure_pam" =~ ^[Yy]$ ]]; then
            configure_pam_interactive
        else
            print_info "Skipping PAM configuration"
            print_info "You can configure PAM manually later using the examples in pam-config-examples/"
        fi
    fi
    
    # Fix any PAM configuration issues after installation/configuration
    fix_pam_configurations
    
    echo ""
    print_info "Next steps:"
    echo "  1. Edit $CONFIG_DIR/$CONFIG_NAME with your Nextcloud server details"
    echo "  2. (Optional) Enable offline authentication caching in config"
    echo "  3. Test authentication: test-pam-nextcloud --username YOUR_USERNAME"
    echo "  4. (Optional) Run pam-nextcloud-sync to sync users and groups on demand"
    if [[ "$AUTO_MODE" == false ]] && [[ ! "$configure_pam" =~ ^[Yy]$ ]]; then
        echo "  5. Configure PAM (see pam-config-examples/ directory)"
    fi
    echo ""
    print_warning "IMPORTANT: Always keep a root shell open when testing PAM configuration!"
}

# Prompt for Nextcloud URL and update the configuration file
prompt_nextcloud_url() {
    echo ""
    print_header "Nextcloud Server Configuration"

    local current_url
    current_url=$(awk -F'=' '/^url[ \t]*=/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}' "$CONFIG_DIR/$CONFIG_NAME" | head -1)

    local server_url=""
    while true; do
        if [[ -n "$current_url" ]]; then
            read -p "Enter Nextcloud server URL [${current_url}]: " server_url
            server_url=${server_url:-$current_url}
        else
            read -p "Enter Nextcloud server URL (e.g., https://cloud.example.com): " server_url
        fi

        # Basic validation
        if [[ -z "$server_url" ]]; then
            print_warning "URL cannot be empty."
            continue
        fi
        if [[ ! "$server_url" =~ ^https?:// ]]; then
            print_warning "URL should start with http:// or https://"
            continue
        fi
        break
    done

    update_nextcloud_url_in_config "$server_url"
}

# Update the url key within the [nextcloud] section in the config
update_nextcloud_url_in_config() {
    local new_url="$1"
    local tmp_file="$CONFIG_DIR/$CONFIG_NAME.tmp"

    awk -v url="$new_url" '
        BEGIN{insec=0; done=0}
        /^\[nextcloud\]/{print; insec=1; next}
        /^\[.*\]/{
            if(insec && !done){print "url = " url; done=1}
            insec=0
        }
        {
            if(insec && $0 ~ /^url[ \t]*=/){
                if(!done){print "url = " url; done=1}
                next
            }
            print
        }
        END{ if(insec && !done){print "url = " url} }
    ' "$CONFIG_DIR/$CONFIG_NAME" > "$tmp_file" && mv "$tmp_file" "$CONFIG_DIR/$CONFIG_NAME"

    if [[ $? -eq 0 ]]; then
        print_success "Updated Nextcloud URL in $CONFIG_DIR/$CONFIG_NAME"
    else
        print_warning "Failed to update URL; please edit $CONFIG_DIR/$CONFIG_NAME manually."
        rm -f "$tmp_file" 2>/dev/null || true
    fi
}

# Configure PAM - only configure common-auth
configure_pam_interactive() {
    print_header "Configuring PAM (Common Auth)"
    
    print_info "This will configure common-auth for all services (SSH, sudo, desktop login, etc.)"
    print_info "Configuration will include: Authentication, Session, and Password change"
    
    configure_common_auth
}

# Configure common-auth with all features enabled
configure_common_auth() {
    local pam_file="/etc/pam.d/common-auth"
    local service_name="Common Auth"
    
    print_info "Configuring PAM for $service_name"
    
    # Check if PAM file exists
    if [[ ! -f "$pam_file" ]]; then
        print_warning "PAM file not found: $pam_file"
        print_info "Creating new file..."
    fi
    
    # Backup existing file
    if [[ -f "$pam_file" ]]; then
        local backup_file="${pam_file}.backup-$(date +%Y%m%d-%H%M%S)"
        cp "$pam_file" "$backup_file"
        print_success "Backed up to: $backup_file"
    fi
    
    # Add authentication line (avoid duplicates)
    print_info "Adding authentication configuration..."
    
    if [[ -f "$pam_file" ]]; then
        if ! grep -q "auth\s\+.*pam_nextcloud\.py" "$pam_file"; then
            # Insert after the first auth line or at the beginning of auth section
            sed -i "/^auth.*/ a auth    sufficient  pam_python.so /lib/security/pam_nextcloud.py" "$pam_file" || {
                # If sed fails, append to file
                echo "auth    sufficient  pam_python.so /lib/security/pam_nextcloud.py" >> "$pam_file"
            }
        else
            print_info "Auth configuration already present; skipping duplicate insert"
        fi
    else
        # Create new file
        cat > "$pam_file" << 'EOF'
# PAM configuration for nextcloud authentication
auth    sufficient  pam_python.so /lib/security/pam_nextcloud.py
auth    sufficient  pam_unix.so nullok_secure try_first_pass
auth    requisite   pam_deny.so
auth    required    pam_permit.so

account required    pam_unix.so
EOF
    fi
    
    
    # Add password configuration (must come before pam_unix)
    print_info "Adding password change configuration..."
    
    if ! grep -q "password.*pam_nextcloud" "$pam_file"; then
        # Insert before the first password line (usually pam_unix)
        if grep -q "^password.*pam_unix" "$pam_file"; then
            # Insert before pam_unix
            sed -i "/^password.*pam_unix/ i password sufficient pam_python.so /lib/security/pam_nextcloud.py" "$pam_file" || {
                echo "password sufficient pam_python.so /lib/security/pam_nextcloud.py" >> "$pam_file"
            }
        else
            # No existing password lines, add at beginning
            sed -i "/^password.*/ a password sufficient pam_python.so /lib/security/pam_nextcloud.py" "$pam_file" || {
                echo "password sufficient pam_python.so /lib/security/pam_nextcloud.py" >> "$pam_file"
            }
        fi
    fi
    
    
    # Configure common-password if it exists
    configure_common_password
    
    print_success "PAM configured for $service_name"
    
    # Show what was configured
    echo ""
    print_info "Current configuration for common-auth:"
    grep "pam_nextcloud" "$pam_file" || echo "  (no pam_nextcloud lines found - manual configuration may be needed)"
    
    echo ""
    print_warning "IMPORTANT REMINDERS:"
    echo "  1. Keep this terminal/shell open!"
    echo "  2. Open a NEW terminal to test authentication"
    echo "  3. Do NOT close this terminal until you've verified login works"
    echo "  4. If you get locked out, use the backup: $backup_file"
    echo ""
}


# Configure common-password for password changes
configure_common_password() {
    local pam_file="/etc/pam.d/common-password"
    
    if [[ ! -f "$pam_file" ]]; then
        return
    fi
    
    # Backup existing file
    if [[ -f "$pam_file" ]]; then
        local backup_file="${pam_file}.backup-$(date +%Y%m%d-%H%M%S)"
        cp "$pam_file" "$backup_file"
    fi
    
    # Add password configuration if not present (must come before pam_unix)
    if ! grep -q "password.*pam_nextcloud" "$pam_file"; then
        # Insert before the first password line (usually pam_unix)
        if grep -q "^password.*pam_unix" "$pam_file"; then
            # Insert before pam_unix
            sed -i "/^password.*pam_unix/ i password sufficient pam_python.so /lib/security/pam_nextcloud.py" "$pam_file" || {
                echo "password sufficient pam_python.so /lib/security/pam_nextcloud.py" >> "$pam_file"
            }
        else
            # No existing password lines, add at beginning
            sed -i "/^password.*/ a password sufficient pam_python.so /lib/security/pam_nextcloud.py" "$pam_file" || {
                echo "password sufficient pam_python.so /lib/security/pam_nextcloud.py" >> "$pam_file"
            }
        fi
        print_info "Added password configuration to common-password"
    fi
}

# Set up /etc/skel with standard directories for new users
setup_skel_directory() {
    local skel_dir="/etc/skel"
    
    # Ensure /etc/skel exists
    if [[ ! -d "$skel_dir" ]]; then
        mkdir -p "$skel_dir"
        chmod 755 "$skel_dir"
        chown root:root "$skel_dir"
    fi
    
    # Create standard directories if they don't exist
    local standard_dirs=(
        ".config"
        ".cache"
        ".local"
        ".local/share"
        ".local/state"
    )
    
    for dir_name in "${standard_dirs[@]}"; do
        local dir_path="$skel_dir/$dir_name"
        if [[ ! -d "$dir_path" ]]; then
            mkdir -p "$dir_path"
            chmod 755 "$dir_path"
            chown root:root "$dir_path"
        fi
    done
}

# Main execution
if [[ "$UNINSTALL_MODE" == true ]]; then
    check_root
    uninstall
else
    check_root
    install
fi

echo ""
print_info "For more information, see README.md"

