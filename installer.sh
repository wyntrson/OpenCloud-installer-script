#!/bin/bash
set -eo pipefail

# --------------- helpers ---------------
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
err()   { echo -e "${RED}[ERR]${NC}   $*" >&2; }
banner(){ echo -e "\n${BOLD}$*${NC}"; }

cleanup() { err "Script failed at line $1. Containers may be in a partial state — check 'docker compose -f $COMPOSE_FILE ps'."; }
trap 'cleanup $LINENO' ERR

COMPOSE_FILE="/opt/opencloud/docker-compose.yml"
OC_IMAGE="opencloudeu/opencloud"

is_valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
  for octet in "$o1" "$o2" "$o3" "$o4"; do
    (( octet >= 0 && octet <= 255 )) || return 1
  done
  return 0
}

# --------------- preflight ---------------
if [[ "$EUID" -ne 0 ]]; then
  err "Please run as root"; exit 1
fi

for cmd in docker tailscale timeout; do
  if ! command -v "$cmd" &>/dev/null; then
    err "'$cmd' is not installed or not in PATH"; exit 1
  fi
done

if ! docker compose version &>/dev/null; then
  err "'docker compose' plugin is not available"; exit 1
fi

if [[ "$(command -v docker)" == "/snap/bin/docker" ]]; then
  err "Docker installed via snap is not supported due to strict path confinement."
  err "Please run: snap remove docker && curl -fsSL https://get.docker.com | sh"
  exit 1
fi

if ! docker info &>/dev/null; then
  err "Docker daemon is not running"; exit 1
fi

# --------------- detect existing deployment ---------------
if [[ -f "$COMPOSE_FILE" ]]; then
  info "Existing compose file found at $COMPOSE_FILE"
  read -p "Tear down and recreate? [y/N]: " RECREATE
  if [[ "${RECREATE,,}" == "y" ]]; then
    docker compose -f "$COMPOSE_FILE" down --remove-orphans
    ok "Previous deployment removed"
  else
    info "Aborting — existing deployment left untouched"; exit 0
  fi
fi

# --------------- collect inputs ---------------
TS_IP=$(tailscale ip -4 2>/dev/null || true)

banner "================================================="
banner " OpenCloud Tenant Installer (Tailscale-Only)"
banner "================================================="
[[ -n "$TS_IP" ]] && info "Detected Tailscale IPv4: $TS_IP" || info "Tailscale IPv4 not detected — enter manually"
echo ""

read -p "Enter the Tailscale IP to bind to [$TS_IP]: " BIND_IP
BIND_IP=${BIND_IP:-$TS_IP}
if [[ -z "$BIND_IP" ]]; then
  err "No Tailscale IP provided and none detected. Is Tailscale running?"; exit 1
fi
if ! is_valid_ipv4 "$BIND_IP"; then
  err "Invalid IPv4 address: $BIND_IP"; exit 1
fi

read -p "Enter the port for OpenCloud [8080]: " OC_PORT
OC_PORT=${OC_PORT:-8080}
if ! [[ "$OC_PORT" =~ ^[0-9]+$ ]] || (( OC_PORT < 1 || OC_PORT > 65535 )); then
  err "Port must be a number between 1 and 65535."; exit 1
fi

read -p "Enter the absolute path for file storage [/mnt/clouddata]: " STORAGE_PATH
STORAGE_PATH=${STORAGE_PATH:-/mnt/clouddata}
if [[ "$STORAGE_PATH" != /* ]]; then
  err "Storage path must be an absolute path."; exit 1
fi

read -p "Enter your Tailscale MagicDNS domain (e.g., machine.alias.ts.net): " TS_DOMAIN
if [[ -z "$TS_DOMAIN" ]]; then
  err "Tailscale MagicDNS domain cannot be empty."; exit 1
fi
if [[ "$TS_DOMAIN" =~ [[:space:]] ]] || [[ "$TS_DOMAIN" != *.* ]]; then
  err "Invalid domain format: $TS_DOMAIN"; exit 1
fi

# --------------- prepare storage ---------------
mkdir -p "$STORAGE_PATH" /opt/opencloud/config
chown -R 1000:1000 "$STORAGE_PATH" /opt/opencloud/config
chmod 750 "$STORAGE_PATH"
ok "Storage directories ready"

# --------------- generate docker-compose.yml ---------------
cat <<EOF > "$COMPOSE_FILE"
services:
  opencloud:
    image: $OC_IMAGE:latest
    container_name: opencloud_tenant
    restart: unless-stopped
    ports:
      - "$BIND_IP:$OC_PORT:9200"
    volumes:
      - "$STORAGE_PATH:/var/lib/opencloud"
      - "/opt/opencloud/config:/etc/opencloud"
    environment:
      OPENCLOUD_URL: "https://$TS_DOMAIN"
      OPENCLOUD_INSECURE: "false"
      PROXY_TLS: "false"
EOF
ok "Compose file written to $COMPOSE_FILE"

# --------------- initialise before starting ---------------
info "Pulling image..."
docker pull "${OC_IMAGE}:latest"
info "Running initialisation (generating secrets, etc.)..."

# Clean up any leftover init container from a previous failed run
docker rm -f opencloud_init &>/dev/null || true

# Use timeout to prevent hanging; --rm cleans up container automatically
set +e
INIT_OUT=$(timeout 60 docker run --rm --name opencloud_init \
  -v "/opt/opencloud/config:/etc/opencloud" \
  -e OPENCLOUD_URL="https://$TS_DOMAIN" \
  "$OC_IMAGE:latest" init 2>&1)
INIT_EXIT=$?
set -e

if [[ $INIT_EXIT -eq 124 ]]; then
  info "Initialisation timed out after 60s; proceeding with existing config."
elif [[ $INIT_EXIT -ne 0 ]]; then
  info "Initialisation exited with code $INIT_EXIT; proceeding and showing output below."
else
  ok "Initialisation step done"
fi

# --------------- start container ---------------
info "Starting container..."
docker compose -f "$COMPOSE_FILE" up -d

# --------------- wait for healthy ---------------
info "Waiting for OpenCloud to become healthy (up to 120 s)..."
SECONDS=0
MAX_WAIT=120
while true; do
  STATE=$(docker inspect --format='{{.State.Health.Status}}' opencloud_tenant 2>/dev/null || echo "starting")
  # If no HEALTHCHECK is defined, STATE is empty — fall back to checking if container is running
  if [[ -z "$STATE" ]]; then
    STATE=$(docker inspect --format='{{.State.Status}}' opencloud_tenant 2>/dev/null || echo "starting")
    [[ "$STATE" == "running" ]] && { ok "Container is running (no healthcheck defined, ${SECONDS}s)"; break; }
  fi
  if [[ "$STATE" == "unhealthy" ]]; then
    err "Container reported unhealthy state."
    err "Recent logs:"
    docker compose -f "$COMPOSE_FILE" logs --tail=40
    exit 1
  fi
  if [[ "$STATE" == "healthy" ]]; then
    ok "Container is healthy (${SECONDS}s)"; break
  fi
  if (( SECONDS >= MAX_WAIT )); then
    err "Timed out waiting for healthy state (last status: $STATE)"
    err "Check logs: docker compose -f $COMPOSE_FILE logs"
    exit 1
  fi
  sleep 3
done

# --------------- show credentials ---------------
info "Configuration results:"
echo -e "$INIT_OUT"

banner "================================================="
banner " INSTALLATION COMPLETE"
banner "================================================="
info "Access URL:   https://$TS_DOMAIN"
info "              (route 443 via 'tailscale serve' or funnel to $BIND_IP:$OC_PORT)"
info "Direct URL:   http://$BIND_IP:$OC_PORT"
info "Storage Path: $STORAGE_PATH"
echo ""
ok "Check the output above for any admin credentials."
