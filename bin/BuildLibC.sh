#!/bin/bash
set -euo pipefail
#set -x
LOG_FILE="/home/timo/build_libc.txt"
BUILD_FILE="/home/timo/build_libc_log.txt"
EMAIL="munnu@kolumbus.fi"
SENDER="noreply@hurricane.munnukka.fi"

CFLAGS="-O2 -march=amdfam10 -pipe"
LDFLAGS="-L/usr/lib/x86_64-linux-gnu"

GLIBC_SRC="/home/timo/projects/glibc"
ALLOWED_FAILURES="$GLIBC_SRC/allowed-failures-hurricane.txt"

PARAMETERS="$#"

source /home/timo/bin/send_notification_email.sh

# Function for logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
    logger "BuildLibC: $1"
}

# Function for handling errors
error() {
    log "VIRHE: $1"
    
    # Send failure notification
    send_notification_email "$EMAIL" "hurricanen LibC käännöksessä virhe" "$LOG_FILE" "$SENDER"
    
    exit 1
}

check_test_results() {
    local build_log="$1"
    local allowed="$HOME/projects/glibc/allowed-failures-hurricane.txt"
    local summary="/home/timo/projects/glibc/build/tests.sum"

    log "Tarkistetaan testitulokset..."

    # Extract actual failures from summary
    local fail_count=0
    local unexpected_fails=""

    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        # Check if this FAIL is in our allowed list
        if ! grep -qxF "$line" "$allowed" 2>/dev/null; then
            unexpected_fails="${unexpected_fails}\n  ${line}"
            ((fail_count++))
        else
            log "  Tunnettu virhe (hyväksytty): $line"
        fi
    done < <(grep "^FAIL:" "$summary" 2>/dev/null)

    if [ "$fail_count" -gt 0 ]; then
        error "$(printf '%d odottamatonta testivirhettä:\n%b' \
            "$fail_count" "$unexpected_fails")"
    fi

    log "Kaikki odottamattomat virheet tarkistettu — OK"
}

if [[ -f "$LOG_FILE" ]]; then
    setfattr -x security.SMACK64 "$LOG_FILE" 2>/dev/null || true
    mv "$LOG_FILE" /home/timo/Documents/log_files/libc_update_$(date +%Y%m%d).txt
fi

if [[ -f "$BUILD_FILE" ]]; then
    setfattr -x security.SMACK64 "$BUILD_FILE" 2>/dev/null || true
    mv "$BUILD_FILE" /home/timo/Documents/log_files/libc_build_$(date +%Y%m%d).txt
fi



cd /home/timo/projects/glibc
git remote update || true
BUILD=$( git status -uno | grep -c "Your branch is behind" || true  )
log "BuildLibC aloittaa. Teenkö buildin on $BUILD"
log "Parametrien lkm käännökseen on $PARAMETERS"

if (( $BUILD > 0 )) || (( $PARAMETERS > 0 )); then
     git pull
     log "BuildLibC aloittaa. Polku on $(pwd)"
     rm -rf build
     mkdir build
     cd build
     BUILD_START=$(date +%s)
     ../configure --prefix=/opt/libc-custom --with-headers=/usr/include\
		  --disable-cat \
		  --localedir=/usr/share/locale \
		  --localstatedir=/var \
		  --sysconfdir=/etc \
		  --disable-pt_chown \
		  --enable-stack-protector=strong \
		  --enable-bind-now \
		  --enable-fortify-source \
		  --disable-timezone-tools \
		  --disable-nscd \
		  > "$BUILD_FILE" || error "Configure epäonnistui"
     make -j2 > "$BUILD_FILE" || error "Käännös epäonnistui."
     BUILD_END=$(date +%s)

     CHECK_START=$(date +%s)
     make -k check \
	  LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu >> "$BUILD_FILE" 2>&1 || true   # -k + || true: run all tests, don't stop
     CHECK_END=$(date +%s)
     
     # Calculate build time
     BUILD_DURATION=$((BUILD_END - BUILD_START))
     HOURS=$((BUILD_DURATION / 3600))
     MINUTES=$(( (BUILD_DURATION % 3600) / 60 ))
     SECONDS=$((BUILD_DURATION % 60))
     BUILD_TIME=$(printf "%02d:%02d:%02d" $HOURS $MINUTES $SECONDS)

     # Calculate check time
     CHECK_DURATION=$((CHECK_END - CHECK_START))
     HOURS=$((CHECK_DURATION / 3600))
     MINUTES=$(( (CHECK_DURATION % 3600) / 60 ))
     SECONDS=$((CHECK_DURATION % 60))
     CHECK_TIME=$(printf "%02d:%02d:%02d" $HOURS $MINUTES $SECONDS)

     # Calculate total time
     TOTAL_DURATION=$((CHECK_END - BUILD_START))
     HOURS=$((TOTAL_DURATION / 3600))
     MINUTES=$(( (TOTAL_DURATION % 3600) / 60 ))
     SECONDS=$((TOTAL_DURATION % 60))
     TOTAL_TIME=$(printf "%02d:%02d:%02d" $HOURS $MINUTES $SECONDS)

     
     # --- Analyse results ---
     SUMMARY="$GLIBC_SRC/build/tests.sum"
     [ -f "$SUMMARY" ] || error "tests.sum puuttuu — make check ei suoritunut"

     # Print full summary to log
     log "=== Testitulokset ==="
     grep -E "^(FAIL|PASS|SKIP|UNSUPPORTED|XFAIL|XPASS):" "$SUMMARY" \
	 | awk -F: '{print $1}' \
	 | sort | uniq -c | sort -rn \
	 | tee -a "$BUILD_FILE"

     # Check for unexpected failures
     UNEXPECTED=0
     while IFS= read -r line; do
	 [[ -z "$line" || "$line" =~ ^# ]] && continue
	 if ! grep -qxF "$line" "$ALLOWED_FAILURES" 2>/dev/null; then
             log "ODOTTAMATON VIRHE: $line"
             ((UNEXPECTED++))
	 else
             log "Tunnettu virhe (hyväksytty): $line"
	 fi
     done < <(grep "^FAIL:" "$SUMMARY")
     
     [ "$UNEXPECTED" -gt 0 ] && \
	 error "$UNEXPECTED odottamatonta testivirhettä. Asennus keskeytetty."

     # --- Install ---
     log "Asennetaan /opt/libc-custom ..."
     INSTALL_START=$(date +%s)
     #make install >> "$BUILD_FILE" 2>&1 || error "Asennus epäonnistui"
     sudo make install install_root=/tmp/libc-build >> "$BUILD_FILE" 2>&1 || error "Asennus epäonnistui"
     sudo cp -a /tmp/libc-build/opt/libc-custom/* /opt/libc-custom/
     if [ ! -d "/opt/libc-custom/bin/localedef" ]; then
     	sudo mkdir -p /opt/libc-custom/bin/localedef 2>/dev/null
     fi
     sudo /opt/libc-custom/lib/ld-linux-x86-64.so.2 --library-path /opt/libc-custom/lib /opt/libc-custom/bin/localedef -c -i fi_FI -f ISO-8859-15 fi_FI.iso885915
     sudo /opt/libc-custom/lib/ld-linux-x86-64.so.2 --library-path /opt/libc-custom/lib /opt/libc-custom/bin/localedef -c -i fi_FI -f ISO-8859-1 fi_FI.iso8859
     sudo /opt/libc-custom/lib/ld-linux-x86-64.so.2 --library-path /opt/libc-custom/lib /opt/libc-custom/bin/localedef -c -i fi_FI -f UTF-8 fi_FI.UTF8
     sudo /opt/libc-custom/lib/ld-linux-x86-64.so.2 --library-path /opt/libc-custom/lib /opt/libc-custom/bin/localedef -c -i en_US -f ISO-8859-15 en_US.iso885915
     sudo /opt/libc-custom/lib/ld-linux-x86-64.so.2 --library-path /opt/libc-custom/lib /opt/libc-custom/bin/localedef -c -i en_US -f ISO-8859-1 en_US.iso8859
     sudo /opt/libc-custom/lib/ld-linux-x86-64.so.2 --library-path /opt/libc-custom/lib /opt/libc-custom/bin/localedef -c -i fi_FI -f UTF-8 fi_FI.UTF8
     INSTALL_END=$(date +%s)

     # --- Verify ---
     /opt/libc-custom/lib/ld-linux-x86-64.so.2 --version >> "$BUILD_FILE" \
	 || error "Asennettu ld.so ei toimi!"

     log "=== Valmis ==="

     log "BuildLibC build time $BUILD_TIME"
     log "BuildLibC check time $CHECK_TIME"
     log "BuildLibC Asennus: $((INSTALL_END - INSTALL_START))s"
     log "BuildLibC total time $TOTAL_TIME"
     log "Loki:    $BUILD_FILE"

     log "BuildLibC juossut."
else
     log "BuildLibC uudempaa sorsaa oo ilmestynyt."
fi

log "BuildLibC juossut."

send_notification_email "$EMAIL" "Hurricane Phantom II LibC käännös tehty." "$LOG_FILE" "$SENDER"
exit 0

