#!/bin/bash

# Script to download, compile and install the latest SQLite3 version
# and send a notification email

# Configuration
DOWNLOAD_DIR="/home/timo/projects/sqlite"
INSTALL_DIR="/opt/sqlite3"
EMAIL_RECIPIENT="munnu@kolumbus.fi"  # Email recipient
EMAIL_SENDER="noreply@hurricane.norttilaakso.fi"  # Email sender
LOGFILE="${DOWNLOAD_DIR}/sqlite_update_$(date +%Y%m%d_%H%M%S).log"

# Source the external notification script
NOTIFICATION_SCRIPT="/home/timo/bin/send_notification_email.sh"  # Update this path to your notification script
if [ -f "$NOTIFICATION_SCRIPT" ]; then
    source "$NOTIFICATION_SCRIPT"
else
    echo "WARNING: Notification script not found at $NOTIFICATION_SCRIPT"
    exit 1
fi

# Time tracking variables
START_TIME=$(date +%s)
CHECKOUT_START_TIME=0
CHECKOUT_END_TIME=0
CONFIGURE_START_TIME=0
CONFIGURE_END_TIME=0
BUILD_START_TIME=0
BUILD_END_TIME=0
INSTALL_START_TIME=0
INSTALL_END_TIME=0
END_TIME=0

# Function to format seconds to human-readable time
format_time() {
    local seconds=$1
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))
    
    if [ $hours -gt 0 ]; then
        echo "${hours}h ${minutes}m ${secs}s"
    elif [ $minutes -gt 0 ]; then
        echo "${minutes}m ${secs}s"
    else
        echo "${secs}s"
    fi
}

# Function to calculate elapsed time
elapsed_time() {
    local start_time=$1
    local end_time=$2
    local elapsed=$((end_time - start_time))
    format_time $elapsed
}

# Function to log messages to both console and log file
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOGFILE"
}

# Function to handle errors
handle_error() {
    log "ERROR: $1"
    
    # Calculate total execution time up to error point
    local error_time=$(date +%s)
    local error_total_time=$(elapsed_time $START_TIME $error_time)
    
    # Format timing information
    local error_timing="The error occurred after running for $error_total_time.\n"
    if [ $CHECKOUT_END_TIME -gt 0 ]; then
        error_timing+="Source checkout completed in $(elapsed_time $CHECKOUT_START_TIME $CHECKOUT_END_TIME).\n"
    fi
    if [ $CONFIGURE_END_TIME -gt 0 ]; then
        error_timing+="Configuration completed in $(elapsed_time $CONFIGURE_START_TIME $CONFIGURE_END_TIME).\n"
    fi
    if [ $BUILD_END_TIME -gt 0 ]; then
        error_timing+="Build completed in $(elapsed_time $BUILD_START_TIME $BUILD_END_TIME).\n"
    fi
    if [ $INSTALL_END_TIME -gt 0 ]; then
        error_timing+="Installation completed in $(elapsed_time $INSTALL_START_TIME $INSTALL_END_TIME).\n"
    fi
    
    # Create a temporary file for the error message
    local tmp_error_file="/tmp/sqlite_error_$(date +%s).log"
    echo -e "The SQLite3 update process failed with the following error:\n\n$1\n\n$error_timing\n\nPlease check the log file at $LOGFILE for details." > "$tmp_error_file"
    
    # Send notification using the external function
    send_notification_email "$EMAIL_RECIPIENT" "SQLite3 Update FAILED" "$tmp_error_file" "$EMAIL_SENDER"
    
    # Clean up the temporary file
    rm -f "$tmp_error_file"
    
    exit 1
}

# Email notification is handled by the external function send_notification_email
# which is sourced from the notification script

# Create log file
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE" || { echo "Cannot create log file!"; exit 1; }

log "Starting SQLite3 update process"

# Check if we have required tools
for cmd in fossil gcc make sudo autoreconf; do
    if ! command -v $cmd &> /dev/null; then
        handle_error "Required command '$cmd' not found. Please install it and try again."
    fi
done

# Create directories if they don't exist
mkdir -p "$DOWNLOAD_DIR" || handle_error "Failed to create download directory: $DOWNLOAD_DIR"
sudo mkdir -p "$INSTALL_DIR" || handle_error "Failed to create installation directory: $INSTALL_DIR"

# Change to download directory
cd "$DOWNLOAD_DIR" || handle_error "Failed to change to download directory: $DOWNLOAD_DIR"

log "Obtaining latest SQLite source using Fossil"

# Define existing Fossil repository location
SQLITE_FOSSIL_FILE="/home/timo/projects/sqlite/src.fossil"

# Create or clean build directory
SQLITE_BUILD_DIR="${DOWNLOAD_DIR}/sqlite-build"
rm -rf "$SQLITE_BUILD_DIR"
mkdir -p "$SQLITE_BUILD_DIR"
cd "$SQLITE_BUILD_DIR" || handle_error "Failed to change to build directory: $SQLITE_BUILD_DIR"

# Open the existing repository and check out the latest trunk version
log "Checking out SQLite source code from existing Fossil repository"
CHECKOUT_START_TIME=$(date +%s)
if [ -f "$SQLITE_FOSSIL_FILE" ]; then
#    fossil open "$SQLITE_FOSSIL_FILE" || handle_error "Failed to open existing SQLite fossil repository"
    
    # Get current branch information
    CURRENT_BRANCH=$(fossil info | grep checkout | awk '{print $2}')
    log "Current Fossil branch: $CURRENT_BRANCH"

    fossil pull 

    LATEST=$(fossil info trunk | grep "^hash:" | awk '{print $2}')
    
    # Check for updates
    log "Checking for updates..."
    
    if [ "$CURRENT_BRANH" != "$LATEST" ]; then
        log "Updates are available, updating to latest version"
        # Update to latest version of the current branch (usually trunk)
        fossil update latest || handle_error "Failed to update to latest version"
    else
        log "Already at the latest version"
    fi
else
    handle_error "Fossil repository file not found at: $SQLITE_FOSSIL_FILE"
fi
CHECKOUT_END_TIME=$(date +%s)
log "Source checkout completed in $(elapsed_time $CHECKOUT_START_TIME $CHECKOUT_END_TIME)"

# Get the current version information
SQLITE_VERSION=$(fossil info | grep -o 'tags: \[.*\]' | sed 's/tags: \[\(.*\)\]/\1/')
SQLITE_DATE=$(fossil info | grep -o 'checkout: .*' | sed 's/checkout: \(.*\)/\1/' | awk '{print $2}')
log "Working with SQLite version: $SQLITE_VERSION (dated: $SQLITE_DATE)"


# Configure, make and install
log "Configuring SQLite with all components enabled"
log "Current directory is $(pwd)"
CONFIGURE_START_TIME=$(date +%s)
CFLAGS="-march=amdfam10 -mtune=amdfam10 -O2" ../configure --prefix="$INSTALL_DIR" \
    --enable-fts5 \
    --json \
    --enable-rtree \
    --enable-math \
    --enable-geopoly \
    --all \
    || handle_error "Configuration failed"
CONFIGURE_END_TIME=$(date +%s)
log "Configuration completed in $(elapsed_time $CONFIGURE_START_TIME $CONFIGURE_END_TIME)"

log "Compiling SQLite"
BUILD_START_TIME=$(date +%s)
make -j$(nproc) || handle_error "Compilation failed"
BUILD_END_TIME=$(date +%s)
log "Compilation completed in $(elapsed_time $BUILD_START_TIME $BUILD_END_TIME)"

log "Installing SQLite to $INSTALL_DIR"
INSTALL_START_TIME=$(date +%s)
sudo make install || handle_error "Installation failed"
INSTALL_END_TIME=$(date +%s)
log "Installation completed in $(elapsed_time $INSTALL_START_TIME $INSTALL_END_TIME)"

# Verify installation
if [ -f "$INSTALL_DIR/bin/sqlite3" ]; then
    INSTALLED_VERSION=$("$INSTALL_DIR/bin/sqlite3" --version | awk '{print $1}')
    log "Successfully installed SQLite version $INSTALLED_VERSION"
    
    # Create success message with build options
    BUILD_OPTIONS=$("$INSTALL_DIR/bin/sqlite3" -line :memory: "SELECT sqlite_version() as version, json_group_object(name, value) as compile_options FROM pragma_compile_options;")
    
    # Get fossil repository information
    cd "$SQLITE_BUILD_DIR" || handle_error "Failed to return to build directory"
    FOSSIL_INFO=$(fossil info)
    BRANCH_INFO=$(fossil branch list)
    TIMELINE_INFO=$(fossil timeline -n 5)
    
    # Calculate total execution time
    END_TIME=$(date +%s)
    TOTAL_TIME=$(elapsed_time $START_TIME $END_TIME)
    
    # Format start time
    START_TIME_FORMATTED=$(date -d @$START_TIME '+%Y-%m-%d %H:%M:%S')
    
    # Generate timing information
    TIMING_INFO="Time Information:\n"
    TIMING_INFO+="  Started at: $START_TIME_FORMATTED\n"
    TIMING_INFO+="  Source checkout time: $(elapsed_time $CHECKOUT_START_TIME $CHECKOUT_END_TIME)\n"
    TIMING_INFO+="  Configuration time: $(elapsed_time $CONFIGURE_START_TIME $CONFIGURE_END_TIME)\n"
    TIMING_INFO+="  Build time: $(elapsed_time $BUILD_START_TIME $BUILD_END_TIME)\n"
    TIMING_INFO+="  Installation time: $(elapsed_time $INSTALL_START_TIME $INSTALL_END_TIME)\n"
    TIMING_INFO+="  Total execution time: $TOTAL_TIME\n"
    
    SUCCESS_MESSAGE="SQLite3 has been successfully updated to version $INSTALLED_VERSION and installed to $INSTALL_DIR.\n\n"
    SUCCESS_MESSAGE+="$TIMING_INFO\n"
    SUCCESS_MESSAGE+="Fossil repository information:\n$FOSSIL_INFO\n\n"
    SUCCESS_MESSAGE+="Branch information:\n$BRANCH_INFO\n\n"
    SUCCESS_MESSAGE+="Recent changes:\n$TIMELINE_INFO\n\n"
    SUCCESS_MESSAGE+="Build information:\n$BUILD_OPTIONS\n\n"
    SUCCESS_MESSAGE+="Update completed at: $(date)\n"
    SUCCESS_MESSAGE+="Log file is available at: $LOGFILE"
    
    # Create a temporary file for the success message
    tmp_success_file="/tmp/sqlite_success_$(date +%s).log"
    
    echo -e "$SUCCESS_MESSAGE" > "$tmp_success_file"
    
    # Send success email using the external function
    send_notification_email "$EMAIL_RECIPIENT" "SQLite3 Update Successful - v$INSTALLED_VERSION" "$tmp_success_file" "$EMAIL_SENDER"
    
    # Clean up the temporary file
    rm -f "$tmp_success_file"
    
    log "Update process completed successfully"
else
    handle_error "Installation verification failed - sqlite3 binary not found at expected location"
fi

# Create symbolic links in /usr/local/bin for convenience (optional)
if [ ! -f "/usr/local/bin/sqlite3" ] || [ -L "/usr/local/bin/sqlite3" ]; then
    log "Creating symbolic link in /usr/local/bin"
    sudo ln -sf "$INSTALL_DIR/bin/sqlite3" /usr/local/bin/sqlite3 || log "WARNING: Failed to create symbolic link. You may need to add $INSTALL_DIR/bin to your PATH."
fi

log "Script execution completed"
exit 0
