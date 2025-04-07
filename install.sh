#!/bin/bash

# WireGuard Connection Logger Installer

# --- Configuration (Match these with your repo structure and script defaults) ---
SCRIPT_SOURCE="wg_connection_logger.sh"
SERVICE_SOURCE="wg-connection-logger.service"
TIMER_SOURCE="wg-connection-logger.timer"
LOGROTATE_SOURCE="wireguard-connections.logrotate" # Use a distinct name for the source file
JSON_MAP_SOURCE="ipaddr-map.json" # Assumes user prepared this file in the repo root

SCRIPT_DEST="/usr/local/sbin/wg_connection_logger.sh"
SERVICE_DEST="/etc/systemd/system/wg-connection-logger.service"
TIMER_DEST="/etc/systemd/system/wg-connection-logger.timer"
LOGROTATE_DEST="/etc/logrotate.d/wireguard-connections" # Destination name might differ
JSON_MAP_DEST_DIR="/root/script"
JSON_MAP_DEST_FILE="${JSON_MAP_DEST_DIR}/ipaddr-map.json"
STATE_FILE_DIR="/var/run" # Or /var/lib/wg-logger if using persistent state

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
    echo "Warning: 'jq' command not found. This is required for JSON peer name mapping." >&2
    read -p "Attempt to install jq now? (y/N): " install_jq
    if [[ "$install_jq" =~ ^[Yy]$ ]]; then
        echo "Installing jq..."
        if apt update && apt install -y jq; then
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

# Ensure source files exist
if [ ! -f "$SCRIPT_SOURCE" ]; then echo "Error: Source file '$SCRIPT_SOURCE' not found in current directory." >&2; exit 1; fi
if [ ! -f "$SERVICE_SOURCE" ]; then echo "Error: Source file '$SERVICE_SOURCE' not found." >&2; exit 1; fi
if [ ! -f "$TIMER_SOURCE" ]; then echo "Error: Source file '$TIMER_SOURCE' not found." >&2; exit 1; fi
if [ ! -f "$LOGROTATE_SOURCE" ]; then echo "Error: Source file '$LOGROTATE_SOURCE' not found." >&2; exit 1; fi
if [ ! -f "$JSON_MAP_SOURCE" ]; then echo "Error: Source file '$JSON_MAP_SOURCE' not found. Did you create/rename it from the example?" >&2; exit 1; fi

# Copy files
echo "  Copying $SCRIPT_SOURCE to $SCRIPT_DEST..."
cp "$SCRIPT_SOURCE" "$SCRIPT_DEST"

echo "  Copying $SERVICE_SOURCE to $SERVICE_DEST..."
cp "$SERVICE_SOURCE" "$SERVICE_DEST"

echo "  Copying $TIMER_SOURCE to $TIMER_DEST..."
cp "$TIMER_SOURCE" "$TIMER_DEST"

echo "  Copying $LOGROTATE_SOURCE to $LOGROTATE_DEST..."
cp "$LOGROTATE_SOURCE" "$LOGROTATE_DEST"

echo "  Creating directory $JSON_MAP_DEST_DIR if it doesn't exist..."
mkdir -p "$JSON_MAP_DEST_DIR"

echo "  Copying $JSON_MAP_SOURCE to $JSON_MAP_DEST_FILE..."
cp "$JSON_MAP_SOURCE" "$JSON_MAP_DEST_FILE"

echo "  Creating state directory $STATE_FILE_DIR if needed (relevant if using persistent state)..."
mkdir -p "$STATE_FILE_DIR" # For /var/lib/wg-logger mainly

echo "Files copied."

# --- Set Permissions ---
echo "Setting permissions..."

chmod +x "$SCRIPT_DEST"
echo "  [✓] $SCRIPT_DEST executable."

chmod 644 "$SERVICE_DEST"
chmod 644 "$TIMER_DEST"
chmod 644 "$LOGROTATE_DEST"
echo "  [✓] Systemd units and logrotate config readable."

# Set secure permissions for the JSON map - only root needs to read it usually
chmod 600 "$JSON_MAP_DEST_FILE"
echo "  [✓] JSON map file permissions set (readable by root only)."

echo "Permissions set."

# --- Systemd Configuration ---
echo "Configuring systemd services..."

echo "  Reloading systemd daemon..."
systemctl daemon-reload

echo "  Enabling the timer..."
systemctl enable wg-connection-logger.timer

echo "  Starting the timer..."
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
echo "Logs will be written to /var/log/wireguard-connections.log (or syslog if configured)."
echo "Check service status with: sudo systemctl status wg-connection-logger.timer"
echo "Remember to configure the script variables in $SCRIPT_DEST if defaults need changing."
echo ""

exit 0
