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

    echo "Creating UE network namespace..."

    ip netns add ue1

    echo "Creating Open5GS TUN interface..."

    ip tuntap add name ogstun mode tun
    ip addr add 10.45.0.1/16 dev ogstun
    ip link set ogstun up

    echo "Enabling IPv4 forwarding..."

    sysctl -w net.ipv4.ip_forward=1

    echo "Adding NAT..."

    iptables -t nat -D POSTROUTING \
        -s 10.45.0.0/16 \
        ! -o ogstun \
        -j MASQUERADE 2>/dev/null || true

    iptables -t nat -A POSTROUTING \
        -s 10.45.0.0/16 \
        ! -o ogstun \
        -j MASQUERADE

    echo "Creating test subscriber..."

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
            downlink: {
              value: 1,
              unit: 3
            },
            uplink: {
              value: 1,
              unit: 3
            }
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
      > "$LAB_DIR/subscriber.log" 2>&1

    echo "Subscriber database result:"
    cat "$LAB_DIR/subscriber.log" || true

    echo
    echo "Preparation complete."
}

start_core() {
    log "Starting Open5GS 4G EPC"

    echo "Stopping old Open5GS processes..."

    sudo systemctl stop open5gs-mmed 2>/dev/null || true
    sudo systemctl stop open5gs-sgwcd 2>/dev/null || true
    sudo systemctl stop open5gs-smfd 2>/dev/null || true
    sudo systemctl stop open5gs-sgwud 2>/dev/null || true
    sudo systemctl stop open5gs-upfd 2>/dev/null || true
    sudo systemctl stop open5gs-hssd 2>/dev/null || true
    sudo systemctl stop open5gs-pcrfd 2>/dev/null || true

    echo "Starting MongoDB..."

    sudo systemctl restart mongod

    echo "Starting HSS..."

    sudo systemctl restart open5gs-hssd

    echo "Starting PCRF..."

    sudo systemctl restart open5gs-pcrfd

    echo "Starting MME..."

    sudo systemctl restart open5gs-mmed

    echo "Starting SGW Control Plane..."

    sudo systemctl restart open5gs-sgwcd

    echo "Starting SMF / PGW Control Plane..."

    sudo systemctl restart open5gs-smfd

    echo "Starting SGW User Plane..."

    sudo systemctl restart open5gs-sgwud

    echo "Starting UPF / PGW User Plane..."

    sudo systemctl restart open5gs-upfd

    sleep 8

    echo
    echo "============================================================"
    echo "Open5GS Processes"
    echo "============================================================"

    ps aux | grep open5gs | grep -v grep || true

    echo
    echo "============================================================"
    echo "Open5GS Services"
    echo "============================================================"

    systemctl --no-pager --type=service \
        | grep open5gs || true

    echo
    echo "============================================================"
    echo "LTE Core Sockets"
    echo "============================================================"

    ss -lntup | grep -E \
        '36412|2123|2152|3868|8805' \
        || true
}

start_enb() {
    log "Starting srsENB"

    mkdir -p "$LAB_DIR"

    if pgrep -x srsenb >/dev/null 2>&1; then
        echo "srsENB is already running."
        return
    fi

    echo "Starting srsENB..."

    srsenb "$ENB_CONF" \
        > "$LAB_DIR/srsenb.log" 2>&1 &

    echo $! > "$LAB_DIR/srsenb.pid"

    sleep 10

    echo
    echo "srsENB process:"

    pgrep -a -x srsenb || true

    echo
    echo "srsENB log:"

    tail -n 100 "$LAB_DIR/srsenb.log" || true
}

test_ue() {
    log "Starting srsUE"

    if pgrep -x srsue >/dev/null 2>&1; then
        echo "srsUE is already running."
        return
    fi

    echo "Starting srsUE inside ue1 namespace..."

    timeout 120 \
        ip netns exec ue1 \
        srsue "$UE_CONF" \
        > "$LAB_DIR/srsue.log" 2>&1 || true

    echo
    echo "============================================================"
    echo "srsUE RESULT"
    echo "============================================================"

    cat "$LAB_DIR/srsue.log" || true
}

stop() {
    log "Stopping LTE Lab"

    echo "Stopping srsUE..."
    pkill -x srsue 2>/dev/null || true

    echo "Stopping srsENB..."
    pkill -x srsenb 2>/dev/null || true

    echo "Stopping Open5GS..."

    sudo systemctl stop open5gs-upfd 2>/dev/null || true
    sudo systemctl stop open5gs-sgwud 2>/dev/null || true
    sudo systemctl stop open5gs-smfd 2>/dev/null || true
    sudo systemctl stop open5gs-sgwcd 2>/dev/null || true
    sudo systemctl stop open5gs-mmed 2>/dev/null || true
    sudo systemctl stop open5gs-pcrfd 2>/dev/null || true
    sudo systemctl stop open5gs-hssd 2>/dev/null || true

    echo "Removing UE namespace..."

    ip netns del ue1 2>/dev/null || true

    echo "Removing ogstun..."

    ip link del ogstun 2>/dev/null || true

    echo "Removing NAT rule..."

    iptables -t nat -D POSTROUTING \
        -s 10.45.0.0/16 \
        ! -o ogstun \
        -j MASQUERADE 2>/dev/null || true

    echo
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
