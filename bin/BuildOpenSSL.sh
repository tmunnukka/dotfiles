#!/bin/bash
set -euo pipefail

source /home/timo/bin/send_notification_email.sh

OPENSSL_SRC="/home/timo/projects/openssl"
LOG_FILE="/home/timo/openssl_update.log"
EMAIL="munnu@kolumbus.fi"
SENDER="timo@hurricane.norttilaakso.fi"
DATE=$(date +%A\ %d.%m.%Y)
CONFIGURE_OPTIONS="--prefix=/opt/openssl shared enable-pie enable-quic enable-tfo zlib-dynamic enable-zstd-dynamic enable-brotli-dynamic enable-ktls enable-fips enable-rc5 enable-demos enable-h3demo \
		   -Wl,--enable-new-dtags \
		   -Wl,-rpath,'/opt/openssl/lib64:/opt/libc-custom/lib' no-docs \
		   -I/opt/libc-custom/include -L/opt/libc-custom/lib \
                   -Wl,--dynamic-linker=/opt/libc-custom/lib/ld-linux-x86-64.so.2"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
    logger "OpenSSL: $1"
}

error() {
    log "Käännös epäonnistui. Tarkista virheloki."
    
    # Send failure email
    echo "OpenSSL käännös epäonnistui $DATE" > /tmp/openssl_update_email.txt
    echo "Virhe tapahtui. Tarkista loki: $LOG_FILE" >> /tmp/openssl_update_email.txt
    send_notification_email "$EMAIL" "Hurricanen OpenSSL käännös epaonnistui" "/tmp/openssl_update_email.txt" "$SENDER"
    
    exit 1
}

update_openssl() {
    local COUNT=$#
    cd "$OPENSSL_SRC"
    
    # Check for updates
    git remote update
    BEHIND=$(git rev-list --count HEAD..@{upstream})
    log "Paikallinen on jäljessä $BEHIND committia."
    log "Update_openssl sai $# parametria"

    if [ $BEHIND -eq 0 ] && [ "$COUNT" -eq 0 ] ; then
        log "Ei päivityksiä saatavilla. Ei tarvetta kääntää."
        return 1
    fi
    
    # Pull updates
    git pull
    log "Uudet päivitykset haettu. Aloitetaan käännös."
    
    # Clean previous build
    log "Puhdistetaan aiempi käännös..."
    make clean || log "Ei aiempaa käännöstä puhdistettavaksi."
    
    # Configure
    log "Konfiguroidaan OpenSSL..."
    eval "./Configure $CONFIGURE_OPTIONS" || error
    
    # Build
    log "Aloitetaan käännös..."
    BUILD_START=$(date +%s)
    make -j$(nproc) > "$LOG_FILE.build" 2>&1 || { log "Käännös epäonnistui. Katso tiedosto $LOG_FILE.build"; error; }
    BUILD_END=$(date +%s)
    
    # Calculate build time
    BUILD_DURATION=$((BUILD_END - BUILD_START))
    HOURS=$((BUILD_DURATION / 3600))
    MINUTES=$(( (BUILD_DURATION % 3600) / 60 ))
    SECONDS=$((BUILD_DURATION % 60))
    BUILD_TIME=$(printf "%02d:%02d:%02d" $HOURS $MINUTES $SECONDS)
    
    log "Käännös valmis, kesto: $BUILD_TIME"
    log "Aloitetaan testit..."

    TEST_START=$(date +%s)
    make -j$(nproc) tests > "$LOG_FILE.test" 2>&1 || { log "Testit epäonnistui. Katso tiedosto $LOG_FILE.test"; error; }
    if grep -E "(\*\*\*|not ok|FAILED|FAILURE|ERROR|FATAL)" "$LOG_FILE.test"; then
        log "Testeissä virheitä. Tarkista \"$LOG_FILE.test\""
        send_notification_email "$EMAIL" "Hurricanen OpenSSL:n testit epäonnistui" "$LOG_FILE.test" "$SENDER"
        error
    elif grep -q "^Failed " "$LOG_FILE.test"; then
        log "Testeissä virheitä. Tarkista \"$LOG_FILE.test\""
        send_notification_email "$EMAIL" "Hurricanen OpenSSL:n testit epäonnistui" "$LOG_FILE.test" "$SENDER"
        error
    else
        log "Testit suoritettu!"
    fi
    
    TEST_END=$(date +%s)
    # Calculate test time
    TEST_DURATION=$((TEST_END - TEST_START))
    TEST_HOURS=$((TEST_DURATION / 3600))
    TEST_MINUTES=$(( (TEST_DURATION % 3600) / 60 ))
    TEST_SECONDS=$((TEST_DURATION % 60))
    TEST_TIME=$(printf "%02d:%02d:%02d" $TEST_HOURS $TEST_MINUTES $TEST_SECONDS)
    log "Testit valmiit, kesto $TEST_TIME"
    
    # Install
    log "Asennetaan OpenSSL..."
    sudo make install > "$LOG_FILE.install" 2>&1 || { log "Asennus epäonnistui. Katso tiedosto $LOG_FILE.install"; error; }
    sudo ldconfig
    
    # Send success notification
    echo "OpenSSL käännös ja asennus onnistui $DATE" > /tmp/openssl_update_email.txt
    echo "Päivitetty $BEHIND committia" >> /tmp/openssl_update_email.txt
    echo "Käännösaika: $BUILD_TIME" >> /tmp/openssl_update_email.txt
    echo "Testiaika: $TEST_TIME" >> /tmp/openssl_update_email.txt
    echo "Versio: $(LD_LIBRARY_PATH=/opt/openssl/lib64 /opt/openssl/bin/openssl version)" >> /tmp/openssl_update_email.txt
    send_notification_email "$EMAIL" "Hurricane:n OpenSSL käännöss onnistui" "/tmp/openssl_update_email.txt" "$SENDER"
    
    return 0
}

# Main execution
log "OpenSSL päivitysprosessi alkaa"
log "Sain $@ parametria"
if update_openssl "$@"; then
    log "Päivitys suoritettu onnistuneesti."
else
    log "Ei päivityksiä saatavilla."
    
    # Send notification that no updates were needed
    echo "OpenSSL päivitys tarkistettu $DATE" > /tmp/openssl_update_email.txt
    echo "Ei uusia päivityksiä saatavilla." >> /tmp/openssl_update_email.txt
    echo "Nykyinen versio: $(openssl version)" >> /tmp/openssl_update_email.txt
    send_notification_email "$EMAIL" "Hurricanen OpenSSL käännös epaonnistui" "/tmp/openssl_update_email.txt" "$SENDER"
fi
