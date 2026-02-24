#!/bin/bash
# trace-fan-mode-bug.sh — Verify hypothesis for issue #2977
#
# This script reads F%dMd (fan mode) values from SMC to confirm whether
# Apple Silicon reports mode 3 (.auto3 / system mode) under normal operation.
# If mode 3 is observed, it confirms the root cause of the sleep/wake bug.
#
# REQUIRES: The Stats SMC helper tool to be installed, and the smc CLI
#           built at the expected path, OR access to the smc binary.
#
# Usage:
#   chmod +x investigations/trace-fan-mode-bug.sh
#   ./investigations/trace-fan-mode-bug.sh [path-to-smc-binary]
#
# The script will:
# 1. Read FNum (number of fans)
# 2. Read F%dMd for each fan (mode: 0=auto, 1=manual, 3=system)
# 3. Read F%dAc (actual RPM) and F%dTg (target RPM)
# 4. Log results with timestamps for sleep/wake testing

set -euo pipefail

SMC_BIN="${1:-}"

if [ -z "$SMC_BIN" ]; then
    CANDIDATES=(
        "/Library/PrivilegedHelperTools/eu.exelban.Stats.SMC.Helper"
        "$(dirname "$0")/../SMC/.build/release/smc"
        "$(dirname "$0")/../.build/release/smc"
    )
    for c in "${CANDIDATES[@]}"; do
        if [ -x "$c" ]; then
            SMC_BIN="$c"
            break
        fi
    done
fi

LOG_FILE="investigations/fan-mode-trace-$(date +%Y%m%d-%H%M%S).log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

log "=== Fan Mode Bug Trace (Issue #2977) ==="
log "Platform: $(uname -m)"
log "macOS: $(sw_vers -productVersion)"
log "SMC binary: ${SMC_BIN:-NOT FOUND}"

if [ -z "$SMC_BIN" ]; then
    log ""
    log "ERROR: No smc binary found."
    log "Build it first:  cd SMC && swift build -c release"
    log "Or provide path: $0 /path/to/smc"
    log ""
    log "ALTERNATIVE: Use defaults to check persisted fan state:"
    log ""

    log "--- Checking UserDefaults for fan mode/speed persistence ---"
    for i in 0 1 2 3; do
        mode=$(defaults read eu.exelban.Stats "fan_${i}_mode" 2>/dev/null || echo "NOT SET")
        speed=$(defaults read eu.exelban.Stats "fan_${i}_speed" 2>/dev/null || echo "NOT SET")
        if [ "$mode" != "NOT SET" ] || [ "$speed" != "NOT SET" ]; then
            log "Fan $i: customMode=$mode, customSpeed=$speed"
        fi
    done

    speed_state=$(defaults read eu.exelban.Stats "Sensors_speed" 2>/dev/null || echo "NOT SET")
    fan_control=$(defaults read eu.exelban.Stats "Sensors_fanControl" 2>/dev/null || echo "NOT SET")
    log "Sensors_speed (save fan speed): $speed_state"
    log "Sensors_fanControl: $fan_control"

    log ""
    log "KEY FINDING: If fan_X_mode = 1 (forced) but user says they never set manual mode,"
    log "this confirms the bug is persisting incorrect state after sleep/wake."
    log ""
    log "TO RESET: defaults delete eu.exelban.Stats fan_0_mode"
    log "          defaults delete eu.exelban.Stats fan_1_mode"
    exit 0
fi

read_fans() {
    log "--- Fan State Snapshot ---"
    local output
    output=$("$SMC_BIN" fans 2>&1) || true
    log "$output"

    log ""
    log "--- Mode Value Analysis ---"

    local fan_count
    fan_count=$(echo "$output" | head -1 | grep -oE '[0-9]+' || echo "0")

    for i in $(seq 0 $((fan_count - 1))); do
        local mode_line
        mode_line=$(echo "$output" | grep "Mode:" | sed -n "$((i + 1))p" || echo "")
        log "Fan $i raw mode line: $mode_line"
    done

    log ""
    log "MODE INTERPRETATION:"
    log "  0 (.automatic) = Standard auto mode"
    log "  1 (.forced)    = Manual/forced mode"
    log "  3 (.auto3)     = System mode (thermalmonitord) ← triggers bug"
    log ""
    log "If any fan shows Mode: auto3 or raw value 3, this confirms the root cause."
    log "The bug in popup.swift line 928 treats .auto3 as non-automatic,"
    log "causing setMode(.forced) after every wake event."
}

check_defaults() {
    log ""
    log "--- UserDefaults State ---"
    for i in 0 1 2 3; do
        mode=$(defaults read eu.exelban.Stats "fan_${i}_mode" 2>/dev/null || echo "NOT SET")
        speed=$(defaults read eu.exelban.Stats "fan_${i}_speed" 2>/dev/null || echo "NOT SET")
        if [ "$mode" != "NOT SET" ] || [ "$speed" != "NOT SET" ]; then
            log "Fan $i: customMode=$mode (0=auto, 1=forced), customSpeed=$speed"
        fi
    done

    speed_state=$(defaults read eu.exelban.Stats "Sensors_speed" 2>/dev/null || echo "NOT SET")
    log "Sensors_speed (save fan speed toggle): $speed_state"
}

read_fans
check_defaults

log ""
log "=== Continuous monitoring (Ctrl+C to stop) ==="
log "Sleep your Mac, then wake it. Watch for mode changes."
log ""

while true; do
    sleep 5
    log "--- $(date '+%H:%M:%S') ---"
    output=$("$SMC_BIN" fans 2>&1) || true
    fan_count=$(echo "$output" | head -1 | grep -oE '[0-9]+' || echo "0")
    for i in $(seq 0 $((fan_count - 1))); do
        actual=$(echo "$output" | grep -A5 "^$i:" | grep "Actual" | grep -oE '[0-9.]+' || echo "?")
        target=$(echo "$output" | grep -A5 "^$i:" | grep "Target" | grep -oE '[0-9.]+' || echo "?")
        mode=$(echo "$output" | grep -A5 "^$i:" | grep "Mode:" || echo "?")
        log "Fan$i: RPM=$actual target=$target $mode"
    done

    for i in 0 1; do
        mode=$(defaults read eu.exelban.Stats "fan_${i}_mode" 2>/dev/null || echo "X")
        if [ "$mode" != "X" ]; then
            log "  UserDefaults fan_${i}_mode=$mode"
        fi
    done
done
