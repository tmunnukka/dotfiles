#!/bin/bash

source "/home/timo/bin/send_notification_email.sh"
source "/home/timo/bin/ansi_codex_scripting.txt"

REPO_DIR="/home/timo/projects/unbound"
EMAIL="munnu@kolumbus.fi"
SENDER="norpely@hurricane.norttilaakso.fi"
LOG_FILE="/home/timo/unbound_build.txt"
BUILD_FILE="/home/timo/unbound_build.build"

CFLAGS="-march=amdfam10 -mtune=amdfam10 -O2 -Wno-deprecated-declarations"
LDFLAGS="-L/opt/glibc-custom/lib \
         -L/opt/openssl/lib64 \
         -Wl,--disable-new-dtags \
         -Wl,-rpath,/opt/glibc-custom/lib:/opt/openssl/lib64:/opt/unbound/lib \
         -Wl,--dynamic-linker=/opt/glibc-custom/lib/ld-linux-x86-64.so.2" \

# Function for logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
    logger "Unbound: $1"
}

error() {
    log "Käännös epäonnistui. Tarkista virheloki."
    send_notification_email "$EMAIL" "Hurricanen unbound - virhe käännöksessä" "$LOG_FILE" "$SENDER"
    exit 1
}

build_unbound(){
    cd "$REPO_DIR"
    make clean
    ./configure --prefix=/opt/unbound --with-conf-file=/etc/unbound/unbound.conf --with-ssl=/opt/openssl --with-libevent --enable-pie -enable-systemd --enable-dnstap --enable-dnscrypt --enable-ipset --disable-sha1 --enable-tfo-client --enable-tfo-server || error "Virhe konfiguroinnissa."
    make  > "$BUILD_FILE" || error "Virhe käännösessä."
    log "Uusi versio käännetty."
    return 0
}

install_unbound(){
    cd "$REPO_DIR"
    sudo systemctl stop unbound || error "unbound palvelu ei pysähtynyt."
    sudo make install || error "uuden vedoksen asennus ei onnistunut."
    sudo systemctl start unbound || error "uuden vedoksen käynnistys ei onnistunut."
    log "Uusi versio asennettu."

}

check_updates(){
    cd "$REPO_DIR" || error "Hakemisto $REPO_DIR ei löydy"
    
    log "Tarkistetaan päivitykset..." >&2
    git remote update || error "Git remote update epäonnistui"
    
    BEHIND=$(git rev-list --count HEAD..@{upstream})
    log "Paikallinen on jäljessä $BEHIND committia." >&2
    
    if [ $BEHIND -eq 0 ]; then
        log "Ei päivityksiä saatavilla." >&2
        return 1
    fi

    echo $BEHIND
    return 0
}

#main loop
main(){
    rm -rf "$LOG_FILE"
    CHANGES=$(check_updates)
    COUNT=$#
    log "Sain $COUNT parametria"
    if [[ $CHANGES -gt 0  ]] || [[ $COUNT -gt 0 ]] ; then
	cd "$REPO_DIR"
	git pull > /dev/null || log "Git pull epäonnistui."
	
        build_unbound
        install_unbound
    else
        log "ei päivityksiä saatavilla." >&2

    fi

}

# Run the main function
log "unbound päivitys käynnistyy.."
rm -rf "$LOG_FILE"
main "$@" || error "Pääprosessi epäonnistui"
log "Päivitystarkistus suoritettu."
# Send success notification
send_notification_email "$EMAIL" "Hurricane unbound tarkistus juossut" "$LOG_FILE" "$SENDER"
exit 0
