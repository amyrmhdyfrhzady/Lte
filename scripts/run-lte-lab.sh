#!/usr/bin/env bash

set -e

MODE="${1:-}"

LAB_DIR="/tmp/lte-lab"
CONFIG_DIR="$(cd "$(dirname "$0")/../configs" && pwd)"

ENB_CONF="$CONFIG_DIR/enb.conf"
EPC_CONF="$CONFIG_DIR/epc.conf"
UE_CONF="$CONFIG_DIR/ue.conf"

mkdir -p "$LAB_DIR"

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
    echo
}

prepare() {
    log "Preparing LTE lab"

    mkdir -p "$LAB_DIR"

    rm -f \
        "$LAB_DIR"/*.log \
        "$LAB_DIR"/*.pcap \
        "$LAB_DIR"/*.pcapng \
        "$LAB_DIR"/*.pid

    echo "LTE-LAB" > "$LAB_DIR/status"

    ip link show ogstun >/dev/null 2>&1 || true

    echo "Preparation complete."
}

start() {
    log "Starting LTE lab"

    mkdir -p "$LAB_DIR"

    if pgrep -x srsepc >/dev/null 2>&1; then
        echo "srsepc is already running."
    else
        echo "Starting srsEPC..."

        srsepc \
            "$EPC_CONF" \
            > "$LAB_DIR/srsepc.log" 2>&1 &

        echo $! > "$LAB_DIR/srsepc.pid"

        sleep 5
    fi

    if pgrep -x srsenb >/dev/null 2>&1; then
        echo "srsENB is already running."
    else
        echo "Starting srsENB..."

        srsenb \
            "$ENB_CONF" \
            > "$LAB_DIR/srsenb.log" 2>&1 &

        echo $! > "$LAB_DIR/srsenb.pid"

        sleep 5
    fi

    echo
    echo "Running LTE processes:"
    pgrep -a -f 'srsepc|srsenb' || true
}

test_lte() {
    log "Starting LTE UE"

    if pgrep -x srsue >/dev/null 2>&1; then
        echo "srsUE is already running."
        return
    fi

    timeout 90 \
        srsue "$UE_CONF" \
        > "$LAB_DIR/srsue.log" 2>&1 || true

    echo
    echo "UE test finished."
}

stop() {
    log "Stopping LTE lab"

    if [ -f "$LAB_DIR/srsue.pid" ]; then
        kill "$(cat "$LAB_DIR/srsue.pid")" 2>/dev/null || true
    fi

    if [ -f "$LAB_DIR/srsenb.pid" ]; then
        kill "$(cat "$LAB_DIR/srsenb.pid")" 2>/dev/null || true
    fi

    if [ -f "$LAB_DIR/srsepc.pid" ]; then
        kill "$(cat "$LAB_DIR/srsepc.pid")" 2>/dev/null || true
    fi

    pkill -x srsue 2>/dev/null || true
    pkill -x srsenb 2>/dev/null || true
    pkill -x srsepc 2>/dev/null || true

    sleep 2

    echo "LTE lab stopped."
}

case "$MODE" in

    prepare)
        prepare
        ;;

    start)
        start
        ;;

    test)
        test_lte
        ;;

    stop)
        stop
        ;;

    *)
        echo "Usage:"
        echo
        echo "  $0 prepare"
        echo "  $0 start"
        echo "  $0 test"
        echo "  $0 stop"
        exit 1
        ;;

esac
