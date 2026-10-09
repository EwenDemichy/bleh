#!/usr/bin/env bash
# =====================================================================
#  1) Remplace Nginx Proxy Manager par Pangolin (guide officiel docker-compose)
#  2) Met en place la mise à jour automatique CHAQUE NUIT À MINUIT :
#     système (apt) + toutes les stacks Docker de /opt/stacks
#  Usage :  sudo bash pangolin-et-maj-auto.sh
#  Relançable sans risque.
# =====================================================================
set -euo pipefail

############################ RÉGLAGES ################################
BASE_DOMAIN=""          # TON nom de domaine, ex : monsite.fr  (sinon il te sera demandé)
DASH_SUB="pangolin"     # le dashboard sera sur pangolin.monsite.fr
EMAIL=""                # email pour les certificats Let's Encrypt (sinon demandé)
TZ="Europe/Paris"
STACKS="/opt/stacks"
AUTO_REBOOT="oui"       # redémarre tout seul si le noyau ou le pilote Nvidia a été mis à jour
######################################################################

log()  { echo -e "\n\033[1;32m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }

[ "$(id -u)" -eq 0 ] || { echo "Lance avec sudo : sudo bash $0"; exit 1; }
command -v docker >/dev/null || { echo "Docker n'est pas installé."; exit 1; }

ask() {  # ask VARIABLE "question"
  local var="$1" msg="$2"
  if [ -z "${!var}" ]; then
    [ -t 0 ] || { echo "$var est vide et il n'y a pas de terminal pour poser la question."; exit 1; }
    read -rp "$msg" "$var"
  fi
}

ask BASE_DOMAIN "Ton nom de domaine (ex : monsite.fr) : "
ask EMAIL       "Ton email (pour Let's Encrypt) : "
[[ "$BASE_DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { echo "Nom de domaine invalide : $BASE_DOMAIN"; exit 1; }
[[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$ ]] || { echo "Email invalide : $EMAIL"; exit 1; }

DASH="${DASH_SUB}.${BASE_DOMAIN}"
IP="$(hostname -I | awk '{print $1}')"
PG="$STACKS/pangolin"

timedatectl set-timezone "$TZ" 2>/dev/null || true

# ==================================================================
# 1. ARRÊT DE NGINX PROXY MANAGER (libère les ports 80/443)
# ==================================================================
if [ -d "$STACKS/npm" ]; then
  log "Arrêt de Nginx Proxy Manager"
  (cd "$STACKS/npm" && docker compose down) || true
  mv "$STACKS/npm" "$STACKS/.npm-ancien-$(date +%F)"   # dossier caché : ignoré par les mises à jour
fi
docker rm -f npm >/dev/null 2>&1 || true

if ss -ltn | awk '{print $4}' | grep -qE ':(80|443)$'; then
  if [ ! -f "$PG/docker-compose.yml" ]; then
    echo "Les ports 80 ou 443 sont encore utilisés par autre chose :"
    ss -ltnp | grep -E ':(80|443)\s' || true
    exit 1
  fi
fi

# ==================================================================
# 2. PANGOLIN (fichiers du guide officiel)
# ==================================================================
log "Installation de Pangolin sur https://$DASH"
mkdir -p "$PG"/config/{db,letsencrypt,traefik/logs}

if [ ! -f "$PG/docker-compose.yml" ]; then
cat > "$PG/docker-compose.yml" <<'EOF'
name: pangolin
services:
  pangolin:
    image: docker.io/fosrl/pangolin:latest
    container_name: pangolin
    restart: unless-stopped
    volumes:
      - ./config:/app/config
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3001/api/v1/"]
      interval: "10s"
      timeout: "10s"
      retries: 15

  gerbil:
    image: docker.io/fosrl/gerbil:latest
    container_name: gerbil
    restart: unless-stopped
    depends_on:
      pangolin:
        condition: service_healthy
    command:
      - --reachableAt=http://gerbil:3004
      - --generateAndSaveKeyTo=/var/config/key
      - --remoteConfig=http://pangolin:3001/api/v1/
    volumes:
      - ./config/:/var/config
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    ports:
      - 51820:51820/udp
      - 21820:21820/udp
      - 443:443
      - 80:80

  traefik:
    image: docker.io/traefik:v3.7
    container_name: traefik
    restart: unless-stopped
    network_mode: service:gerbil
    depends_on:
      pangolin:
        condition: service_healthy
    command:
      - --configFile=/etc/traefik/traefik_config.yml
    volumes:
      - ./config/traefik:/etc/traefik:ro
      - ./config/letsencrypt:/letsencrypt
      - ./config/traefik/logs:/var/log/traefik

networks:
  default:
    driver: bridge
    name: pangolin
EOF
fi

if [ ! -f "$PG/config/traefik/traefik_config.yml" ]; then
cat > "$PG/config/traefik/traefik_config.yml" <<'EOF'
api:
  insecure: true
  dashboard: true

providers:
  http:
    endpoint: "http://pangolin:3001/api/v1/traefik-config"
    pollInterval: "5s"
  file:
    filename: "/etc/traefik/dynamic_config.yml"

experimental:
  plugins:
    badger:
      moduleName: "github.com/fosrl/badger"
      version: "v1.4.0"

log:
  level: "INFO"
  format: "common"
  maxSize: 100
  maxBackups: 3
  maxAge: 3
  compress: true

certificatesResolvers:
  letsencrypt:
    acme:
      httpChallenge:
        entryPoint: web
      email: "admin@example.com"
      storage: "/letsencrypt/acme.json"
      caServer: "https://acme-v02.api.letsencrypt.org/directory"

entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"
    transport:
      respondingTimeouts:
        readTimeout: "30m"
    http:
      tls:
        certResolver: "letsencrypt"
      encodedCharacters:
        allowEncodedSlash: true
        allowEncodedQuestionMark: true

serversTransport:
  insecureSkipVerify: true

ping:
  entryPoint: "web"
EOF
sed -i "s|admin@example.com|$EMAIL|" "$PG/config/traefik/traefik_config.yml"
fi

if [ ! -f "$PG/config/traefik/dynamic_config.yml" ]; then
cat > "$PG/config/traefik/dynamic_config.yml" <<'EOF'
http:
  middlewares:
    badger:
      plugin:
        badger:
          disableForwardAuth: true
    redirect-to-https:
      redirectScheme:
        scheme: https

  routers:
    main-app-router-redirect:
      rule: "Host(`pangolin.example.com`)"
      service: next-service
      entryPoints:
        - web
      middlewares:
        - redirect-to-https
        - badger

    next-router:
      rule: "Host(`pangolin.example.com`) && !PathPrefix(`/api/v1`)"
      service: next-service
      entryPoints:
        - websecure
      middlewares:
        - badger
      tls:
        certResolver: letsencrypt

    api-router:
      rule: "Host(`pangolin.example.com`) && PathPrefix(`/api/v1`)"
      service: api-service
      entryPoints:
        - websecure
      middlewares:
        - badger
      tls:
        certResolver: letsencrypt

    ws-router:
      rule: "Host(`pangolin.example.com`)"
      service: api-service
      entryPoints:
        - websecure
      middlewares:
        - badger
      tls:
        certResolver: letsencrypt

  services:
    next-service:
      loadBalancer:
        servers:
          - url: "http://pangolin:3002"

    api-service:
      loadBalancer:
        servers:
          - url: "http://pangolin:3000"

tcp:
  serversTransports:
    pp-transport-v1:
      proxyProtocol:
        version: 1
    pp-transport-v2:
      proxyProtocol:
        version: 2
EOF
sed -i "s|pangolin\.example\.com|$DASH|g" "$PG/config/traefik/dynamic_config.yml"
fi

if [ ! -f "$PG/config/config.yml" ]; then
SECRET="$(openssl rand -hex 32)"
cat > "$PG/config/config.yml" <<'EOF'
gerbil:
    start_port: 51820
    base_endpoint: "pangolin.example.com"

app:
    dashboard_url: "https://pangolin.example.com"
    log_level: "info"
    telemetry:
        anonymous_usage: false

domains:
    domain1:
        base_domain: "example.com"

server:
    secret: "replace-with-a-long-random-secret"
    cors:
        origins: ["https://pangolin.example.com"]
        methods: ["GET", "POST", "PUT", "DELETE", "PATCH"]
        allowed_headers: ["X-CSRF-Token", "Content-Type"]
        credentials: false

flags:
    require_email_verification: false
    disable_signup_without_invite: true
    disable_user_create_org: false
    allow_raw_resources: true
EOF
sed -i "s|pangolin\.example\.com|$DASH|g; s|\"example\.com\"|\"$BASE_DOMAIN\"|; s|replace-with-a-long-random-secret|$SECRET|" "$PG/config/config.yml"
chmod 600 "$PG/config/config.yml"
fi

# Pare-feu (les ports ouverts vers Internet côté box doivent être redirigés vers ce serveur)
ufw allow 80/tcp    >/dev/null 2>&1 || true
ufw allow 443/tcp   >/dev/null 2>&1 || true
ufw allow 51820/udp >/dev/null 2>&1 || true
ufw allow 21820/udp >/dev/null 2>&1 || true

if ! getent hosts "$DASH" >/dev/null; then
  warn "$DASH ne pointe vers aucune adresse pour l'instant (DNS). Crée l'enregistrement avant d'ouvrir la page."
fi

log "Démarrage de Pangolin"
(cd "$PG" && docker compose up -d)

echo -n "Attente de Pangolin"
for _ in $(seq 1 40); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' pangolin 2>/dev/null || true)" = "healthy" ] && break
  echo -n "."; sleep 3
done
echo

# ==================================================================
# 3. AJUSTEMENTS DES AUTRES STACKS
# ==================================================================
# Uptime Kuma : le tag stable actuel est :2
if [ -f "$STACKS/uptimekuma/compose.yaml" ] && grep -q 'uptime-kuma:1' "$STACKS/uptimekuma/compose.yaml"; then
  log "Uptime Kuma : passage à la version 2"
  sed -i 's|louislam/uptime-kuma:1|louislam/uptime-kuma:2|' "$STACKS/uptimekuma/compose.yaml"
  (cd "$STACKS/uptimekuma" && docker compose pull -q && docker compose up -d) || warn "Uptime Kuma : à vérifier"
fi

# Homepage : remplace la tuile Nginx Proxy Manager par Pangolin
HPS="$STACKS/homepage/config/services.yaml"
if [ -f "$HPS" ] && grep -q 'Nginx Proxy Manager' "$HPS"; then
  sed -i "s|Nginx Proxy Manager:|Pangolin:|; \
          s|icon: nginx-proxy-manager.png|icon: pangolin.png|; \
          s|description: Proxy et HTTPS|description: Accès distant et HTTPS|; \
          s|.*href: http://$IP:81.*|        href: https://$DASH|; \
          /siteMonitor: http:\/\/$IP:81/d" "$HPS"
fi
[ -f "$STACKS/ACCES.txt" ] && sed -i "s|^Nginx Proxy Mgr.*|Pangolin         https://$DASH   (stack : $PG)|" "$STACKS/ACCES.txt" || true

# ==================================================================
# 4. MISES À JOUR AUTOMATIQUES À MINUIT
# ==================================================================
log "Mise en place des mises à jour automatiques (chaque nuit à 00:00)"

cat > /usr/local/sbin/maj-nuit.sh <<'EOF'
#!/usr/bin/env bash
# Mise à jour automatique : système + toutes les stacks Docker
export DEBIAN_FRONTEND=noninteractive
STACKS="/opt/stacks"
AUTO_REBOOT="__AUTO_REBOOT__"
LOG="/var/log/maj-nuit.log"
exec >>"$LOG" 2>&1

echo
echo "===== $(date '+%F %T') : début des mises à jour ====="

snap() { dpkg-query -W -f='${Package} ${Version}\n' 'nvidia-*' 'linux-image-*' 2>/dev/null | sort || true; }
AVANT="$(snap)"

echo "--- Système (apt)"
apt-get update -q && apt-get -y -q -o Dpkg::Options::=--force-confold upgrade
apt-get -y -q autoremove --purge

echo "--- Conteneurs Docker"
for d in "$STACKS"/*/; do
  name="$(basename "$d")"
  if grep -qxF "$name" "$STACKS/.no-update" 2>/dev/null; then echo "* $name : ignoré (.no-update)"; continue; fi
  found=0
  for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    [ -f "$d$f" ] && found=1
  done
  [ "$found" = 1 ] || continue
  echo "* $name"
  ( cd "$d" && docker compose pull -q && docker compose up -d --remove-orphans ) || echo "  ECHEC : $name"
done
docker image prune -af --filter "until=72h" >/dev/null 2>&1 || true

APRES="$(snap)"
echo "===== $(date '+%F %T') : fin ====="
if [ "$AVANT" != "$APRES" ] && [ "$AUTO_REBOOT" = "oui" ]; then
  echo "Noyau ou pilote Nvidia mis à jour : redémarrage dans 1 minute."
  shutdown -r +1 "Redémarrage après mise à jour du noyau/pilote"
fi
EOF
sed -i "s|__AUTO_REBOOT__|$AUTO_REBOOT|" /usr/local/sbin/maj-nuit.sh
chmod 755 /usr/local/sbin/maj-nuit.sh

cat > /etc/systemd/system/maj-nuit.service <<'EOF'
[Unit]
Description=Mises à jour automatiques (système + Docker)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/maj-nuit.sh
TimeoutStartSec=3h
EOF

cat > /etc/systemd/system/maj-nuit.timer <<'EOF'
[Unit]
Description=Mises à jour chaque nuit à minuit

[Timer]
OnCalendar=*-*-* 00:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > /etc/logrotate.d/maj-nuit <<'EOF'
/var/log/maj-nuit.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF

systemctl daemon-reload
systemctl enable --now maj-nuit.timer
touch "$STACKS/.no-update"

# ==================================================================
# 5. RÉSUMÉ
# ==================================================================
echo
echo "=============================================================="
echo " Pangolin installé : https://$DASH"
echo
echo " 1) DNS : crée chez ton hébergeur de domaine deux enregistrements A"
echo "      $DASH      ->  ton IP publique"
echo "      *.$BASE_DOMAIN   ->  ton IP publique   (pour les futures applis)"
echo " 2) Box : redirige vers $IP  les ports  80/TCP  443/TCP  51820/UDP  21820/UDP"
echo " 3) Ouvre  https://$DASH/auth/initial-setup  et utilise le jeton ci-dessous :"
echo
docker logs pangolin 2>&1 | grep -i -B1 -A2 'token' | tail -n 12 || true
echo
echo "   (si rien ne s'affiche : cd $PG && docker compose logs pangolin | grep -i token)"
echo
echo " Mises à jour automatiques : chaque nuit à 00:00"
echo "   prochaine exécution : $(systemctl list-timers maj-nuit.timer --no-legend 2>/dev/null | awk '{print $1, $2}')"
echo "   lancer maintenant   : sudo systemctl start maj-nuit.service   (suivi : tail -f /var/log/maj-nuit.log)"
echo "   exclure une stack   : echo NOM | sudo tee -a $STACKS/.no-update"
echo "=============================================================="
