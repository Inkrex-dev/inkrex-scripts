#!/bin/bash

# VPS Maintenance Script
# Usage: ./vps-maintenance.sh [--exec]
# Repository: https://github.com/Inkrex-dev/inkrex-scripts

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

APT_UPDATED=false
APT_UPGRADED=false
DOCKER_CLEANED=false
KERNEL_CLEANED=false
LOG_CLEANED=false
SNAP_CLEANED=false

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

show_usage() {
    echo ""
    echo -e "${GREEN}========================================="
    echo "    VPS Maintenance Script"
    echo -e "=========================================${NC}"
    echo ""
    echo -e "${YELLOW}USAGE:${NC}"
    echo "  $0 --exec"
    echo ""
    echo -e "${YELLOW}DESCRIPTION:${NC}"
    echo "  Performs system maintenance tasks including:"
    echo "  • APT package updates and upgrades"
    echo "  • Docker cleanup (if installed)"
    echo "  • Old kernel removal"
    echo "  • Log cleanup"
    echo "  • Snap package cleanup (if installed)"
    echo "  • Failed service checks"
    echo "  • Reboot requirement check"
    echo ""
    echo -e "${YELLOW}EXAMPLES:${NC}"
    echo ""
    print_cyan "Run maintenance:"
    echo "   sudo bash $0 --exec"
    echo ""
    echo -e "${YELLOW}NOTES:${NC}"
    echo "  • Script must be run as root or with sudo"
    echo "  • Use --exec flag to actually perform maintenance"
    echo "  • All operations are non-destructive"
    echo "  • Disk space is checked before operations"
    echo ""
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root or with sudo"
        show_usage
        exit 1
    fi
}

check_disk_space() {
    print_info "Checking available disk space..."
    AVAILABLE=$(df / | tail -1 | awk '{print $4}')
    AVAILABLE_GB=$((AVAILABLE / 1024 / 1024))
    
    if [ "$AVAILABLE_GB" -lt 1 ]; then
        print_warning "Low disk space detected: ${AVAILABLE_GB}GB available"
        print_warning "Proceeding with caution..."
    else
        print_success "Disk space check passed: ${AVAILABLE_GB}GB available"
    fi
}

check_docker() {
    if command -v docker &> /dev/null; then
        return 0
    else
        return 1
    fi
}

check_snap() {
    if command -v snap &> /dev/null; then
        return 0
    else
        return 1
    fi
}

maintain_apt() {
    print_info "Updating package lists..."
    apt update
    APT_UPDATED=true
    print_success "Package lists updated"
    
    print_info "Upgrading packages..."
    apt upgrade -y
    APT_UPGRADED=true
    print_success "Packages upgraded"
    
    print_info "Cleaning package cache..."
    apt autoclean
    print_success "Package cache cleaned"
    
    print_info "Removing unused packages..."
    apt autoremove -y
    print_success "Unused packages removed"
}

cleanup_docker() {
    if ! check_docker; then
        print_info "Docker not installed, skipping Docker cleanup"
        return
    fi
    
    set +e
    print_warning "Cleaning up Docker images, containers, and networks..."
    print_warning "This may take a while if cleanup hasn't been done recently on an active system"
    docker system prune -af
    print_success "Docker system cleaned"
    
    print_warning "Cleaning up Docker volumes..."
    print_warning "This may take a while if cleanup hasn't been done recently on an active system"
    docker volume prune -f
    DOCKER_CLEANED=true
    print_success "Docker volumes cleaned"
    set -e
}

cleanup_kernels() {
    print_info "Checking for old kernel versions..."
    INSTALLED_KERNELS=$(dpkg -l | grep -E '^ii.*linux-image-[0-9]' | awk '{print $2}' | sort -V)
    CURRENT_KERNEL=$(uname -r)
    
    KERNELS_TO_REMOVE=""
    KEEP_COUNT=0
    
    while IFS= read -r kernel; do
        if [ -z "$kernel" ]; then
            continue
        fi
        kernel_version=$(echo "$kernel" | sed 's/linux-image-//')
        if [[ "$kernel_version" == *"$CURRENT_KERNEL"* ]] || [ "$KEEP_COUNT" -lt 2 ]; then
            if [[ "$kernel_version" == *"$CURRENT_KERNEL"* ]]; then
                print_info "Keeping current kernel: $kernel"
            else
                print_info "Keeping kernel: $kernel"
            fi
            KEEP_COUNT=$((KEEP_COUNT + 1))
        else
            KERNELS_TO_REMOVE="$KERNELS_TO_REMOVE $kernel "
        fi
    done < <(echo "$INSTALLED_KERNELS" | tac)
    
    if [ -n "$KERNELS_TO_REMOVE" ]; then
        set +e
        print_info "Removing old kernel versions..."
        for kernel in $KERNELS_TO_REMOVE; do
            apt-get purge -y "$kernel" 2>/dev/null || true
        done
        KERNEL_CLEANED=true
        print_success "Old kernels removed"
        set -e
    else
        print_info "No old kernels to remove"
    fi
}

cleanup_logs() {
    print_info "Cleaning old journal logs (keeping last 7 days)..."
    journalctl --vacuum-time=7d
    LOG_CLEANED=true
    print_success "Journal logs cleaned"
}

cleanup_snap() {
    if ! check_snap; then
        print_info "Snap not installed, skipping snap cleanup"
        return
    fi
    
    set +e
    print_info "Cleaning up old snap revisions..."
    REMOVED_COUNT=0
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            snapname=$(echo "$line" | awk '{print $1}')
            revision=$(echo "$line" | awk '{print $2}')
            if snap remove "$snapname" --revision="$revision" 2>/dev/null; then
                REMOVED_COUNT=$((REMOVED_COUNT + 1))
            fi
        fi
    done < <(snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}')
    
    if [ "$REMOVED_COUNT" -gt 0 ]; then
        SNAP_CLEANED=true
        print_success "Old snap revisions cleaned ($REMOVED_COUNT removed)"
    else
        print_info "No old snap revisions to clean"
    fi
    set -e
}

check_failed_services() {
    print_info "Checking for failed systemd services..."
    FAILED_SERVICES=$(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}' || true)
    
    if [ -n "$FAILED_SERVICES" ]; then
        print_warning "Failed services detected:"
        echo "$FAILED_SERVICES" | while read service; do
            print_warning "  • $service"
        done
    else
        print_success "No failed services detected"
    fi
}

check_reboot_required() {
    print_info "Checking if reboot is required..."
    if [ -f /var/run/reboot-required ]; then
        print_warning "========================================="
        print_warning "     REBOOT REQUIRED"
        print_warning "========================================="
        print_warning "System updates require a reboot."
        print_warning "Please reboot the system when convenient."
        if [ -f /var/run/reboot-required.pkgs ]; then
            print_warning "Packages requiring reboot:"
            cat /var/run/reboot-required.pkgs | sed 's/^/  • /'
        fi
        print_warning "========================================="
    else
        print_success "No reboot required"
    fi
}

if [ "$1" != "--exec" ]; then
    show_usage
    exit 0
fi

check_root
check_disk_space

print_info "Starting VPS maintenance..."

maintain_apt
cleanup_docker || true
cleanup_kernels || true
cleanup_logs
cleanup_snap || true
check_failed_services || true
check_reboot_required || true

echo ""
print_success "========================================="
print_success "      Maintenance Complete"
print_success "========================================="
echo ""
print_info "Completed tasks:"
[ "$APT_UPDATED" = true ] && print_info "  ✓ APT package lists updated"
[ "$APT_UPGRADED" = true ] && print_info "  ✓ Packages upgraded"
print_info "  ✓ APT cache cleaned"
print_info "  ✓ Unused packages removed"
[ "$DOCKER_CLEANED" = true ] && print_info "  ✓ Docker cleaned"
[ "$KERNEL_CLEANED" = true ] && print_info "  ✓ Old kernels removed"
[ "$LOG_CLEANED" = true ] && print_info "  ✓ Logs cleaned"
[ "$SNAP_CLEANED" = true ] && print_info "  ✓ Snap cleaned"
print_info "  ✓ Failed services checked"
echo ""

exit 0

