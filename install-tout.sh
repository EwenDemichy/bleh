#!/usr/bin/env bash
# =====================================================================
#  HOMELAB TOUT-EN-UN  -  Debian 12/13 + Docker + toutes les applis
#  Usage :  sudo bash install-tout.sh
#  Le script est relançable sans risque (il saute ce qui est déjà fait).
# =====================================================================
set -euo pipefail

############################ RÉGLAGES ################################
TZ="Europe/Paris"
DATA_DIR="/data"            # médias + téléchargements (gros disque !)
STACKS="/opt/stacks"        # un dossier par stack (compose.yaml dedans)
INSTALL_NVIDIA="oui"        # pilote Nvidia pour Jellyfin/Tdarr (GTX 750 Ti)
INSTALL_TAILSCALE="oui"     # accès distant sécurisé

# Stacks à NE PAS installer (séparées par des espaces). Exemple : SKIP="immich tdarr crafty"
# Noms possibles : portainer npm adguard homeassistant media jdownloader crafty homepage
#   uptimekuma dozzle scrutiny vaultwarden immich syncthing navidrome audiobookshelf
#   wizarr tdarr mealie stirling ittools nodered mosquitto
SKIP=""

# --- VPN pour qBittorrent (FORTEMENT conseillé, sinon torrent à découvert) ---
# Providers gérés : protonvpn, mullvad, nordvpn, airvpn, privado, windscribe, ...
# Liste complète : https://github.com/qdm12/gluetun-wiki
VPN_PROVIDER=""             # laisse vide = qBittorrent SANS VPN
VPN_TYPE="openvpn"          # openvpn ou wireguard
VPN_USER=""                 # openvpn : identifiant
VPN_PASSWORD=""             # openvpn : mot de passe
VPN_WG_PRIVATE_KEY=""       # wireguard : clé privée
VPN_WG_ADDRESSES=""         # wireguard : ex 10.2.0.2/32
VPN_COUNTRIES=""            # ex "Switzerland,Netherlands"
######################################################################

log()  { echo -e "\n\033[1;32m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }

[ "$(id -u)" -eq 0 ] || { echo "Lance avec sudo : sudo bash $0"; exit 1; }
. /etc/os-release
[ "$ID" = "debian" ] || { echo "Prévu pour Debian uniquement."; exit 1; }

# Utilisateur propriétaire des fichiers
USR="${SUDO_USER:-}"
[ -n "$USR" ] || USR="$(getent passwd 1000 | cut -d: -f1 || true)"
[ -n "$USR" ] || USR="root"
PUID="$(id -u "$USR")"; PGID="$(id -g "$USR")"
IP="$(hostname -I | awk '{print $1}')"
FAILED=()
USE_GPU="$INSTALL_NVIDIA"
MARK="/var/lib/install-tout.nvidia"

# ------------------------------------------------------------------
# Fonction : écrit un compose.yaml (lu sur stdin) puis lance la stack
# ------------------------------------------------------------------
stack() {
  local name="$1" d="$STACKS/$1"
  if [[ " $SKIP " == *" $name "* ]]; then cat >/dev/null; warn "$name ignoré (SKIP)"; return 0; fi
  mkdir -p "$d"
  cat > "$d/compose.yaml"
  log "Stack : $name"
  if (cd "$d" && docker compose up -d); then
    echo "OK : $name"
  else
    warn "ÉCHEC : $name (voir : cd $d && docker compose logs)"
    FAILED+=("$name")
  fi
}
skipped() { [[ " $SKIP " == *" $1 "* ]]; }

# ==================================================================
# 1. SYSTÈME + OUTILS
# ==================================================================
log "Mise à jour du système et outils de base"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget git ca-certificates gnupg \
  openssl htop btop ncdu tmux smartmontools lm-sensors nano unzip rsync ufw lsof \
  iotop net-tools dnsutils

# ==================================================================
# 2. DOCKER
# ==================================================================
if ! command -v docker >/dev/null; then
  log "Installation de Docker"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
systemctl enable docker
systemctl restart docker
[ "$USR" = "root" ] || usermod -aG docker "$USR"
docker network inspect homelab >/dev/null 2>&1 || docker network create homelab >/dev/null

# ==================================================================
# 3. DOSSIERS
# ==================================================================
log "Création de l'arborescence"
mkdir -p "$DATA_DIR"/torrents/{films,series,musique} \
         "$DATA_DIR"/media/{films,series,musique,audiobooks,podcasts} \
         "$DATA_DIR"/{downloads,photos,syncthing}
mkdir -p "$STACKS"
chown "$PUID:$PGID" "$DATA_DIR" "$STACKS"
chown -R "$PUID:$PGID" "$DATA_DIR"/{torrents,media,downloads,syncthing} 2>/dev/null || true

# ==================================================================
# 4. NVIDIA
# ==================================================================
enable_nonfree() {
  local c f
  for f in /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list; do
    [ -f "$f" ] || continue
    for c in contrib non-free non-free-firmware; do
      if [[ "$f" == *.sources ]]; then
        sed -i -E "/^Components:/{/ ${c}( |\$)/!s/\$/ ${c}/}" "$f"
      else
        sed -i -E "/^deb .*debian/{/ ${c}( |\$)/!s/\$/ ${c}/}" "$f"
      fi
    done
  done
}

if [ "$INSTALL_NVIDIA" = "oui" ]; then
  if ! command -v nvidia-smi >/dev/null; then
    log "Pilote Nvidia"
    enable_nonfree
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y linux-headers-"$(dpkg --print-architecture)" \
      nvidia-driver firmware-misc-nonfree
  fi
  if ! dpkg -s nvidia-container-toolkit >/dev/null 2>&1; then
    log "NVIDIA Container Toolkit"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update
    apt-get install -y nvidia-container-toolkit
  fi
  nvidia-ctk runtime configure --runtime=docker >/dev/null
  systemctl restart docker

  if ! nvidia-smi >/dev/null 2>&1; then
    if [ -f "$MARK" ]; then
      warn "Le GPU ne répond toujours pas après redémarrage : on continue SANS GPU."
      warn "Vérifie : retirer la GT 610, Secure Boot désactivé, puis 'dmesg | grep -i nvidia'"
      USE_GPU="non"
    else
      touch "$MARK"
      echo
      echo "=============================================================="
      echo " Pilote Nvidia installé. REDÉMARRAGE NÉCESSAIRE :"
      echo "     sudo reboot"
      echo " Puis relance : sudo bash $0"
      echo "=============================================================="
      exit 0
    fi
  fi
fi

if [ "$USE_GPU" = "oui" ]; then
  GPU_BLOCK=$(cat <<'EOF'
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
EOF
)
else
  GPU_BLOCK=""
fi

# ==================================================================
# 5. TAILSCALE + PARE-FEU
# ==================================================================
if [ "$INSTALL_TAILSCALE" = "oui" ] && ! command -v tailscale >/dev/null; then
  log "Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
fi

log "Pare-feu UFW"
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow OpenSSH >/dev/null
ufw allow from 192.168.0.0/16 >/dev/null
ufw allow from 10.0.0.0/8 >/dev/null
ufw allow from 172.16.0.0/12 >/dev/null
ufw allow in on tailscale0 >/dev/null 2>&1 || true
ufw --force enable >/dev/null

systemctl enable --now smartmontools 2>/dev/null || systemctl enable --now smartd 2>/dev/null || true

# ==================================================================
# 6. LES STACKS
# ==================================================================

# ---------- Portainer ----------
stack portainer <<EOF
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    ports: ["9443:9443"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
networks:
  default:
    name: homelab
    external: true
EOF

# ---------- Nginx Proxy Manager ----------
stack npm <<EOF
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: npm
    restart: unless-stopped
    ports: ["80:80", "443:443", "81:81"]
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
networks:
  default:
    name: homelab
    external: true
EOF

# ---------- AdGuard Home ----------
if ! skipped adguard; then
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNSStubListener=no\n' > /etc/systemd/resolved.conf.d/adguard.conf
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    systemctl restart systemd-resolved
  fi
fi
stack adguard <<EOF
services:
  adguard:
    image: adguard/adguardhome:latest
    container_name: adguard
    restart: unless-stopped
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "3000:3000/tcp"
    volumes:
      - ./work:/opt/adguardhome/work
      - ./conf:/opt/adguardhome/conf
networks:
  default:
    name: homelab
    external: true
EOF

# ---------- Home Assistant (+ Mosquitto + Node-RED) ----------
stack homeassistant <<EOF
services:
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    container_name: homeassistant
    restart: unless-stopped
    network_mode: host
    environment:
      TZ: $TZ
    volumes:
      - ./config:/config
      - /etc/localtime:/etc/localtime:ro
EOF

if ! skipped mosquitto; then
  mkdir -p "$STACKS/mosquitto/config" "$STACKS/mosquitto/data" "$STACKS/mosquitto/log"
  [ -f "$STACKS/mosquitto/config/mosquitto.conf" ] || cat > "$STACKS/mosquitto/config/mosquitto.conf" <<EOF
persistence true
persistence_location /mosquitto/data/
log_dest stdout
listener 1883
allow_anonymous true
EOF
  chmod -R 777 "$STACKS/mosquitto/data" "$STACKS/mosquitto/log"
fi
stack mosquitto <<EOF
services:
  mosquitto:
    image: eclipse-mosquitto:2
    container_name: mosquitto
    restart: unless-stopped
    ports: ["1883:1883"]
    volumes:
      - ./config:/mosquitto/config
      - ./data:/mosquitto/data
      - ./log:/mosquitto/log
networks:
  default:
    name: homelab
    external: true
EOF

if ! skipped nodered; then mkdir -p "$STACKS/nodered/data"; chown -R 1000:1000 "$STACKS/nodered/data"; fi
stack nodered <<EOF
services:
  nodered:
    image: nodered/node-red:latest
    container_name: nodered
    restart: unless-stopped
    ports: ["1880:1880"]
    environment:
      TZ: $TZ
    volumes:
      - ./data:/data
networks:
  default:
    name: homelab
    external: true
EOF

# ---------- STACK MÉDIA : Jellyfin + *arr + qBittorrent (+ VPN) ----------
mkdir -p "$STACKS/media"
if ! skipped media; then
  mkdir -p "$STACKS/media/jellyseerr"; chown -R 1000:1000 "$STACKS/media/jellyseerr"
fi

if [ -n "$VPN_PROVIDER" ]; then
  {
    echo "VPN_SERVICE_PROVIDER=$VPN_PROVIDER"
    echo "VPN_TYPE=$VPN_TYPE"
    if [ "$VPN_TYPE" = "wireguard" ]; then
      echo "WIREGUARD_PRIVATE_KEY=$VPN_WG_PRIVATE_KEY"
      echo "WIREGUARD_ADDRESSES=$VPN_WG_ADDRESSES"
    else
      echo "OPENVPN_USER=$VPN_USER"
      echo "OPENVPN_PASSWORD=$VPN_PASSWORD"
    fi
    if [ -n "$VPN_COUNTRIES" ]; then echo "SERVER_COUNTRIES=$VPN_COUNTRIES"; fi
    echo "TZ=$TZ"
  } > "$STACKS/media/gluetun.env"
  chmod 600 "$STACKS/media/gluetun.env"
  GLUETUN_SVC=$(cat <<EOF
  gluetun:
    image: qmcgaw/gluetun:latest
    container_name: gluetun
    restart: unless-stopped
    cap_add: [NET_ADMIN]
    devices: ["/dev/net/tun:/dev/net/tun"]
    env_file: gluetun.env
    ports:
      - "8080:8080"
      - "6881:6881"
      - "6881:6881/udp"
EOF
)
  QBIT_NET=$(cat <<'EOF'
    network_mode: "service:gluetun"
    depends_on:
      gluetun:
        condition: service_healthy
EOF
)
  QBIT_PORTS=""
  QBIT_HOST="gluetun"
else
  warn "Pas de VPN configuré : qBittorrent tournera SANS protection."
  GLUETUN_SVC=""
  QBIT_NET=""
  QBIT_PORTS=$(cat <<'EOF'
    ports:
      - "8080:8080"
      - "6881:6881"
      - "6881:6881/udp"
EOF
)
  QBIT_HOST="qbittorrent"
fi

stack media <<EOF
services:
${GLUETUN_SVC}

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    restart: unless-stopped
${QBIT_NET}
${QBIT_PORTS}
    environment:
      PUID: $PUID
      PGID: $PGID
      TZ: $TZ
      WEBUI_PORT: 8080
      TORRENTING_PORT: 6881
    volumes:
      - ./qbittorrent:/config
      - $DATA_DIR:/data

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    restart: unless-stopped
    ports: ["9696:9696"]
    environment: { PUID: $PUID, PGID: $PGID, TZ: $TZ }
    volumes: ["./prowlarr:/config"]

  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    restart: unless-stopped
    ports: ["8191:8191"]
    environment:
      TZ: $TZ
      LOG_LEVEL: info

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    restart: unless-stopped
    ports: ["8989:8989"]
    environment: { PUID: $PUID, PGID: $PGID, TZ: $TZ }
    volumes: ["./sonarr:/config", "$DATA_DIR:/data"]

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    restart: unless-stopped
    ports: ["7878:7878"]
    environment: { PUID: $PUID, PGID: $PGID, TZ: $TZ }
    volumes: ["./radarr:/config", "$DATA_DIR:/data"]

  lidarr:
    image: lscr.io/linuxserver/lidarr:latest
    container_name: lidarr
    restart: unless-stopped
    ports: ["8686:8686"]
    environment: { PUID: $PUID, PGID: $PGID, TZ: $TZ }
    volumes: ["./lidarr:/config", "$DATA_DIR:/data"]

  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    restart: unless-stopped
    ports: ["6767:6767"]
    environment: { PUID: $PUID, PGID: $PGID, TZ: $TZ }
    volumes: ["./bazarr:/config", "$DATA_DIR:/data"]

  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    user: "$PUID:$PGID"
    ports: ["8096:8096"]
    environment:
      TZ: $TZ
      JELLYFIN_PublishedServerUrl: http://$IP:8096
      NVIDIA_DRIVER_CAPABILITIES: all
      NVIDIA_VISIBLE_DEVICES: all
    volumes:
      - ./jellyfin/config:/config
      - ./jellyfin/cache:/cache
      - $DATA_DIR/media:/data/media
${GPU_BLOCK}

  jellyseerr:
    image: fallenbagel/jellyseerr:latest
    container_name: jellyseerr
    restart: unless-stopped
    ports: ["5055:5055"]
    environment:
      TZ: $TZ
    volumes: ["./jellyseerr:/app/config"]

networks:
  default:
    name: homelab
    external: true
EOF

# ---------- JDownloader 2 ----------
stack jdownloader <<EOF
services:
  jdownloader:
    image: jlesage/jdownloader-2:latest
    container_name: jdownloader
    restart: unless-stopped
    ports: ["5800:5800"]
    environment:
      USER_ID: $PUID
      GROUP_ID: $PGID
      TZ: $TZ
    volumes:
      - ./config:/config
      - $DATA_DIR/downloads:/output
networks:
  default:
    name: homelab
    external: true
EOF

# ---------- Crafty (Minecraft) ----------
stack crafty <<EOF
services:
  crafty:
    image: registry.gitlab.com/crafty-controller/crafty-4:latest
    container_name: crafty
    restart: unless-stopped
    environment:
      TZ: $TZ
    ports:
      - "8443:8443"
      - "8124:8123"
      - "19132:19132/udp"
      - "25500-25600:25500-25600"
    volumes:
      - ./backups:/crafty/backups
      - ./logs:/crafty/logs
      - ./servers:/crafty/servers
      - ./config:/crafty/app/config
      - ./import:/crafty/import
networks:
  default:
    name: homelab
    external: true
EOF

# ---------- Tdarr (conversion en H.264 grâce au GPU) ----------
stack tdarr <<EOF
services:
  tdarr:
    image: ghcr.io/haveagitgat/tdarr:latest
    container_name: tdarr
    restart: unless-stopped
    ports: ["8265:8265", "8266:8266"]
    environment:
      TZ: $TZ
      PUID: $PUID
      PGID: $PGID
      serverIP: 0.0.0.0
      serverPort: 8266
      webUIPort: 8265
      internalNode: "true"
      nodeName: noeud-local
      NVIDIA_DRIVER_CAPABILITIES: all
      NVIDIA_VISIBLE_DEVICES: all
    volumes:
      - ./server:/app/server
      - ./configs:/app/configs
      - ./logs:/app/logs
      - ./temp:/temp
      - $DATA_DIR/media:/media
${GPU_BLOCK}
networks:
  default:
    name: homelab
    external: true
EOF

# ---------- Vaultwarden ----------
stack vaultwarden <<EOF
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    ports: ["8222:80"]
    environment:
      SIGNUPS_ALLOWED: "true"
      TZ: $TZ
    volumes: ["./data:/data"]
networks:
  default:
    name: homelab
    external: true
EOF

# ---------- Immich (photos) : fichiers officiels ----------
if ! skipped immich; then
  mkdir -p "$STACKS/immich"
  if [ ! -f "$STACKS/immich/compose.yaml" ]; then
    log "Immich : téléchargement des fichiers officiels"
    if wget -qO "$STACKS/immich/compose.yaml" https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml \
       && wget -qO "$STACKS/immich/.env" https://github.com/immich-app/immich/releases/latest/download/example.env; then
      DBPASS="$(openssl rand -hex 16)"
      sed -i -E "s|^UPLOAD_LOCATION=.*|UPLOAD_LOCATION=$DATA_DIR/photos|; \
                 s|^DB_DATA_LOCATION=.*|DB_DATA_LOCATION=./postgres|; \
                 s|^#? ?TZ=.*|TZ=$TZ|; \
                 s|^DB_PASSWORD=.*|DB_PASSWORD=$DBPASS|" "$STACKS/immich/.env"
    else
      warn "Immich : téléchargement impossible, ignoré."
      rm -f "$STACKS/immich/compose.yaml" "$STACKS/immich/.env"
    fi
  fi
  if [ -f "$STACKS/immich/compose.yaml" ]; then
    log "Stack : immich"
    if (cd "$STACKS/immich" && docker compose up -d); then echo "OK : immich"; else warn "ÉCHEC : immich"; FAILED+=("immich"); fi
  fi
fi

# ---------- Syncthing ----------
stack syncthing <<EOF
services:
  syncthing:
    image: lscr.io/linuxserver/syncthing:latest
    container_name: syncthing
    restart: unless-stopped
    ports: ["8384:8384", "22000:22000/tcp", "22000:22000/udp", "21027:21027/udp"]
    environment: { PUID: $PUID, PGID: $PGID, TZ: $TZ }
    volumes: ["./config:/config", "$DATA_DIR/syncthing:/data1"]
networks:
  default:
    name: homelab
    external: true
EOF

# ---------- Navidrome (musique) ----------
stack navidrome <<EOF
services:
  navidrome:
    image: deluan/navidrome:latest
    container_name: navidrome
    restart: unless-stopped
    user: "$PUID:$PGID"
    ports: ["4533:4533"]
    environment:
      ND_SCANSCHEDULE: 1h
      ND_LOGLEVEL: info
      TZ: $TZ
    volumes: ["./data:/data", "$DATA_DIR/media/musique:/music:ro"]
networks:
  default:
    name: homelab
    external: true
EOF

# ---------- Audiobookshelf ----------
stack audiobookshelf <<EOF
services:
  audiobookshelf:
    image: ghcr.io/advplyr/audiobookshelf:latest
    container_name: audiobookshelf
    restart: unless-stopped
    ports: ["13378:80"]
    environment:
      TZ: $TZ
    volumes:
      - $DATA_DIR/media/audiobooks:/audiobooks
      - $DATA_DIR/media/podcasts:/podcasts
      - ./config:/config
      - ./metadata:/metadata
networks:
  default:
    name: homelab
    external: true
EOF

# ---------- Wizarr (invitations Jellyfin) ----------
stack wizarr <<EOF
services:
  wizarr:
    image: ghcr.io/wizarrrr/wizarr:latest
    container_name: wizarr
    restart: unless-stopped
    ports: ["5690:5690"]
    environment:
      TZ: $TZ
    volumes: ["./database:/data/database"]
networks:
  default:
    name: homelab
    external: true
EOF

# ---------- Mealie (recettes) ----------
stack mealie <<EOF
services:
  mealie:
    image: ghcr.io/mealie-recipes/mealie:latest
    container_name: mealie
    restart: unless-stopped
    ports: ["9925:9000"]
    environment:
      ALLOW_SIGNUP: "false"
      PUID: $PUID
      PGID: $PGID
      TZ: $TZ
      BASE_URL: http://$IP:9925
    volumes: ["./data:/app/data"]
    deploy:
      resources:
        limits:
          memory: 1000M
networks:
  default:
    name: homelab
    external: true
EOF

# ---------- Stirling-PDF + IT-Tools ----------
stack stirling <<EOF
services:
  stirling:
    image: stirlingtools/stirling-pdf:latest
    container_name: stirling
    restart: unless-stopped
    ports: ["8083:8080"]
    environment:
      DOCKER_ENABLE_SECURITY: "false"
    volumes: ["./data:/usr/share/tessdata"]
networks:
  default:
    name: homelab
    external: true
EOF

stack ittools <<EOF
services:
  ittools:
    image: corentinth/it-tools:latest
    container_name: ittools
    restart: unless-stopped
    ports: ["8084:80"]
networks:
  default:
    name: homelab
    external: true
EOF

# ---------- Supervision : Uptime Kuma, Dozzle, Scrutiny ----------
stack uptimekuma <<EOF
services:
  uptimekuma:
    image: louislam/uptime-kuma:1
    container_name: uptimekuma
    restart: unless-stopped
    ports: ["3101:3001"]
    volumes: ["./data:/app/data"]
networks:
  default:
    name: homelab
    external: true
EOF

stack dozzle <<EOF
services:
  dozzle:
    image: amir20/dozzle:latest
    container_name: dozzle
    restart: unless-stopped
    ports: ["8888:8080"]
    volumes: ["/var/run/docker.sock:/var/run/docker.sock:ro"]
networks:
  default:
    name: homelab
    external: true
EOF

SCRUT_DEV=""
while read -r n; do SCRUT_DEV+="      - /dev/$n"$'\n'; done < <(lsblk -dno NAME,TYPE | awk '$2=="disk" && ($1 ~ /^sd/ || $1 ~ /^nvme/){print $1}')
if [ -n "$SCRUT_DEV" ]; then
stack scrutiny <<EOF
services:
  scrutiny:
    image: ghcr.io/analogj/scrutiny:master-omnibus
    container_name: scrutiny
    restart: unless-stopped
    cap_add: [SYS_RAWIO, SYS_ADMIN]
    ports: ["8082:8080"]
    volumes:
      - /run/udev:/run/udev:ro
      - ./config:/opt/scrutiny/config
      - ./influxdb:/opt/scrutiny/influxdb
    devices:
${SCRUT_DEV}
networks:
  default:
    name: homelab
    external: true
EOF
fi

# ---------- Homepage (page d'accueil avec tous les liens) ----------
HP="$STACKS/homepage/config"
if ! skipped homepage; then
  mkdir -p "$HP"
  [ -f "$HP/services.yaml" ] || cat > "$HP/services.yaml" <<EOF
- Médias:
    - Jellyfin:
        href: http://$IP:8096
        description: Films, séries, musique
    - Jellyseerr:
        href: http://$IP:5055
        description: Demandes de films/séries
    - Wizarr:
        href: http://$IP:5690
        description: Invitations
    - Navidrome:
        href: http://$IP:4533
    - Audiobookshelf:
        href: http://$IP:13378
    - Tdarr:
        href: http://$IP:8265
- Automatisation:
    - Radarr:
        href: http://$IP:7878
    - Sonarr:
        href: http://$IP:8989
    - Lidarr:
        href: http://$IP:8686
    - Prowlarr:
        href: http://$IP:9696
    - Bazarr:
        href: http://$IP:6767
    - qBittorrent:
        href: http://$IP:8080
    - JDownloader:
        href: http://$IP:5800
- Maison & cloud:
    - Home Assistant:
        href: http://$IP:8123
    - Node-RED:
        href: http://$IP:1880
    - Immich:
        href: http://$IP:2283
    - Syncthing:
        href: http://$IP:8384
    - Vaultwarden:
        href: http://$IP:8222
    - Mealie:
        href: http://$IP:9925
- Système:
    - Portainer:
        href: https://$IP:9443
    - Nginx Proxy Manager:
        href: http://$IP:81
    - AdGuard Home:
        href: http://$IP:3000
    - Uptime Kuma:
        href: http://$IP:3101
    - Dozzle:
        href: http://$IP:8888
    - Scrutiny:
        href: http://$IP:8082
- Outils & jeux:
    - Stirling-PDF:
        href: http://$IP:8083
    - IT-Tools:
        href: http://$IP:8084
    - Crafty (Minecraft):
        href: https://$IP:8443
EOF
  [ -f "$HP/settings.yaml" ] || printf 'title: Mon Homelab\ntheme: dark\ncolor: slate\n' > "$HP/settings.yaml"
fi
stack homepage <<EOF
services:
  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: homepage
    restart: unless-stopped
    ports: ["3100:3000"]
    environment:
      HOMEPAGE_ALLOWED_HOSTS: "$IP:3100,localhost:3100"
      PUID: $PUID
      PGID: $PGID
    volumes:
      - ./config:/app/config
      - /var/run/docker.sock:/var/run/docker.sock:ro
networks:
  default:
    name: homelab
    external: true
EOF

# ==================================================================
# 7. RÉSUMÉ
# ==================================================================
cat > "$STACKS/ACCES.txt" <<EOF
HOMELAB - adresses (remplace par l'IP si besoin : $IP)

PAGE D'ACCUEIL   http://$IP:3100
Portainer        https://$IP:9443    (crée le compte admin tout de suite)
Nginx Proxy Mgr  http://$IP:81       (admin@example.com / changeme)
AdGuard Home     http://$IP:3000     (à l'assistant, garde le port 3000)
Jellyfin         http://$IP:8096
Jellyseerr       http://$IP:5055
Radarr           http://$IP:7878
Sonarr           http://$IP:8989
Lidarr           http://$IP:8686
Prowlarr         http://$IP:9696
Bazarr           http://$IP:6767
FlareSolverr     http://$IP:8191
qBittorrent      http://$IP:8080     (mot de passe temporaire : voir 'docker logs qbittorrent')
JDownloader      http://$IP:5800
Home Assistant   http://$IP:8123
Node-RED         http://$IP:1880     (MQTT : $IP:1883)
Crafty           https://$IP:8443    (mdp : $STACKS/crafty/config/default-creds.txt)
Immich           http://$IP:2283
Syncthing        http://$IP:8384
Vaultwarden      http://$IP:8222     (désactive SIGNUPS_ALLOWED après ton compte)
Navidrome        http://$IP:4533
Audiobookshelf   http://$IP:13378
Wizarr           http://$IP:5690
Tdarr            http://$IP:8265
Mealie           http://$IP:9925     (admin@example.com / MyPassword)
Stirling-PDF     http://$IP:8083
IT-Tools         http://$IP:8084
Uptime Kuma      http://$IP:3101
Dozzle           http://$IP:8888
Scrutiny         http://$IP:8082

Dans Radarr/Sonarr/Lidarr/qBittorrent : dossiers dans /data/torrents et /data/media (hardlinks OK).
Hôte qBittorrent à saisir dans les *arr : ${QBIT_HOST}  port 8080
Hôte FlareSolverr dans Prowlarr : http://flaresolverr:8191
Tout le monde est sur le réseau Docker "homelab" : tu peux utiliser les noms de conteneurs.
EOF
chown "$PUID:$PGID" "$STACKS/ACCES.txt"

echo
echo "=============================================================="
cat "$STACKS/ACCES.txt"
echo "=============================================================="
if [ ${#FAILED[@]} -gt 0 ]; then warn "Stacks en échec : ${FAILED[*]}"; fi
echo "Ce récapitulatif est sauvegardé dans $STACKS/ACCES.txt"
echo "Pense à : sudo tailscale up   (accès distant)"
[ "$USR" = "root" ] || echo "Reconnecte-toi en SSH pour que le groupe 'docker' soit actif pour $USR."
