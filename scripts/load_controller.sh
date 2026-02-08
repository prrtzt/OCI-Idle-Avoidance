#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_LOG_FILE="${SCRIPT_DIR}/load_controller.log"
LOG_FILE="${LOG_FILE:-$DEFAULT_LOG_FILE}"

LOW_BURST_THRESHOLD=19.0
LOW_SINGLE_THRESHOLD=22.0
HIGH_THRESHOLD=27.0
CRITICAL_THRESHOLD=80.0
BURST_GENERATORS=5
MAX_GENERATORS=40
GENERATOR_USAGE=0.01
LOOP_SLEEP_SECONDS=5

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

load_pids=()

if ! mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null; then
    LOG_FILE="$DEFAULT_LOG_FILE"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
fi

log() {
    local color="$1"
    local message="$2"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    echo "[$timestamp] $message" >> "$LOG_FILE" 2>/dev/null || true
    echo -e "${color}[$timestamp] $message${NC}"
}

is_managed_pid() {
    local pid="$1"
    local cmdline

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1

    cmdline="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    [[ "$cmdline" == *"${SCRIPT_DIR}/load_generator.py"* ]]
}

prune_load_pids() {
    local pid
    local active_pids=()

    for pid in "${load_pids[@]}"; do
        if is_managed_pid "$pid"; then
            active_pids+=("$pid")
        fi
    done

    load_pids=("${active_pids[@]}")
}

spawn_load_generators() {
    local requested="$1"
    local available
    local spawn_count
    local i
    local load_pid

    prune_load_pids
    available=$((MAX_GENERATORS - ${#load_pids[@]}))
    if (( available <= 0 )); then
        log "$YELLOW" "Generator cap reached (${MAX_GENERATORS}); skipping new generators"
        return
    fi

    spawn_count="$requested"
    if (( spawn_count > available )); then
        spawn_count="$available"
    fi

    for ((i = 0; i < spawn_count; i++)); do
        python3 "${SCRIPT_DIR}/load_generator.py" "${GENERATOR_USAGE}" &
        load_pid=$!
        load_pids+=("$load_pid")
    done

    log "$GREEN" "Started ${spawn_count} load generator(s) (total: ${#load_pids[@]}/${MAX_GENERATORS})"
}

stop_one_generator() {
    local last_index
    local pid

    prune_load_pids
    if (( ${#load_pids[@]} == 0 )); then
        log "$YELLOW" "No active load generators to stop"
        return
    fi

    last_index=$(( ${#load_pids[@]} - 1 ))
    pid="${load_pids[$last_index]}"
    if kill "$pid" 2>/dev/null; then
        log "$RED" "Stopped 1 load generator (pid: ${pid})"
    else
        log "$YELLOW" "Unable to stop load generator (pid: ${pid}); it may have already exited"
    fi

    unset "load_pids[$last_index]"
    load_pids=("${load_pids[@]}")
}

stop_all_generators() {
    local pid

    prune_load_pids
    if (( ${#load_pids[@]} == 0 )); then
        log "$YELLOW" "No active load generators to stop"
        return
    fi

    for pid in "${load_pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    load_pids=()
    log "$GREEN" "Stopped all load generators"
}

cleanup() {
    log "$RED" "Stopping load generators and exiting..."
    stop_all_generators
    log "$GREEN" "Controller exited cleanly."
    exit 0
}

read_cpu_usage() {
    local output
    local avg_usage

    output="$(mpstat -P ALL 5 1)"
    avg_usage="$(echo "$output" | awk '/Average:/ && $2 ~ /[0-9]/ {idle+=$NF; count++} END {if (count > 0) printf "%.2f", 100 - idle/count; else print "NaN"}')"
    echo "$avg_usage"
}

for dependency in mpstat bc python3 ps; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        log "$RED" "Missing dependency: ${dependency}. Install it before running the controller."
        exit 1
    fi
done

log "$GREEN" "OCI Idle Avoidance Controller starting..."
trap cleanup SIGINT SIGTERM

while true; do
    avg_usage="$(read_cpu_usage)"
    if [[ "$avg_usage" == "NaN" ]]; then
        log "$RED" "Unable to parse CPU usage from mpstat output; retrying"
        sleep "$LOOP_SLEEP_SECONDS"
        continue
    fi

    prune_load_pids
    log "$YELLOW" "CPU Usage: ${avg_usage}% | Active load generators: ${#load_pids[@]}"

    if (( $(echo "$avg_usage > $CRITICAL_THRESHOLD" | bc -l) )); then
        log "$RED" "CRITICAL: CPU usage above ${CRITICAL_THRESHOLD}% - stopping all load generators"
        stop_all_generators
    elif (( $(echo "$avg_usage > $HIGH_THRESHOLD" | bc -l) )); then
        log "$RED" "CPU usage above ${HIGH_THRESHOLD}% - stopping 1 load generator"
        stop_one_generator
    elif (( $(echo "$avg_usage < $LOW_BURST_THRESHOLD" | bc -l) )); then
        log "$GREEN" "CPU usage below ${LOW_BURST_THRESHOLD}% - starting ${BURST_GENERATORS} load generators"
        spawn_load_generators "$BURST_GENERATORS"
    elif (( $(echo "$avg_usage < $LOW_SINGLE_THRESHOLD" | bc -l) )); then
        log "$GREEN" "CPU usage between ${LOW_BURST_THRESHOLD}% and ${LOW_SINGLE_THRESHOLD}% - starting 1 load generator"
        spawn_load_generators 1
    fi

    sleep "$LOOP_SLEEP_SECONDS"
done
