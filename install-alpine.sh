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
DISK_SIZE="4"
RAM_SIZE="2048"
CORES="2"
BRIDGE="vmbr0"
IP="dhcp"
STORAGE_POOL="local-lvm"

# Colors
green=$(tput setaf 2)
red=$(tput setaf 1)
yellow=$(tput setaf 3)
reset=$(tput sgr0)

msg_info() { echo -e "${green}[INFO] $1${reset}"; }
msg_err() { echo -e "${red}[ERROR] $1${reset}"; }

# Check for root
if [ "$(id -u)" -ne 0 ]; then
  msg_err "This script must be run as root"
  exit 1
fi

# Check for whiptail
if ! command -v whiptail &> /dev/null; then
    msg_err "Whiptail is required but not installed. Please install it (apt install whiptail) or use the legacy script."
    exit 1
fi

# --- function to show menu ---
function selection_menu() {
    # Find next available CT ID
    NEXTID=$(pvesh get /cluster/nextid)
    
    # Get Storage Pools
    raw_storage=$(pvesm status -content rootdir | awk 'NR>1 {print $1}')
    if [ -z "$raw_storage" ]; then
        raw_storage="local-lvm"
    fi
    STORAGE_MENU_ARGS=()
    while read -r line; do
        STORAGE_MENU_ARGS+=("$line" "Storage Pool")
    done <<< "$raw_storage"

    # Dialogs
    CT_ID=$(whiptail --inputbox "Enter Container ID" 8 78 "$NEXTID" --title "Container ID" 3>&1 1>&2 2>&3)
    [ -z "$CT_ID" ] && exit 1

    if pct status $CT_ID >/dev/null 2>&1; then
       whiptail --msgbox "Container $CT_ID already exists!" 8 78
       exit 1
    fi

    CT_NAME=$(whiptail --inputbox "Enter Container Name" 8 78 "$CT_NAME" --title "Container Name" 3>&1 1>&2 2>&3)
    [ -z "$CT_NAME" ] && exit 1

    CORES=$(whiptail --inputbox "Enter CPU Cores" 8 78 "$CORES" --title "CPU Allocation" 3>&1 1>&2 2>&3)
    [ -z "$CORES" ] && exit 1

    RAM_SIZE=$(whiptail --inputbox "Enter RAM (MB)" 8 78 "$RAM_SIZE" --title "Memory Allocation" 3>&1 1>&2 2>&3)
    [ -z "$RAM_SIZE" ] && exit 1

    DISK_SIZE=$(whiptail --inputbox "Enter Disk Size (GB)" 8 78 "$DISK_SIZE" --title "Disk Allocation" 3>&1 1>&2 2>&3)
    [ -z "$DISK_SIZE" ] && exit 1

    if [ ${#STORAGE_MENU_ARGS[@]} -eq 2 ]; then
        STORAGE_POOL=${STORAGE_MENU_ARGS[0]}
    else
        STORAGE_POOL=$(whiptail --menu "Select Storage Pool" 15 60 4 "${STORAGE_MENU_ARGS[@]}" --title "Storage Selection" 3>&1 1>&2 2>&3)
    fi
    [ -z "$STORAGE_POOL" ] && exit 1
}

# Run Menu
selection_menu

# Confirmation
if ! whiptail --yesno "Ready to create container?\n\nID: $CT_ID\nName: $CT_NAME\nCores: $CORES\nRAM: $RAM_SIZE MB\nDisk: $DISK_SIZE GB\nStorage: $STORAGE_POOL" 15 60; then
    exit 0
fi

clear

# Verify Template
TEMPLATE_SEARCH=$(pveam available | grep alpine | sort -V | tail -n 1 | awk '{print $2}')
if [ -z "$TEMPLATE_SEARCH" ]; then
    msg_info "No Alpine template found. Assuming local cache or manual setup."
else
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
sleep 5

msg_info "Setting up Alpine Guest..."
pct exec $CT_ID -- ash -c "apk update && apk add bash curl"

INSTALL_SCRIPT_LOCAL="/tmp/alpine-bentopdf-install.sh"
cat << 'EOF' > "$INSTALL_SCRIPT_LOCAL"
#!/usr/bin/env bash
set -e
APP="BentoPDF"
REPO_URL="https://github.com/nickdesi/bentopdf.git"
INSTALL_DIR="/opt/bentopdf"
PORT=8080
green=$(tput setaf 2); red=$(tput setaf 1); yellow=$(tput setaf 3); reset=$(tput sgr0)
msg_ok() { echo -e "${green}✔ $1${reset}"; }
msg_info() { echo -e "${yellow}ℹ $1${reset}"; }

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
whiptail --msgbox "$APP installed successfully!\n\nAccess it at: http://${CT_IP}:8080\n\nRun 'update' inside the container to update." 10 60
