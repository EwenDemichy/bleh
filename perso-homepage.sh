#!/usr/bin/env bash
# Personnalisation de Homepage : icônes, fond, pastilles de statut, widgets
# Usage : sudo bash perso-homepage.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Lance avec sudo : sudo bash $0"; exit 1; }

IP="$(hostname -I | awk '{print $1}')"
CFG="/opt/stacks/homepage/config"
mkdir -p "$CFG"

# Sauvegarde de l'ancienne config
B="$CFG/backup-$(date +%F-%H%M%S)"
mkdir -p "$B"
cp -f "$CFG"/*.yaml "$B"/ 2>/dev/null || true

# ---------------- settings.yaml : apparence ----------------
cat > "$CFG/settings.yaml" <<EOF
title: Mon Homelab
language: fr
theme: dark
color: slate
headerStyle: clean
statusStyle: dot
useEqualHeights: true
cardBlur: md
hideVersion: true

background:
  image: https://images.unsplash.com/photo-1502790671504-542ad42d5189?auto=format&fit=crop&w=2560&q=80
  blur: sm
  saturate: 100
  brightness: 50
  opacity: 100

layout:
  Médias:
    style: row
    columns: 3
  Automatisation:
    style: row
    columns: 4
  Maison & cloud:
    style: row
    columns: 3
  Système:
    style: row
    columns: 3
  Outils & jeux:
    style: row
    columns: 3
EOF

# ---------------- widgets.yaml : barre du haut ----------------
cat > "$CFG/widgets.yaml" <<EOF
- resources:
    cpu: true
    memory: true
    disk: /

- datetime:
    text_size: xl
    locale: fr
    format:
      dateStyle: long
      timeStyle: short
      hourCycle: h23

- search:
    provider: duckduckgo
    target: _blank
EOF

# ---------------- bookmarks.yaml : liens utiles ----------------
cat > "$CFG/bookmarks.yaml" <<EOF
- Guides:
    - TRaSH Guides:
        - abbr: TG
          href: https://trash-guides.info/
    - Wiki Gluetun (VPN):
        - abbr: GL
          href: https://github.com/qdm12/gluetun-wiki
    - Docs Jellyfin:
        - abbr: JF
          href: https://jellyfin.org/docs/

- Outils:
    - Tailscale:
        - abbr: TS
          href: https://login.tailscale.com/admin/machines
    - Docker Hub:
        - abbr: DH
          href: https://hub.docker.com/
EOF

# ---------------- services.yaml : tuiles ----------------
cat > "$CFG/services.yaml" <<EOF
- Médias:
    - Jellyfin:
        icon: jellyfin.png
        href: http://$IP:8096
        description: Films, séries, musique
        siteMonitor: http://$IP:8096
    - Jellyseerr:
        icon: jellyseerr.png
        href: http://$IP:5055
        description: Demander un film ou une série
        siteMonitor: http://$IP:5055
    - Wizarr:
        icon: wizarr.png
        href: http://$IP:5690
        description: Invitations
        siteMonitor: http://$IP:5690
    - Navidrome:
        icon: navidrome.png
        href: http://$IP:4533
        description: Musique
        siteMonitor: http://$IP:4533
    - Audiobookshelf:
        icon: audiobookshelf.png
        href: http://$IP:13378
        description: Livres audio, podcasts
        siteMonitor: http://$IP:13378
    - Tdarr:
        icon: tdarr.png
        href: http://$IP:8265
        description: Conversion H.264
        siteMonitor: http://$IP:8265

- Automatisation:
    - Radarr:
        icon: radarr.png
        href: http://$IP:7878
        description: Films
        siteMonitor: http://$IP:7878
    - Sonarr:
        icon: sonarr.png
        href: http://$IP:8989
        description: Séries
        siteMonitor: http://$IP:8989
    - Lidarr:
        icon: lidarr.png
        href: http://$IP:8686
        description: Musique
        siteMonitor: http://$IP:8686
    - Prowlarr:
        icon: prowlarr.png
        href: http://$IP:9696
        description: Indexeurs
        siteMonitor: http://$IP:9696
    - Bazarr:
        icon: bazarr.png
        href: http://$IP:6767
        description: Sous-titres
        siteMonitor: http://$IP:6767
    - qBittorrent:
        icon: qbittorrent.png
        href: http://$IP:8080
        description: Torrents
        siteMonitor: http://$IP:8080
    - JDownloader:
        icon: mdi-download
        href: http://$IP:5800
        description: Téléchargements directs
        siteMonitor: http://$IP:5800

- Maison & cloud:
    - Home Assistant:
        icon: home-assistant.png
        href: http://$IP:8123
        description: Domotique
        siteMonitor: http://$IP:8123
    - Node-RED:
        icon: node-red.png
        href: http://$IP:1880
        description: Automatisations
        siteMonitor: http://$IP:1880
    - Immich:
        icon: immich.png
        href: http://$IP:2283
        description: Photos
        siteMonitor: http://$IP:2283
    - Syncthing:
        icon: syncthing.png
        href: http://$IP:8384
        description: Synchronisation
        siteMonitor: http://$IP:8384
    - Vaultwarden:
        icon: vaultwarden.png
        href: http://$IP:8222
        description: Mots de passe
        siteMonitor: http://$IP:8222
    - Mealie:
        icon: mealie.png
        href: http://$IP:9925
        description: Recettes
        siteMonitor: http://$IP:9925

- Système:
    - Portainer:
        icon: portainer.png
        href: https://$IP:9443
        description: Gestion des conteneurs
    - Nginx Proxy Manager:
        icon: nginx-proxy-manager.png
        href: http://$IP:81
        description: Proxy et HTTPS
        siteMonitor: http://$IP:81
    - AdGuard Home:
        icon: adguard-home.png
        href: http://$IP:3000
        description: DNS et blocage de pubs
        siteMonitor: http://$IP:3000
    - Uptime Kuma:
        icon: uptime-kuma.png
        href: http://$IP:3101
        description: Surveillance
        siteMonitor: http://$IP:3101
    - Dozzle:
        icon: dozzle.png
        href: http://$IP:8888
        description: Logs en direct
        siteMonitor: http://$IP:8888
    - Scrutiny:
        icon: scrutiny.png
        href: http://$IP:8082
        description: Santé des disques
        siteMonitor: http://$IP:8082

- Outils & jeux:
    - Stirling-PDF:
        icon: stirling-pdf.png
        href: http://$IP:8083
        description: Outils PDF
        siteMonitor: http://$IP:8083
    - IT-Tools:
        icon: it-tools.png
        href: http://$IP:8084
        description: Boîte à outils
        siteMonitor: http://$IP:8084
    - Crafty:
        icon: mdi-minecraft
        href: https://$IP:8443
        description: Serveurs Minecraft
EOF

chown -R "${SUDO_USER:-root}" "$CFG" 2>/dev/null || true

echo
echo "Terminé. Recharge http://$IP:3100 (Ctrl+F5)."
echo "Ancienne config sauvegardée dans : $B"
