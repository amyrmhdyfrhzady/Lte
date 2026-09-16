#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_DIR="/tmp/lte-lab"
CONFIG_DIR="$PROJECT_DIR/configs"
SRSRAN_DIR="$PROJECT_DIR/srsRAN_4G"

mkdir -p "$LAB_DIR" "$CONFIG_DIR"

log() {
    echo
    echo "========== $* =========="
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

prepare_srsran_configs() {
    log "Preparing fresh srsRAN configs"

    # Always overwrite generated configs.
    # This prevents stale configs from previous runs.
    cp -f "$SRSRAN_DIR/srsenb/enb.conf.example" "$CONFIG_DIR/enb.conf"
    cp -f "$SRSRAN_DIR/srsenb/sib.conf.example" "$CONFIG_DIR/sib.conf"
    cp -f "$SRSRAN_DIR/srsenb/rr.conf.example" "$CONFIG_DIR/rr.conf"
    cp -f "$SRSRAN_DIR/srsenb/rb.conf.example" "$CONFIG_DIR/rb.conf"
    cp -f "$SRSRAN_DIR/srsue/ue.conf.example" "$CONFIG_DIR/ue.conf"

    python3 - "$CONFIG_DIR/enb.conf" "$CONFIG_DIR/ue.conf" <<'PY'
import sys
from pathlib import Path

enb_path = Path(sys.argv[1])
ue_path = Path(sys.argv[2])


def set_section_value(text, section, key, value):
    lines = text.splitlines()

    start = None
    end = len(lines)

    for i, line in enumerate(lines):
        s = line.strip()

        if s.startswith("[") and s.endswith("]"):
            if start is not None:
                end = i
                break

            if s[1:-1].strip() == section:
                start = i

    if start is None:
        raise RuntimeError(f"section [{section}] not found")

    key_prefix = key + " ="
    found = False
    output = []

    for i, line in enumerate(lines):
        if start <= i < end:
            stripped = line.strip()

            if stripped.startswith(key_prefix):
                if not found:
                    indent = line[:len(line) - len(line.lstrip())]
                    output.append(f"{indent}{key} = {value}")
                    found = True
                else:
                    # Remove duplicate key.
                    continue
            else:
                output.append(line)
        else:
            output.append(line)

    if not found:
        raise RuntimeError(
            f"key '{key}' not found in section [{section}]"
        )

    return "\n".join(output) + "\n"


# ------------------------------------------------------------
# eNB
# ------------------------------------------------------------

enb = enb_path.read_text()

# Open5GS MME SCTP listener.
enb = set_section_value(
    enb,
    "mme",
    "mme_addr",
    "127.0.0.2"
)

# ZMQ RF.
enb = set_section_value(
    enb,
    "rf",
    "device_args",
    "fail_on_disconnect=true,tx_port=tcp://*:2000,rx_port=tcp://127.0.0.1:2001,id=enb,base_srate=23.04e6"
)

enb_path.write_text(enb)


# ------------------------------------------------------------
# UE
# ------------------------------------------------------------

ue = ue_path.read_text()

# Set IMSI only inside [usim].
ue = set_section_value(
    ue,
    "usim",
    "imsi",
    "901700123456789"
)

# Set APN only inside [nas].
# This replaces the existing option instead of adding another one.
ue = set_section_value(
    ue,
    "nas",
    "apn",
    "internet"
)

# ZMQ RF.
ue = set_section_value(
    ue,
    "rf",
    "device_args",
    "tx_port=tcp://*:2001,rx_port=tcp://127.0.0.1:2000,id=ue,base_srate=23.04e6"
)

ue_path.write_text(ue)
PY

    # Make sure old filename overrides cannot interfere.
    sed -i '/^[[:space:]]*filename[[:space:]]*=/d' "$CONFIG_DIR/ue.conf"

    echo "Fresh configs prepared:"
    ls -lh \
        "$CONFIG_DIR/enb.conf" \
        "$CONFIG_DIR/sib.conf" \
        "$CONFIG_DIR/rr.conf" \
        "$CONFIG_DIR/rb.conf" \
        "$CONFIG_DIR/ue.conf"
}


configure_open5gs() {
    log "Configuring Open5GS"

    local IMSI="901700123456789"
    local K="00112233445566778899AABBCCDDEEFF"
    local OPC="63BFA50EE6523365FF14C1F45F88737D"
    local AMF="8000"

    mkdir -p "$LAB_DIR/open5gs"

    # MME
    if [[ -f /etc/open5gs/mme.yaml ]]; then
        sudo cp /etc/open5gs/mme.yaml "$LAB_DIR/mme.yaml"

        sudo sed -i \
            -e 's/127\.0\.0\.2/127.0.0.2/g' \
            -e 's/127\.0\.0\.1/127.0.0.2/g' \
            /etc/open5gs/mme.yaml || true
    fi

    # Keep the existing Open5GS setup if already configured.
    # Subscriber creation is handled below through mongosh/open5gs-dbctl.
    if command -v open5gs-dbctl >/dev/null 2>&1; then
        open5gs-dbctl add "$IMSI" "$K" "$OPC" "$AMF" || true
    fi
}


setup_network() {
    log "Setting up virtual LTE network"

    sudo ip netns del ue1 2>/dev/null || true
    sudo ip link del ogstun 2>/dev/null || true

    sudo ip netns add ue1

    sudo ip tuntap add name ogstun mode tun
    sudo ip addr add 10.45.0.1/16 dev ogstun
    sudo ip link set ogstun up

    sudo ip link set lo up

    sudo iptables -t nat -C POSTROUTING \
        -s 10.45.0.0/16 \
        -j MASQUERADE 2>/dev/null || \
    sudo iptables -t nat -A POSTROUTING \
        -s 10.45.0.0/16 \
        -j MASQUERADE

    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
}


restart_core() {
    log "Restarting Open5GS"

    sudo systemctl restart open5gs-mmed 2>/dev/null || true
    sudo systemctl restart open5gs-sgwcd 2>/dev/null || true
    sudo systemctl restart open5gs-smfd 2>/dev/null || true
    sudo systemctl restart open5gs-upfd 2>/dev/null || true
    sudo systemctl restart open5gs-pgwd 2>/dev/null || true
    sudo systemctl restart open5gs-hssd 2>/dev/null || true
    sudo systemctl restart open5gs-pcrfd 2>/dev/null || true

    sleep 3
}


check_mme() {
    log "Checking MME SCTP listener"

    if command -v ss >/dev/null 2>&1; then
        ss -lnp | grep 36412 || true
    fi

    if command -v lsof >/dev/null 2>&1; then
        sudo lsof -nP -iSCTP:36412 || true
    fi
}


start_enb() {
    log "Starting srsENB"

    pkill -f "$SRSRAN_DIR/srsenb/.*srsenb" 2>/dev/null || true

    "$SRSRAN_DIR/srsenb/src/srsenb" \
        "$CONFIG_DIR/enb.conf" \
        >"$LAB_DIR/srsenb.log" 2>&1 &

    ENB_PID=$!
    echo "$ENB_PID" > "$LAB_DIR/srsenb.pid"

    echo "srsENB PID: $ENB_PID"
}


start_ue() {
    log "Starting srsUE"

    pkill -f "$SRSRAN_DIR/srsue/.*srsue" 2>/dev/null || true

    "$SRSRAN_DIR/srsue/src/srsue" \
        "$CONFIG_DIR/ue.conf" \
        >"$LAB_DIR/srsue.log" 2>&1 &

    UE_PID=$!
    echo "$UE_PID" > "$LAB_DIR/srsue.pid"

    echo "srsUE PID: $UE_PID"
}


show_logs() {
    log "srsENB log"

    if [[ -f "$LAB_DIR/srsenb.log" ]]; then
        cat "$LAB_DIR/srsenb.log"
    fi

    log "srsUE log"

    if [[ -f "$LAB_DIR/srsue.log" ]]; then
        cat "$LAB_DIR/srsue.log"
    fi
}


cleanup() {
    log "Collecting artifacts"

    mkdir -p "$LAB_DIR/artifacts"

    cp -f "$CONFIG_DIR"/*.conf "$LAB_DIR/artifacts/" 2>/dev/null || true
    cp -f "$LAB_DIR"/*.log "$LAB_DIR/artifacts/" 2>/dev/null || true

    sudo ss -lnp 2>/dev/null > "$LAB_DIR/artifacts/listeners.txt" || true
    ip addr > "$LAB_DIR/artifacts/ip-addr.txt" 2>&1 || true
    ip route > "$LAB_DIR/artifacts/ip-route.txt" 2>&1 || true
}


main() {
    log "LTE LAB START"

    prepare_srsran_configs
    configure_open5gs
    setup_network
    restart_core
    check_mme
    start_enb

    sleep 3

    start_ue

    sleep 10

    show_logs
    cleanup

    log "LTE LAB FINISHED"
}

main "$@"
