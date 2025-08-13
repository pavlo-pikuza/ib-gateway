#!/usr/bin/env bash

# !!! target OS - Ubuntu 22.04 !!!

COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env"
GATEWAY_USER="ibgateway"
ROOT_DIR="/opt/ib-gateway"

# === Logging ===
LOG_DIR="${LOG_DIR:-./logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/remote_setup_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "$LOG_FILE") 2>&1
echo "[i] Logging to $LOG_FILE"

trap 'rc=$?; if [[ $rc -ne 0 ]]; then echo "[!] Script failed with exit code $rc. See log: $LOG_FILE"; fi' EXIT


set -euo pipefail

# === Check sshpass locally ===
if ! command -v sshpass >/dev/null 2>&1; then
  echo "[!] sshpass is required but not installed. Please install it and rerun."
  exit 1
fi

# === Usage & args ===
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <REMOTE_IP> <ROOT_PASSWORD>"
  exit 1
fi
REMOTE_IP="$1"
ROOT_PWD="$2"

# === Pre-flight: ensure local files exist ===
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "[!] ${ENV_FILE} not found. Aborting."
  exit 1
fi

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "[!] ${COMPOSE_FILE} not found. Aborting."
  exit 1
fi


SSH_BASE_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
SSH=(sshpass -p "$ROOT_PWD" ssh "${SSH_BASE_OPTS[@]}" root@"$REMOTE_IP")
SCP=(sshpass -p "$ROOT_PWD" scp "${SSH_BASE_OPTS[@]}")

echo "[i] Connecting to ${REMOTE_IP} as root..."

# === install Docker engine
"${SSH[@]}" "bash -s" <<'REMOTE_DOCKER'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release sudo

# Docker repo + key
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
| tee /etc/apt/sources.list.d/docker.list >/dev/null

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl restart docker
REMOTE_DOCKER

# === Add user ===
generate_ib_pwd() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 15 | tr -d '\n'
  else
    LC_ALL=C tr -dc 'A-Za-z0-9!@#%^&*()_+{};.,?=-' </dev/urandom | head -c 20
  fi
}

IB_PWD="$(generate_ib_pwd)"
PW_FILE="./ibgateway_password.txt"
umask 177
printf '%s\n' "$IB_PWD" > "$PW_FILE"
chmod 600 "$PW_FILE"
echo "[i] ibgateway password saved to ${PW_FILE}"

"${SSH[@]}" "GATEWAY_USER=$(printf %q "$GATEWAY_USER")" "IB_PWD=$(printf %q "$IB_PWD")" bash -s <<'REMOTE_USER'
set -euo pipefail

if ! id -u "${GATEWAY_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${GATEWAY_USER}"
fi

echo "${GATEWAY_USER}:${IB_PWD}" | chpasswd

if [[ ! -f "/etc/sudoers.d/${GATEWAY_USER}" ]]; then
  echo "${GATEWAY_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${GATEWAY_USER}"
  chmod 440 "/etc/sudoers.d/${GATEWAY_USER}"
fi

usermod -aG docker "${GATEWAY_USER}" || true
REMOTE_USER

# === Setup user's folder
"${SSH[@]}" "GATEWAY_USER=$(printf %q "$GATEWAY_USER") ROOT_DIR=$(printf %q "$ROOT_DIR") bash -s" <<'REMOTE_APPDIR'
set -euo pipefail
mkdir -p "${ROOT_DIR}"
chown -R "${GATEWAY_USER}:${GATEWAY_USER}" "${ROOT_DIR}"
REMOTE_APPDIR

# === Set timezone (needs the TZ value we parsed locally) ===
TZ_VALUE="$(
  awk -F= 'tolower($1)=="tz"{print $2; exit}' "${ENV_FILE}" \
  | tr -d '\r' | xargs
)"
TZ_VALUE="${TZ_VALUE:-UTC}"
echo "[i] Timezone from ${ENV_FILE}: ${TZ_VALUE}"
"${SSH[@]}" "timedatectl set-timezone \"$TZ_VALUE\" || (echo '[!] timedatectl failed; falling back to /etc/timezone' && echo \"$TZ_VALUE\" > /etc/timezone && dpkg-reconfigure -f noninteractive tzdata || true)"

# === Copy project files to remote ===
echo "[i] Copying .env and ${COMPOSE_FILE} to ${ROOT_DIR} ..."
"${SCP[@]}" -p "${ENV_FILE}" "root@${REMOTE_IP}:${ROOT_DIR}/${ENV_FILE}"
"${SCP[@]}" -p "${COMPOSE_FILE}" "root@${REMOTE_IP}:${ROOT_DIR}/${COMPOSE_FILE}"  
"${SSH[@]}" "chown -R ${GATEWAY_USER}:${GATEWAY_USER} ${ROOT_DIR}"

# === Build & up (as dedicated user) ===
echo "[i] Building and starting with Docker Compose..."
"${SSH[@]}" "sudo -u ${GATEWAY_USER} bash -lc 'cd ${ROOT_DIR} && \
  (docker compose version >/dev/null 2>&1 && docker compose up -d --build) || \
  (command -v docker-compose >/dev/null 2>&1 && docker-compose up -d --build) || \
  (echo \"[!] Neither docker compose plugin nor docker-compose found\"; exit 1)
'"

# === SSH hardening: allow only ibgateway, disable root, keep password auth ===
"${SSH[@]}" "GATEWAY_USER=$(printf %q "$GATEWAY_USER")" bash -s <<'REMOTE_SSHD'
set -euo pipefail
CFG="/etc/ssh/sshd_config"

# Restrict root-login
if grep -qE '^\s*PermitRootLogin' "$CFG"; then
  sed -i 's/^\s*PermitRootLogin.*/PermitRootLogin no/' "$CFG"
else
  echo 'PermitRootLogin no' >> "$CFG"
fi

# Allow ssh only for ibgateway user
if grep -qE '^\s*AllowUsers' "$CFG"; then
  sed -i "s/^\s*AllowUsers.*/AllowUsers ${GATEWAY_USER}/" "$CFG"
else
  echo "AllowUsers ${GATEWAY_USER}" >> "$CFG"
fi

# Password autentification ON
if grep -qE '^\s*PasswordAuthentication' "$CFG"; then
  sed -i 's/^\s*PasswordAuthentication.*/PasswordAuthentication yes/' "$CFG"
else
  echo 'PasswordAuthentication yes' >> "$CFG"
fi

# For empty passwords
if grep -qE '^\s*PermitEmptyPasswords' "$CFG"; then
  sed -i 's/^\s*PermitEmptyPasswords.*/PermitEmptyPasswords no/' "$CFG"
else
  echo 'PermitEmptyPasswords no' >> "$CFG"
fi

systemctl reload sshd || systemctl reload ssh
REMOTE_SSHD


echo "[✓] Done. Service should be up on ${REMOTE_IP}."
cat <<EOF
    Useful checks:
      sshpass -f ./ibgateway_password.txt ssh -o StrictHostKeyChecking=no ibgateway@${REMOTE_IP} 'docker ps'
      sshpass -f ./ibgateway_password.txt ssh -o StrictHostKeyChecking=no ibgateway@${REMOTE_IP} 'journalctl -u docker -n 200 --no-pager'
EOF
