#!/bin/bash

# SSH User Setup Script
# Usage: ./create-user.sh <username> [public_key] [ssh_port] [add_to_sudo]
# Repository: https://github.com/Inkrex-dev/inkrex-scripts

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Variables for rollback
USER_CREATED=false
SSH_CONFIG_BACKUP=""
SUDOERS_MODIFIED=false

# Function to print colored messages
print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_cyan() {
    echo -e "${CYAN}$1${NC}"
}

# Function to display usage
show_usage() {
    echo ""
    echo -e "${GREEN}========================================="
    echo "    SSH User Setup Script"
    echo -e "=========================================${NC}"
    echo ""
    echo -e "${YELLOW}USAGE:${NC}"
    echo "  $0 <username> [public_key] [ssh_port] [add_to_sudo]"
    echo ""
    echo -e "${YELLOW}PARAMETERS:${NC}"
    echo "  username      Username to create (required)"
    echo "  public_key    SSH public key (optional, if not provided will ask for password)"
    echo "  ssh_port      New SSH port number (optional, default: 22)"
    echo "  add_to_sudo   'yes' or 'true' to add user to sudo group (optional)"
    echo ""
    echo -e "${YELLOW}EXAMPLES:${NC}"
    echo ""
    print_cyan "1. Create user with SSH key only:"
    echo "   sudo bash $0 john \"ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB...\""
    echo ""
    print_cyan "2. Create user with SSH key and add to sudo:"
    echo "   sudo bash $0 john \"ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB...\" \"\" yes"
    echo ""
    print_cyan "3. Create user with SSH key, sudo, and custom port 2222:"
    echo "   sudo bash $0 john \"ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB...\" 2222 yes"
    echo ""
    print_cyan "4. Create user with password only (no SSH key):"
    echo "   sudo bash $0 john"
    echo ""
    print_cyan "5. Create user with password and sudo:"
    echo "   sudo bash $0 john \"\" \"\" yes"
    echo ""
    print_cyan "6. Create user with password, sudo, and custom port 2222:"
    echo "   sudo bash $0 john \"\" 2222 yes"
    echo ""
    echo -e "${YELLOW}NOTES:${NC}"
    echo "  • Script must be run as root or with sudo"
    echo "  • If no public key is provided, you will be prompted for a password"
    echo "  • Passwordless sudo is enabled only when both SSH key and sudo access are enabled"
    echo "  • Root login and password authentication are disabled when using SSH keys"
    echo "  • SSH configuration is automatically backed up before changes"
    echo "  • Changes are rolled back automatically if any error occurs"
    echo ""
}

# Function to rollback changes
rollback() {
    print_error "Rolling back changes..."
    
    if [ "$USER_CREATED" = true ]; then
        print_info "Removing user $USERNAME..."
        userdel -r "$USERNAME" 2>/dev/null || true
    fi
    
    if [ -n "$SSH_CONFIG_BACKUP" ] && [ -f "$SSH_CONFIG_BACKUP" ]; then
        print_info "Restoring SSH config backup..."
        cp "$SSH_CONFIG_BACKUP" /etc/ssh/sshd_config
        rm -f "$SSH_CONFIG_BACKUP"
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    fi
    
    if [ "$SUDOERS_MODIFIED" = true ]; then
        print_info "Removing sudoers entry..."
        sed -i "/^$USERNAME ALL=(ALL) NOPASSWD:ALL$/d" /etc/sudoers 2>/dev/null || true
    fi
    
    print_error "Rollback completed. Exiting."
    exit 1
}

# Trap errors and call rollback
trap 'rollback' ERR

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    print_error "This script must be run as root or with sudo"
    show_usage
    exit 1
fi

# Check parameters
if [ -z "$1" ]; then
    print_error "Username is required!"
    show_usage
    exit 1
fi

USERNAME="$1"
PUBLIC_KEY="${2:-}"
SSH_PORT="${3:-}"
ADD_TO_SUDO="${4:-}"

print_info "Starting SSH user setup for: $USERNAME"

# Validate username
if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    print_error "Invalid username. Username must start with a lowercase letter or underscore, and contain only lowercase letters, digits, hyphens, and underscores."
    exit 1
fi

# Check if user already exists
if id "$USERNAME" &>/dev/null; then
    print_error "User '$USERNAME' already exists!"
    exit 1
fi

# Validate SSH port if provided
if [ -n "$SSH_PORT" ]; then
    # Check if it's a number
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
        print_error "SSH port must be a number"
        exit 1
    fi
    
    # Check valid range
    if [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
        print_error "SSH port must be between 1 and 65535"
        exit 1
    fi
    
    # Check for common restricted ports (excluding 22 which is default SSH)
    RESTRICTED_PORTS=(20 21 23 25 53 80 110 143 443 465 587 993 995 3306 5432 6379 27017)
    for port in "${RESTRICTED_PORTS[@]}"; do
        if [ "$SSH_PORT" -eq "$port" ]; then
            print_error "Port $SSH_PORT is commonly used for other services. Please choose a different port (recommended: 2222, 2200, or high port like 49152-65535)"
            exit 1
        fi
    done
    
    print_info "Will change SSH port to: $SSH_PORT"
fi

# Normalize ADD_TO_SUDO flag
ADD_TO_SUDO_FLAG=false
if [[ "$ADD_TO_SUDO" =~ ^(yes|true|1|y|YES|TRUE|Yes|True)$ ]]; then
    ADD_TO_SUDO_FLAG=true
    print_info "Will add user to sudo group"
fi

# Determine authentication method
USE_SSH_KEY=false
if [ -n "$PUBLIC_KEY" ]; then
    USE_SSH_KEY=true
    print_info "Using SSH key authentication"
else
    print_info "No public key provided. User will be created with password authentication."
fi

# Backup SSH config
print_info "Backing up SSH configuration..."
SSH_CONFIG_BACKUP="/etc/ssh/sshd_config.backup.$(date +%Y%m%d%H%M%S)"
cp /etc/ssh/sshd_config "$SSH_CONFIG_BACKUP"
print_success "SSH config backed up to: $SSH_CONFIG_BACKUP"

# Step 1: Create user
print_info "Creating user: $USERNAME"
if [ "$USE_SSH_KEY" = true ]; then
    # Create user without password
    adduser --disabled-password --gecos "" "$USERNAME"
    USER_CREATED=true
    print_success "User created without password"
else
    # Create user with password prompt
    adduser --gecos "" "$USERNAME"
    USER_CREATED=true
    print_success "User created with password"
fi

# Step 2: Add user to sudo if requested
if [ "$ADD_TO_SUDO_FLAG" = true ]; then
    print_info "Adding user to sudo group..."
    usermod -aG sudo "$USERNAME"
    print_success "User added to sudo group"
    
    # Add passwordless sudo only if using SSH key
    if [ "$USE_SSH_KEY" = true ]; then
        print_info "Setting up passwordless sudo..."
        echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
        SUDOERS_MODIFIED=true
        print_success "Passwordless sudo configured"
    fi
fi

# Step 3: Set up SSH key if provided
if [ "$USE_SSH_KEY" = true ]; then
    print_info "Setting up SSH key authentication..."
    
    # Create .ssh directory
    USER_HOME=$(eval echo ~"$USERNAME")
    mkdir -p "$USER_HOME/.ssh"
    chmod 700 "$USER_HOME/.ssh"
    
    # Add public key
    echo "$PUBLIC_KEY" > "$USER_HOME/.ssh/authorized_keys"
    chmod 600 "$USER_HOME/.ssh/authorized_keys"
    
    # Set correct ownership
    chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"
    
    print_success "SSH key configured"
fi

# Step 4: Configure SSH daemon
print_info "Configuring SSH daemon..."

# Disable password authentication if using SSH key
if [ "$USE_SSH_KEY" = true ]; then
    if grep -q "^#*PasswordAuthentication" /etc/ssh/sshd_config; then
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    else
        echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
    fi
    print_success "Password authentication disabled"
fi

# Disable root login
if grep -q "^#*PermitRootLogin" /etc/ssh/sshd_config; then
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
else
    echo "PermitRootLogin no" >> /etc/ssh/sshd_config
fi
print_success "Root login disabled"

# Change SSH port if provided
if [ -n "$SSH_PORT" ]; then
    if grep -q "^#*Port" /etc/ssh/sshd_config; then
        sed -i "s/^#*Port.*/Port $SSH_PORT/" /etc/ssh/sshd_config
    else
        echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
    fi
    print_success "SSH port changed to $SSH_PORT"
fi

# Step 5: Test SSH configuration
print_info "Testing SSH configuration..."
if ! sshd -t 2>&1; then
    print_error "SSH configuration test failed!"
    rollback
fi
print_success "SSH configuration is valid"

# Step 6: Restart SSH service
print_info "Restarting SSH service..."
systemctl daemon-reload
systemctl restart ssh 2>/dev/null || systemctl restart sshd

# Verify SSH service is running
sleep 2
if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
    print_success "SSH service restarted successfully"
    systemctl restart ssh.socket 2>/dev/null || true
else
    print_error "SSH service failed to restart!"
    rollback
fi

# Clean up backup on success
rm -f "$SSH_CONFIG_BACKUP"

# Final summary
echo ""
print_success "========================================="
print_success "         Setup Complete"
print_success "========================================="
echo ""
print_info "Username: $USERNAME"
if [ "$USE_SSH_KEY" = true ]; then
    print_info "Authentication: SSH Key"
    print_info "Password authentication: Disabled"
else
    print_info "Authentication: Password"
    print_info "Password authentication: Enabled"
fi
if [ "$ADD_TO_SUDO_FLAG" = true ]; then
    print_info "Sudo access: Enabled"
    if [ "$USE_SSH_KEY" = true ]; then
        print_info "Passwordless sudo: Enabled"
    fi
else
    print_info "Sudo access: Not enabled"
fi
print_info "Root login: Disabled"
if [ -n "$SSH_PORT" ]; then
    echo ""
    print_warning "========================================="
    print_warning "     SSH PORT HAS BEEN CHANGED"
    print_warning "========================================="
    print_warning "New SSH Port: $SSH_PORT"
    print_warning ""
    print_warning "Connect using:"
    print_warning "  ssh -p $SSH_PORT $USERNAME@<server-ip>"
    print_warning ""
    print_warning "⚠️  CRITICAL: Test the new SSH connection"
    print_warning "  in a separate terminal BEFORE closing"
    print_warning "  this session to avoid being locked out!"
    print_warning "========================================="
fi
echo ""

exit 0
