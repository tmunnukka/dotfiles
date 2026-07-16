#!/bin/bash

source "/home/timo/bin/send_notification_email.sh"
source "/home/timo/bin/ansi_codex_scripting.txt"

REPO_DIR="/home/timo/projects/CMake"
EMAIL="munnu@kolumbus.fi"
SENDER="norpely@bogey.norttilaakso.fi"
LOG_FILE="/home/timo/cmake_build.txt"
BUILD_FILE="/home/timo/cmake_build.build"

# --- Functions ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
    logger "Unbound: $1"
}

error() {
    log "Käännös epäonnistui. Tarkista virheloki."
    send_notification_email "$EMAIL" "Bogeyn CMake - virhe käännöksessä" "$LOG_FILE" "$SENDER"
    exit 1
}

# Function to reliably compare two version strings.
# Returns 0 if V1 is LESS THAN V2
# Returns 1 if V1 is GREATER THAN or EQUAL TO V2
version_gte() {
    # If the versions are the same, they are considered equal/greater for this check.
    if [[ "$1" == "$2" ]]; then
        return 1
    fi
    
    local v1=$(echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^v//')
    local v2=$(echo "$2" | tr '[:upper:]' '[:lower:]' | sed 's/^v//')    

    # Sorts the versions, lowest first. Checks if V2 (the older one) is the smallest.
    local sorted_smallest=$(printf '%s\n%s' "$v1" "$v2" | sort -V | head -n1)
    
    # If V2 is the smallest, then V1 is GREATER THAN V2 (newer).
    if [[ "$sorted_smallest" == "$v2" ]]; then
        return 0 # V1 is GREATER THAN V2
    else
        return 1 # V1 is LESS THAN V2
    fi
}

# --- Script Start ---

check_update(){
    log "--- Checking for New CMake Tags ---"
    git reset --hard HEAD

    # 1. Fetch all tags from the remote
    echo "Fetching all remote tags..."
    git fetch --tags
    
    # 2. Find the current commit's closest tag to use as the base for comparison
    #    --points-at HEAD: finds the exact tag for the current commit.
    #    --contains HEAD: finds the *most recent* tag that *includes* the current commit. 
    # We'll use the latter for more robustness, then strip the '-dirty' if it exists.
    # We also want the *closest* tag, which is best found using git describe.
    CURRENT_TAG_INFO=$(git describe --tags --always --match 'v[0-9]*' 2>/dev/null)
    
    # Extract the base tag name (e.g., strip potential commit hash and other info)
    # This uses the part before the first '-' or the whole string if no '-'
    CURRENT_TAG=$(echo "$CURRENT_TAG_INFO" | sed -E 's/([v0-9.]+)-.*/\1/')
    
    # Use a default old tag if git describe fails (e.g., on a brand new repo)
    if [ -z "$CURRENT_TAG" ]; then
        CURRENT_TAG="v0.0.0"
    fi
    
    echo "Current version/commit is based on: **$CURRENT_TAG**"
    log "Current version/commit is based on: **$CURRENT_TAG**"
    # 3. Find the latest **non-RC** tag from remote
    LATEST_TAG=$(git tag -l 'v*' | grep -v -E 'rc[0-9]+$' | sort -V | tail -1)
    
    # Check if a latest tag was found
    if [ -z "$LATEST_TAG" ]; then
        echo "Error: Could not find a suitable non-RC tag."
        log "Error: Could not find a suitable non-RC tag."
        return 1
    fi
    
    echo "Latest available remote tag is: **$LATEST_TAG**"
    log "Latest available remote tag is: **$LATEST_TAG**"    

    # 4. Compare the versions
    if [[ "$LATEST_TAG" == "$CURRENT_TAG" ]]; then
        echo "Status: **$LATEST_TAG** is already the version currently checked out. No update required."
        log "Status: **$LATEST_TAG** is already the version currently checked out. No update required."
        return 1
    fi
    
    # Compare: Check if LATEST_TAG is strictly newer than CURRENT_TAG
    if version_gte "$LATEST_TAG" "$CURRENT_TAG"; then
        
        # 5. PERFORM CHECKOUT
        echo "--- UPDATE REQUIRED ---"
        echo "Newer tag **$LATEST_TAG** found! Performing direct checkout..."
        log "Newer tag **$LATEST_TAG** found! Performing direct checkout..."
    
        # a) Checkout the tag directly, resulting in a detached HEAD state
        git checkout "$LATEST_TAG"
    
        echo "---"
        echo "Successfully checked out to commit **$LATEST_TAG** (detached HEAD)."
        log "Successfully checked out to commit **$LATEST_TAG** (detached HEAD)."
        git clean -fdx
        return 0
        
    else
        # This scenario should only happen if the user manually checked out an older tag
        # or the initial tag finding was flawed, but it's a safe guard.
        echo "Status: The latest tag found ($LATEST_TAG) is not newer than the current tag ($CURRENT_TAG). No action taken."
        log "Status: The latest tag found ($LATEST_TAG) is not newer than the current tag ($CURRENT_TAG). No action taken."
        return 1
    fi
    return 1
    
}

build_cmake(){
    cd "$REPO_DIR"
    log "Configuring and building CMake"
    rm -rf Build
    mkdir Build
    cd Build
    log "Configuring build."
    ../bootstrap --prefix=/opt/cmake --parallel=20 -- -DOPENSSL_ROOT_DIR=/opt/openssl >"$BUILD_FILE"
    log "Starting build."
    make -j35 &>"$BUILD_FILE"
    log "Starting tests."
    make -j35 test &>"$BUILD_FILE"
}

install_cmake(){
    log "Installing CMake to /opt/cmake"
    cd "$REPO_DIR"/Build
    log "Starting installation."
    sudo make install >"$BUILD_FILE"
}

main (){
    cd "$REPO_DIR"
    if check_update; then
        build_cmake
        install_cmake
    fi

}

rm -rf "$LOG_FILE"
log "CMaken päivitys alkaa"
main || error
log "Update done."
send_notification_email "$EMAIL" "Bogey CMake tarkistus juossut" "$LOG_FILE" "$SENDER"

