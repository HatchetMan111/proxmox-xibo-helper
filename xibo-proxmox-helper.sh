#!/usr/bin/env bash
# ===============================================================
# Xibo CMS - Proxmox Helper Script (Interactive Installer)
# ===============================================================

set -e

APP="Xibo CMS"
OSTYPE="ubuntu"
OSVERSION="24.10-1"
BRIDGE="vmbr0"

# --- Banner ---
clear
echo -e "\e[1;36m"
echo "─────────────────────────────────────────────"
echo "   🧩 ${APP} - Proxmox Interactive Installer"
echo "─────────────────────────────────────────────"
echo -e "\e[0m"

# --- Check PVE ---
if ! command -v pveversion >/dev/null 2>&1; then
  echo "❌ Dieses Script muss auf einem Proxmox Host ausgeführt werden!"
  exit 1
fi

# --- Fragen an den Benutzer ---
read -p "🆔 Container ID (leer = auto): " CTID
CTID=${CTID:-$(pvesh get /cluster/nextid)}

read -p "🖥️  Hostname [xibo]: " HOSTNAME
HOSTNAME=${HOSTNAME:-xibo}

read -p "💾 Disk Size in GB [20]: " DISK
DISK=${DISK:-20}

read -p "🧠 Memory in MB [4096]: " MEMORY
MEMORY=${MEMORY:-4096}

read -p "⚙️  CPU Cores [2]: " CORE
CORE=${CORE:-2}

read -p "🔐 Xibo MySQL Passwort [xiboPass123]: " MYSQL_PASSWORD
MYSQL_PASSWORD=${MYSQL_PASSWORD:-xiboPass123}

read -p "🌐 HTTP Port [8080]: " XIBO_PORT
XIBO_PORT=${XIBO_PORT:-8080}

echo -e "\n🚀 Starte Installation von ${APP} im Container #${CTID}...\n"

# --- Dynamisches Ubuntu-Template finden ---
TEMPLATE_STORE=$(pvesm status | awk '/dir/ && /active/ {print $1; exit}')
LATEST_TEMPLATE=$(pveam available | grep ubuntu | grep standard | tail -n 1 | awk '{print $2}')
TEMPLATE="${TEMPLATE_STORE}:vztmpl/${LATEST_TEMPLATE}"

# --- Template herunterladen falls nötig ---
if ! pveam list $TEMPLATE_STORE | grep -q "$(basename $LATEST_TEMPLATE)"; then
  echo "📦 Lade Ubuntu Template (${LATEST_TEMPLATE}) herunter..."
  pveam download $TEMPLATE_STORE $LATEST_TEMPLATE
fi

# --- Container erstellen ---
pct create $CTID $TEMPLATE \
  -hostname $HOSTNAME \
  -cores $CORE \
  -memory $MEMORY \
  -swap 2048 \
  -rootfs local-lvm:${DISK} \
  -net0 name=eth0,bridge=$BRIDGE,ip=dhcp \
  -unprivileged 1 \
  -features nesting=1,keyctl=1 \
  -onboot 1 \
  -description "${APP} (Docker)" \
  -password "Xibo123!"

pct start $CTID
echo "⏳ Warte auf Container-Start..."
sleep 15

# --- Installation im Container ---
echo "🐳 Installiere Docker & ${APP}..."
pct exec $CTID -- bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive

# System aktualisieren
apt-get update
apt-get upgrade -y

# Docker installieren
apt-get install -y apt-transport-https ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \"\$VERSION_CODENAME\") stable\" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Xibo vorbereiten
mkdir -p /opt/xibo && cd /opt/xibo

# Docker Compose File mit KORREKTEN Images erstellen
cat > docker-compose.yml << EOF
version: '3.8'

services:
  xibo-cms:
    image: xibosignage/xibo-cms:latest
    ports:
      - \"$XIBO_PORT:80\"
    environment:
      MYSQL_HOST: xibo-db
      MYSQL_USER: xibo
      MYSQL_PASSWORD: $MYSQL_PASSWORD
      MYSQL_DATABASE: xibo
      MYSQL_PORT: 3306
      CMS_SERVER_NAME: localhost
      CMS_DEV_MODE: \"false\"
    volumes:
      - xibo_uploads:/var/www/cms/uploads
      - xibo_library:/var/www/cms/library
      - xibo_cache:/var/www/cms/cache
      - xibo_backup:/var/www/cms/backup
    depends_on:
      - xibo-db
    restart: unless-stopped

  xibo-db:
    image: mariadb:10.11
    environment:
      MYSQL_ROOT_PASSWORD: $MYSQL_PASSWORD
      MYSQL_DATABASE: xibo
      MYSQL_USER: xibo
      MYSQL_PASSWORD: $MYSQL_PASSWORD
    volumes:
      - xibo_db:/var/lib/mysql
    command: [
        \"--character-set-server=utf8mb4\",
        \"--collation-server=utf8mb4_unicode_ci\",
        \"--skip-character-set-client-handshake\"
    ]
    restart: unless-stopped

volumes:
  xibo_uploads:
  xibo_library:
  xibo_db:
  xibo_cache:
  xibo_backup:
EOF

# Container starten
docker compose up -d

# Warte auf Start
echo \"⏳ Warte auf Xibo Initialisierung (kann 2-3 Minuten dauern)...\"
sleep 60
"

# --- IP ermitteln ---
echo "⏳ Warte auf Netzwerk..."
sleep 10
IP=$(pct exec $CTID ip -4 addr show dev eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)

# --- Final Check ---
echo "🔍 Prüfe Installation..."
if pct exec $CTID -- docker ps | grep -q xibo; then
    echo -e "\e[1;32m"
    echo "✅ ${APP} erfolgreich installiert!"
    echo -e "\e[0m"
    echo "─────────────────────────────────────────────"
    echo "📦 Container-ID : $CTID"
    echo "🌐 Zugriff      : http://${IP}:${XIBO_PORT}"
    echo "🔑 Login        : admin / password"
    echo "🗄️  Datenpfad   : /opt/xibo"
    echo "─────────────────────────────────────────────"
    echo "💡 Nach Login bitte Passwort ändern!"
    echo "⚠️  Erster Start kann 2-3 Minuten dauern!"
    echo "─────────────────────────────────────────────"
else
    echo "❌ Container läuft nicht - prüfe Logs:"
    pct exec $CTID -- docker compose logs
fi
