#!/bin/bash

set -euo pipefail
#set -x

export LANG=fi_FI.UTF-8
export LC_ALL=fi_FI.UTF-8
#export CPPFLAGS="-I/opt/openssl/include"
#export LDFLAGS="-L/opt/openssl/lib64 -Wl,-rpath,/opt/openssl/lib64"
export LD_LIBRARY_PATH="/opt/openssl/lib64"
export PKG_CONFIG_PATH="/opt/openssl/lib64/pkgconfig"

# Configuration
PG_SRC="/home/timo/projects/postgresql"
PG_DATA="/home/timo/projects/postgresql_data"
PG_BACKUP="/home/timo/projects/postgresql_old_data"
PG_PREFIX="/opt/postgresql"
EMAIL="munnu@kolumbus.fi"
SENDER="timo@hurricane.munnukka.fi"
DATE=$(date +%Y%m%d)
LOG_FILE="/home/timo/postgresql_update.log"
BACKUPS_TO_KEEP=5
export CFLAGS="-march=amdfam10 -mtune=amdfam10 -O2 pipe"
export CPPFLAGS="-I/opt/libc-custom/include \
       	         -I/opt/openssl/include"
export LDFLAGS="-L/opt/openssl/lib64 -Wl,-rpath,/opt/openssl/lib64 \
	        -L/opt/libc-custom/lib \
	        -Wl,--enable-new-dtags \
                -Wl,-rpath,/opt/postgresql/lib:/opt/libc-custom/lib \
                -Wl,--dynamic-linker=/opt/libc-custom/lib/ld-linux-x86-64.so.2 "

CONFIGURE_OPTIONS="--prefix=${PG_PREFIX} --with-openssl --with-includes=/opt/openssl/include --with-libraries=/opt/openssl/lib64 --with-perl --with-python --with-pam \
		    --with-systemd --with-libxml --with-libxslt --with-lz4 --with-zstd --enable-tap-tests --with-liburing \
		    PKG_CONFIG_PATH=/opt/openssl/lib64/pkgconfig "

source /home/timo/bin/send_notification_email.sh


# Function for logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
    logger "PostgreSQL: $1"
}

# Function for handling errors
error() {
    log "VIRHE: $1"
    
    # Send failure notification
    send_notification_email "$EMAIL" "hurricanen PostgreSQL käännöksessä virhe" "$LOG_FILE" "$SENDER"
    
    exit 1
}

# Check for updates
check_updates() {
    local COUNT="$1"
    cd "$PG_SRC" || error "Hakemisto $PG_SRC ei löydy"
    
    log "Tarkistetaan päivitykset..."
    git remote update || error "Git remote update epäonnistui"
    
    BEHIND=$(git rev-list --count HEAD..@{upstream})
    log "Paikallinen on jäljessä $BEHIND committia."
    log "Sain parametrina $COUNT"
    
    if [ $BEHIND -eq 0 ] && [ $COUNT -eq 0 ] ; then
        log "Ei päivityksiä saatavilla."
        return 1
    fi

    return 0
}

# Build PostgreSQL
build_postgresql() {
    cd "$PG_SRC" || error "Hakemisto $PG_SRC ei löydy"
    
    log "Haetaan uusimmat muutokset..."
    git pull || error "Git pull epäonnistui"
    
    log "Puhdistetaan aiempi käännös..."
    make clean || log "Ei aiempaa käännöstä puhdistettavaksi"
    
    log "Konfiguroidaan PostgreSQL..."
    CFLAGS="-march=amdfam10 -mtune=amdfam10 -O2" ./configure $CONFIGURE_OPTIONS || error "Configure epäonnistui"
    
    log "Käännetään PostgreSQL..."
    BUILD_START=$(date +%s)
    CORES=$(nproc)
    make -j$((CORES)) || error "Make epäonnistui"
    BUILD_END=$(date +%s)
    
    log "Ajetaan testit..."
    make -j$((CORES)) check-world PGOPTIONS="-c default_text_search_config=pg_catalog.english" | tee /tmp/postgresql_testit.txt
    if [ $? -ne 0 ]; then
	error "Testit epäonnistui."
    fi
    if grep -E "^FAILED|^ERROR|^FATAL|failed in|test .* failed" /tmp/postgresql_testit.txt; then
        error "Testit epäonnistui."
    fi
    
    # Calculate build time
    BUILD_DURATION=$((BUILD_END - BUILD_START))
    HOURS=$((BUILD_DURATION / 3600))
    MINUTES=$(( (BUILD_DURATION % 3600) / 60 ))
    SECONDS=$((BUILD_DURATION % 60))
    BUILD_TIME=$(printf "%02d:%02d:%02d" $HOURS $MINUTES $SECONDS)
    
    log "Käännös valmis, kesto: $BUILD_TIME"
    return 0
}

# Install PostgreSQL
install_postgresql() {
    local backup_file="${PG_BACKUP}/data_${DATE}.sql"
    
    log "Varmuuskopioidaan tietokanta..."
    sudo -H -E -u postgres bash -c "${PG_PREFIX}/bin/pg_dumpall > ${backup_file}" || \
        error "Tietokannan varmuuskopiointi epäonnistui"
    
    log "Pysäytetään PostgreSQL-palvelin..."
    sudo systemctl stop postgresql || error "PostgreSQL-palvelimen pysäyttäminen epäonnistui"
    
    log "Varmuuskopioidaan PostgreSQL-data..."
    sudo mv "$PG_DATA" "${PG_DATA}_${DATE}" || error "Data-hakemiston siirto epäonnistui"
    
    log "Asennetaan uusi PostgreSQL..."
    sudo -E bash -c "cd $PG_SRC && make install" || error "PostgreSQL-asennus epäonnistui"
    
    log "Luodaan uusi data-hakemisto..."
    sudo mkdir -p "$PG_DATA" || error "Data-hakemiston luonti epäonnistui"
    sudo chown -R postgres:postgres "$PG_DATA" || error "Oikeuksien asettaminen epäonnistui"
    
    log "Alustetaan tietokanta..."
    sudo -H -E -u postgres bash -c "cd $PG_DATA && ${PG_PREFIX}/bin/initdb -E UTF-8 --locale=fi_FI.UTF8 -D ." || \
        error "Tietokannan alustus epäonnistui"
    
    log "Kopioidaan konfiguraatiotiedostot..."
    sudo -H -E -u postgres bash -c "cp -a ${PG_BACKUP}/*conf ${PG_DATA}/" || \
        error "Konfiguraatiotiedostojen kopiointi epäonnistui"
    
    log "Käynnistetään PostgreSQL-palvelin..."
    sudo systemctl start postgresql || error "PostgreSQL-palvelimen käynnistys epäonnistui"
    
    log "Palautetaan tietokanta varmuuskopiosta..."
    sudo -H -E -u postgres bash -c "${PG_PREFIX}/bin/psql < ${backup_file}" || \
        error "Tietokannan palautus epäonnistui"

    sudo -H -E -u postgres bash -c "${PG_PREFIX}/bin/psql -n blueweather < /home/timo/bin/drop_ruuvi_table.sql" || \
    log "Ruuvimittaustaulu poistettu "
    
    log "Päivitetään tilaukset..."
    sudo -H -E -u postgres bash -c "${PG_PREFIX}/bin/psql -n blueweather < /home/timo/bin/start_ruuvi_subscription.sql" || \
        log "Tilaus ja mittaustulokset poistettu"
    ssh -i /home/timo/.ssh/id_ed255129_home timo@raspberrypi8 "/opt/postgresql/bin/psql -U postgres -d blueweather < /home/timo/bin/recreate_ruuvi_publication.sql" || \
	log "RaspberryPi8:n julkaisu uudistettu"
    
    sudo -H -E -u postgres bash -c "${PG_PREFIX}/bin/psql -n blueweather < /home/timo/bin/finish_ruuvi_subscription.sql" || \
        log "Tilauksen päivitys epäonnistui, jatketaan silti..."
    
    
    return 0
}

cleanup_old_backups() {
    log "Siivotaan vanhat varmuuskopiot..."

    # 1. Clean up old data directories
    # Note: Using '${PG_DATA}' inside single quotes requires breaking the quote or using exports
    sudo bash -c 'DIRECTORIES=$(ls -d '"${PG_DATA}"'_* 2>/dev/null | head -n -'"${BACKUPS_TO_KEEP}"'); \
        if [ -n "$DIRECTORIES" ]; then \
            for dir in $DIRECTORIES; do \
                rm -rf "$dir"; \
            done \
        fi'

    # 2. Clean up old SQL dump files securely
    sudo bash -c 'cd "'"${PG_BACKUP}"'" && \
        OLDFILES=$(ls -t data_*.sql 2>/dev/null | tail -n +$(( '"${BACKUPS_TO_KEEP}"' + 1 ))); \
        if [ -n "$OLDFILES" ]; then \
            echo "$OLDFILES" | xargs -r shred -uzn 5; \
        fi'

    return 0
}


# Main execution
main() {
    local COUNT="$#"
    log "PostgreSQL päivitysprosessi alkaa"
    log "Main saa parametrien lkm:na $COUNT"
    
    if check_updates "$COUNT"; then
        log "Päivityksiä saatavilla, aloitetaan käännös..."
        
        # Build PostgreSQL
        build_postgresql || error "Käännös epäonnistui"
        
        # Install PostgreSQL
        install_postgresql || error "Asennus epäonnistui"
        
        # Clean up old backups
        cleanup_old_backups || log "Varmuuskopioiden siivous epäonnistui, jatketaan silti..."
        
        # Send success notification
        log "PostgreSQL päivitys onnistui."
    else
        # Send no-update notification
        log "Ei päivityksiä saatavilla."
	send_notification_email "$EMAIL" "hurricanen PostgreSQL käännökseen ole tullut päivityksiä." "$LOG_FILE" "$SENDER"
    fi
    
    log "PostgreSQL päivitysprosessi valmis."
    return 0
}

# Run the main function
if [ -f "$LOG_FILE" ]; then
    setfattr -x security.SMACK64 "$LOG_FILE" 2>/dev/null || true
    mv "$LOG_FILE" /home/timo/Documents/log_files/postgresql_update_$(date +%Y%m%d).txt
fi
main "$@" || error "Pääprosessi epäonnistui"
send_notification_email "$EMAIL" "hurricanen PostgreSQL käännös!" "$LOG_FILE" "$SENDER"

# let's compile PHP against PostgreSQL's libraries
/home/timo/bin/BuildPHP.sh

exit 0
