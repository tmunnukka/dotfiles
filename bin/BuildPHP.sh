#!/bin/bash
set -eu pipefail

LOGFILE="/tmp/php_build.log"
COMPILELOG="/tmp/php_compile.log"
EMAIL="munnu@kolumbus.fi"
SENDER="root@hurricane.norttilaakso.fi"
PVM=$(date +%A\ %d.%m.%Y)
PROJECT_DIR="/home/timo/projects/php-src"
PHP_INSTALL_DIR="/opt/php"
CFLAGS="-march=amdfam10 -mtune=amdfam10 -O2"

source /home/timo/bin/send_notification_email.sh

function log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

function error() {
    log "PHP:n käännös ei onnistunut. Tarkista virheloki."
    send_report "FAILURE"
    exit 1
}

function send_report() {
    STATUS=$1
    send_notification_email "$EMAIL" "hurricane PHP report $PVM $STATUS" "$LOGFILE" "$SENDER"
}

# Start build process
cd "$PROJECT_DIR"

# Check for updates
check_updates() {
    log "Tarkistan päivitykset."
    cd "$PROJECT_DIR" || error "Hakemisto $PROJECT_DI ei löydy"
    
    log "Tarkistetaan päivitykset..."
    git remote update || error "Git remote update epäonnistui"
    
    BEHIND=$(git rev-list --count HEAD..@{upstream})
    log "Paikallinen on jäljessä $BEHIND committia."
    
    if [ $BEHIND -eq 0 ]; then
        log "Ei päivityksiä saatavilla."
	return 1
    fi
    
    return 0
}


if check_updates; then
    log "New updates available, totalling $BEHIND. Pulling latest changes."
    git pull || error
    
    log "Starting PHP build process."
    make clean
    ./buildconf
    ./configure OPENSSL_CFLAGS=-I/opt/openssl/include/ \
        OPENSSL_LIBS="-L/opt/openssl/lib64/ -lssl -lcrypto" \
        --prefix="$PHP_INSTALL_DIR" --with-config-file-path="$PHP_INSTALL_DIR/etc" \
        --with-pdo-pgsql=/opt/postgresql --with-pgsql=/opt/postgresql \
        --with-curl --with-openssl --enable-fpm --with-fpm-systemd --enable-soap \
        --enable-calendar --with-bz2 --enable-sockets --enable-sysvsem \
        --enable-sysvshm --enable-pcntl --enable-mbregex --enable-bcmath \
        --with-mhash --with-freetype --enable-intl --with-xsl --without-sqlite3 \
        --without-pdo-sqlite --enable-opcache --with-pear --with-zlib || error
    
    log "Compiling PHP..."
    START_TIME=$(date +%s)
    nice -n 10 make > "$COMPILELOG" 2>%1
    if [ $? -ne 0 ]; then
       log "Käännös epäonnistui. Katso tiedosto $COMPILELOG"
       # Extract the last few error messages to show specific issues
       grep -A 5 "error:" "$COMPILELOG" | tail -n 20 >> "$LOGFILE"
       error
    fi
 
    END_TIME=$(date +%s)
    ELAPSED_TIME=$((END_TIME - START_TIME))
    HOURS=$((ELAPSED_TIME / 3600))
    MINUTES=$(( (ELAPSED_TIME % 3600) / 60 ))
    SECONDS=$((ELAPSED_TIME % 60))
    BUILD_TIME=$(printf "%02d:%02d:%02d" $HOURS $MINUTES $SECONDS)

    log "Compilation took $BUILD_TIME."
    
    log "Stopping PHP-FPM service..."
    sudo -E -u root systemctl stop php-fpm || error
    
    log "Installing PHP..."
    sudo -E -u root make install || error
    
    log "Starting PHP-FPM service..."
    sudo -E -u root systemctl start php-fpm || error
    
    log "PHP build and installation completed successfully."
    send_report "SUCCESS"
else
    log "No new updates found. Skipping build."
    send_report "NO UPDATES"
fi

log "PHP build script finished."
mv "$LOGFILE" /home/timo/Documents/log_files/php_update_$(date +%Y%m%d).txt
exit 0
