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
    
    # Remove desktop integration files
    if [[ -f "$MODULE_DIR/pam_nextcloud_desktop.py" ]]; then
        rm -f "$MODULE_DIR/pam_nextcloud_desktop.py"
        print_success "Removed: $MODULE_DIR/pam_nextcloud_desktop.py"
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
    
    if [[ -f "/etc/xdg/autostart/gnome-nextcloud-setup.desktop" ]]; then
        rm -f /etc/xdg/autostart/gnome-nextcloud-setup.desktop
        print_success "Removed: /etc/xdg/autostart/gnome-nextcloud-setup.desktop"
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
                if [[ "$AUTO_MODE" == false ]]; then
                    read -p "Add pam_nextcloud to $service_name? (y/N): " add_pam
                    if [[ "$add_pam" =~ ^[Yy]$ ]]; then
                        add_pam_nextcloud_to_file "$pam_file" "$service_name"
                        services_fixed=$((services_fixed + 1))
                    fi
                else
                    print_info "Skipping $service_name (use interactive mode to configure)"
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
    
    # Install desktop integration module
    if [[ -f "pam_nextcloud_desktop.py" ]]; then
        cp pam_nextcloud_desktop.py "$MODULE_DIR/pam_nextcloud_desktop.py"
        chmod 644 "$MODULE_DIR/pam_nextcloud_desktop.py"
        chown root:root "$MODULE_DIR/pam_nextcloud_desktop.py"
        print_success "Installed: $MODULE_DIR/pam_nextcloud_desktop.py"
    fi
    
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
        print_success "Installed test script: /usr/local/bin/test-pam-nextcloud"
    fi
    
    # Install user provisioning script
    if [[ -f "provision-nextcloud-users.py" ]]; then
        cp provision-nextcloud-users.py /usr/local/bin/provision-nextcloud-users
        chmod 755 /usr/local/bin/provision-nextcloud-users
        print_success "Installed provisioning script: /usr/local/bin/provision-nextcloud-users"
    fi
    
    # Install desktop integration scripts
    if [[ -f "gnome-nextcloud-setup.sh" ]]; then
        cp gnome-nextcloud-setup.sh /usr/local/bin/
        chmod 755 /usr/local/bin/gnome-nextcloud-setup.sh
        print_success "Installed: /usr/local/bin/gnome-nextcloud-setup.sh"
    fi
    
    if [[ -f "kde-nextcloud-setup.sh" ]]; then
        cp kde-nextcloud-setup.sh /usr/local/bin/
        chmod 755 /usr/local/bin/kde-nextcloud-setup.sh
        print_success "Installed: /usr/local/bin/kde-nextcloud-setup.sh"
    fi
    
    # Install KDE autostart desktop file
    if [[ -f "kde-nextcloud-setup.sh" ]]; then
        print_info "Installing KDE autostart configuration..."
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
        print_success "Installed: /etc/xdg/autostart/kde-nextcloud-setup.desktop"
    fi
    
    # Install GNOME autostart desktop file
    if [[ -f "gnome-nextcloud-setup.sh" ]]; then
        print_info "Installing GNOME autostart configuration..."
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
        print_success "Installed: /etc/xdg/autostart/gnome-nextcloud-setup.desktop"
    fi
    
    # Handle configuration file
    if [[ -f "$CONFIG_DIR/$CONFIG_NAME" ]]; then
        print_warning "Configuration file already exists: $CONFIG_DIR/$CONFIG_NAME"
        if [[ "$AUTO_MODE" == false ]]; then
            read -p "Overwrite? (y/N): " overwrite
            if [[ "$overwrite" =~ ^[Yy]$ ]]; then
                cp pam_nextcloud.conf.example "$CONFIG_DIR/$CONFIG_NAME"
                # Make readable by all (but writable only by root) so desktop integration works
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
    echo "  3. (Optional) Enable group synchronization in config"
    echo "  4. Test authentication: test-pam-nextcloud --username YOUR_USERNAME"
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

# Configure PAM interactively
configure_pam_interactive() {
    print_header "Configuring PAM"
    
    echo "Select which PAM service to configure:"
    echo "  1) SSH (sshd) - For SSH login"
    echo "  2) Display Manager (lightdm/gdm/sddm) - For graphical login"
    echo "  3) Common Auth - For all services"
    echo "  4) Sudo - For sudo authentication"
    echo "  5) Standard setup (SSHD + Display Manager + Sudo)"
    echo "  6) Cancel"
    echo ""
    read -p "Choice [1-5]: " pam_choice
    
    case $pam_choice in
        1)
            configure_pam_service "sshd" "SSH"
            ;;
        2)
            # Detect display manager
            if command -v lightdm &> /dev/null || [[ -f /etc/pam.d/lightdm ]]; then
                configure_pam_service "lightdm" "LightDM"
            elif command -v gdm &> /dev/null || command -v gdm3 &> /dev/null || [[ -f /etc/pam.d/gdm-password ]]; then
                configure_pam_service "gdm-password" "GDM"
            elif command -v sddm &> /dev/null || [[ -f /etc/pam.d/sddm ]]; then
                configure_pam_service "sddm" "SDDM"
            else
                print_warning "Could not detect display manager"
                read -p "Enter PAM service name (e.g., lightdm, gdm-password, sddm): " service_name
                if [[ -n "$service_name" ]]; then
                    configure_pam_service "$service_name" "$service_name"
                fi
            fi
            ;;
        3)
            configure_pam_service "common-auth" "Common Auth"
            ;;
        4)
            configure_pam_service "sudo" "Sudo"
            ;;
        5)
            configure_standard_services
            ;;
        6|*)
            print_info "Cancelled PAM configuration"
            return
            ;;
    esac
}

# Configure specific PAM service
configure_pam_service() {
    local service=$1
    local service_name=$2
    local pam_file="/etc/pam.d/$service"
    
    print_info "Configuring PAM for $service_name"
    
    # Check if PAM file exists
    if [[ ! -f "$pam_file" ]]; then
        print_warning "PAM file not found: $pam_file"
        read -p "Create new file? (y/N): " create_file
        if [[ ! "$create_file" =~ ^[Yy]$ ]]; then
            return
        fi
    fi
    
    # Backup existing file
    if [[ -f "$pam_file" ]]; then
        local backup_file="${pam_file}.backup-$(date +%Y%m%d-%H%M%S)"
        cp "$pam_file" "$backup_file"
        print_success "Backed up to: $backup_file"
    fi
    
    # Check what to configure
    echo ""
    echo "What would you like to enable?"
    echo "  1) Authentication only"
    echo "  2) Authentication + Session (for group sync & desktop integration)"
    echo "  3) Authentication + Session + Password change"
    echo ""
    read -p "Choice [1-3]: " config_choice
    
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
    
    # Add session configuration if requested
    if [[ "$config_choice" == "2" ]] || [[ "$config_choice" == "3" ]]; then
        print_info "Adding session configuration (group sync & desktop integration)..."
        
        if ! grep -q "session.*pam_nextcloud" "$pam_file"; then
            echo "session optional    pam_python.so /lib/security/pam_nextcloud.py" >> "$pam_file"
        fi
    fi
    
    # Add password configuration if requested
    if [[ "$config_choice" == "3" ]]; then
        print_info "Adding password change configuration..."
        
        if ! grep -q "password.*pam_nextcloud" "$pam_file"; then
            sed -i "/^password.*/ a password sufficient pam_python.so /lib/security/pam_nextcloud.py" "$pam_file" || {
                echo "password sufficient pam_python.so /lib/security/pam_nextcloud.py" >> "$pam_file"
            }
        fi
    fi
    
    print_success "PAM configured for $service_name"
    
    # Show what was configured
    echo ""
    print_info "Current configuration for $service:"
    grep "pam_nextcloud" "$pam_file" || echo "  (no pam_nextcloud lines found - manual configuration may be needed)"
    
    echo ""
    print_warning "IMPORTANT REMINDERS:"
    echo "  1. Keep this terminal/shell open!"
    echo "  2. Open a NEW terminal to test authentication"
    echo "  3. Do NOT close this terminal until you've verified login works"
    echo "  4. If you get locked out, use the backup: $backup_file"
    echo ""
    
    # Restart service if needed
    if [[ "$service" == "sshd" ]]; then
        read -p "Restart SSH service now? (y/N): " restart_ssh
        if [[ "$restart_ssh" =~ ^[Yy]$ ]]; then
            if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null; then
                print_success "SSH service restarted"
            else
                print_warning "Could not restart SSH service automatically"
            fi
        fi
    fi
}

# Configure common services: sshd, desktop display manager, sudo
configure_standard_services() {
    print_header "Configuring PAM: Standard setup (SSHD + Display Manager + Sudo)"

    # SSHD
    configure_pam_service "sshd" "SSH"

    # Detect display manager
    local dm_service=""
    local dm_label=""
    if command -v lightdm &> /dev/null || [[ -f /etc/pam.d/lightdm ]]; then
        dm_service="lightdm"; dm_label="LightDM"
    elif command -v gdm &> /dev/null || command -v gdm3 &> /dev/null || [[ -f /etc/pam.d/gdm-password ]]; then
        dm_service="gdm-password"; dm_label="GDM"
    elif command -v sddm &> /dev/null || [[ -f /etc/pam.d/sddm ]]; then
        dm_service="sddm"; dm_label="SDDM"
    fi

    if [[ -n "$dm_service" ]]; then
        configure_pam_service "$dm_service" "$dm_label"
    else
        print_warning "No display manager detected; skipping desktop login configuration"
    fi

    # Sudo
    configure_pam_service "sudo" "Sudo"

    # Ensure desktop integration is enabled in config
    enable_desktop_integration_config "$dm_label"

    # Optionally pre-provision desktop integration for a user now
    echo ""
    read -p "Pre-provision desktop integration for a user now? Enter username (blank to skip): " target_user
    if [[ -n "$target_user" ]]; then
        provision_desktop_for_user "$target_user" "$dm_label"
    fi
}

# Ensure enable_desktop_integration is true and set force_desktop_type based on DM
enable_desktop_integration_config() {
    local dm_label="$1"  # e.g., GDM/LightDM/SDDM
    local force_type=""
    case "$dm_label" in
        GDM|LightDM) force_type="gnome" ;;
        SDDM) force_type="kde" ;;
        *) force_type="" ;;
    esac

    if [[ -f "$CONFIG_DIR/$CONFIG_NAME" ]]; then
        # enable_desktop_integration = true (insert under [nextcloud] if missing)
        if grep -q "^enable_desktop_integration\s*=\s*" "$CONFIG_DIR/$CONFIG_NAME"; then
            sed -i "s/^enable_desktop_integration\s*=.*/enable_desktop_integration = true/" "$CONFIG_DIR/$CONFIG_NAME"
        else
            awk 'BEGIN{done=0} {print $0} $0=="[nextcloud]" && !done {print "enable_desktop_integration = true"; done=1}' "$CONFIG_DIR/$CONFIG_NAME" > "$CONFIG_DIR/$CONFIG_NAME.tmp" && mv "$CONFIG_DIR/$CONFIG_NAME.tmp" "$CONFIG_DIR/$CONFIG_NAME"
        fi

        # force_desktop_type = <type>
        if [[ -n "$force_type" ]]; then
            if grep -q "^force_desktop_type\s*=\s*" "$CONFIG_DIR/$CONFIG_NAME"; then
                sed -i "s/^force_desktop_type\s*=.*/force_desktop_type = $force_type/" "$CONFIG_DIR/$CONFIG_NAME"
            else
                awk -v val="$force_type" 'BEGIN{done=0} {print $0} $0=="[nextcloud]" && !done {print "force_desktop_type = " val; done=1}' "$CONFIG_DIR/$CONFIG_NAME" > "$CONFIG_DIR/$CONFIG_NAME.tmp" && mv "$CONFIG_DIR/$CONFIG_NAME.tmp" "$CONFIG_DIR/$CONFIG_NAME"
            fi
        fi
        print_success "Desktop integration enabled in $CONFIG_DIR/$CONFIG_NAME"
    fi
}

# Pre-provision desktop integration files for a user (GNOME/KDE)
provision_desktop_for_user() {
    local user="$1"
    local dm_label="$2"

    # Resolve user home
    local home_dir
    home_dir=$(getent passwd "$user" | cut -d: -f6)
    if [[ -z "$home_dir" || ! -d "$home_dir" ]]; then
        print_warning "User $user or home directory not found; skipping pre-provision"
        return
    fi

    # Read server URL from config
    local server_url
    server_url=$(awk -F'=' '/^url[ \t]*=/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}' "$CONFIG_DIR/$CONFIG_NAME" | head -1)
    if [[ -z "$server_url" ]]; then
        print_warning "Nextcloud URL not set in $CONFIG_DIR/$CONFIG_NAME; skipping pre-provision"
        return
    fi

    # Nextcloud Desktop Client hint
    local nc_dir="$home_dir/.config/Nextcloud"
    mkdir -p "$nc_dir"
    cat > "$nc_dir/sync-hint.json" << EOF
{
  "server": "$server_url",
  "user": "$user",
  "configured_via": "pam_nextcloud",
  "note": "This server was auto-detected from PAM authentication"
}
EOF
    chown -R "$user":"$user" "$nc_dir"
    chmod 700 "$nc_dir"
    chmod 600 "$nc_dir/sync-hint.json"

    # GNOME Online Accounts marker
    local goa_dir="$home_dir/.config/goa-1.0"
    mkdir -p "$goa_dir"
    local marker="$goa_dir/.nextcloud-setup-$(date +%s)"
    cat > "$marker" << EOF
{
  "username": "$user",
  "server": "$server_url"
}
EOF
    chown -R "$user":"$user" "$goa_dir"
    chmod 700 "$goa_dir"
    chmod 600 "$marker"

    print_success "Pre-provisioned desktop integration for user $user"
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

