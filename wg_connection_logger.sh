#!/bin/bash

# --- Configuration ---
WG_INTERFACE="wg0" # Your WireGuard interface name
# Path to the JSON file containing peer information
PEER_MAP_JSON_FILE="/root/script/ipaddr-map.json"
LOG_FILE="/var/log/wireguard-connections.log"
STATE_FILE="/var/run/wg_connection_logger.state"
HANDSHAKE_TIMEOUT=180 # Seconds
POLL_INTERVAL=60    # Seconds
USE_SYSLOG=false     # Set to true to use 'logger'
DEBUG_MODE=false     # Enable extra debug logging if needed

# --- Functions ---
debug_log() {
    if [ "$DEBUG_MODE" = true ]; then
        local message="DEBUG: $1"
        if [ "$USE_SYSLOG" = true ]; then
            logger -t wg-logger-debug "$message"
        else
            echo "$(date --iso-8601=seconds) $message" >> "${LOG_FILE}"
        fi
    fi
}

log_event() {
    local event_type="$1"
    local pubkey="$2"
    local peer_ip="$3"
    local peer_name_resolved="${peer_names[$pubkey]}"
    local peer_name="${peer_name_resolved:-Unknown}" # Use Unknown if not found

    local message="${event_type} PeerName='${peer_name}' PeerKey=${pubkey} Endpoint=${peer_ip}"

    # Handle system errors passed differently
    if [[ "$event_type" == "ERROR" && "$pubkey" == "System" ]]; then
        message="$4"
    fi

    debug_log "LOG_EVENT: Type=${event_type}, Key=>${pubkey}<, Name='${peer_name}', IP=${peer_ip}"

    if [ "$USE_SYSLOG" = true ]; then
        if [[ "$event_type" == "ERROR" ]]; then logger -t wg-logger -p daemon.error "$message"; else logger -t wg-logger "$message"; fi
    else
        echo "$(date --iso-8601=seconds) $message" >> "${LOG_FILE}"
    fi
}

# --- Peer Name Loading from JSON ---
declare -A peer_names # Associative array for PublicKey -> Name mapping

load_peer_names_from_json() {
    local json_file="$1"
    local names_found=0

    debug_log "Starting peer name loading from JSON: ${json_file}"

    # Check if jq is installed
    if ! command -v jq &> /dev/null; then
        log_event "ERROR" "System" "N/A" "'jq' command not found. Please install jq (sudo apt install jq)."
        debug_log "Error: 'jq' command not found."
        return 1
    fi

    # Check if JSON file exists and is readable
    if [[ ! -r "$json_file" ]]; then
        log_event "ERROR" "System" "N/A" "Peer map JSON file ${json_file} not found or not readable."
        debug_log "Error: JSON file ${json_file} not found or not readable."
        return 1
    fi

    debug_log "JSON file found and readable. Processing with jq..."

    # Use jq to iterate through the JSON object
    # For each top-level key (client name), get its .publicKey value
    # Output format: ClientName PublicKey
    local map_data
    map_data=$(jq -r 'to_entries[] | "\(.key) \(.value.publicKey)"' "$json_file")
    local jq_exit_code=$?

    if [[ $jq_exit_code -ne 0 ]]; then
         log_event "ERROR" "System" "N/A" "jq failed to parse ${json_file}. Check JSON validity and structure."
         debug_log "Error: jq command failed with exit code ${jq_exit_code}."
         return 1
    fi

    if [[ -z "$map_data" ]]; then
         debug_log "Warning: jq processed the file, but extracted no key-publicKey pairs. Is the file empty or structure incorrect?"
         return 2 # Indicate nothing found, but parsing technically worked
    fi

    # Populate the associative array
    while read -r name key; do
        if [[ -n "$name" && -n "$key" ]]; then
            peer_names["$key"]="$name"
            debug_log "  Mapped Key >${key}< to Name '${name}'"
            ((names_found++))
        else
            debug_log "  Skipping invalid line from jq output: Name='${name}', Key='${key}'"
        fi
    done <<< "$map_data" # Feed jq output to the loop

    debug_log "Finished loading peer names from JSON. Total names mapped: ${names_found}."
    if [[ $names_found -eq 0 ]]; then
         debug_log "Warning: No valid peer names were mapped from the JSON file."
         return 2
    fi

    return 0 # Success
}

# --- Main Logic ---

# Load peer names at the start
load_peer_names_from_json "$PEER_MAP_JSON_FILE"
load_exit_code=$?
debug_log "Peer name loading finished with exit code ${load_exit_code}."

# Exit if loading names failed critically (jq missing, file missing)
if [[ $load_exit_code -eq 1 ]]; then
    exit 1
fi

# --- (Rest of the script: state file handling, wg show polling, comparison, saving state - remains the same as previous version) ---

mkdir -p "$(dirname "${STATE_FILE}")"; touch "${STATE_FILE}"
declare -A current_peers; declare -A previous_peers
while IFS='|' read -r key ip ts; do if [[ -n "$key" && -n "$ip" && "$ts" =~ ^[0-9]+$ ]]; then previous_peers["$key"]="$ip|$ts"; fi; done < <(cat "${STATE_FILE}" 2>/dev/null)

wg_dump=$(wg show "${WG_INTERFACE}" dump 2>/dev/null); wg_exit_code=$?
if [[ $wg_exit_code -ne 0 ]]; then log_event "ERROR" "System" "N/A" "ERROR Failed to run 'wg show ${WG_INTERFACE} dump' (Exit Code: ${wg_exit_code})."; exit 1; fi
current_time=$(date +%s)

while IFS=$'\t' read -r pubkey psk endpoint allowed_ips latest_handshake rx tx keepalive; do
    [[ -z "$pubkey" || "$pubkey" == "(none)" || "$endpoint" == "(none)" || "$pubkey" == "public_key" ]] && continue
    peer_ip=${endpoint%:*}

    debug_log "WG_DUMP: Processing key from 'wg show dump': >${pubkey}<"
    if [[ -v peer_names["$pubkey"] ]]; then debug_log "WG_DUMP: Key >${pubkey}< FOUND in peer_names map. Name: '${peer_names[$pubkey]}'";
    else debug_log "WG_DUMP: Key >${pubkey}< NOT FOUND in peer_names map."; fi

    if [[ "$latest_handshake" =~ ^[1-9][0-9]*$ ]]; then
        current_peers["$pubkey"]="${peer_ip}|${latest_handshake}"
        prev_state="${previous_peers[$pubkey]}"
        if [[ -z "$prev_state" ]]; then log_event "CONNECT" "$pubkey" "$peer_ip";
        else
            prev_ip=${prev_state%|*}; prev_ts=${prev_state#*|}
            time_diff=$((current_time - latest_handshake))
            if [[ "$peer_ip" != "$prev_ip" ]]; then log_event "UPDATE (IP Change)" "$pubkey" "$peer_ip";
            elif [[ "$latest_handshake" -gt "$prev_ts" && "$time_diff" -lt $((POLL_INTERVAL + 10)) ]]; then log_event "RECONNECT/UPDATE" "$pubkey" "$peer_ip"; fi
        fi
    else
        current_peers["$pubkey"]="${peer_ip}|0"
        prev_state="${previous_peers[$pubkey]}"; if [[ -n "$prev_state" ]]; then prev_ts=${prev_state#*|}; if [[ "$prev_ts" -ne 0 ]]; then :; fi; fi
    fi
done <<< "$wg_dump"

for pubkey in "${!previous_peers[@]}"; do
    prev_state="${previous_peers[$pubkey]}"; prev_ip=${prev_state%|*}; prev_ts=${prev_state#*|}
    if [[ "$prev_ts" -eq 0 ]]; then continue; fi
    if [[ -z "${current_peers[$pubkey]}" ]]; then log_event "DISCONNECT (Removed)" "$pubkey" "$prev_ip";
    else
         current_state="${current_peers[$pubkey]}"; current_ip=${current_state%|*}; current_ts=${current_state#*|}
         if [[ "$current_ts" -eq 0 || ("$current_ts" -eq "$prev_ts" && $((current_time - current_ts)) -gt "$HANDSHAKE_TIMEOUT") ]]; then
            log_event "DISCONNECT (Timeout)" "$pubkey" "$current_ip"; current_peers["$pubkey"]="${current_ip}|0";
         fi
    fi
done

temp_state_file="${STATE_FILE}.tmp"; : > "${temp_state_file}"
for pubkey in "${!current_peers[@]}"; do if [[ -n "$pubkey" && -n "${current_peers[$pubkey]}" ]]; then echo "${pubkey}|${current_peers[$pubkey]}" >> "${temp_state_file}"; fi; done
mv "${temp_state_file}" "${STATE_FILE}"

exit 0
