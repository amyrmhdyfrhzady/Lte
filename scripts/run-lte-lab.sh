#!/usr/bin/env bash

set -euo pipefail

MODE="${1:-}"

LAB_DIR="/tmp/lte-lab"
CONFIG_DIR="$(cd "$(dirname "$0")/../configs" && pwd)"

ENB_CONF="$CONFIG_DIR/enb.conf"
UE_CONF="$CONFIG_DIR/ue.conf"

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
    echo
}

prepare() {
    log "Preparing LTE Lab"

    mkdir -p "$LAB_DIR"

    rm -f "$LAB_DIR"/*.log
    rm -f "$LAB_DIR"/*.pcap
    rm -f "$LAB_DIR"/*.pcapng
    rm -f "$LAB_DIR"/*.pid

    ip netns del ue1 2>/dev/null || true
    ip link del ogstun 2>/dev/null || true

    ip netns add ue1

    echo "Creating Open5GS TUN interface"

    ip tuntap add name ogstun mode tun
    ip addr add 10.45.0.1/16 dev ogstun
    ip link set ogstun up

    echo "Creating test subscriber"

    mongosh \
      --quiet \
      --eval '
        db = db.getSiblingDB("open5gs");

        db.subscribers.deleteMany({
          imsi: "901700123456789"
        });

        db.subscribers.insertOne({
          imsi: "901700123456789",
          security: {
            k: "00112233445566778899AABBCCDDEEFF",
            opc: "63BFA50EE6523365FF14C1F45F88737D",
            amf: "8000"
          },
          ambr: {
            downlink: { value: 1, unit: 3 },
            uplink: { value: 1, unit: 3 }
          },
          slice: [
            {
              sst: 1,
              default_indicator: true,
              session: [
                {
                  name: "internet",
                  type: 3,
                  qos: {
                    index: 9,
                    arp: 1
                  }
                }
              ]
            }
          ]
        });
      ' \
      > "$LAB_DIR/subscriber.log" 2>&1 || true

    echo "Preparation complete."
}

start_core() {
    log "Starting Open5GS EPC"

    sudo systemctl restart open5gs-mmed
    sudo systemctl restart open5gs-hssd
    sudo systemctl restart open5gs-pcrfd
    sudo systemctl restart open5gs-sgwcd
    sudo systemctl restart open5gs-sgwud
    sudo systemctl restart open5gs-pgwd

    sleep 5

    echo "Open5GS services:"
    systemctl --no-pager --type=service \
      | grep open5gs || true

    echo
    echo "Open5GS sockets:"
    ss -lntup | grep -E '36412|2123|2152|3868' || true
}

start_enb() {
    log "Starting srsENB"

    mkdir -p "$LAB_DIR"

    if pgrep -x srsenb >/dev/null 2>&1; then
        echo "srsENB is already running."
        return
    fi

    srsenb "$ENB_CONF" \
      > "$LAB_DIR/srsenb.log" 2>&1 &

    echo $! > "$LAB_DIR/srsenb.pid"

    sleep 8

    echo "srsENB process:"
    pgrep -a -x srsenb || true
}

test_ue() {
    log "Starting srsUE"

    if pgrep -x srsue >/dev/null 2>&1; then
        echo "srsUE is already running."
        return
    fi

    timeout 90 \
      ip netns exec ue1 \
      srsue "$UE_CONF" \
      > "$LAB_DIR/srsue.log" 2>&1 || true

    echo
    echo "UE test finished."

    echo
    echo "UE log:"
    cat "$LAB_DIR/srsue.log" || true
}

stop() {
    log "Stopping LTE Lab"

    pkill -x srsue 2>/dev/null || true
    pkill -x srsenb 2>/dev/null || true

    sudo systemctl stop open5gs-pgwd 2>/dev/null || true
    sudo systemctl stop open5gs-sgwud 2>/dev/null || true
    sudo systemctl stop open5gs-sgwcd 2>/dev/null || true
    sudo systemctl stop open5gs-pcrfd 2>/dev/null || true
    sudo systemctl stop open5gs-hssd 2>/dev/null || true
    sudo systemctl stop open5gs-mmed 2>/dev/null || true

    ip netns del ue1 2>/dev/null || true
    ip link del ogstun 2>/dev/null || true

    echo "LTE Lab stopped."
}

case "$MODE" in
    prepare)
        prepare
        ;;
    start-core)
        start_core
        ;;
    start-enb)
        start_enb
        ;;
    test-ue)
        test_ue
        ;;
    stop)
        stop
        ;;
    *)
        echo "Usage:"
        echo
        echo "  $0 prepare"
        echo "  $0 start-core"
        echo "  $0 start-enb"
        echo "  $0 test-ue"
        echo "  $0 stop"
        exit 1
        ;;
esac
