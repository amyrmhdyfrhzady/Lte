#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

LAB_DIR="/tmp/lte-lab"
CONFIG_DIR="$PROJECT_DIR/configs"
SRSRAN_DIR="$PROJECT_DIR/srsRAN_4G"

ENB_CONF="$CONFIG_DIR/enb.conf"
UE_CONF="$CONFIG_DIR/ue.conf"

MME_ADDR="127.0.0.2"
MME_SCTP_PORT="36412"

IMSI="901700123456789"
K="00112233445566778899AABBCCDDEEFF"
OPC="63BFA50EE6523365FF14C1F45F88737D"
APN="internet"

MCC="901"
MNC="70"
TAC="7"

mkdir -p "$LAB_DIR" "$CONFIG_DIR"

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

prepare_srsran_configs() {
    log "Preparing srsRAN configuration files"

    if [[ ! -f "$CONFIG_DIR/enb.conf" ]]; then
        cp "$SRSRAN_DIR/srsenb/enb.conf.example" "$CONFIG_DIR/enb.conf"
    fi

    if [[ ! -f "$CONFIG_DIR/sib.conf" ]]; then
        cp "$SRSRAN_DIR/srsenb/sib.conf.example" "$CONFIG_DIR/sib.conf"
    fi

    if [[ ! -f "$CONFIG_DIR/rr.conf" ]]; then
        cp "$SRSRAN_DIR/srsenb/rr.conf.example" "$CONFIG_DIR/rr.conf"
    fi

    if [[ ! -f "$CONFIG_DIR/rb.conf" ]]; then
        cp "$SRSRAN_DIR/srsenb/rb.conf.example" "$CONFIG_DIR/rb.conf"
    fi

    if [[ ! -f "$CONFIG_DIR/ue.conf" ]]; then
        cp "$SRSRAN_DIR/srsue/ue.conf.example" "$CONFIG_DIR/ue.conf"
    fi

    python3 - "$ENB_CONF" "$UE_CONF" <<'PY'
import sys
from pathlib import Path

enb = Path(sys.argv[1])
ue = Path(sys.argv[2])

def replace_or_add(text, key, value):
    lines = text.splitlines()
    found = False
    out = []

    for line in lines:
        stripped = line.strip()

        if stripped.startswith(key) and "=" in stripped:
            indent = line[:len(line) - len(line.lstrip())]
            out.append(f"{indent}{key} = {value}")
            found = True
        else:
            out.append(line)

    if not found:
        out.append(f"{key} = {value}")

    return "\n".join(out) + "\n"

text = enb.read_text()

text = replace_or_add(text, "mme_addr", "127.0.0.2")
text = replace_or_add(
    text,
    "device_args",
    "fail_on_disconnect=true,tx_port=tcp://*:2000,rx_port=tcp://127.0.0.1:2001,id=enb,base_srate=23.04e6"
)

# Make sure the test PLMN is used.
text = text.replace("mcc = 001", "mcc = 901")
text = text.replace("mnc = 01", "mnc = 70")

enb.write_text(text)

text = ue.read_text()

text = replace_or_add(
    text,
    "device_args",
    "tx_port=tcp://*:2001,rx_port=tcp://127.0.0.1:2000,id=ue,base_srate=23.04e6"
)

text = replace_or_add(text, "imsi", "901700123456789")
text = replace_or_add(text, "apn", "internet")

ue.write_text(text)
PY

    # Remove pcap filename because recent srsUE rejects invalid/default
    # pcap filename configurations.
    sed -i '/^[[:space:]]*filename[[:space:]]*=/d' "$UE_CONF"

    echo
    echo "eNB MME configuration:"
    grep -nE '^[[:space:]]*mme_addr[[:space:]]*=' "$ENB_CONF" || true

    echo
    echo "eNB ZMQ configuration:"
    grep -nE '^[[:space:]]*device_args[[:space:]]*=' "$ENB_CONF" || true

    echo
    echo "UE ZMQ configuration:"
    grep -nE '^[[:space:]]*device_args[[:space:]]*=' "$UE_CONF" || true
}

prepare_open5gs() {
    log "Preparing Open5GS"

    mkdir -p "$LAB_DIR/open5gs"

    # Configure MME PLMN and TAC.
    if [[ -f /etc/open5gs/mme.yaml ]]; then
        cp /etc/open5gs/mme.yaml "$LAB_DIR/mme.yaml.backup" || true

        python3 - <<'PY'
from pathlib import Path

path = Path("/etc/open5gs/mme.yaml")

if path.exists():
    text = path.read_text()

    text = text.replace(
        "mcc: 999",
        "mcc: 901"
    )

    text = text.replace(
        "mnc: 70",
        "mnc: 70"
    )

    path.write_text(text)
PY
    fi

    # Ensure the MME configuration contains the required test PLMN/TAC.
    python3 - <<'PY'
from pathlib import Path

path = Path("/etc/open5gs/mme.yaml")

if not path.exists():
    raise SystemExit("Open5GS MME configuration not found")

text = path.read_text()

# Keep the existing configuration intact and only normalize the
# test PLMN/TAC values where they already occur.
text = text.replace(
    "mcc: 001",
    "mcc: 901"
)

text = text.replace(
    "mnc: 01",
    "mnc: 70"
)

path.write_text(text)
PY

    # Test namespace used by the UE.
    ip netns del ue1 2>/dev/null || true
    ip netns add ue1

    # Create the Open5GS tunnel interface if it does not already exist.
    ip link del ogstun 2>/dev/null || true

    ip tuntap add name ogstun mode tun
    ip addr add 10.45.0.1/16 dev ogstun
    ip link set ogstun up

    # Enable forwarding.
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    # NAT for the simulated UE network.
    iptables -t nat -D POSTROUTING -s 10.45.0.0/16 -j MASQUERADE 2>/dev/null || true
    iptables -t nat -A POSTROUTING -s 10.45.0.0/16 -j MASQUERADE

    # Insert test subscriber.
    if command -v mongosh >/dev/null 2>&1; then
        mongosh open5gs --quiet <<EOF || true
db.subscribers.updateOne(
  { imsi: "$IMSI" },
  {
    \$set: {
      imsi: "$IMSI",
      security: {
        k: "$K",
        opc: "$OPC",
        amf: "8000"
      },
      slice: [
        {
          sst: 1,
          default_indicator: true,
          session: [
            {
              name: "$APN",
              type: 3,
              qos: {
                index: 9,
                arp: {
                  priority: 8,
                  pre_emption_capability: 1,
                  pre_emption_vulnerability: 1
                }
              }
            }
          ]
        }
      ]
    }
  },
  { upsert: true }
)
EOF
    elif command -v mongo >/dev/null 2>&1; then
        mongo open5gs --quiet <<EOF || true
db.subscribers.updateOne(
  { imsi: "$IMSI" },
  {
    \$set: {
      imsi: "$IMSI",
      security: {
        k: "$K",
        opc: "$OPC",
        amf: "8000"
      }
    }
  },
  { upsert: true }
)
EOF
    fi
}

start_core() {
    log "Starting Open5GS core"

    systemctl restart mongod || true
    sleep 2

    systemctl restart open5gs-hssd || true
    systemctl restart open5gs-pcrfd || true
    systemctl restart open5gs-mmed || true
    systemctl restart open5gs-sgwcd || true
    systemctl restart open5gs-smfd || true
    systemctl restart open5gs-sgwud || true
    systemctl restart open5gs-upfd || true

    sleep 5

    echo
    echo "Open5GS service status:"
    systemctl --no-pager --full status open5gs-mmed || true

    echo
    echo "Checking MME SCTP listener..."

    if command -v ss >/dev/null 2>&1; then
        ss -lnp | grep -E '127\.0\.0\.2:36412|36412' || true
    fi
}

check_mme() {
    log "Checking MME S1 endpoint"

    echo "Expected MME:"
    echo "  Address : $MME_ADDR"
    echo "  SCTP    : $MME_SCTP_PORT"

    echo
    echo "Current SCTP listeners:"

    if command -v ss >/dev/null 2>&1; then
        ss -lnp | grep -E 'sctp|36412' || true
    fi

    echo

    # Do not fail the complete lab only because ss output formatting differs.
    # The important check is whether the MME listener exists.
    if ss -Hlnp 2>/dev/null | grep -qE "127\.0\.0\.2:${MME_SCTP_PORT}"; then
        echo "MME SCTP listener detected on $MME_ADDR:$MME_SCTP_PORT"
    else
        echo "WARNING: MME SCTP listener was not detected on $MME_ADDR:$MME_SCTP_PORT"
        echo "Open5GS MME may still be starting. Waiting..."
        sleep 3

        if ss -Hlnp 2>/dev/null | grep -qE "127\.0\.0\.2:${MME_SCTP_PORT}"; then
            echo "MME SCTP listener detected after waiting."
        else
            echo "WARNING: MME SCTP listener is still not visible."
            echo "Continuing so the srsENB log can show the actual failure."
        fi
    fi
}

start_enb() {
    log "Starting srsENB"

    # Force the correct MME address one more time immediately before
    # starting srsENB. This prevents an old generated config from being used.
    python3 - "$ENB_CONF" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

lines = text.splitlines()
found = False
out = []

for line in lines:
    if line.strip().startswith("mme_addr") and "=" in line:
        indent = line[:len(line) - len(line.lstrip())]
        out.append(f"{indent}mme_addr = 127.0.0.2")
        found = True
    else:
        out.append(line)

if not found:
    out.append("mme_addr = 127.0.0.2")

path.write_text("\n".join(out) + "\n")
PY

    echo
    echo "Final eNB MME address:"
    grep -nE '^[[:space:]]*mme_addr[[:space:]]*=' "$ENB_CONF"

    echo
    echo "Starting srsENB..."

    (
        cd "$CONFIG_DIR"
        exec srsenb "$ENB_CONF"
    ) > "$LAB_DIR/srsenb.log" 2>&1 &

    ENB_PID=$!
    echo "$ENB_PID" > "$LAB_DIR/srsenb.pid"

    echo "srsENB PID: $ENB_PID"

    sleep 8

    echo
    echo "Recent srsENB log:"
    tail -n 80 "$LAB_DIR/srsenb.log" || true
}

test_ue() {
    log "Starting srsUE"

    (
        ip netns exec ue1 bash -c "
            cd '$CONFIG_DIR'
            exec srsue '$UE_CONF'
        "
    ) > "$LAB_DIR/srsue.log" 2>&1 &

    UE_PID=$!
    echo "$UE_PID" > "$LAB_DIR/srsue.pid"

    echo "srsUE PID: $UE_PID"

    sleep 15

    echo
    echo "Recent srsUE log:"
    tail -n 100 "$LAB_DIR/srsue.log" || true
}

collect_status() {
    log "Collecting LTE lab status"

    echo
    echo "=== Open5GS MME ==="
    systemctl --no-pager --full status open5gs-mmed || true

    echo
    echo "=== SCTP ==="
    ss -lnp 2>/dev/null | grep -E '36412|sctp' || true

    echo
    echo "=== srsENB ==="
    if [[ -f "$LAB_DIR/srsenb.log" ]]; then
        tail -n 150 "$LAB_DIR/srsenb.log"
    fi

    echo
    echo "=== srsUE ==="
    if [[ -f "$LAB_DIR/srsue.log" ]]; then
        tail -n 150 "$LAB_DIR/srsue.log"
    fi

    echo
    echo "=== Network ==="
    ip addr show ogstun 2>/dev/null || true

    echo
    echo "=== Open5GS API UE info ==="
    curl -sS --max-time 5 \
        http://127.0.0.2:9090/ue-info 2>/dev/null || true

    echo
    echo
    echo "=== Open5GS API eNB info ==="
    curl -sS --max-time 5 \
        http://127.0.0.2:9090/enb-info 2>/dev/null || true
}

stop() {
    log "Stopping LTE lab"

    if [[ -f "$LAB_DIR/srsue.pid" ]]; then
        kill "$(cat "$LAB_DIR/srsue.pid")" 2>/dev/null || true
    fi

    if [[ -f "$LAB_DIR/srsenb.pid" ]]; then
        kill "$(cat "$LAB_DIR/srsenb.pid")" 2>/dev/null || true
    fi

    pkill -f "srsue.*ue.conf" 2>/dev/null || true
    pkill -f "srsenb.*enb.conf" 2>/dev/null || true

    ip netns del ue1 2>/dev/null || true

    iptables -t nat -D POSTROUTING -s 10.45.0.0/16 -j MASQUERADE 2>/dev/null || true

    ip link del ogstun 2>/dev/null || true
}

case "${1:-}" in
    prepare)
        prepare_srsran_configs
        prepare_open5gs
        ;;

    start-core)
        start_core
        check_mme
        ;;

    start-enb)
        check_mme
        start_enb
        ;;

    test-ue)
        test_ue
        ;;

    status)
        collect_status
        ;;

    stop)
        stop
        ;;

    all)
        prepare_srsran_configs
        prepare_open5gs
        start_core
        check_mme
        start_enb
        test_ue
        collect_status
        ;;

    *)
        echo "Usage:"
        echo "  $0 prepare"
        echo "  $0 start-core"
        echo "  $0 start-enb"
        echo "  $0 test-ue"
        echo "  $0 status"
        echo "  $0 stop"
        echo "  $0 all"
        exit 1
        ;;
esac
