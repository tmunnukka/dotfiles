#!/bin/bash
set -euo pipefail

export LANG=fi_FI.UTF-8
export LC_ALL=fi_FI.UTF-8

# Parameters
#   local recipient="$1:-munnu@kolumbus.fi"
#   local subject="$2"
#   local log_file="$3"      # Path to log file in /tmp
#   local sender="${4:-noreply@norttilaakso.fi}"  # Default sender if not provided


source /home/timo/bin/send_notification_email.sh

BLENDER_SRC="/home/timo/projects/blender-git/blender"
BLENDER_BUILD="/home/timo/projects/blender-git/build_linux_full"
LOG_FILE="/home/timo/blender_update.log"
EMAIL="munnu@kolumbus.fi"
SENDER="timo@bogey.munnukka.fi"
DATE=$(date +%A\ %d.%m.%Y)
export CFLAGS="-O3 -march=znver1 -flto -pipe"
export CXXFLAGS="-O3 -march=znver1 -flto -pipe"
export LDFLAGS="-flto=auto -Wl,-O1 -Wl,--as-needed"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
    logger "Blender: $1"
}

error() {
    log "Käännös epäonnistui. Tarkista virheloki."
    
    # Send failure email
    echo "Blender käännös epäonnistui $DATE" > /tmp/blender_update_email.txt
    echo "Virhe tapahtui. Tarkista loki: $LOG_FILE" >> /tmp/blender_update_email.txt
    send_notification_email "$EMAIL" "Bogeyn Blender käännös epaonnistui" "/tmp/blender_update_email.txt" "$SENDER"
    
    exit 1
}

update_blender() {
    cd "$BLENDER_SRC"
    COUNT=$#
    
    # Check for updates
    git fetch
    BEHIND=$(git rev-list --count HEAD..@{upstream})
    log "Paikallinen on jäljessä $BEHIND committia."
    log "Sain $COUNT parametria."
    if [ $BEHIND -eq 0 ] && [ $COUNT -eq 0 ] ; then
        log "Ei päivityksiä saatavilla. Ei tarvetta kääntää."
        return 1
    fi
    
    # Remove old build directory
    log "Poistetaan aiempi build-hakemisto: $BLENDER_BUILD"
    if [ -d "$BLENDER_BUILD" ]; then
        rm -rf "$BLENDER_BUILD"
        log "Aiempi build-hakemisto poistettu."
    fi
    
    # Update sources
    log "Päivitetään lähdekoodit..."
    make update || error
    
    # Count commits since last build (save this for email)
    COMMIT_COUNT=$BEHIND
    CORES=$(nproc)
    
    # Start the build
    log "Aloitetaan käännös..."
    BUILD_START=$(date +%s)
    make -j$((CORES + 1)) full \
         CMAKE_ARGS="-DOPENSSL_ROOT_DIR=/opt/openssl \
              -DOPENSSL_INCLUDE_DIR=/opt/openssl/include \
              -DOPENSSL_CRYPTO_LIBRARY=/opt/openssl/lib64/libcrypto.so \
              -DOPENSSL_SSL_LIBRARY=/opt/openssl/lib64/libssl.so" \
	 CFLAGS="$CFLAGS" \
         CXXFLAGS="$CXXFLAGS" \
         LDFLAGS="$LDFLAGS" \
	 > "$LOG_FILE.build" 2>&1
    if [ $? -ne 0 ]; then
        log "Käännös epäonnistui. Katso tiedosto $LOG_FILE.build"
        # Extract the last few error messages to show specific issues
        grep -A 5 "error:" "$LOG_FILE.build" | tail -n 20 >> "$LOG_FILE"
        error
    fi
    BUILD_END=$(date +%s)
    
    # Calculate build time
    BUILD_DURATION=$((BUILD_END - BUILD_START))
    HOURS=$((BUILD_DURATION / 3600))
    MINUTES=$(( (BUILD_DURATION % 3600) / 60 ))
    SECONDS=$((BUILD_DURATION % 60))
    BUILD_TIME=$(printf "%02d:%02d:%02d" $HOURS $MINUTES $SECONDS)
    
    log "Käännös valmis, kesto: $BUILD_TIME"


    # Send success notification
    echo "Blender käännös onnistui $DATE" > /tmp/blender_update_email.txt
    echo "Päivitetty $COMMIT_COUNT committia" >> /tmp/blender_update_email.txt
    echo "Käännösaika: $BUILD_TIME" >> /tmp/blender_update_email.txt
    send_notification_email "$EMAIL" "Bogeyn Blender käännös onnistui" "/tmp/blender_update_email.txt" "$SENDER"
    rm -rf /tmp/blender_update_email.txt
    return 0
}

# Main execution
rm -rf "$LOG_FILE"
rm -rf "$LOG_FILE.build"
log "Blender päivitysprosessi alkaa"
if update_blender "$@"; then
    log "Päivitys suoritettu onnistuneesti."
else
    log "Ei päivityksiä saatavilla."
    
    # Send notification that no updates were needed
    echo "Blender päivitys tarkistettu $DATE" > /tmp/blender_update_email.txt
    echo "Ei uusia päivityksiä saatavilla." >> /tmp/blender_update_email.txt
    send_notification_email "$EMAIL" "Bogeyn Blender - ei päivityksiä" "$LOG_FILE" "$SENDER"
    rm -rf /tmp/blender_update_email.txt

fi
