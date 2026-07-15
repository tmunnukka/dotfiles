#!/bin/bash
set -euo pipefail

# Set locale explicitly
export LANG=fi_FI.UTF-8
export LC_ALL=fi_FI.UTF-8
export LD_LIBARY_PATH=/opt/openssl/lib64:/opt/local/bin

# Parameters
#   local recipient="$1:-munnu@kolumbus.fi"
#   local subject="$2"
#   local log_file="$3"      # Path to log file in /tmp
#   local sender="${4:-noreply@norttilaakso.fi}"  # Default sender if not provided


source /home/timo/bin/send_notification_email.sh

EMACS_DIR="/home/timo/projects/emacs"
LOG_FILE="/home/timo/emacs_update.log"
BUILD_LOG_FILE="/home/timo/emacs_build.log"
EMAIL="munnu@kolumbus.fi"
SENDER="timo@hurricane.munnukka.fi"
DATE=$(date +%A\ %d.%m.%Y)
BUILD_COUNTER_FILE="$HOME/.emacs_build_number"
VERSION_FILE="$EMACS_DIR/lisp/loadup.el"
CFLAGS="-march=amdfam10 -mtune=amdfam10 -O2 -Wno-redundant-decls"

export PKG_CONFIG_PATH="/opt/openssl/lib64/pkgconfig:/opt/postgresql/lib/pkgconfig"
export CPPFLAGS="-I/opt/openssl/include"
export LDFLAGS="-L/opt/openssl/lib64 -Wl,-rpath,/opt/openssl/lib64 \
	        -Wl,--enable-new-dtags"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
    logger "Emacs: $1"
}

error() {
    log "Käännös epäonnistui. Tarkista virheloki."
    send_notification_email "$EMAIL" "Hurricanen Emacs - virhe käännöksessä" "$LOG_FILE" "$SENDER"
    exit 1
}

update_emacs() {
    cd "$EMACS_DIR"
    COUNT=$#

    
    # Check for updates
    git reset --hard HEAD 
    git remote update
    BEHIND=$(git rev-list --count HEAD..@{upstream})
    log "Paikallinen on jäljessä $BEHIND committia."
    log "Update sai $COUNT parametria."
    
    if [ $BEHIND -eq 0 ] && [ $COUNT -eq 0 ]; then
        log "Sorsat eivät ole päivittyneet. Ei tarvetta päivitykselle."
        return 1
    fi

    # Initialize or read counter
    if [ -f "$BUILD_COUNTER_FILE" ]; then
        BUILD_NUM=$(cat "$BUILD_COUNTER_FILE")    
    else
        BUILD_NUM=1
    fi     
    
    # Pull updates
    git pull
    log "Uudet päivitykset haettu. Aloitetaan käännös."
    
    # Build
    make distclean
    git clean -fdx
    ./autogen.sh all
    ./configure WARN_CFLAGS="-Wno-redundant-decls" --prefix=/opt/emacs --with-tree-sitter --with-x-toolkit=gtk3 --with-native-compilation || error

    # inserting the build number here
    if [ -f "$VERSION_FILE" ]; then
	sed -i "s/(if versions (1+ (apply #'max versions)) [0-9]*))))/(if versions (1+ (apply #'max versions)) $BUILD_NUM))))/" $VERSION_FILE
    fi

    START_TIME=$(date +%s)
    make -j1 >$BUILD_LOG_FILE 2>&1 || error
    END_TIME=$(date +%s)

    BUILD_DURATION=$((END_TIME - START_TIME ))
    HOURS=$((BUILD_DURATION / 3600))
    MINUTES=$(( (BUILD_DURATION % 3600) / 60 ))
    SECONDS=$((BUILD_DURATION % 60))
    BUILD_TIME=$(printf "%02d:%02d:%02d" $HOURS $MINUTES $SECONDS)

    log "Käännös valmis, kesto: $BUILD_TIME"
    
    # Install
    sudo -E -u root bash -c "cd $EMACS_DIR && make install"
    sudo -E -H -u root bash -c 'ldconfig'
    log "Emacs $DATE asennettu onnistuneesti."
    echo $((BUILD_NUM + 1)) > "$BUILD_COUNTER_FILE"

    
    # Send notification
    echo "Emacs päivitetty $DATE" > /tmp/emacs_update_email.txt
    echo "Käännösaika: $BUILD_TIME" >> /tmp/emacs_update_email.txt
    echo "Muutoksia löytyi: $BEHIND" >> /tmp/emacs_update_email.txt
    echo "Build number: $BUILD_NUM" >> /tmp/emacs_update_email.txt
    send_notification_email "$EMAIL" "Hurricanen Emacs päivitetty" "/tmp/emacs_update_email.txt" "$SENDER"
    
    return 0
}


# Main execution
rm -rf "$LOG_FILE"
rm -rf "$BUILD_LOG_FILE"

log "Emacs päivitysprosessi alkaa"
log "Sain $@ parametria"
if update_emacs "$@"; then
    log "Päivitys suoritettu onnistuneesti."
else
    log "Ei päivityksiä saatavilla."
    send_notification_email "$EMAIL" "Hurricanen Emacs - ei päivityksiä" "$LOG_FILE" "$SENDER"
fi
