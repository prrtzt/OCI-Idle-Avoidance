#!/bin/bash
#
# OCI Idle Avoidance Controller
#
# Monitors CPU usage and spawns/stops load generators to maintain minimum usage.
# This prevents Oracle Cloud from reclaiming VMs due to idling.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_LOG_FILE="${SCRIPT_DIR}/load_controller.log"
LOG_FILE="${LOG_FILE:-$DEFAULT_LOG_FILE}"

# ============================================================================
# Configuration Thresholds
# ============================================================================
# LOW_BURST_THRESHOLD: Below this %, spawn BURST_GENERATORS (aggressive ramp-up)
# LOW_SINGLE_THRESHOLD: Below this %, spawn 1 generator (gentle ramp-up)
# HIGH_THRESHOLD: Above this %, stop 1 generator (gentle ramp-down)
# CRITICAL_THRESHOLD: Above this %, stop ALL generators (emergency stop)
# Hysteresis zone (22-27%): No action taken to prevent oscillation
# ============================================================================
LOW_BURST_THRESHOLD=19.0
LOW_SINGLE_THRESHOLD=22.0
HIGH_THRESHOLD=27.0
CRITICAL_THRESHOLD=80.0
BURST_GENERATORS=5
MAX_GENERATORS=40
GENERATOR_USAGE="${GENERATOR_USAGE:-0.01}"
MPSTAT_INTERVAL=5

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Process tracking
load_pids=()

# Logging initialization flag
_log_initialized=false

# Controller instance lock
_lock_acquired=false
CONTROLLER_LOCK_FILE="${CONTROLLER_LOCK_FILE:-}"

# ============================================================================
# Initialization
# ============================================================================

validate_generator_usage() {
    if ! [[ "$GENERATOR_USAGE" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        echo "ERROR: GENERATOR_USAGE must be a valid number (got: $GENERATOR_USAGE)" >&2
        exit 1
    fi
    local valid
    valid=$(echo "$GENERATOR_USAGE >= 0.0 && $GENERATOR_USAGE <= 1.0" | bc -l)
    if [[ "$valid" != "1" ]]; then
        echo "ERROR: GENERATOR_USAGE must be between 0.0 and 1.0 (got: $GENERATOR_USAGE)" >&2
        exit 1
    fi
}

init_log_file() {
    local log_dir
    log_dir="$(dirname "$LOG_FILE")"

    # Resolve to absolute path to prevent symlink attacks on file or directory
    if [[ -L "$LOG_FILE" ]]; then
        echo "ERROR: Log file path is a symlink, refusing to use: $LOG_FILE" >&2
        LOG_FILE="$DEFAULT_LOG_FILE"
        log_dir="$(dirname "$LOG_FILE")"
    fi

    if [[ -L "$log_dir" ]]; then
        # Allow systemd-managed private log directories (symlinks containing "private/")
        local symlink_target
        symlink_target="$(readlink "$log_dir" 2>/dev/null || echo "")"
        if [[ ! "$symlink_target" =~ private/ ]]; then
            echo "ERROR: Log directory is a symlink, refusing to use: $log_dir" >&2
            LOG_FILE="$DEFAULT_LOG_FILE"
            log_dir="$(dirname "$LOG_FILE")"
        fi
        # For systemd-managed directories, keep using the symlink path
        # The dynamic user will have proper permissions through systemd
    fi

    if ! mkdir -p "$log_dir" 2>/dev/null; then
        LOG_FILE="$DEFAULT_LOG_FILE"
        log_dir="$(dirname "$LOG_FILE")"
        mkdir -p "$log_dir" 2>/dev/null || {
            echo "ERROR: Cannot create log directory: $log_dir" >&2
            exit 1
        }
    fi

    # Create log file with secure permissions if it doesn't exist
    if [[ ! -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE" 2>/dev/null || {
            echo "ERROR: Cannot create log file: $LOG_FILE" >&2
            exit 1
        }
        chmod 0640 "$LOG_FILE" 2>/dev/null || true
    fi

    _log_initialized=true
}

init_lock_file() {
    if [[ -z "$CONTROLLER_LOCK_FILE" ]]; then
        CONTROLLER_LOCK_FILE="$(dirname "$LOG_FILE")/load_controller.lock"
    fi
}

acquire_instance_lock() {
    local lock_pid
    local lock_dir

    init_lock_file
    lock_dir="$(dirname "$CONTROLLER_LOCK_FILE")"

    if [[ -L "$CONTROLLER_LOCK_FILE" ]]; then
        echo "ERROR: Lock file path is a symlink, refusing to use: $CONTROLLER_LOCK_FILE" >&2
        exit 1
    fi

    if [[ -L "$lock_dir" ]]; then
        echo "ERROR: Lock directory is a symlink, refusing to use: $lock_dir" >&2
        exit 1
    fi

    mkdir -p "$lock_dir" 2>/dev/null || {
        echo "ERROR: Cannot create lock directory: $lock_dir" >&2
        exit 1
    }

    if (set -o noclobber; echo "$$" > "$CONTROLLER_LOCK_FILE") 2>/dev/null; then
        _lock_acquired=true
        return
    fi

    if [[ -f "$CONTROLLER_LOCK_FILE" ]]; then
        lock_pid="$(cat "$CONTROLLER_LOCK_FILE" 2>/dev/null || true)"
        if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "ERROR: Another controller instance is already running (pid: $lock_pid)" >&2
            exit 1
        fi

        rm -f "$CONTROLLER_LOCK_FILE" 2>/dev/null || {
            echo "ERROR: Cannot remove stale lock file: $CONTROLLER_LOCK_FILE" >&2
            exit 1
        }

        if (set -o noclobber; echo "$$" > "$CONTROLLER_LOCK_FILE") 2>/dev/null; then
            _lock_acquired=true
            return
        fi
    fi

    echo "ERROR: Unable to acquire controller lock: $CONTROLLER_LOCK_FILE" >&2
    exit 1
}

release_instance_lock() {
    local lock_pid

    if [[ "$_lock_acquired" != "true" ]] || [[ -z "$CONTROLLER_LOCK_FILE" ]]; then
        return
    fi

    lock_pid="$(cat "$CONTROLLER_LOCK_FILE" 2>/dev/null || true)"
    if [[ "$lock_pid" == "$$" ]]; then
        rm -f "$CONTROLLER_LOCK_FILE" 2>/dev/null || true
    fi
}

# ============================================================================
# Logging
# ============================================================================

log() {
    local color="$1"
    local message="$2"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    if [[ "$_log_initialized" == "true" ]]; then
        echo "[$timestamp] $message" >> "$LOG_FILE" 2>/dev/null || {
            echo "WARNING: Failed to write to log file" >&2
        }
    fi
    echo -e "${color}[$timestamp] $message${NC}"
}

# ============================================================================
# Process Management
# ============================================================================

is_managed_pid() {
    local pid="$1"
    local cmdline
    local expected_path

    # Validate PID format
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1

    # Check if process exists
    kill -0 "$pid" 2>/dev/null || return 1

    # Get full command line with extended width
    cmdline="$(ps -p "$pid" -o args= -ww 2>/dev/null || true)"

    # SCRIPT_DIR is already canonical, so match against that exact path
    expected_path="${SCRIPT_DIR}/load_generator.py"

    # Match: python3 /path/to/load_generator.py <usage> (stricter pattern)
    # Ensures the path appears as the script argument, not embedded in another path
    [[ "$cmdline" =~ python3?[[:space:]]+"$expected_path"[[:space:]] ]]
}

prune_load_pids() {
    local pid
    local active_pids=()

    for pid in "${load_pids[@]+"${load_pids[@]}"}"; do
        if is_managed_pid "$pid"; then
            active_pids+=("$pid")
        fi
    done

    load_pids=("${active_pids[@]+"${active_pids[@]}"}")
}

spawn_load_generators() {
    local requested="$1"
    local available
    local spawn_count
    local i
    local load_pid
    local spawned=0

    # Array already pruned in main loop
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
        # Re-check availability before each spawn to minimize race window
        if (( ${#load_pids[@]} >= MAX_GENERATORS )); then
            break
        fi

        python3 "${SCRIPT_DIR}/load_generator.py" "${GENERATOR_USAGE}" &
        load_pid=$!

        # Verify the process started successfully
        if kill -0 "$load_pid" 2>/dev/null; then
            load_pids+=("$load_pid")
            ((spawned++)) || true
        else
            log "$YELLOW" "Failed to spawn load generator"
        fi
    done

    if (( spawned > 0 )); then
        log "$GREEN" "Started ${spawned} load generator(s) (total: ${#load_pids[@]}/${MAX_GENERATORS})"
    fi
}

wait_for_termination() {
    local pid="$1"
    local max_wait_secs=3
    local poll_interval_secs=0.5
    local max_checks=$((max_wait_secs * 2))
    local checks=0

    while kill -0 "$pid" 2>/dev/null && (( checks < max_checks )); do
        sleep "$poll_interval_secs"
        ((checks++)) || true
    done

    # Force kill only if this is still one of our managed generators.
    if is_managed_pid "$pid"; then
        kill -KILL "$pid" 2>/dev/null || true
        log "$YELLOW" "Force-killed managed generator (pid: ${pid}) after SIGTERM timeout"
    elif kill -0 "$pid" 2>/dev/null; then
        log "$YELLOW" "Skipping SIGKILL for pid ${pid}: process no longer matches managed generator"
    fi
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

    if kill -TERM "$pid" 2>/dev/null; then
        wait_for_termination "$pid"
    else
        log "$YELLOW" "Unable to stop load generator (pid: ${pid}); it may have already exited"
    fi

    prune_load_pids

    if is_managed_pid "$pid"; then
        log "$YELLOW" "Load generator still active after stop attempt (pid: ${pid}); keeping it tracked"
    else
        log "$RED" "Stopped 1 load generator (pid: ${pid})"
    fi
}

stop_all_generators() {
    local pid
    local count
    local remaining

    prune_load_pids

    if (( ${#load_pids[@]} == 0 )); then
        log "$YELLOW" "No active load generators to stop"
        return
    fi

    count="${#load_pids[@]}"

    # Send SIGTERM to all
    for pid in "${load_pids[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done

    # Wait for all to terminate, force-kill if needed
    for pid in "${load_pids[@]}"; do
        wait_for_termination "$pid"
    done

    prune_load_pids
    remaining="${#load_pids[@]}"

    if (( remaining == 0 )); then
        log "$GREEN" "Stopped all ${count} load generators"
    else
        log "$YELLOW" "Stopped $((count - remaining))/${count} generators; ${remaining} still active and tracked"
    fi
}

cleanup() {
    log "$RED" "Stopping load generators and exiting..."
    stop_all_generators
    log "$GREEN" "Controller exited cleanly."
    exit 0
}

# ============================================================================
# CPU Monitoring
# ============================================================================

read_cpu_usage() {
    local output
    local avg_usage
    local timeout_secs=$((MPSTAT_INTERVAL + 5))

    # Run mpstat with timeout to prevent hangs
    if ! output="$(timeout "$timeout_secs" mpstat -P ALL "$MPSTAT_INTERVAL" 1 2>/dev/null)"; then
        echo "NaN"
        return
    fi

    avg_usage="$(echo "$output" | awk '/Average:/ && $2 ~ /[0-9]/ {idle+=$NF; count++} END {if (count > 0) printf "%.2f", 100 - idle/count; else print "NaN"}')"
    echo "$avg_usage"
}

# Safe bc comparison that validates input
bc_compare() {
    local value="$1"
    local operator="$2"
    local threshold="$3"
    local result

    # Validate value is a valid number
    if ! [[ "$value" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        echo "0"
        return
    fi

    result=$(echo "$value $operator $threshold" | bc -l 2>/dev/null) || result="0"
    echo "${result:-0}"
}

# ============================================================================
# Main
# ============================================================================

# Check dependencies
for dependency in mpstat bc python3 ps timeout; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        echo "ERROR: Missing dependency: ${dependency}. Install it before running the controller." >&2
        exit 1
    fi
done

# Validate configuration
validate_generator_usage

# Initialize logging
init_log_file
acquire_instance_lock
trap release_instance_lock EXIT

log "$GREEN" "OCI Idle Avoidance Controller starting..."
log "$GREEN" "Configuration: GENERATOR_USAGE=${GENERATOR_USAGE}, MAX_GENERATORS=${MAX_GENERATORS}"
log "$GREEN" "Lock file: ${CONTROLLER_LOCK_FILE}"

# Set up signal handlers
trap cleanup SIGINT SIGTERM

while true; do
    avg_usage="$(read_cpu_usage)"

    if [[ "$avg_usage" == "NaN" ]] || [[ -z "$avg_usage" ]]; then
        log "$RED" "Unable to parse CPU usage from mpstat output; retrying"
        sleep 2
        continue
    fi

    prune_load_pids
    log "$YELLOW" "CPU Usage: ${avg_usage}% | Active load generators: ${#load_pids[@]}"

    if (( $(bc_compare "$avg_usage" ">" "$CRITICAL_THRESHOLD") )); then
        log "$RED" "CRITICAL: CPU usage above ${CRITICAL_THRESHOLD}% - stopping all load generators"
        stop_all_generators
    elif (( $(bc_compare "$avg_usage" ">" "$HIGH_THRESHOLD") )); then
        log "$RED" "CPU usage above ${HIGH_THRESHOLD}% - stopping 1 load generator"
        stop_one_generator
    elif (( $(bc_compare "$avg_usage" "<" "$LOW_BURST_THRESHOLD") )); then
        log "$GREEN" "CPU usage below ${LOW_BURST_THRESHOLD}% - starting ${BURST_GENERATORS} load generators"
        spawn_load_generators "$BURST_GENERATORS"
    elif (( $(bc_compare "$avg_usage" "<" "$LOW_SINGLE_THRESHOLD") )); then
        log "$GREEN" "CPU usage between ${LOW_BURST_THRESHOLD}% and ${LOW_SINGLE_THRESHOLD}% - starting 1 load generator"
        spawn_load_generators 1
    fi
    # No sleep needed - mpstat already takes MPSTAT_INTERVAL seconds
done
