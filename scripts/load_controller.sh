#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/load_controller.log"

RED='\033[0;31m'      # For errors or important actions
GREEN='\033[0;32m'    # For successful actions
YELLOW='\033[0;33m'   # For information
NC='\033[0m'          # No Color

# Logging function that writes to both console and log file
log() {
    local color="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Log to file without color codes
    echo "[$timestamp] $message" >> "$LOG_FILE"

    # Display to console with color
    echo -e "${color}[$timestamp] $message${NC}"
}

# Check if sysstat package is installed
if ! command -v mpstat &> /dev/null
then
    log "$RED" "sysstat could not be found. Install it with 'sudo apt-get install sysstat'"
    exit
fi

log "$GREEN" "OCI Idle Avoidance Controller starting..."

load_pids=()

# Function to stop child processes and exit
function cleanup {
    log "$RED" "Stopping load generators and exiting..."
    for pid in "${load_pids[@]}"; do
        kill $pid
    done
    log "$GREEN" "All load generators stopped. Exiting."
    exit
}

# Catch interrupt signal (Ctrl+C) and terminate signal
trap cleanup SIGINT SIGTERM

while true; do
    output=$(mpstat -P ALL 5 1)
    avg_usage=$(echo "$output" | awk '/Average:/ && $2 ~ /[0-9]/ {total+=$NF; count++} END {print 100 - total/count}')
    log "$YELLOW" "CPU Usage: $avg_usage% | Active load generators: ${#load_pids[@]}"

    if (( $(echo "$avg_usage < 19.0" | bc -l) )); then
        log "$GREEN" "CPU usage below 22% threshold - starting 5 load generators"
        for i in {1..5}; do
            python3 "${SCRIPT_DIR}/load_generator.py" 0.01 & load_pid=$!
            load_pids+=($load_pid)
        done
        log "$GREEN" "Started 5 load generators (total: ${#load_pids[@]})"
    elif (( $(echo "$avg_usage >= 19.0 && $avg_usage < 22.0" | bc -l) )); then
        log "$GREEN" "CPU usage between 19-22% - starting 1 load generator"
        python3 "${SCRIPT_DIR}/load_generator.py" 0.01 & load_pid=$!
        load_pids+=($load_pid)
        log "$GREEN" "Started 1 load generator (total: ${#load_pids[@]})"
    elif (( $(echo "$avg_usage > 27.0" | bc -l) )); then
        if (( ${#load_pids[@]} > 0 )); then
            log "$RED" "CPU usage above 27% - stopping 1 load generator"
            kill ${load_pids[-1]} # kill the last load generator
            unset 'load_pids[${#load_pids[@]}-1]' # remove it from the array
            log "$RED" "Stopped 1 load generator (remaining: ${#load_pids[@]})"
        else
            log "$YELLOW" "CPU usage above 27% but no load generators running"
        fi
    elif (( $(echo "$avg_usage > 80.0" | bc -l) )); then
        if (( ${#load_pids[@]} > 0 )); then
            log "$RED" "CRITICAL: CPU usage above 80% - stopping all load generators"
            for pid in "${load_pids[@]}"; do
                kill $pid
            done
            load_pids=()
            log "$GREEN" "Stopped all load generators (remaining: 0)"
        else
            log "$YELLOW" "CPU usage above 80% but no load generators running"
        fi
    fi
    sleep 5
done
