#!/bin/bash
# =============================================================================
# Open5GS — start all 5G SA NFs in a single container
# Used by docker-compose.yml to run the full 5G Core in one process group.
# =============================================================================
set -eo pipefail

# ── Create TUN device for UPF ────────────────────────────────────────────────
if [ ! -c /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 666 /dev/net/tun
fi

if ! grep -q "ogstun" /proc/net/dev 2>/dev/null; then
    ip tuntap add name ogstun mode tun
    ip link set ogstun up
fi

ip addr del "${IPV4_TUN_ADDR:-10.45.0.1/16}" dev ogstun 2>/dev/null || true
ip addr add "${IPV4_TUN_ADDR:-10.45.0.1/16}" dev ogstun
ip link set ogstun up
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -A POSTROUTING -s "${IPV4_TUN_SUBNET:-10.45.0.0/16}" ! -o ogstun -j MASQUERADE

# ── Fix FreeDiameter resolution for 5G SA only ───────────────────────────────
echo "127.0.0.1 pcrf" >> /etc/hosts

# ── Start NFs in dependency order ────────────────────────────────────────────
# NRF must be first — all other NFs register with it.
NFS=(
    open5gs-nrfd
    open5gs-scpd
    open5gs-ausfd
    open5gs-udrd
    open5gs-udmd
    open5gs-pcfd
    open5gs-bsfd
    open5gs-nssfd
    open5gs-smfd
    open5gs-upfd
    open5gs-amfd
)

PIDS=()
for nf in "${NFS[@]}"; do
    echo "[open5gs] Starting ${nf}..."
    ${nf} -c /opt/open5gs/etc/open5gs/open5gs.yaml &
    PIDS+=($!)
    # Small stagger so NRF is discoverable before dependents register
    sleep 0.5
done

# ── Wait for any NF to exit (indicates a crash) ─────────────────────────────
wait -n "${PIDS[@]}" 2>/dev/null
echo "[open5gs] A network function exited — shutting down all NFs"
kill "${PIDS[@]}" 2>/dev/null
wait
exit 1
