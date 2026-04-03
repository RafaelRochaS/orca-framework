#!/usr/bin/env bash
# =============================================================================
# lab.sh — Main control script for the 5G Research Lab
# Usage: ./lab.sh [up|down|status|logs|restart|clean|ue|xapp]
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[LAB]${NC}   $*"; }
success() { echo -e "${GREEN}[LAB]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[LAB]${NC}   $*"; }
error()   { echo -e "${RED}[LAB]${NC}   $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
RIC_DIR="${SCRIPT_DIR}/repos/oran-sc-ric"
SUBSCRIBER_CSV="${SCRIPT_DIR}/config/open5gs/subscriber_db.csv"

usage() {
  echo ""
  echo -e "  ${CYAN}5G Research Lab — Control Script${NC}"
  echo ""
  echo "  Usage: ./lab.sh <command>"
  echo ""
  echo "  Commands:"
  echo "    up        Start all lab services (core → RIC → OOP → RAN)"
  echo "    down      Stop all lab services"
  echo "    restart   Restart all services"
  echo "    status    Show health of all containers"
  echo "    logs      Tail logs (optional: ./lab.sh logs <service>)"
  echo "    ue        Attach a UE to the running network"
  echo "    xapp      Launch a sample KPM monitoring xApp"
  echo "    build     Pre-build all source images (do this before first 'up')
    clean     Remove all containers, networks, volumes"
  echo "    shell     Open a shell in a running container"
  echo ""
}

# ── Startup sequence ──────────────────────────────────────────────────────────
# Order matters: 5GC must be up before gNB tries to register via N2 (SCTP/NGAP)
# RIC must be up before gNB tries to connect via E2
cmd_build() {
  echo ""
  warn "The OCUDU gNB and srsUE images must be compiled from source with ZMQ support."
  warn "This takes 15-25 minutes on first run (subsequent builds use layer cache)."
  echo ""
  info "Building OCUDU gNB (ZMQ-enabled)..."
  docker compose -f "${COMPOSE_FILE}" build ocudu-gnb
  info "Building srsUE (ZMQ-enabled, from srsRAN_4G)..."
  docker compose -f "${COMPOSE_FILE}" build srsue
  info "Building OOP Gateway (Open Exposure Gateway)..."
  docker compose -f "${COMPOSE_FILE}" build oop-gateway
  info "Building OOP Service Resource Manager..."
  docker compose -f "${COMPOSE_FILE}" build oop-orchestrator
  success "All images built. Run ./lab.sh up to start the lab."
}

cmd_up() {
  info "Starting 5G Research Lab..."
  echo ""

  # Pre-flight: check if gNB image exists — it needs a source build first
  if ! docker image inspect lab_ocudu_gnb:latest &>/dev/null; then
    warn "OCUDU image not found — a source build is required."
    warn "This will take 15-25 minutes on first run."
    read -rp "Build now? (yes/no): " confirm
    if [[ "${confirm}" == "yes" ]]; then
      cmd_build
    else
      error "Cannot start without the gNB image. Run: ./lab.sh build"
    fi
  fi

  # Step 1: 5G Core (Open5GS)
  info "Step 1/4 — Starting Open5GS 5G Core..."
  docker compose -f "${COMPOSE_FILE}" up -d mongodb open5gs
  info "  Waiting for AMF to become healthy..."
  _wait_healthy "open5gs" 90
  _provision_subscribers
  success "  Open5GS 5GC is up"

  # Step 2: O-RAN SC Near-RT RIC
  info "Step 2/4 — Starting O-RAN SC Near-RT RIC..."
  if [[ -d "${RIC_DIR}" && ! -f "${RIC_DIR}/.stub" ]]; then
    docker compose -f "${RIC_DIR}/docker-compose.yml" up -d
    info "  Waiting for RIC E2 termination (up to 60s)..."
    sleep 20  # RIC components need time to interconnect internally
    success "  Near-RT RIC is up"
  else
    warn "  RIC repo not found — skipping (run bootstrap.sh first)"
  fi

  # Step 3: ETSI OpenOP (CAMARA API Gateway + Orchestrator)
  info "Step 3/4 — Starting ETSI OpenOP (CAMARA layer)..."
  docker compose -f "${COMPOSE_FILE}" up -d oop-gateway oop-orchestrator
  _wait_healthy "oop-gateway" 60
  success "  OpenOP services are up"

  # Step 4: OCUDU gNB (connects to both 5GC and RIC)
  info "Step 4/4 — Starting OCUDU gNB (ZMQ)..."
  docker compose -f "${COMPOSE_FILE}" up -d ocudu-gnb
  sleep 5
  success "  OCUDU gNB started"

  echo ""
  cmd_status
  echo ""
  echo -e "${GREEN}Lab is running! Key endpoints:${NC}"
  echo -e "  Open5GS WebUI  → ${CYAN}http://localhost:9999${NC}"
  echo -e "  CAMARA API GW  → ${CYAN}http://localhost:8080${NC}"
  echo -e "  OOP Dashboard  → ${CYAN}http://localhost:8090${NC}"
  echo -e "  Grafana        → ${CYAN}http://localhost:3000${NC}  (admin/admin)"
  echo ""
  echo -e "  To attach a UE: ${YELLOW}./lab.sh ue${NC}"
}

cmd_down() {
  info "Stopping lab services..."
  docker compose -f "${COMPOSE_FILE}" down
  if [[ -d "${RIC_DIR}" ]]; then
    docker compose -f "${RIC_DIR}/docker-compose.yml" down 2>/dev/null || true
  fi
  success "Lab stopped"
}

cmd_status() {
  echo ""
  echo -e "${CYAN}═══ Lab Service Status ═══════════════════════════════${NC}"
  docker compose -f "${COMPOSE_FILE}" ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
  echo ""
  if [[ -d "${RIC_DIR}" ]]; then
    echo -e "${CYAN}═══ Near-RT RIC Status ════════════════════════════════${NC}"
    docker compose -f "${RIC_DIR}/docker-compose.yml" ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || \
      warn "RIC not running"
    echo ""
  fi
}

cmd_logs() {
  local service="${2:-}"
  if [[ -n "${service}" ]]; then
    docker compose -f "${COMPOSE_FILE}" logs -f "${service}"
  else
    docker compose -f "${COMPOSE_FILE}" logs -f --tail=50
  fi
}

cmd_ue() {
  _provision_subscribers
  info "Launching srsUE (ZMQ-based) and attaching to network..."
  docker compose -f "${COMPOSE_FILE}" up -d srsue
  info "UE container started. Tailing UE logs (Ctrl+C to detach):"
  sleep 2
  docker compose -f "${COMPOSE_FILE}" logs -f srsue
}

_provision_subscribers() {
  if [[ ! -f "${SUBSCRIBER_CSV}" ]]; then
    warn "Subscriber CSV not found at ${SUBSCRIBER_CSV}"
    return
  fi

  local imsi k opc amf sqn sst sd apn ip
  local provisioned=0
  while IFS=',' read -r imsi k opc amf sqn sst sd apn ip _; do
    # Skip comments and empty lines.
    imsi="${imsi//[[:space:]]/}"
    [[ -z "${imsi}" || "${imsi:0:1}" == "#" ]] && continue

    k="${k//[[:space:]]/}"
    opc="${opc//[[:space:]]/}"
    amf="${amf//[[:space:]]/}"
    apn="${apn//[[:space:]]/}"
    ip="${ip//[[:space:]]/}"

    if [[ -z "${k}" || -z "${opc}" ]]; then
      warn "Skipping subscriber ${imsi}: missing K or OPc"
      continue
    fi

    amf="${amf:-8000}"
    apn="${apn:-internet}"

    docker compose -f "${COMPOSE_FILE}" exec -T \
      -e IMSI="${imsi}" \
      -e KI="${k}" \
      -e OPC="${opc}" \
      -e AMF="${amf}" \
      -e APN="${apn}" \
      -e UE_IPV4="${ip}" \
      mongodb mongosh 'mongodb://localhost/open5gs' --quiet --eval '
        const imsi = process.env.IMSI;
        const apn = process.env.APN || "internet";
        const doc = {
          schema_version: NumberInt(1),
          imsi: imsi,
          msisdn: [], imeisv: [], mme_host: [], mm_realm: [], purge_flag: [],
          slice: [{
            sst: NumberInt(1),
            default_indicator: true,
            session: [{
              name: apn,
              type: NumberInt(3),
              qos: { index: NumberInt(9), arp: { priority_level: NumberInt(8), pre_emption_capability: NumberInt(1), pre_emption_vulnerability: NumberInt(2) } },
              ambr: {
                downlink: { value: NumberInt(1000000000), unit: NumberInt(0) },
                uplink: { value: NumberInt(1000000000), unit: NumberInt(0) }
              },
              pcc_rule: []
            }]
          }],
          security: {
            k: process.env.KI,
            op: null,
            opc: process.env.OPC,
            amf: process.env.AMF || "8000"
          },
          ambr: {
            downlink: { value: NumberInt(1000000000), unit: NumberInt(0) },
            uplink: { value: NumberInt(1000000000), unit: NumberInt(0) }
          },
          access_restriction_data: 32,
          network_access_mode: 0,
          subscriber_status: 0,
          operator_determined_barring: 0,
          subscribed_rau_tau_timer: 12,
          __v: 0
        };
        if (process.env.UE_IPV4) {
          doc.slice[0].session[0].ue = { ipv4: process.env.UE_IPV4 };
        }
        db.subscribers.updateOne({ imsi: imsi }, { $set: doc }, { upsert: true });
      ' >/dev/null

    provisioned=$((provisioned + 1))
  done < "${SUBSCRIBER_CSV}"

  if (( provisioned == 0 )); then
    warn "No valid subscriber rows found in ${SUBSCRIBER_CSV}"
  else
    success "  Provisioned ${provisioned} subscriber(s) from CSV"
  fi
}

cmd_xapp() {
  info "Launching KPM monitoring xApp..."
  if [[ ! -d "${RIC_DIR}" ]]; then
    error "RIC directory not found. Run bootstrap.sh first."
  fi
  info "This xApp subscribes to DRB.UEThpDl and DRB.UEThpUl from connected gNBs."
  docker compose -f "${RIC_DIR}/docker-compose.yml" \
    exec python_xapp_runner ./kpm_mon_xapp.py \
    --metrics=DRB.UEThpDl,DRB.UEThpUl \
    --kpm_report_style=5
}

cmd_clean() {
  warn "This will remove ALL lab containers, networks, and volumes!"
  read -rp "Are you sure? (yes/no): " confirm
  if [[ "${confirm}" != "yes" ]]; then
    info "Aborted."
    return
  fi
  docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
  if [[ -d "${RIC_DIR}" ]]; then
    docker compose -f "${RIC_DIR}/docker-compose.yml" down -v --remove-orphans 2>/dev/null || true
  fi
  success "Lab cleaned"
}

cmd_shell() {
  local service="${2:-open5gs}"
  info "Opening shell in ${service}..."
  docker compose -f "${COMPOSE_FILE}" exec "${service}" /bin/bash
}

_wait_healthy() {
  local service="$1"; local timeout="$2"; local elapsed=0
  while ! docker compose -f "${COMPOSE_FILE}" ps "${service}" \
    | grep -qE "(healthy|running)"; do
    sleep 3; elapsed=$((elapsed + 3))
    if (( elapsed >= timeout )); then
      warn "Timeout waiting for ${service} — continuing anyway"
      return
    fi
    echo -n "."
  done
  echo ""
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "${1:-help}" in
  build)   cmd_build ;;
  up)      cmd_up ;;
  down)    cmd_down ;;
  restart) cmd_down; cmd_up ;;
  status)  cmd_status ;;
  logs)    cmd_logs "$@" ;;
  ue)      cmd_ue ;;
  xapp)    cmd_xapp ;;
  clean)   cmd_clean ;;
  shell)   cmd_shell "$@" ;;
  *)       usage ;;
esac
