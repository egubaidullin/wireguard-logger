# WireGuard Connection Logger

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Log WireGuard peer connection and disconnection events on Ubuntu using standard system tools, and generate summarized session reports. This project polls `wg show` periodically, compares state, logs events (timestamp, IP, public key, resolved name), and provides a Python script to analyze these logs into user sessions.

*Note: This logger was developed alongside and is compatible with setups managed by [egubaidullin/wireguard_managing](https://github.com/egubaidullin/wireguard_managing), particularly regarding the expected `ipaddr-map.json` format.*

## Features

*   **Event Logging:**
    *   Logs peer connection (`CONNECT`) and disconnection (`DISCONNECT`) events.
    *   Detects reconnections or IP changes (`RECONNECT/UPDATE`).
    *   Resolves peer public keys to human-readable names using a configurable JSON map file.
    *   Logs include: Timestamp (ISO 8601), Event Type, Peer Name, Peer Public Key, Peer Endpoint IP.
    *   Uses `systemd` timers for periodic execution.
    *   Integrates with `logrotate` for automatic log management.
    *   Low resource usage, relies on standard Linux utilities (`bash`, `wg`, `jq`, `systemd`).
    *   Provides an `install.sh` script for easy setup of the logger component.
*   **Session Reporting (`generate_wg_report.py`):**
    *   Parses the generated text log files (including rotated/compressed ones).
    *   Calculates continuous connection sessions for each user.
    *   Filters reports by user (`PeerName` or `all`) and date range.
    *   Merges consecutive connection events into single sessions.
    *   Outputs a summary report in CSV format.
    *   Columns include: `PeerName`, `SessionStart`, `SessionEnd`, `Duration (HH:MM:SS)`, `EndpointIP` (at session start).

## Requirements

*   **OS:** Ubuntu (tested on 20.04/22.04, should work on similar systemd-based distributions).
*   **WireGuard:** WireGuard must be installed and configured (`wg-tools` package).
*   **jq:** The command-line JSON processor is required *by the logger script* (`jq` package).
*   **Python 3:** Required for the session reporting script (`generate_wg_report.py`). Standard library modules are used primarily.
*   **Systemd:** Used for running the logger script periodically.
*   **Logrotate:** Used for managing log files.
*   **Root privileges:** Required for installation (`install.sh`), running the `wg` command (by the logger), and potentially for reading logs and the peer map (by the reporter).

## Installation (Logger Component)

1.  **Clone the Repository:**
    ```bash
    git clone https://github.com/egubaidullin/wireguard-logger.git
    cd wireguard-logger
    ```

2.  **Prepare the Peer Map File (`ipaddr-map.json`):**
    *   This tool uses a JSON file to map WireGuard public keys to user-friendly names. It's essential for both the logger and the reporter.
    *   Edit the included `ipaddr-map.json.example` file:
        *   Rename it to `ipaddr-map.json`.
        *   Populate it with your client names as top-level keys and their corresponding `publicKey` values. The structure should align with the one used by `egubaidullin/wireguard_managing`:
          ```json
          {
              "ClientAlias1": {
                  "publicKey": "PublicKeyString1=",
                  "privateKey": "(optional, not used by logger/reporter)",
                  "presharedKey": "(optional, not used by logger/reporter)",
                  "address": "(optional, not used by logger/reporter)"
              },
              "AnotherClient": {
                  "publicKey": "PublicKeyString2=",
                  "...": "..."
              }
          }
          ```
    *   Ensure the `publicKey` values exactly match those in your WireGuard configuration and the output of `wg show`.
    *   The installer (`install.sh`) will copy this `ipaddr-map.json` file to `/root/script/ipaddr-map.json` by default.

3.  **Run the Installer (`install.sh`):**
    *   This script installs the *logger component only* (the background script, systemd units, logrotate config).
    *   Make sure the installer script is executable: `chmod +x install.sh`
    *   Run the installer with root privileges:
        ```bash
        sudo ./install.sh
        ```
    *   The script will:
        *   Check for dependencies (`jq`, `wg`).
        *   Copy necessary files (`wg_connection_logger.sh`, systemd units, logrotate config, `ipaddr-map.json`).
        *   Set file permissions.
        *   Reload systemd, enable and start the timer service.

## Configuration (Logger Component)

While the installer sets up defaults, you might want to adjust some settings:

*   **Logger Script (`/usr/local/sbin/wg_connection_logger.sh`):**
    *   `WG_INTERFACE`: Name of your WireGuard interface (default: `wg0`).
    *   `PEER_MAP_JSON_FILE`: Path to the JSON peer map (default: `/root/script/ipaddr-map.json`).
    *   `LOG_FILE`: Path to the output log file (default: `/var/log/wireguard-connections.log`).
    *   `STATE_FILE`: Path to store connection state between runs (default: `/var/run/wg_connection_logger.state`). Consider `/var/lib/wg-logger/` for persistence across reboots if `/var/run` is temporary.
    *   `HANDSHAKE_TIMEOUT`: Seconds of inactivity before a peer is considered disconnected (default: `180`).
    *   `POLL_INTERVAL`: How often the script checks `wg show` (default: `60`).
    *   `USE_SYSLOG`: Set to `true` to log via `logger` to syslog/journald (default: `false`).
    *   `DEBUG_MODE`: Set to `true` for verbose debugging output (default: `false`).

*   **Systemd Timer (`/etc/systemd/system/wg-connection-logger.timer`):**
    *   `OnUnitActiveSec`: Adjust how often the logger script runs (e.g., `30s`, `1min`). Remember to `sudo systemctl daemon-reload` and `sudo systemctl restart wg-connection-logger.timer` after changing.

*   **Log Rotation (`/etc/logrotate.d/wireguard-connections`):**
    *   Modify this file to change log rotation frequency, retention, etc.

## Usage

### Viewing Logs

*   **Live Event Logs:**
    ```bash
    sudo tail -f /var/log/wireguard-connections.log
    ```
    *   If using syslog (`USE_SYSLOG=true`):
        ```bash
        sudo journalctl -f -t wg-logger
        ```

*   **Check Logger Service Status:**
    ```bash
    sudo systemctl status wg-connection-logger.timer
    sudo systemctl status wg-connection-logger.service
    ```

*   **Querying Raw Logs:**
    *   Use standard tools like `grep`, `awk`, `sort`, `zgrep`.
    *   Consider `lnav` for interactive analysis: `sudo lnav /var/log/wireguard-connections.log*`

### Generating Session Reports

Use the `generate_wg_report.py` script (requires Python 3). Ensure it's executable: `chmod +x generate_wg_report.py`. Run with `sudo` if needed to access logs/map file.

*   **Generate report for a specific user for the last 3 days (default):**
    ```bash
    sudo ./generate_wg_report.py --user 'SpecificClientName' --output report_user_last3d.csv
    ```

*   **Generate report for ALL users for a specific date range:**
    ```bash
    sudo ./generate_wg_report.py --user all --start-date 2025-04-01 --end-date 2025-04-10 --output report_all_apr1-10.csv
    ```

*   **Specify map file path, log directory, or default days:**
    ```bash
    sudo ./generate_wg_report.py --user all --days 7 --map-file /etc/wireguard/peer_map.json --log-dir /mnt/wg_logs --output report_custom.csv
    ```

*   **See all options:**
    ```bash
    ./generate_wg_report.py --help
    ```

## Troubleshooting

*   **Logger Not Running:** Check `systemctl status` and `journalctl -u wg-connection-logger.service`.
*   **"jq: command not found" / "wg: command not found":** Install dependencies (`sudo apt install jq wireguard-tools`).
*   **Logger: Peer Names 'Unknown':** Check `jq` installed, `PEER_MAP_JSON_FILE` path/permissions/content, exact key matching, enable `DEBUG_MODE` in the logger script.
*   **Reporter: Peer Names 'Unknown':** Verify the `--map-file` path passed to the script (or the default `/root/script/ipaddr-map.json`), check its permissions and JSON validity. Ensure keys in the map match those in the logs.
*   **Reporter: "No log entries found" / "No sessions":** Check `--log-dir`, `--log-prefix`, date range, and user filter. Ensure logs actually exist for the period. Check file permissions in the log directory.
*   **Permission Errors:** Ensure scripts are executable (`chmod +x`) and run with sufficient privileges (`sudo`) to access `wg show`, log files, and the map file.

## Uninstallation (Logger Component)

The `install.sh` script installs the background logger. The reporting script is used manually. To remove the installed logger:

1.  **Stop and Disable Systemd Units:**
    ```bash
    sudo systemctl stop wg-connection-logger.timer
    sudo systemctl disable wg-connection-logger.timer
    sudo systemctl stop wg-connection-logger.service
    ```

2.  **Remove Files Installed by `install.sh`:**
    ```bash
    # Determine installed map file path from the logger script if unsure
    INSTALLED_MAP_FILE=$(grep -oP 'PEER_MAP_JSON_FILE=\K"[^"]+"' /usr/local/sbin/wg_connection_logger.sh | tr -d '"')
    INSTALLED_STATE_FILE=$(grep -oP 'STATE_FILE=\K"[^"]+"' /usr/local/sbin/wg_connection_logger.sh | tr -d '"')
    
    echo "Removing installed files..."
    sudo rm -f /usr/local/sbin/wg_connection_logger.sh
    sudo rm -f /etc/systemd/system/wg-connection-logger.service
    sudo rm -f /etc/systemd/system/wg-connection-logger.timer
    sudo rm -f /etc/logrotate.d/wireguard-connections
    sudo rm -f "${INSTALLED_MAP_FILE:-/root/script/ipaddr-map.json}" # Remove installed map
    sudo rm -f "${INSTALLED_STATE_FILE:-/var/run/wg_connection_logger.state}" # Remove state file
    
    echo "Files removed (check output for errors)."
    echo "NOTE: Log files in /var/log/wireguard-connections.log* have NOT been removed."
    read -p "Do you want to remove the log files as well? [y/N]: " remove_logs
    if [[ "$remove_logs" =~ ^[Yy]$ ]]; then
        echo "Removing log files..."
        sudo rm -vf /var/log/wireguard-connections.log*
    fi
    ```

3.  **Reload Systemd:**
    ```bash
    sudo systemctl daemon-reload
    sudo systemctl reset-failed
    ```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details (if you add one).
