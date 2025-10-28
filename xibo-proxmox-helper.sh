#!/usr/bin/env bash
# ===============================================================
# Xibo CMS - Proxmox Helper Script (Interactive Installer)
# Author: GPT-5
# Tested on Proxmox VE 8.x
# ===============================================================

set -e

APP="Xibo CMS"
OSTYPE="ubuntu"
OSVERSION="OSVERSION="24.10-1"
"
BRIDGE="vmbr0"
XIBO_VERSION="release-4.0.9"

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

# --- Template prüfen ---
TEMPLATE="local:vztmpl/ubuntu-${OSVERSION}-standard_amd64.tar.zst"
if ! pveam list local | grep -q "ubuntu-${OSVERSION}"; then
  echo "📦 Lade Ubuntu ${OSVERSION} Template herunter..."
  pveam download local ubuntu-${OSVERSION}-standard_amd64.tar.zst
fi

# --- Container erstellen ---
pct create $CTID $TEMPLATE \
  -hostname $HOSTNAME \
  -cores $CORE \
  -memory $MEMORY \
  -rootfs local-lvm:${DISK} \
  -net0 name=eth0,bridge=$BRIDGE,ip=dhcp \
  -unprivileged 1 \
  -features nesting=1,keyctl=1 \
  -onboot 1 \
  -description "${APP} (Docker)" \
  -password "xibo"

pct start $CTID
sleep 10

# --- Installation im Container ---
echo "🐳 Installiere Docker & ${APP}..."
pct exec $CTID -- bash -c "
set -e
apt update && apt upgrade -y
apt install -y docker.io docker-compose-v2 curl unzip wget
mkdir -p /opt/xibo && cd /opt/xibo
wget -q https://github.com/xibosignage/xibo-docker/archive/refs/heads/$XIBO_VERSION.zip
unzip -q $XIBO_VERSION.zip
mv xibo-docker-$XIBO_VERSION/* .
rm -rf xibo-docker-$XIBO_VERSION $XIBO_VERSION.zip
cat > .env <<EOF
MYSQL_PASSWORD=$MYSQL_PASSWORD
MYSQL_ROOT_PASSWORD=$MYSQL_PASSWORD
CMS_PORT=$XIBO_PORT
CMS_SERVER_NAME=localhost
CMS_DEV_MODE=false
EOF
docker compose up -d
"

# --- IP ermitteln ---
IP=$(pct exec $CTID ip -4 addr show dev eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)

# --- Ausgabe ---
clear
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
echo "─────────────────────────────────────────────"
