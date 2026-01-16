#!/usr/bin/env bash

# Proxmox Host Script for Alpine BentoPDF
# Run this on your Proxmox VE Host

set -e

# Configuration
TEMPLATE_STORAGE="local"
TEMPLATE="alpine" # Will be dynamically resolved
CT_ID=""
CT_NAME="alpine-bentopdf"
CT_PASSWORD="ChangeMe123!" # Temporary password
DISK_SIZE="4G"
RAM_SIZE="2048"
CORES="2"
BRIDGE="vmbr0"
IP="dhcp"

# Colors
green=$(tput setaf 2)
red=$(tput setaf 1)
reset=$(tput sgr0)

msg_info() { echo -e "${green}[INFO] $1${reset}"; }
msg_err() { echo -e "${red}[ERROR] $1${reset}"; }

# Check for root
if [ "$(id -u)" -ne 0 ]; then
  msg_err "This script must be run as root"
  exit 1
fi

# Input Prompts
read -p "Enter Container ID (e.g., 105): " CT_ID
if [ -z "$CT_ID" ]; then msg_err "ID is required"; exit 1; fi

if pct status $CT_ID >/dev/null 2>&1; then
   msg_err "Container $CT_ID already exists!"
   exit 1
fi

read -p "Enter Container Name [alpine-bentopdf]: " input_name
CT_NAME=${input_name:-$CT_NAME}

read -p "Enter RAM (MB) [2048]: " input_ram
RAM_SIZE=${input_ram:-$RAM_SIZE}

read -p "Enter Cores [2]: " input_cores
CORES=${input_cores:-$CORES}

read -p "Enter Disk Size (GB) [4]: " input_disk
DISK_SIZE=${input_disk:-$DISK_SIZE}

read -p "Enter Storage Pool [local-lvm]: " input_storage
STORAGE_POOL=${input_storage:-"local-lvm"}

# Verify Template (Simplification: assuming user has a template or we download one)
# Ideally, we should check `pveam available` and download if missing.
# For now, we'll try to use a generic alpine template command or specific one.
# An easier way is to just use 'alpine-3.19-default' (latest usually) if available/cached
# or let pct handle download if configured.
# We will use "system" storage for template by default.
TEMPLATE_SEARCH=$(pveam available | grep alpine | sort -V | tail -n 1 | awk '{print $2}')
if [ -z "$TEMPLATE_SEARCH" ]; then
    msg_info "No Alpine template found in available list. Assuming local cache or manual setup."
else
    # Auto-download latest alpine if not present
    if ! pveam list local | grep -q "alpine"; then
       msg_info "Downloading Alpine template: $TEMPLATE_SEARCH"
       pveam download local "$TEMPLATE_SEARCH"
       TEMPLATE="$TEMPLATE_SEARCH"
    else
       TEMPLATE=$(pveam list local | grep alpine | tail -n 1 | awk '{print $2}')
    fi
fi

msg_info "Creating LXC Container $CT_ID ($CT_NAME)..."
pct create $CT_ID /var/lib/vz/template/cache/$TEMPLATE \
    --hostname $CT_NAME \
    --features nesting=1 \
    --memory $RAM_SIZE \
    --cores $CORES \
    --net0 name=eth0,bridge=$BRIDGE,ip=$IP \
    --rootfs $STORAGE_POOL:$DISK_SIZE \
    --password $CT_PASSWORD \
    --unprivileged 1 \
    --start 1

msg_info "Waiting for container to start..."
until pct status $CT_ID | grep -q "status: running"; do
  sleep 1
done
sleep 5 # Give it a moment to initialize network

msg_info "Setting up Alpine Guest..."

# Allow non-interactive commands
pct exec $CT_ID -- ash -c "apk update && apk add bash curl"

# Fetch and Push the Install Script
# We need to get the install script into the container.
# Since we are creating this from a gist or artifacts, we'll write it to a temp file then push.

INSTALL_SCRIPT_LOCAL="/tmp/alpine-bentopdf-install.sh"
cat << 'EOF' > "$INSTALL_SCRIPT_LOCAL"
#!/usr/bin/env bash
# Alpine BentoPDF Install Script
set -e
APP="BentoPDF"
REPO_URL="https://github.com/nickdesi/bentopdf.git"
INSTALL_DIR="/opt/bentopdf"
PORT=8080
green=$(tput setaf 2); red=$(tput setaf 1); reset=$(tput sgr0)
msg_ok() { echo -e "${green}✔ $1${reset}"; }
echo "Updating Alpine..."
apk update && apk upgrade || true
echo "Installing Dependencies..."
apk add --no-cache bash curl git nodejs npm make g++ python3
echo "Setting up $APP..."
[ -d "$INSTALL_DIR" ] && rm -rf "$INSTALL_DIR"
echo "Cloning repository from $REPO_URL..."
git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
cd "$INSTALL_DIR"
echo "Installing npm dependencies..."
if [ -f "package-lock.json" ]; then npm ci --no-audit --no-fund || npm install --no-audit --no-fund; else npm install --no-audit --no-fund; fi
echo "Building $APP..."
export SIMPLE_MODE=true
npm run build -- --mode production
echo "Creating Service..."
cat > /etc/init.d/bentopdf <<SERV
#!/sbin/openrc-run
description="BentoPDF Service"
pidfile="/run/bentopdf.pid"
command="/usr/bin/npx"
command_args="serve dist -p $PORT"
command_background=true
directory="$INSTALL_DIR"
user="root"
depend() { need net; after firewall; }
SERV
chmod +x /etc/init.d/bentopdf
echo "Starting Service..."
rc-update add bentopdf default
rc-service bentopdf start

# Create Update Script
cat > /usr/bin/update << 'UPDATESCRIPT'
#!/usr/bin/env bash
set -e
APP="BentoPDF"
INSTALL_DIR="/opt/bentopdf"
green=$(tput setaf 2); red=$(tput setaf 1); yellow=$(tput setaf 3); reset=$(tput sgr0)

msg_info() { echo -e "${yellow}ℹ $1${reset}"; }
msg_ok() { echo -e "${green}✔ $1${reset}"; }

echo "Updating Alpine OS..."
apk update && apk upgrade

echo "Checking for $APP updates..."
cd "$INSTALL_DIR"
git fetch

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse @{u})

if [ "$LOCAL" != "$REMOTE" ]; then
    msg_info "Update available for $APP."
    msg_info "Pulling latest changes..."
    git pull
    
    msg_info "Installing dependencies..."
    if [ -f "package-lock.json" ]; then
        npm ci --no-audit --no-fund || npm install --no-audit --no-fund
    else
        npm install --no-audit --no-fund
    fi

    msg_info "Building application..."
    export SIMPLE_MODE=true
    npm run build -- --mode production

    msg_info "Restarting service..."
    rc-service bentopdf restart
    msg_ok "$APP updated successfully!"
else
    msg_ok "$APP is already up to date."
fi
UPDATESCRIPT
chmod +x /usr/bin/update

msg_ok "$APP installed. IP: $(hostname -i)"
EOF

msg_info "Pushing installation script to container..."
pct push $CT_ID "$INSTALL_SCRIPT_LOCAL" "/root/install.sh"
pct exec $CT_ID -- chmod +x /root/install.sh

msg_info "Running installation script inside container..."
pct exec $CT_ID -- bash /root/install.sh

msg_info "Cleanup..."
pct exec $CT_ID -- rm /root/install.sh
rm "$INSTALL_SCRIPT_LOCAL"

msg_info "Installation Complete!"
CT_IP=$(pct exec $CT_ID -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo -e "${green}BentoPDF should be reachable at http://${CT_IP}:8080${reset}"
