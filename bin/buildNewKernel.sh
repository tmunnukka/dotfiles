#!/bin/bash
#
# Automatic Kernel Build Script
# 
# This script:
# 1. Checks for new Linux kernel updates from the stable repository
# 2. Pulls updates and builds a new .deb package if available
# 3. Installs the new kernel with headers (for NVidia drivers)
# 4. Removes the old kernel from the boot list
# 5. Logs progress and sends email notification on success

# Exit on error and unset variables
set -euo pipefail
# 2. Advanced Shell Options (shopt)
shopt -s inherit_errexit
shopt -s failglob

# Parameters
#   local recipient="$1:-munnu@kolumbus.fi"
#   local subject="$2"
#   local log_file="$3"      # Path to log file in /tmp
#   local sender="${4:-noreply@norttilaakso.fi}"  # Default sender if not provided


source /home/timo/bin/send_notification_email.sh

# Configuration
KERNEL_DIR="/home/timo/projects/linux-stable"
LOG_TAG="BuildKernel"
EMAIL="munnu@kolumbus.fi"
SENDER="noreply@hurricane.norttilaakso.fi"
EMAIL_TEMPLATE="$HOME/bin/uuskerneltemplate.txt"
EMAIL_TEMP_FILE="/tmp/kernel_email_$$.txt"

# Function for logging
log() {
    logger "$LOG_TAG $1"
    echo "$LOG_TAG: $1"
}

# Function for error handling
handle_error() {
    local error_message="$1"
    local error_code="${2:-1}"
    
    log "ERROR: $error_message"
    
    # Send error notification email
    {
        echo ""
        echo "Kernel Build Error Report"
        echo "======================="
        echo ""
        echo "Error: $error_message"
        echo "Time: $(date +%A\ %d.%m.%Y)"
        echo "Directory: $(pwd)"
        echo "Current kernel: $(uname -r)"
        echo ""
        echo "Last 20 lines of build log (if available):"
        echo "----------------------------------------"
        if [ -f "/tmp/kernel_build_log.txt" ]; then
            tail -n 20 "/tmp/kernel_build_log.txt"
        else
            echo "No build log available"
        fi
    } >> "$EMAIL_TEMP_FILE"
    # Send error email
    send_notification_email "$EMAIL" "Hurricanen kernel - virhe käännöksessä" "$EMAIL_TEMP_FILE" "$SENDER"
    mv "$EMAIL_TEMP_FILE" /home/timo/Documents/log_files/kernel_update_$(date +%Y%m%d).txt
    
    exit "$error_code"
}

# getting the first parameter passed to this script
# if something is passed we compile the kernel regardless of changes.
# this cases pipefail. Should use "${1:-}" == "--force" to get FORCED parameterization
#PARAMETER1=${1-}
#if [[ -n "${1:-}" ]]; then
#    echo "Provided an argument: $1 - will compile kernel regardless of git updates."
#    log "Parameter provided. Will compile kernel regardless of git udpates."
#fi
# Change to kernel directory
cd "$KERNEL_DIR"

# Check for updates
log "Starting kernel check process"

# Record start time
START_TIME=$(date +%s)

#log "Checking we're in correct hurricane-local branch to get Phenom II patch"
# Ensure we're on the right branch
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "hurricane-local" ]; then
    log "Wrong branch: $CURRENT_BRANCH — switching to hurricane-local"
    git checkout hurricane-local
    if [ $? -ne 0 ]; then
        log "Failed to switch branch, aborting"
        exit 1
    fi
fi

# changing branch to 
#git checkout origin/linux-6.12.y
# Fetch the latest changes from the remote repository
log "Fetching latest changes from upstream"
git fetch origin

# Simple check: Are there any incoming changes?
#UPDATES_AVAILABLE=$(git rev-list --count HEAD..@{u} 2>/dev/null)
UPDATES_AVAILABLE=$(git rev-list --count hurricane-local..origin/linux-6.12.y 2>/dev/null)

log "Updates available: $UPDATES_AVAILABLE commits"

REBASED_ON=$(git rev-parse hurricane-local^)
UPSTREAM_TIP=$(git rev-parse origin/linux-6.12.y)

log "Rebased on: $REBASED_ON"
log "Upstream tip: $UPSTREAM_TIP"

if [[ "$UPDATES_AVAILABLE" -gt 0 ]] || [[ "$#" -gt 0 ]]; then
    # Pull changes to actual branch from git actual branch
    git fetch origin linux-6.12.y:linux-6.12.y
    # patches are in hurricane-local
    #git checkout hurricane-local
    git rebase origin/linux-6.12.y || handle_error "git rebase failed. Cannot merge Phenom II patches. Script aborted"
    
    # Clean and build new kernel package
    log "Building new kernel .deb package in $(pwd)"
    make clean
    
    # Create a log file for the build process
    BUILD_LOG="/tmp/kernel_build_log.txt"
    
    # Compile kernel with time measurement and capture output to log file
    log "Starting build process (saving log to $BUILD_LOG)"
    if ! nice -n 19 /usr/bin/time -f %E make bindeb-pkg > "$BUILD_LOG" 2>&1; then
        handle_error "Kernel compilation failed. Check $BUILD_LOG for details."
    fi
    
    # Extract build time from the log file
    BUILD_TIME=$(grep -oE '[0-9]+:[0-9]{2}(:[0-9]{2})?(\.[0-9]+)?' "$BUILD_LOG" | tail -1) || true
    [ -z "$BUILD_TIME" ] && BUILD_TIME="Unknown (check log file)"
    
    log "Kernel compilation completed in $BUILD_TIME"
    
    # Get version of newly built kernel
    NEW_KERNEL_VERSION=$(make -s kernelrelease 2>/dev/null | tail -1)
    log "Kernel $NEW_KERNEL_VERSION built successfully in $BUILD_TIME"
    
    # Find the .deb packages
    KERNEL_IMAGE=$(find .. -maxdepth 1 -name "linux-image-$NEW_KERNEL_VERSION*.deb" -type f -print -quit)
    KERNEL_HEADERS=$(find .. -maxdepth 1 -name "linux-headers-$NEW_KERNEL_VERSION*.deb" -type f -print -quit)
    
    # Verify packages were created
    if [ -z "$KERNEL_IMAGE" ] || [ -z "$KERNEL_HEADERS" ]; then
        handle_error "Failed to find kernel packages after successful build"
    fi
    
    # Install the new kernel and headers
    log "Installing new kernel packages"
    if ! sudo dpkg -i "$KERNEL_IMAGE" "$KERNEL_HEADERS"; then
        handle_error "Failed to install kernel packages"
    fi

    # Run depmod and regenerate initramfs — required for make bindeb-pkg installs
    log "Running depmod for $NEW_KERNEL_VERSION"
    if ! sudo depmod "$NEW_KERNEL_VERSION"; then
	handle_error "depmod failed for $NEW_KERNEL_VERSION"
    fi

    log "Generating initramfs for $NEW_KERNEL_VERSION"
    if ! sudo update-initramfs -c -k "$NEW_KERNEL_VERSION"; then
	handle_error "update-initramfs failed for $NEW_KERNEL_VERSION"
    fi
    
    # Remove old kernels (keep the current running one and the new one)
    log "Cleaning up old kernel packages"

    # Purge all 6.12 kernels except the newly built one
    log "Cleaning up old 6.12 series kernel packages"
    OLD_6_12_KERNELS=$(dpkg -l | grep ^ii | grep linux-image | grep "6\.12" \
			   | grep -v "$NEW_KERNEL_VERSION" \
			   | awk '{print $2}')

    if [ -n "$OLD_6_12_KERNELS" ]; then
	OLD_6_12_HEADERS=$(echo "$OLD_6_12_KERNELS" | sed 's/linux-image/linux-headers/g')
	log "Removing: $OLD_6_12_KERNELS"
	echo "$OLD_6_12_KERNELS $OLD_6_12_HEADERS" \
            | xargs -r sudo apt-get purge -y --ignore-missing
    else
	log "No old 6.12 series kernels to remove"
    fi
    
    log "Keeping newly built kernel $NEW_KERNEL_VERSION as the primary kernel"
    
    # Set newly built kernel as default in GRUB
    log "Setting new kernel as default boot option"
    if ! sudo update-grub; then
        handle_error "Failed to update GRUB configuration"
    fi
        
    log "New kernel $NEW_KERNEL_VERSION set as default boot option (string method)"
    
    # Get currently installed kernels (before the new one)
    CURRENT_KERNEL=$(uname -r)
    INSTALLED_KERNELS=$(dpkg -l | grep ^ii| grep linux-image | grep -v "$CURRENT_KERNEL" | grep -v "$NEW_KERNEL_VERSION" | awk '{print $2}' | tr '\n' ' ')
    
    # Calculate total duration
    END_TIME=$(date +%s)
    TOTAL_DURATION=$(( END_TIME - START_TIME ))
    TOTAL_DURATION_HRS=$(( TOTAL_DURATION / 3600))
    TOTAL_DURATION_MIN=$(( (TOTAL_DURATION % 3600)  / 60 ))
    TOTAL_DURATION_SEC=$(( TOTAL_DURATION % 60 ))
    
    # Create email with updated information
    cp "$EMAIL_TEMPLATE" "$EMAIL_TEMP_FILE"
    {
        echo ""
        echo "Kernel Build Report"
        echo "==================="
        echo ""
        echo "New kernel version: $NEW_KERNEL_VERSION"
        echo "Current running kernel: $CURRENT_KERNEL"
        echo "Installed kernel packages: $INSTALLED_KERNELS"
        echo ""
        echo "Build time: $BUILD_TIME"
        echo "Total process time: ${TOTAL_DURATION_HRS}h ${TOTAL_DURATION_MIN}m ${TOTAL_DURATION_SEC}s"
        echo ""
        echo "Kernel image: $KERNEL_IMAGE"
        echo "Kernel headers: $KERNEL_HEADERS"
        echo ""
        echo "Build completed at: $(date +%A\ %d.%m.%Y)"
    } >> "$EMAIL_TEMP_FILE"
    
    # Send email notification
    log "Sending email notification"
    send_notification_email "$EMAIL" "Hurricanen kernel käännös onnistui" "$EMAIL_TEMP_FILE" "$SENDER"
    mv "$EMAIL_TEMP_FILE" /home/timo/Documents/log_files/kernel_update_$(date +%Y%m%d).txt

    
    log "Completed in $BUILD_TIME"
else
    log "No kernel updates available."
    # Create email with updated information
    cp "$EMAIL_TEMPLATE" "$EMAIL_TEMP_FILE"
    {
        echo ""
        echo "No new kernel compiled."
        echo ""
        echo "Completed run at: $(date +%A\ %d.%m.%Y)"
    } > "$EMAIL_TEMP_FILE"
    send_notification_email "$EMAIL" "Hurricaneen ei uutta kerneliä." "$EMAIL_TEMP_FILE" "$SENDER"
    mv "$EMAIL_TEMP_FILE" /home/timo/Documents/log_files/kernel_update_$(date +%Y%m%d).txt
fi

