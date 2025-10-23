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
            apt-get install -y libpam-python python3 python3-pip
            ;;
        fedora|rhel|centos)
            dnf install -y pam_python python3 python3-pip
            ;;
        arch|manjaro)
            pacman -S --noconfirm python-pam python python-pip
            ;;
        *)
            print_warning "Unsupported distribution: $DISTRO"
            print_info "Please install pam_python and Python 3 manually"
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
    
    # Handle configuration file
    if [[ -f "$CONFIG_DIR/$CONFIG_NAME" ]]; then
        print_warning "Configuration file already exists: $CONFIG_DIR/$CONFIG_NAME"
        if [[ "$AUTO_MODE" == false ]]; then
            read -p "Overwrite? (y/N): " overwrite
            if [[ "$overwrite" =~ ^[Yy]$ ]]; then
                cp pam_nextcloud.conf.example "$CONFIG_DIR/$CONFIG_NAME"
                print_success "Configuration file overwritten"
            fi
        fi
    else
        print_info "Installing configuration file..."
        cp pam_nextcloud.conf.example "$CONFIG_DIR/$CONFIG_NAME"
        chmod 600 "$CONFIG_DIR/$CONFIG_NAME"
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
    print_info "Next steps:"
    echo "  1. Edit $CONFIG_DIR/$CONFIG_NAME with your Nextcloud server details"
    echo "  2. (Optional) Enable offline authentication caching in config"
    echo "  3. (Optional) Enable group synchronization in config"
    echo "  4. Test authentication: test-pam-nextcloud --username YOUR_USERNAME"
    echo "  5. Configure PAM (see pam-config-examples/ directory)"
    echo ""
    print_warning "IMPORTANT: Be careful when configuring PAM!"
    print_warning "Always keep a root shell open when testing PAM configuration."
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

