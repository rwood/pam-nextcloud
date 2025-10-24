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
            ;;
        fedora|rhel|centos)
            dnf install -y pam_python python3 python3-pip libnotify
            ;;
        arch|manjaro)
            pacman -S --noconfirm python-pam python python-pip libnotify
            ;;
        *)
            print_warning "Unsupported distribution: $DISTRO"
            print_info "Please install pam_python, Python 3, and libnotify manually"
            return 1
            ;;
    esac
    
    # Install Python dependencies
    pip3 install requests
    
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
                print_success "Configuration file overwritten"
            fi
        fi
    else
        print_info "Installing configuration file..."
        cp pam_nextcloud.conf.example "$CONFIG_DIR/$CONFIG_NAME"
        # Make readable by all (but writable only by root) so desktop integration works
        chmod 644 "$CONFIG_DIR/$CONFIG_NAME"
        chown root:root "$CONFIG_DIR/$CONFIG_NAME"
        print_success "Installed: $CONFIG_DIR/$CONFIG_NAME"
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

# Configure PAM interactively
configure_pam_interactive() {
    print_header "Configuring PAM"
    
    echo "Select which PAM service to configure:"
    echo "  1) SSH (sshd) - For SSH login"
    echo "  2) Display Manager (lightdm/gdm/sddm) - For graphical login"
    echo "  3) Common Auth - For all services"
    echo "  4) Sudo - For sudo authentication"
    echo "  5) Cancel"
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
        5|*)
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
auth    required    pam_unix.so try_first_pass

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

