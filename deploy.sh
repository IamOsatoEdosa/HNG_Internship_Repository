#!/usr/bin/env bash
# POSIX-friendly with bash shebang for better readability; avoid bash-only features.

set -euo pipefail

# Global constants
SCRIPT_NAME="deploy.sh"
DATESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="$(pwd)"
LOG_FILE="${LOG_DIR}/deploy_${DATESTAMP}.log"

# Logging helpers
log_info()  { printf "[INFO] %s\n" "$1" | tee -a "$LOG_FILE"; }
log_warn()  { printf "[WARN] %s\n" "$1" | tee -a "$LOG_FILE"; }
log_error() { printf "[ERROR] %s\n" "$1" | tee -a "$LOG_FILE" >&2; }

# Trap unexpected errors
cleanup_on_error() {
  local exit_code=$?
  log_error "Unexpected error occurred. Exit code: ${exit_code}"
  log_error "Check log file: ${LOG_FILE}"
  exit "${exit_code}"
}
trap cleanup_on_error ERR

# Validation functions (POSIX-ish)
is_integer() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_valid_port() {
  is_integer "$1" || return 1
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_valid_ip() {
  IFS='.' read -r o1 o2 o3 o4 <<EOF
$1
EOF
  for o in "$o1" "$o2" "$o3" "$o4"; do
    is_integer "$o" || return 1
    [ "$o" -ge 0 ] && [ "$o" -le 255 ] || return 1
  done
  [ -n "$o4" ]
}

is_valid_url() {
  case "$1" in
    http://*|https://*) printf "%s" "$1" | grep -qE '^https?://.+' ;;
    *) return 1 ;;
  esac
}

# Prompt helpers
prompt() {
  local label="${1}"
  local default="${2:-}"
  local reply

  if [ -n "$default" ]; then
    read -r -p "$label [$default]: " reply
    reply="${reply:-$default}"
  else
    read -r -p "$label: " reply
  fi

  printf "%s" "$reply"
}

prompt_secret() {
  local label="$1"
  local secret
  printf "%s: " "$label" >&2
  stty -echo
  IFS= read -r secret
  stty echo
  printf '\n' >&2
  secret="$(printf '%s' "$secret" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  printf "%s" "$secret"
}

# Start
log_info "Starting ${SCRIPT_NAME}"
log_info "Logging to ${LOG_FILE}"

# 1) Collect Parameters
REPO_URL="$(prompt 'Git repository URL (HTTPS)')"
PAT="$(prompt_secret 'Personal Access Token (PAT)')"
#printf 'DEBUG: PAT length = %s\n' "${#PAT}" >&2
#printf 'DEBUG: PAT raw -> [%s]\n' "$PAT" >&2

BRANCH="$(prompt 'Branch name' 'main')"
SSH_USER="$(prompt 'Remote SSH username')"
SERVER_IP="$(prompt 'Remote server IP address')"
SSH_KEY_PATH="$(prompt 'SSH private key path (e.g., ~/.ssh/id_rsa)')"
APP_PORT="$(prompt 'Application internal container port (e.g., 3000)')"

# 2) Validate Parameters
log_info "Validating inputs..."

if ! is_valid_url "$REPO_URL"; then
  log_error "Invalid repository URL: $REPO_URL"
  exit 10
fi

if [ -z "$PAT" ]; then
  log_error "PAT cannot be empty."
  exit 11
fi

if [ -z "$BRANCH" ]; then
  log_warn "Branch empty, defaulting to main."
  BRANCH="main"
fi

if [ -z "$SSH_USER" ]; then
  log_error "SSH username cannot be empty."
  exit 12
fi

if ! is_valid_ip "$SERVER_IP"; then
  log_error "Invalid IP address: $SERVER_IP"
  exit 13
fi

EXPANDED_SSH_KEY_PATH="$(eval echo "$SSH_KEY_PATH")"
if [ ! -f "$EXPANDED_SSH_KEY_PATH" ]; then
  log_error "SSH key not found at: $EXPANDED_SSH_KEY_PATH"
  exit 14
fi
KEY_MODE="$(stat -c %a "$EXPANDED_SSH_KEY_PATH" 2>/dev/null || echo "")"
if [ -n "$KEY_MODE" ] && [ "$KEY_MODE" -gt 600 ]; then
  log_warn "SSH key permissions are $KEY_MODE; recommend chmod 600."
fi

if ! is_valid_port "$APP_PORT"; then
  log_error "Invalid port: $APP_PORT (must be 1-65535)"
  exit 15
fi

log_info "All inputs validated successfully."
log_info "Step 1 complete. Next: Clone repository (Step 2)."

# -------------------------------
# Step 2: Clone the Repository
# -------------------------------
log_info "Starting Step 2: Clone repository..."

# Build authenticated repo URL
AUTH_REPO_URL="${REPO_URL/https:\/\//https:\/\/${PAT}@}"

# Debug: show URL with PAT masked
echo "DEBUG: AUTH_REPO_URL = $(echo "$AUTH_REPO_URL" | sed -E 's|(https://)[^@]+@github.com|\1****@github.com|')" >&2

# Normalize repo name
REPO_NAME="${REPO_NAME:-$(basename -s .git "${REPO_URL%/}")}"
echo "DEBUG: REPO_NAME=$REPO_NAME"

# Escape PAT for safe logging
SAFE_PAT="$(printf '%s' "$PAT" | sed 's/[&/\]/\\&/g')"

# Clone or update repo
if [ -d "$REPO_NAME/.git" ]; then
  log_warn "Repository '$REPO_NAME' already exists. Pulling latest changes..."
  git -C "$REPO_NAME" fetch origin "$BRANCH" 2>&1 | sed "s|${SAFE_PAT}|****|g" | tee -a "$LOG_FILE"
  git -C "$REPO_NAME" checkout "$BRANCH" 2>&1 | sed "s|${SAFE_PAT}|****|g" | tee -a "$LOG_FILE"
  git -C "$REPO_NAME" pull origin "$BRANCH" 2>&1 | sed "s|${SAFE_PAT}|****|g" | tee -a "$LOG_FILE"
else
  log_info "Cloning repository into '$REPO_NAME'..."
  git clone "$AUTH_REPO_URL" "$REPO_NAME" 2>&1 | sed "s|${SAFE_PAT}|****|g" | tee -a "$LOG_FILE"
  log_info "Repository cloned successfully."
  # Do NOT cd here — Step 3 will handle navigation
fi

log_info "Step 2 complete. Next: Navigate into repo (Step 3)."

# -------------------------------
# Step 3: Navigate into Cloned Directory
# -------------------------------
log_info "Starting Step 3: Navigate into cloned directory..."

REPO_NAME="${REPO_NAME:-$(basename -s .git "${REPO_URL%/}")}"
REPO_PATH="$(pwd)/$REPO_NAME"

STEP3_STATUS=0

# Guard directory existence
[ -d "$REPO_PATH" ] || {
  log_error "Repository directory $REPO_PATH not found."
  STEP3_STATUS=1
}

# Guard cd operation
if [ $STEP3_STATUS -eq 0 ]; then
  cd "$REPO_PATH" 2>/dev/null || {
    log_error "Failed to enter repository directory: $REPO_PATH"
    STEP3_STATUS=1
  }
fi

# Verify Dockerfile or docker-compose.yml exists
if [ $STEP3_STATUS -eq 0 ]; then
  if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ]; then
    log_info "Verified: Dockerfile or docker-compose.yml found."
  else
    log_error "Neither Dockerfile nor docker-compose.yml found in $REPO_PATH."
    STEP3_STATUS=1
  fi
fi

# Final verdict (use exit for bash runs; use return if sourcing)
if [ $STEP3_STATUS -eq 0 ]; then
  echo "Yes step 3 whoooop"
  log_info "Step 3 SUCCESS. Next: Connect to remote server (Step 4)."
else
  log_error "Step 3 FAILURE. Cannot proceed to Step 4."
  # Prefer exit for non-sourced runs:
  exit 16
  # If you always source, replace the line above with: return 1
fi

# -------------------------------
# Step 4: SSH into the Remote Server
# -------------------------------
log_info "Starting Step 4: SSH into the remote server..."

# Sanity check: ensure required variables are set
if [ -z "$SSH_USER" ] || [ -z "$SERVER_IP" ] || [ -z "$SSH_KEY_PATH" ]; then
    log_error "Missing SSH connection details. Ensure SSH_USER, SERVER_IP, and SSH_KEY_PATH are set."
    return 1   # use return since script is sourced
fi

# (a) SSH dry-run
log_info "Attempting SSH dry-run to $SSH_USER@$SERVER_IP..."
ssh -i "$SSH_KEY_PATH" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    "$SSH_USER@$SERVER_IP" "echo '[INFO] SSH connection successful'" 2>&1 | tee -a "$LOG_FILE"

if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    log_error "SSH dry-run failed. Please check your key, username, and server IP."
    return 1
fi

# (b) Confirm we can execute arbitrary commands remotely
log_info "Executing basic remote commands to validate environment..."
ssh -i "$SSH_KEY_PATH" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    "$SSH_USER@$SERVER_IP" "whoami && hostname && uname -a" 2>&1 | tee -a "$LOG_FILE"

if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    log_error "Remote command execution failed."
    return 1
else
    log_info "Remote command execution succeeded. Ready for Step 5 provisioning."
fi

log_info "Step 4 complete. Remote server is reachable and ready for environment setup."

# -------------------------------
# Step 5: Prepare the Remote Environment
# -------------------------------
log_info "Starting Step 5: Prepare the remote environment..."

ssh -i "$SSH_KEY_PATH" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    "$SSH_USER@$SERVER_IP" bash -s <<'REMOTE_CMDS' | tee -a "$LOG_FILE"
set -e

echo "[INFO] Updating system packages..."
sudo apt-get update -y && sudo apt-get upgrade -y

echo "[INFO] Installing Docker if missing..."
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
fi

echo "[INFO] Installing Docker Compose if missing..."
if ! command -v docker-compose >/dev/null 2>&1; then
    sudo apt-get install -y docker-compose
fi

echo "[INFO] Installing Nginx if missing..."
if ! command -v nginx >/dev/null 2>&1; then
    sudo apt-get install -y nginx
fi

echo "[INFO] Adding user to Docker group..."
sudo usermod -aG docker "$USER"

echo "[INFO] Enabling and starting services..."
sudo systemctl enable docker
sudo systemctl start docker
sudo systemctl enable nginx
sudo systemctl start nginx

echo "[INFO] Confirming installation versions..."
docker --version || echo "Docker not found"
docker-compose --version || echo "Docker Compose not found"
nginx -v || echo "Nginx not found"

echo "[INFO] Remote environment preparation complete."
REMOTE_CMDS

if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    log_error "Step 5 failed during remote execution."
    return 1
else
    log_info "Step 5 complete. Remote environment is ready. Versions logged to $LOG_FILE"
fi

# -------------------------------
# Step 6: Deploy the Dockerized Application
# -------------------------------
log_info "Starting Step 6: Deploy the Dockerized Application..."

# (a) Transfer project files to remote server
log_info "Transferring project files to remote server..."
rsync -avz --exclude '.git' --exclude '__pycache__' ./ \
    -e "ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10" \
    "$SSH_USER@$SERVER_IP:~/myproject" | tee -a "$LOG_FILE"

if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    log_error "File transfer failed."
    exit 21
fi

# (b–e) Build and run containers, validate, confirm accessibility
ssh -i "$SSH_KEY_PATH" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    "$SSH_USER@$SERVER_IP" bash -s <<'REMOTE_CMDS' | tee -a "$LOG_FILE"
set -e

cd ~/myproject

echo "[INFO] Building Docker image..."
docker build -t myproject:latest .

# Stop and remove any existing container with the same name
if [ "$(docker ps -aq -f name=myproject_container)" ]; then
    echo "[INFO] Removing existing container..."
    docker rm -f myproject_container || true
fi

echo "[INFO] Running Docker container..."
docker run -d --name myproject_container -p 5000:5000 myproject:latest

echo "[INFO] Validating container status..."
docker ps --filter "name=myproject_container"

echo "[INFO] Checking container logs (last 20 lines)..."
docker logs --tail=20 myproject_container || true

echo "[INFO] Inspecting running processes inside container..."
docker top myproject_container || true

echo "[INFO] Waiting 5 seconds for app startup..."
sleep 5

echo "[INFO] Confirming app accessibility on port 5000 (from host)..."
if curl -fs http://localhost:5000/ >/dev/null; then
    echo "[INFO] Application responded successfully on port 5000."
else
    echo "[WARN] Application did not respond on port 5000."
fi

echo "[INFO] Step 6 remote deployment complete."
REMOTE_CMDS

if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    log_error "Step 6 failed during remote deployment."
    exit 22
else
    log_info "Step 6 SUCCESS. Application deployed and accessible on http://$SERVER_IP:5000"
fi

# -------------------------------
# Step 7: Configure Nginx as a Reverse Proxy
# -------------------------------
log_info "Starting Step 7: Configure Nginx as a Reverse Proxy..."

ssh -i "$SSH_KEY_PATH" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    "$SSH_USER@$SERVER_IP" bash -s <<'REMOTE_CMDS' | tee -a "$LOG_FILE"
set -e

NGINX_CONF="/etc/nginx/sites-available/myproject"
NGINX_LINK="/etc/nginx/sites-enabled/myproject"

echo "[INFO] Cleaning up any bad configs..."
# Remove if it's a directory or wrong type
if [ -d "\$NGINX_CONF" ]; then
    sudo rm -rf "\$NGINX_CONF"
fi
if [ -d "\$NGINX_LINK" ]; then
    sudo rm -rf "\$NGINX_LINK"
fi

# Remove old symlink if it exists
if [ -L "\$NGINX_LINK" ]; then
    sudo rm -f "\$NGINX_LINK"
fi

echo "[INFO] Writing fresh Nginx config to \$NGINX_CONF..."
sudo tee "\$NGINX_CONF" > /dev/null <<'EOF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # SSL placeholder
    # listen 443 ssl;
    # ssl_certificate /etc/letsencrypt/live/yourdomain/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/yourdomain/privkey.pem;
}
EOF

echo "[INFO] Creating symlink in sites-enabled..."
sudo ln -s "\$NGINX_CONF" "\$NGINX_LINK"

# Remove default config if present
if [ -f /etc/nginx/sites-enabled/default ]; then
    sudo rm /etc/nginx/sites-enabled/default
    echo "[INFO] Removed default Nginx site."
fi

echo "[INFO] Testing Nginx configuration..."
sudo nginx -t

echo "[INFO] Reloading Nginx..."
sudo systemctl reload nginx

echo "[INFO] Nginx reverse proxy configured successfully."
REMOTE_CMDS

if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    log_error "Step 7 failed during Nginx configuration."
    exit 23
else
    log_info "Step 7 SUCCESS. App should now be accessible at http://$SERVER_IP/"
    log_info "SSL placeholders are in place — ready for Certbot or self-signed certs."
fi

# -------------------------------
# Step 8: Validate Deployment
# -------------------------------
log_info "Starting Step 8: Validate Deployment..."

ssh -i "$SSH_KEY_PATH" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    "$SSH_USER@$SERVER_IP" bash -s <<'REMOTE_CMDS' | tee -a "$LOG_FILE"
set -e

echo "[INFO] (Local-to-Server) Checking Docker service status..."
if systemctl is-active --quiet docker; then
    echo "[INFO] Docker service is running."
else
    echo "[ERROR] Docker service is NOT running."
    exit 31
fi

echo "[INFO] (Local-to-Server) Checking target container health..."
if docker ps --filter "name=myproject_container" --filter "status=running" | grep -q myproject_container; then
    echo "[INFO] Container 'myproject_container' is active and running."
else
    echo "[ERROR] Container 'myproject_container' is not running."
    exit 32
fi

echo "[INFO] (Local-to-Server) Checking Nginx service status..."
if systemctl is-active --quiet nginx; then
    echo "[INFO] Nginx service is running."
else
    echo "[ERROR] Nginx service is NOT running."
    exit 33
fi

echo "[INFO] (Local-to-Server) Testing Nginx proxy from inside the server..."
if curl -fs http://localhost/ >/dev/null; then
    echo "[INFO] Local proxy test succeeded (server can reach app via Nginx)."
else
    echo "[ERROR] Local proxy test failed (Nginx not serving app internally)."
    exit 34
fi

echo "[INFO] Step 8 local (on-server) validation complete."
REMOTE_CMDS

if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    log_error "Step 8 failed during on-server validation."
    exit 35
else
    log_info "Step 8 SUCCESS (on-server). Proceeding to remote validation..."
fi

# (d) Remote test from your WSL host
echo "[INFO] (Remote-from-WSL) Testing endpoint from outside the server..."
if curl -fs "http://$SERVER_IP/" >/dev/null; then
    log_info "Remote test succeeded: Application accessible at http://$SERVER_IP/"
else
    log_error "Remote test failed: Application not accessible from outside."
    exit 36
fi