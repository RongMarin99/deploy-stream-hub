#!/bin/bash
# Run this on the server. Needs only this file + docker-compose.prod.yml — no
# source code, no manual .env editing, no need to have Docker installed already
# (this script installs it for you if missing). First run asks a few questions
# (admin username/password/email, your domain or IP) and generates secrets for you.
#
# Run as root, or as a user that can sudo without issue.
#
# Usage:
#   ./setup.sh                first run: interactive setup, then starts everything
#   ./setup.sh                later runs: pulls latest images, restarts (no prompts)
#   ./setup.sh --reconfigure  redo the questions (won't change an already-seeded
#                             admin password — see note below)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not found — installing it automatically (takes a minute)..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | $SUDO sh
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- https://get.docker.com | $SUDO sh
  else
    echo "Need curl or wget to auto-install Docker, and neither is on this machine." >&2
    echo "Ask whoever manages this server to install curl, or install Docker manually: https://docs.docker.com/engine/install/" >&2
    exit 1
  fi
  $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker install didn't finish cleanly. Ask whoever manages this server to install it manually: https://docs.docker.com/engine/install/" >&2
    exit 1
  fi
  echo "Docker installed."
fi

if ! $SUDO docker compose version >/dev/null 2>&1; then
  echo "Docker's Compose plugin is missing even after install. Ask whoever manages this server to check the Docker install: https://docs.docker.com/engine/install/" >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required (used to generate secrets) but was not found." >&2
  echo "On Debian/Ubuntu: $SUDO apt-get install -y openssl" >&2
  exit 1
fi

ENV_FILE=".env"
COMPOSE_FILE="docker-compose.prod.yml"
if [ ! -f "$COMPOSE_FILE" ] && [ -f "docker-compose.yml" ]; then
  COMPOSE_FILE="docker-compose.yml"
fi

if [ ! -f "$COMPOSE_FILE" ] || grep -q "Not Found" "$COMPOSE_FILE"; then
  echo "Error: Cannot find valid '$COMPOSE_FILE' or 'docker-compose.yml' in current directory." >&2
  echo "Please ensure you have cloned or downloaded the deployment repository files into this directory." >&2
  exit 1
fi

if [ -f "$ENV_FILE" ] && [ "$1" != "--reconfigure" ]; then
  echo "Found existing setup. Pulling latest images and restarting..."
  docker compose -f "$COMPOSE_FILE" pull
  docker compose -f "$COMPOSE_FILE" up -d
  echo
  echo "StreamHub is up."
  echo "(run './setup.sh --reconfigure' to redo the setup questions)"
  exit 0
fi

echo "=== StreamHub server setup ==="
echo

read -rp "Admin username [admin]: " ADMIN_USERNAME
ADMIN_USERNAME=${ADMIN_USERNAME:-admin}

read -rp "Admin email [admin@example.com]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-admin@example.com}

while true; do
  read -rsp "Admin password: " ADMIN_PASSWORD
  echo
  [ -n "$ADMIN_PASSWORD" ] && break
  echo "Password can't be empty."
done

read -rp "Server domain or IP people will use to reach this site (e.g. streamhub.example.com or 203.0.113.5) [localhost]: " SERVER_HOST
SERVER_HOST=${SERVER_HOST:-localhost}

echo
echo "YouTube sync (optional — press Enter to skip; add later by editing .env):"
read -rp "Google OAuth client ID: " GOOGLE_CLIENT_ID
read -rsp "Google OAuth client secret: " GOOGLE_CLIENT_SECRET
echo

JWT_SECRET_KEY=$(openssl rand -hex 48)
AES_ENCRYPTION_KEY=$(openssl rand -base64 32)

cat > "$ENV_FILE" <<EOF
PROJECT_NAME=StreamHub
ENV=production
DEBUG=false
LOG_LEVEL=INFO

API_V1_PREFIX=/api/v1
CORS_ORIGINS=["*"]

DATABASE_URL=postgresql+asyncpg://streamhub:streamhub@postgres:5432/streamhub
REDIS_URL=redis://redis:6379/0
CELERY_BROKER_URL=redis://redis:6379/1
CELERY_RESULT_BACKEND=redis://redis:6379/2

JWT_SECRET_KEY=${JWT_SECRET_KEY}
JWT_ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=15
REFRESH_TOKEN_EXPIRE_DAYS=7

AES_ENCRYPTION_KEY=${AES_ENCRYPTION_KEY}

STORAGE_ROOT=./storage
UPLOAD_DIR=uploads
THUMBNAIL_DIR=thumbnails
TEMP_DIR=temp
LOG_DIR=logs

MAX_UPLOAD_SIZE_MB=2048

ADMIN_USERNAME=${ADMIN_USERNAME}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
ADMIN_EMAIL=${ADMIN_EMAIL}

GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}
GOOGLE_CLIENT_SECRET=${GOOGLE_CLIENT_SECRET}
GOOGLE_REDIRECT_URI=http://${SERVER_HOST}:3001/settings/youtube

NUXT_PUBLIC_API_BASE=http://${SERVER_HOST}:8000/api/v1
NUXT_PUBLIC_WS_BASE=ws://${SERVER_HOST}:8000/ws
EOF

chmod 600 "$ENV_FILE"

echo
echo "Config saved. Pulling images and starting StreamHub..."
docker compose -f "$COMPOSE_FILE" pull
docker compose -f "$COMPOSE_FILE" up -d

echo
echo "=================================================="
echo " StreamHub is up."
echo " Frontend: http://${SERVER_HOST}:3001"
echo " Backend health: http://${SERVER_HOST}:8000/api/v1/health"
echo " Admin login: ${ADMIN_USERNAME} / (the password you just entered)"
echo "=================================================="
echo " Note: the admin password only seeds on first boot (empty database)."
echo " Re-running setup later won't change it once the admin user exists."
echo " Data lives in Docker volumes (streamhub_*): updates never delete it."
echo " NEVER run 'docker compose down -v' — that is the only thing that wipes data."
