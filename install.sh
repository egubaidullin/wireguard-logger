#!/bin/bash

# WireGuard Connection Logger Installer
# Assumes ipaddr-map.json is managed externally in JSON_MAP_DEST_FILE

# --- Configuration (Match these with your repo structure and script defaults) ---
SCRIPT_SOURCE="wg_connection_logger.sh"
SERVICE_SOURCE="wg-connection-logger.service"
TIMER_SOURCE="wg-connection-logger.timer"
LOGROTATE_SOURCE="wireguard-connections.logrotate"

SCRIPT_DEST="/usr/local/sbin/wg_connection_logger.sh"
SERVICE_DEST="/etc/systemd/system/wg-connection-logger.service"
TIMER_DEST="/etc/systemd/system/wg-connection-logger.timer"
LOGROTATE_DEST="/etc/logrotate.d/wireguard-connections"

# Destination path for the externally managed JSON map file
JSON_MAP_DEST_DIR="/root/script"
JSON_MAP_DEST_FILE="${JSON_MAP_DEST_DIR}/ipaddr-map.json"

# Determine state file directory from logger script if possible, else default
STATE_FILE_DIR=$(grep -oP 'STATE_FILE=\K"[^"]+"' "$SCRIPT_SOURCE" 2>/dev/null | xargs dirname || echo "/var/run")

# --- Safety Checks ---
set -e # Exit immediately if a command exits with a non-zero status.

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
  echo "Error: This script must be run as root. Please use sudo." >&2
  exit 1
fi

echo "Starting WireGuard Connection Logger Installation..."

# --- Dependency Checks ---
echo "Checking dependencies..."

if ! command -v wg &> /dev/null; then
    echo "Error: 'wg' command not found. Please install wireguard-tools (e.g., 'sudo apt install wireguard-tools')." >&2
    exit 1
fi
echo "  [✓] wg command found."

if ! command -v jq &> /dev/null; then
    echo "Warning: 'jq' command not found. This is required for the logger script to function correctly." >&2
    read -p "Attempt to install jq now? (y/N): " install_jq
    if [[ "$install_jq" =~ ^[Yy]$ ]]; then
        echo "Installing jq..."
        if apt-get update && apt-get install -y jq; then
            echo "jq installed successfully."
        else
            echo "Error: Failed to install jq. Please install it manually ('sudo apt install jq') and rerun this script." >&2
            exit 1
        fi
    else
        echo "Error: jq is required. Please install it manually ('sudo apt install jq') and rerun this script." >&2
        exit 1
    fi
fi
echo "  [✓] jq command found."

if ! command -v systemctl &> /dev/null; then
    echo "Error: 'systemctl' command not found. This script requires a systemd-based OS." >&2
    exit 1
fi
echo "  [✓] systemd found."

echo "Dependencies met."

# --- File Installation ---
echo "Installing files..."

# Ensure source files exist in the repository directory
if [ ! -f "$SCRIPT_SOURCE" ]; then echo "Error: Source file '$SCRIPT_SOURCE' not found in current directory." >&2; exit 1; fi
if [ ! -f "$SERVICE_SOURCE" ]; then echo "Error: Source file '$SERVICE_SOURCE' not found." >&2; exit 1; fi
if [ ! -f "$TIMER_SOURCE" ]; then echo "Error: Source file '$TIMER_SOURCE' not found." >&2; exit 1; fi
if [ ! -f "$LOGROTATE_SOURCE" ]; then echo "Error: Source file '$LOGROTATE_SOURCE' not found." >&2; exit 1; fi

# Copy essential files
echo "  Copying $SCRIPT_SOURCE to $SCRIPT_DEST..."
cp "$SCRIPT_SOURCE" "$SCRIPT_DEST"

echo "  Copying $SERVICE_SOURCE to $SERVICE_DEST..."
cp "$SERVICE_SOURCE" "$SERVICE_DEST"

echo "  Copying $TIMER_SOURCE to $TIMER_DEST..."
cp "$TIMER_SOURCE" "$TIMER_DEST"

echo "  Copying $LOGROTATE_SOURCE to $LOGROTATE_DEST..."
cp "$LOGROTATE_SOURCE" "$LOGROTATE_DEST"

# Ensure target directories exist
echo "  Ensuring directory $JSON_MAP_DEST_DIR exists..."
mkdir -p "$JSON_MAP_DEST_DIR"

echo "  Ensuring state directory $STATE_FILE_DIR exists..."
mkdir -p "$STATE_FILE_DIR"

echo "Essential files copied."

# --- Check for Externally Managed Peer Map ---
echo "Checking for peer map file..."
if [ -f "$JSON_MAP_DEST_FILE" ]; then
    echo "  [✓] Found existing peer map file: $JSON_MAP_DEST_FILE"
    # Set secure permissions just in case they were wrong
    chmod 600 "$JSON_MAP_DEST_FILE"
    echo "      Permissions set to 600 (root read-only)."
else
    echo "  [!] WARNING: Peer map file not found at expected location: $JSON_MAP_DEST_FILE"
    echo "      The logger script requires this file to resolve peer names."
    echo "      Please ensure it is generated (e.g., by adding/managing users with wireguard_managing scripts)."
fi

# --- Set Permissions ---
echo "Setting permissions for installed files..."

chmod +x "$SCRIPT_DEST"
echo "  [✓] $SCRIPT_DEST executable."

chmod 644 "$SERVICE_DEST"
chmod 644 "$TIMER_DEST"
chmod 644 "$LOGROTATE_DEST"
echo "  [✓] Systemd units and logrotate config readable."

echo "Permissions set."

# --- Systemd Configuration ---
echo "Configuring systemd services..."

echo "  Reloading systemd daemon..."
systemctl daemon-reload

echo "  Enabling the timer..."
systemctl enable wg-connection-logger.timer

echo "  Starting the timer..."
# Stop first in case it was already running with old units
systemctl stop wg-connection-logger.timer >/dev/null 2>&1 || true
systemctl stop wg-connection-logger.service >/dev/null 2>&1 || true
# Now start the timer, which will activate the service
systemctl start wg-connection-logger.timer

echo "Systemd configuration complete."

# --- Final Check ---
echo "Verifying timer status (may take a moment to activate)..."
sleep 2 # Give systemd a moment
systemctl status wg-connection-logger.timer --no-pager

echo ""
echo "-----------------------------------------------------"
echo " WireGuard Connection Logger installation complete! "
echo "-----------------------------------------------------"
echo ""
if [ ! -f "$JSON_MAP_DEST_FILE" ]; then
    echo "--> REMINDER: The peer map file ($JSON_MAP_DEST_FILE) was not found."
    echo "    Peer names will appear as 'Unknown' in logs until the file is generated."
fi
echo "Logs will be written to /var/log/wireguard-connections.log (or syslog if configured)."
echo "Check service status with: sudo systemctl status wg-connection-logger.timer"
echo "Configure the logger script via: sudo nano $SCRIPT_DEST"
echo ""

exit 0
