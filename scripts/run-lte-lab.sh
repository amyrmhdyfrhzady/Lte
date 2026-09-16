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

    echo "Cleaning previous processes..."

    sudo pkill -x srsue 2>/dev/null || true
    sudo pkill -x srsenb 2>/dev/null || true

    ip netns del ue1 2>/dev/null || true
    ip link del ogstun 2>/dev/null || true

    echo "Configuring Open5GS MME PLMN/TAC..."

    sudo python3 - <<'PY'
from pathlib import Path

path = Path("/etc/open5gs/mme.yaml")
text = path.read_text()

replacements = {
    "        mcc: 999": "        mcc: 901",
    "        mnc: 70": "        mnc: 70",
    "      tac: 1": "      tac: 7",
}

lines = text.splitlines()

section = None

for i, line in enumerate(lines):

    if line.strip() == "gummei:":
        section = "gummei"
        continue

    if line.strip() == "tai:":
        section = "tai"
        continue

    if section == "gummei":
        if "mcc:" in line:
            lines[i] = "        mcc: 901"
        elif "mnc:" in line:
            lines[i] = "        mnc: 70"

    elif section == "tai":
        if "mcc:" in line:
            lines[i] = "        mcc: 901"
        elif "mnc:" in line:
            lines[i] = "        mnc: 70"
        elif "tac:" in line:
            lines[i] = "      tac: 7"

path.write_text("\n".join(lines) + "\n")
PY

    echo "MME PLMN/TAC:"
    sudo grep -A18 -E "gummei:|tai:" /etc/open5gs/mme.yaml || true

    echo
    echo "Creating UE network namespace..."

    ip netns add ue1

    echo
    echo "Creating Open5GS TUN interface..."

    ip tuntap add name ogstun mode tun
    ip addr add 10.45.0.1/16 dev ogstun
    ip link set ogstun up

    echo
    echo "Enabling IPv4 forwarding..."

    sudo sysctl -w net.ipv4.ip_forward=1

    echo
    echo "Adding NAT..."

    sudo iptables -t nat -D POSTROUTING \
        -s 10.45.0.0/16 \
        ! -o ogstun \
        -j MASQUERADE 2>/dev/null || true

    sudo iptables -t nat -A POSTROUTING \
        -s 10.45.0.0/16 \
        ! -o ogstun \
        -j MASQUERADE

    echo
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

    echo
    echo "Subscriber database result:"
    cat "$LAB_DIR/subscriber.log" || true

    echo
    echo "Checking srsRAN configuration files..."

    echo
    echo "Installed srsRAN configuration locations:"

    find /usr/local/etc /etc /usr/share \
        -type f \
        \( -name "sib.conf*" -o -name "rr.conf*" -o -name "drb.conf*" \) \
        2>/dev/null \
        | head -n 50 || true

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

    echo
    echo "Starting MongoDB..."

    sudo systemctl restart mongod

    echo
    echo "Starting HSS..."

    sudo systemctl restart open5gs-hssd

    echo
    echo "Starting PCRF..."

    sudo systemctl restart open5gs-pcrfd

    echo
    echo "Starting MME..."

    sudo systemctl restart open5gs-mmed

    echo
    echo "Starting SGW Control Plane..."

    sudo systemctl restart open5gs-sgwcd

    echo
    echo "Starting SMF / PGW Control Plane..."

    sudo systemctl restart open5gs-smfd

    echo
    echo "Starting SGW User Plane..."

    sudo systemctl restart open5gs-sgwud

    echo
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

    echo
    echo "============================================================"
    echo "MME PLMN/TAC"
    echo "============================================================"

    sudo grep -A18 -E "gummei:|tai:" \
        /etc/open5gs/mme.yaml || true
}

start_enb() {
    log "Starting srsENB"

    mkdir -p "$LAB_DIR"

    if pgrep -x srsenb >/dev/null 2>&1; then
        echo "srsENB is already running."
        return
    fi

    echo "Checking eNB configuration..."

    if [ ! -f "$ENB_CONF" ]; then
        echo "ERROR: $ENB_CONF not found."
        exit 1
    fi

    echo
    echo "eNB configuration:"
    cat "$ENB_CONF"

    echo
    echo "Starting srsENB..."

    srsenb "$ENB_CONF" \
        > "$LAB_DIR/srsenb.log" 2>&1 &

    echo $! > "$LAB_DIR/srsenb.pid"

    sleep 10

    echo
    echo "============================================================"
    echo "srsENB PROCESS"
    echo "============================================================"

    pgrep -a -x srsenb || true

    echo
    echo "============================================================"
    echo "srsENB LOG"
    echo "============================================================"

    tail -n 150 "$LAB_DIR/srsenb.log" || true

    echo
    echo "============================================================"
    echo "S1AP SOCKET"
    echo "============================================================"

    ss -lnp | grep 36412 || true
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

    echo
    echo "============================================================"
    echo "UE NETWORK INTERFACES"
    echo "============================================================"

    ip netns exec ue1 ip addr || true

    echo
    echo "============================================================"
    echo "UE ROUTES"
    echo "============================================================"

    ip netns exec ue1 ip route || true

    echo
    echo "============================================================"
    echo "Open5GS UE INFO"
    echo "============================================================"

    curl -s \
        "http://127.0.0.2:9090/ue-info?" \
        || true

    echo
    echo
    echo "============================================================"
    echo "Open5GS eNB INFO"
    echo "============================================================"

    curl -s \
        "http://127.0.0.2:9090/enb-info?" \
        || true
}

stop() {
    log "Stopping LTE Lab"

    echo "Stopping srsUE..."

    sudo pkill -x srsue 2>/dev/null || true

    echo "Stopping srsENB..."

    sudo pkill -x srsenb 2>/dev/null || true

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

    sudo iptables -t nat -D POSTROUTING \
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
