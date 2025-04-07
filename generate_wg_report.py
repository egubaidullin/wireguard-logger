#!/usr/bin/env python3

import argparse
import csv
import datetime
import glob
import gzip
import json
import os
import re
import sys
from collections import defaultdict

# Regex to parse the log line format
# Groups: 1: Timestamp, 2: Event, 3: PeerName, 4: PeerKey, 5: EndpointIP
LOG_PATTERN = re.compile(
    r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2})\s+"  # 1: Timestamp (ISO 8601 with tz)
    r"(\S+(?:\s+\([^)]+\))?)\s+"                             # 2: Event (e.g., CONNECT, DISCONNECT (Timeout))
    r"PeerName='([^']*)'\s+"                                 # 3: PeerName
    r"PeerKey=([^ ]+)\s+"                                    # 4: PeerKey
    r"Endpoint=(\S+)"                                        # 5: EndpointIP
)

def parse_arguments():
    """Parses command-line arguments."""
    parser = argparse.ArgumentParser(description="Generate WireGuard connection session report.")
    parser.add_argument(
        "-u", "--user",
        default="all",
        help="PeerName to report on, or 'all' for all users (default: all)."
    )
    parser.add_argument(
        "-s", "--start-date",
        help="Start date (YYYY-MM-DD). Defaults to 3 days ago."
    )
    parser.add_argument(
        "-e", "--end-date",
        help="End date (YYYY-MM-DD). Defaults to today."
    )
    parser.add_argument(
        "-o", "--output",
        required=True,
        help="Path for the output CSV file."
    )
    parser.add_argument(
        "--map-file",
        default="/root/script/ipaddr-map.json",
        help="Path to the JSON peer map file (optional, for resolving 'Unknown' names)."
    )
    parser.add_argument(
        "--log-dir",
        default="/var/log",
        help="Directory containing log files (default: /var/log)."
    )
    parser.add_argument(
        "--log-prefix",
        default="wireguard-connections.log",
        help="Prefix of the log files (default: wireguard-connections.log)."
    )
    parser.add_argument(
        "--days",
        type=int,
        default=3,
        help="Default number of days back if start/end dates are not specified (default: 3)."
    )

    args = parser.parse_args()

    # Set default dates if not provided
    today = datetime.date.today()
    if args.end_date:
        args.end_date_dt = datetime.datetime.strptime(args.end_date, "%Y-%m-%d").date()
    else:
        args.end_date_dt = today

    if args.start_date:
        args.start_date_dt = datetime.datetime.strptime(args.start_date, "%Y-%m-%d").date()
    else:
        args.start_date_dt = args.end_date_dt - datetime.timedelta(days=args.days -1) # N days including end date

    # Ensure start date is not after end date
    if args.start_date_dt > args.end_date_dt:
        print(f"Error: Start date ({args.start_date}) cannot be after end date ({args.end_date}).", file=sys.stderr)
        sys.exit(1)

    return args

def load_peer_map(map_file_path):
    """Loads the PeerKey -> PeerName map from JSON."""
    peer_map = {}
    if not os.path.exists(map_file_path):
        print(f"Warning: Peer map file not found at {map_file_path}. Names might be 'Unknown'.", file=sys.stderr)
        return peer_map
    try:
        with open(map_file_path, 'r') as f:
            data = json.load(f)
        for name, details in data.items():
            if 'publicKey' in details:
                peer_map[details['publicKey']] = name
    except Exception as e:
        print(f"Warning: Could not load or parse peer map file {map_file_path}: {e}", file=sys.stderr)
    return peer_map

def format_duration(td):
    """Formats a timedelta object into HH:MM:SS."""
    if not isinstance(td, datetime.timedelta):
        return "N/A"
    total_seconds = int(td.total_seconds())
    hours, remainder = divmod(total_seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours:02}:{minutes:02}:{seconds:02}"

def process_logs(args, peer_map):
    """Reads logs, parses entries, and calculates sessions."""
    log_files = glob.glob(os.path.join(args.log_dir, f"{args.log_prefix}*"))
    log_entries = []
    processed_files = 0

    print(f"Scanning log files in {args.log_dir} matching {args.log_prefix}*...")

    for log_file in sorted(log_files, reverse=True): # Process newer files first potentially
        try:
            print(f"  Processing {os.path.basename(log_file)}...")
            open_func = gzip.open if log_file.endswith(".gz") else open
            enc = 'utf-8' # Assume UTF-8 encoding

            with open_func(log_file, "rt", encoding=enc, errors='replace') as f:
                for line in f:
                    match = LOG_PATTERN.match(line)
                    if match:
                        timestamp_str, event, name_from_log, key, ip = match.groups()

                        try:
                            # Parse timestamp, make timezone-aware (even if offset is needed)
                            # Python < 3.11 doesn't like ':' in tz offset from isoformat easily
                            if ':' == timestamp_str[-3:-2]: # Handle ISO 8601 format like +08:00
                                timestamp_dt = datetime.datetime.fromisoformat(timestamp_str)
                            else: # Handle older formats if they appear (less likely)
                                timestamp_dt = datetime.datetime.strptime(timestamp_str, '%Y-%m-%dT%H:%M:%S%z')
                        except ValueError as e_ts:
                             print(f"Warning: Skipping line due to timestamp parse error: {timestamp_str} - {e_ts}. Line: {line.strip()}", file=sys.stderr)
                             continue


                        # Filter by date *after* parsing timestamp
                        if not (args.start_date_dt <= timestamp_dt.date() <= args.end_date_dt):
                            continue

                        # Filter by user *after* resolving name potentially
                        peer_name = peer_map.get(key, name_from_log) # Use map name if available
                        if args.user != "all" and peer_name != args.user:
                            continue

                        log_entries.append({
                            "timestamp": timestamp_dt,
                            "event": event.split()[0], # Get primary event type (CONNECT, DISCONNECT, etc.)
                            "peer_key": key,
                            "peer_name": peer_name,
                            "endpoint": ip,
                        })
            processed_files += 1
        except Exception as e:
            print(f"Warning: Could not process file {log_file}: {e}", file=sys.stderr)

    if not processed_files:
         print(f"Error: No log files found or processed matching pattern in {args.log_dir}.", file=sys.stderr)
         sys.exit(1)

    if not log_entries:
        print("No relevant log entries found for the specified user and date range.")
        return []

    print(f"Sorting {len(log_entries)} log entries...")
    log_entries.sort(key=lambda x: x["timestamp"])

    print("Calculating sessions...")
    peer_states = defaultdict(lambda: {"status": "disconnected", "session_start_time": None, "session_start_ip": None, "current_name": "Unknown"})
    sessions = []
    last_log_time = log_entries[-1]['timestamp'] if log_entries else None

    for entry in log_entries:
        key = entry["peer_key"]
        state = peer_states[key]
        timestamp = entry["timestamp"]

        # Update name if we see a known one
        if entry["peer_name"] != "Unknown":
            state["current_name"] = entry["peer_name"]

        is_connect_event = entry["event"] in ["CONNECT", "RECONNECT/UPDATE"]
        is_disconnect_event = entry["event"].startswith("DISCONNECT")

        if is_connect_event:
            if state["status"] == "disconnected":
                # Start of a new session
                state["status"] = "connected"
                state["session_start_time"] = timestamp
                state["session_start_ip"] = entry["endpoint"]
                # Ensure name is captured at session start
                if state["current_name"] == "Unknown" and entry["peer_name"] != "Unknown":
                     state["current_name"] = entry["peer_name"]

        elif is_disconnect_event:
            if state["status"] == "connected":
                # End of a session
                start_time = state["session_start_time"]
                end_time = timestamp
                duration = end_time - start_time if start_time and end_time else None
                sessions.append({
                    "PeerName": state["current_name"],
                    "SessionStart": start_time.isoformat() if start_time else "N/A",
                    "SessionEnd": end_time.isoformat() if end_time else "N/A",
                    "Duration (HH:MM:SS)": format_duration(duration),
                    "EndpointIP": state["session_start_ip"] or "N/A",
                    #"_PeerKey": key # Optional: for debugging
                })
                # Reset state
                state["status"] = "disconnected"
                state["session_start_time"] = None
                state["session_start_ip"] = None
            # else: # Was already disconnected, ignore redundant disconnect

    # Handle sessions ongoing at the end of the log period
    print("Checking for ongoing sessions...")
    for key, state in peer_states.items():
        if state["status"] == "connected":
            start_time = state["session_start_time"]
            # Consider the session end as the time of the last relevant log entry
            end_time = last_log_time
            duration = end_time - start_time if start_time and end_time else None
            sessions.append({
                "PeerName": state["current_name"],
                "SessionStart": start_time.isoformat() if start_time else "N/A",
                "SessionEnd": "Ongoing (as of " + (end_time.isoformat() if end_time else "N/A") + ")",
                "Duration (HH:MM:SS)": format_duration(duration) + " (up to last log)",
                "EndpointIP": state["session_start_ip"] or "N/A",
                #"_PeerKey": key # Optional: for debugging
            })

    print(f"Found {len(sessions)} sessions.")
    return sessions

def write_csv_report(sessions, output_file):
    """Writes the calculated sessions to a CSV file."""
    if not sessions:
        print("No sessions to write to CSV.")
        return

    fieldnames = ["PeerName", "SessionStart", "SessionEnd", "Duration (HH:MM:SS)", "EndpointIP"]
    print(f"Writing report to {output_file}...")

    try:
        with open(output_file, 'w', newline='', encoding='utf-8') as csvfile:
            writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(sessions)
        print("CSV report generated successfully.")
    except Exception as e:
        print(f"Error writing CSV file {output_file}: {e}", file=sys.stderr)
        sys.exit(1)

def main():
    """Main execution function."""
    args = parse_arguments()
    peer_map = load_peer_map(args.map_file)
    sessions = process_logs(args, peer_map)
    write_csv_report(sessions, args.output)

if __name__ == "__main__":
    main()
