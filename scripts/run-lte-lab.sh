#!/usr/bin/env bash

set -euo pipefail

MODE="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

LAB_DIR="/tmp/lte-lab"
CONFIG_DIR="$PROJECT_DIR/configs"
SRSRAN_DIR="$PROJECT_DIR/srsRAN_4G"

ENB_CONF="$CONFIG_DIR/enb.conf"
UE_CONF="$CONFIG_DIR/ue.conf"

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
    echo
}

prepare_srsran_configs() {

    log "Preparing srsRAN configuration files"

    mkdir -p "$CONFIG_DIR"

    if [ ! -d "$SRSRAN_DIR" ]; then
        echo "ERROR: srsRAN_4G directory not found:"
        echo "$SRSRAN_DIR"
        exit 1
    fi

    echo "Using srsRAN source:"
    echo "$SRSRAN_DIR"

    ENB_EXAMPLE="$SRSRAN_DIR/srsenb/enb.conf.example"
    SIB_EXAMPLE="$SRSRAN_DIR/srsenb/sib.conf.example"
    RR_EXAMPLE="$SRSRAN_DIR/srsenb/rr.conf.example"
    RB_EXAMPLE="$SRSRAN_DIR/srsenb/rb.conf.example"
    UE_EXAMPLE="$SRSRAN_DIR/srsue/ue.conf.example"

    for file in \
        "$ENB_EXAMPLE" \
        "$SIB_EXAMPLE" \
        "$RR_EXAMPLE" \
        "$RB_EXAMPLE" \
        "$UE_EXAMPLE"
    do
        if [ ! -f "$file" ]; then
            echo "ERROR: Missing srsRAN example:"
            echo "$file"
            exit 1
        fi
    done

    echo
    echo "Copying version-matched srsRAN examples..."

    cp "$ENB_EXAMPLE" "$ENB_CONF"
    cp "$SIB_EXAMPLE" "$CONFIG_DIR/sib.conf"
    cp "$RR_EXAMPLE" "$CONFIG_DIR/rr.conf"
    cp "$RB_EXAMPLE" "$CONFIG_DIR/rb.conf"
    cp "$UE_EXAMPLE" "$UE_CONF"

    echo "srsRAN configuration files created."

    echo
    echo "Patching eNB configuration..."

    python3 - "$ENB_CONF" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

def replace(text, old, new):
    if old in text:
        return text.replace(old, new, 1)
    return text

text = replace(text, "mcc = 001", "mcc = 901")
text = replace(text, "mnc = 01", "mnc = 70")

text = replace(text, "#device_name = zmq", "device_name = zmq")
text = replace(
    text,
    "#device_args = fail_on_disconnect=true,tx_port=tcp://*:2000,rx_port=tcp://localhost:2001,id=enb,base_srate=23.04e6",
    "device_args = fail_on_disconnect=true,tx_port=tcp://*:2000,rx_port=tcp://127.0.0.1:2001,id=enb,base_srate=23.04e6"
)

path.write_text(text)
PY

    echo
    echo "Patching RR configuration..."

    python3 - "$CONFIG_DIR/rr.conf" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

text = text.replace("tac = 0x0001", "tac = 0x0007")
text = text.replace("tac = 0x0007", "tac = 0x0007")

path.write_text(text)
PY

    echo
    echo "Patching UE configuration..."

    python3 - "$UE_CONF" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

def replace(text, old, new):
    if old in text:
        return text.replace(old, new, 1)
    return text

# ZMQ
text = replace(text, "#device_name = zmq", "device_name = zmq")

text = replace(
    text,
    "#device_args = tx_port=tcp://*:2001,rx_port=tcp://localhost:2000,id=ue,base_srate=23.04e6",
    "device_args = tx_port=tcp://*:2001,rx_port=tcp://127.0.0.1:2000,id=ue,base_srate=23.04e6"
)

# USIM
text = replace(text, "imsi = 001010123456780", "imsi = 901700123456789")
text = replace(
    text,
    "opc  = 63BFA50EE6523365FF14C1F45F88737D",
    "opc  = 63BFA50EE6523365FF14C1F45F88737D"
)
text = replace(
    text,
    "k    = 00112233445566778899aabbccddeeff",
    "k    = 00112233445566778899aabbccddeeff"
)

# APN
text = replace(text, "apn = srsapn", "apn = internet")

# Remove old invalid pcap.filename if present.
lines = []
for line in text.splitlines():
    stripped = line.strip()

    if stripped.startswith("filename =") and "[pcap]" in "":
        continue

    if stripped == "pcap.filename":
        continue

    lines.append(line)

text = "\n".join(lines) + "\n"

path.write_text(text)
PY

    echo
    echo "Forcing valid UE PCAP configuration..."

    python3 - "$UE_CONF" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

lines = text.splitlines()

out = []
inside_pcap = False

for line in lines:

    stripped = line.strip()

    if stripped.startswith("["):
        inside_pcap = stripped == "[pcap]"

    if inside_pcap:
        if stripped.startswith("filename ="):
            continue

    out.append(line)

text = "\n".join(out) + "\n"

path.write_text(text)
PY

    echo
    echo "Checking generated configuration files..."

    ls -lh \
        "$ENB_CONF" \
        "$CONFIG_DIR/sib.conf" \
        "$CONFIG_DIR/rr.conf" \
        "$CONFIG_DIR/rb.conf" \
        "$UE_CONF"

    echo
    echo "============================================================"
    echo "eNB RF configuration"
    echo "============================================================"

    grep -A8 -B3 \
        -E "device_name|device_args" \
        "$ENB_CONF" || true

    echo
    echo "============================================================"
    echo "UE RF configuration"
    echo "============================================================"

    grep -A8 -B3 \
        -E "device_name|device_args" \
        "$UE_CONF" || true

    echo
    echo "============================================================"
    echo "UE USIM"
    echo "============================================================"

    grep -A12 \
        "^\[usim\]" \
        "$UE_CONF" || true

    echo
    echo "srsRAN configuration preparation complete."
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

    prepare_srsran_configs

    echo
    echo "Configuring Open5GS MME PLMN/TAC..."

    sudo python3 - <<'PY'
from pathlib import Path

path = Path("/etc/open5gs/mme.yaml")
text = path.read_text()

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

        if "mcc:" in line and not line.lstrip().startswith("#"):
            lines[i] = "        mcc: 901"

        elif "mnc:" in line and not line.lstrip().startswith("#"):
            lines[i] = "        mnc: 70"

    elif section == "tai":

        if "mcc:" in line and not line.lstrip().startswith("#"):
            lines[i] = "        mcc: 901"

        elif "mnc:" in line and not line.lstrip().startswith("#"):
            lines[i] = "        mnc: 70"

        elif "tac:" in line and not line.lstrip().startswith("#"):
            lines[i] = "      tac: 7"

path.write_text("\n".join(lines) + "\n")
PY

    echo
    echo "MME PLMN/TAC:"

    sudo grep -A18 -E \
        "gummei:|tai:" \
        /etc/open5gs/mme.yaml || true

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
        -j MASQUERADE \
        2>/dev/null || true

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

    sudo grep -A18 -E \
        "gummei:|tai:" \
        /etc/open5gs/mme.yaml || true
}

start_enb() {

    log "Starting srsENB"

    mkdir -p "$LAB_DIR"

    if pgrep -x srsenb >/dev/null 2>&1; then
        echo "srsENB is already running."
        return
    fi

    if [ ! -f "$ENB_CONF" ]; then
        echo "ERROR: $ENB_CONF not found."
        exit 1
    fi

    for file in \
        "$CONFIG_DIR/sib.conf" \
        "$CONFIG_DIR/rr.conf" \
        "$CONFIG_DIR/rb.conf"
    do
        if [ ! -f "$file" ]; then
            echo "ERROR: Missing eNB configuration:"
            echo "$file"
            exit 1
        fi
    done

    echo "Starting srsENB from configuration directory..."

    (
        cd "$CONFIG_DIR"

        srsenb "$ENB_CONF"
    ) > "$LAB_DIR/srsenb.log" 2>&1 &

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

    tail -n 200 \
        "$LAB_DIR/srsenb.log" || true

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

    if [ ! -f "$UE_CONF" ]; then
        echo "ERROR: $UE_CONF not found."
        exit 1
    fi

    echo "Starting srsUE inside ue1 namespace..."

    timeout 120 \
        ip netns exec ue1 \
        bash -c "
            cd '$CONFIG_DIR'
            exec srsue '$UE_CONF'
        " \
        > "$LAB_DIR/srsue.log" 2>&1 \
        || true

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
        -j MASQUERADE \
        2>/dev/null || true

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
