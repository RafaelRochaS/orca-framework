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
RIC_COMPOSE_FILE="${RIC_DIR}/docker-compose.yml"
SUBSCRIBER_CSV="${SCRIPT_DIR}/config/open5gs/subscriber_db.csv"
RIC_E2TERM_CONTAINER="ric_e2term"
RIC_DBAAS_CONTAINER="ric_dbaas"
RIC_XAPP_RUNNER_SERVICE="python_xapp_runner"
LAB_RAN_NETWORK="lab_ran"
RIC_E2TERM_RAN_IP="10.53.2.100"
GNB_RAN_IP="10.53.2.30"
XAPP_HTTP_PORT="8099"
XAPP_RMR_PORT="4572"
XAPP_METRICS="DRB.UEThpDl,DRB.UEThpUl"
XAPP_REPORT_STYLE="5"

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
  echo "    xapp      Launch KPM monitoring xApp for the active gNB node"
  echo "    build     Pre-build all source images (do this before first 'up')"
  echo "    clean     Remove all containers, networks, volumes"
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
  local ric_enabled=false
  local ran_node_id=""

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
    ric_enabled=true
    docker compose -f "${RIC_COMPOSE_FILE}" up -d
    info "  Waiting for RIC E2 termination (up to 60s)..."
    sleep 20  # RIC components need time to interconnect internally
    _attach_e2term_to_lab_ran || warn "  Could not auto-attach e2term to ${LAB_RAN_NETWORK}"
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

  if [[ "${ric_enabled}" == "true" ]]; then
    info "  Waiting for gNB ↔ e2term SCTP association..."
    if _wait_for_e2_association 90; then
      success "  E2 SCTP association detected"
    else
      warn "  E2 SCTP association was not detected within timeout"
    fi

    info "  Resolving active RAN node ID from RIC..."
    ran_node_id="$(_wait_for_ran_node_id 90 || true)"
    if [[ -n "${ran_node_id}" ]]; then
      success "  Active RAN node: ${ran_node_id}"
      info "  Launching KPM xApp for ${ran_node_id}..."
      if _launch_xapp_for_ran_node "${ran_node_id}"; then
        if _wait_for_subscription_for_ran_node "${ran_node_id}" 60; then
          success "  xApp subscription is active for ${ran_node_id}"
        else
          warn "  xApp launched but subscription validation timed out"
        fi
      else
        warn "  Failed to launch xApp automatically"
      fi
    else
      warn "  Could not resolve a RAN node ID from RIC; skipping auto xApp launch"
    fi
  fi

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
  docker rm -f lab_ue >/dev/null 2>&1 || true
  if [[ -d "${RIC_DIR}" ]]; then
    docker compose -f "${RIC_COMPOSE_FILE}" down 2>/dev/null || true
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
    docker compose -f "${RIC_COMPOSE_FILE}" ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || \
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
  _attach_e2term_to_lab_ran || warn "Could not auto-attach e2term to ${LAB_RAN_NETWORK}"

  local ran_node_id
  ran_node_id="$(_wait_for_ran_node_id 60 || true)"
  if [[ -z "${ran_node_id}" ]]; then
    error "No active RAN node found in RIC state. Ensure gNB is connected first."
  fi

  info "Using RAN node ID: ${ran_node_id}"
  info "This xApp subscribes to ${XAPP_METRICS} from the connected gNB."
  _launch_xapp_for_ran_node "${ran_node_id}" || error "Failed to launch xApp"

  if _wait_for_subscription_for_ran_node "${ran_node_id}" 60; then
    success "xApp subscription is active for ${ran_node_id}"
  else
    warn "xApp launched but subscription validation timed out"
  fi
}

cmd_clean() {
  warn "This will remove ALL lab containers, networks, and volumes!"
  read -rp "Are you sure? (yes/no): " confirm
  if [[ "${confirm}" != "yes" ]]; then
    info "Aborted."
    return
  fi
  docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
  docker rm -f lab_ue >/dev/null 2>&1 || true
  if [[ -d "${RIC_DIR}" ]]; then
    docker compose -f "${RIC_COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
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

_attach_e2term_to_lab_ran() {
  if ! docker network inspect "${LAB_RAN_NETWORK}" >/dev/null 2>&1; then
    warn "  ${LAB_RAN_NETWORK} network is not available yet"
    return 1
  fi
  if ! docker inspect "${RIC_E2TERM_CONTAINER}" >/dev/null 2>&1; then
    warn "  ${RIC_E2TERM_CONTAINER} container is not running"
    return 1
  fi

  local attached_ip
  attached_ip="$(docker inspect -f "{{with index .NetworkSettings.Networks \"${LAB_RAN_NETWORK}\"}}{{.IPAddress}}{{end}}" "${RIC_E2TERM_CONTAINER}" 2>/dev/null || true)"

  if [[ -z "${attached_ip}" ]]; then
    if docker network connect --ip "${RIC_E2TERM_RAN_IP}" "${LAB_RAN_NETWORK}" "${RIC_E2TERM_CONTAINER}" >/dev/null 2>&1; then
      success "  Attached ${RIC_E2TERM_CONTAINER} to ${LAB_RAN_NETWORK} (${RIC_E2TERM_RAN_IP})"
      return 0
    fi
    warn "  Failed to attach ${RIC_E2TERM_CONTAINER} to ${LAB_RAN_NETWORK}"
    return 1
  fi

  if [[ "${attached_ip}" != "${RIC_E2TERM_RAN_IP}" ]]; then
    warn "  ${RIC_E2TERM_CONTAINER} uses ${attached_ip} on ${LAB_RAN_NETWORK} (expected ${RIC_E2TERM_RAN_IP})"
  else
    success "  ${RIC_E2TERM_CONTAINER} already attached to ${LAB_RAN_NETWORK} (${attached_ip})"
  fi
  return 0
}

_wait_for_e2_association() {
  local timeout="$1"
  local elapsed=0

  while true; do
    if docker exec "${RIC_E2TERM_CONTAINER}" sh -lc "grep -q '${GNB_RAN_IP}' /proc/net/sctp/assocs" >/dev/null 2>&1; then
      return 0
    fi

    sleep 3
    elapsed=$((elapsed + 3))
    if (( elapsed >= timeout )); then
      return 1
    fi
  done
}

_resolve_ran_node_id() {
  docker exec "${RIC_DBAAS_CONTAINER}" redis-cli --raw KEYS '{e2Manager},RAN:*' 2>/dev/null \
    | sed -n 's/^{e2Manager},RAN://p' \
    | head -n 1
}

_wait_for_ran_node_id() {
  local timeout="$1"
  local elapsed=0
  local ran_node_id=""

  while true; do
    ran_node_id="$(_resolve_ran_node_id || true)"
    if [[ -n "${ran_node_id}" ]]; then
      echo "${ran_node_id}"
      return 0
    fi

    sleep 3
    elapsed=$((elapsed + 3))
    if (( elapsed >= timeout )); then
      return 1
    fi
  done
}

_launch_xapp_for_ran_node() {
  local ran_node_id="$1"

  docker compose -f "${RIC_COMPOSE_FILE}" restart "${RIC_XAPP_RUNNER_SERVICE}" >/dev/null 2>&1 || true
  sleep 2

  docker compose -f "${RIC_COMPOSE_FILE}" exec -d "${RIC_XAPP_RUNNER_SERVICE}" \
    python3 ./kpm_mon_xapp.py \
    --metrics="${XAPP_METRICS}" \
    --kpm_report_style="${XAPP_REPORT_STYLE}" \
    --http_server_port "${XAPP_HTTP_PORT}" \
    --rmr_port "${XAPP_RMR_PORT}" \
    --e2_node_id "${ran_node_id}" >/dev/null
}

_wait_for_subscription_for_ran_node() {
  local ran_node_id="$1"
  local timeout="$2"
  local elapsed=0

  while true; do
    if docker exec "${RIC_DBAAS_CONTAINER}" sh -lc "for k in \$(redis-cli --raw KEYS '{submgr_e2SubsDb},*'); do redis-cli --raw GET \"\$k\"; done" 2>/dev/null \
      | grep -Fq "\"RanName\":\"${ran_node_id}\""; then
      return 0
    fi

    sleep 3
    elapsed=$((elapsed + 3))
    if (( elapsed >= timeout )); then
      return 1
    fi
  done
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
