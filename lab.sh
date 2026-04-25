#!/usr/bin/env bash
# =============================================================================
# lab.sh — Main control script for the 5G Research Lab
# Usage: ./lab.sh [up|down|status|logs|restart|clean|ue|xapp|xapp-health|validate]
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
# Must match RMR_SEED_RT (12050 route targets 4560/4561/4562 in this RIC image).
XAPP_RMR_PORT="4562"
XAPP_METRICS="DRB.UEThpDl,DRB.UEThpUl"
# Style 1 is robust for validation; style 5 needs valid UE IDs and may stay silent.
XAPP_REPORT_STYLE="1"
XAPP_HEALTH_HTTP_PORT="18099"
XAPP_HEALTH_RMR_PORT="4561"
UE_TUN_IFACE="tun_srsue"
UE_UPF_GATEWAY_IP="10.45.0.1"
UE_RAN_IFACE="eth0"
UE_RAN_SUBNET="10.53.2.0/24"
VALIDATION_LOG_WINDOW="15m"
VALIDATION_TIMEOUT_SECONDS="120"
VALIDATION_LOG_TAIL_LINES="2000"
XAPP_HEALTH_TIMEOUT_SECONDS="45"
XAPP_HEALTH_LOG_TAIL_LINES="5000"
XAPP_HEALTH_TRAFFIC_PINGS="40"

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
  echo "    validate  Validate UE attach + internet path via UPF"
  echo "    xapp      Launch KPM monitoring xApp for the active gNB node"
  echo "    xapp-health  Validate end-to-end KPM flow (UE traffic → gNB → RIC → xApp)"
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

cmd_validate() {
  info "Validating UE connectivity path (UE ↔ gNB ↔ 5GC ↔ UPF ↔ internet)..."

  local failures=0
  local gnb_line=""
  local core_line=""
  local ue_reg_line=""
  local ue_pdu_line=""
  local ue_pdu_ip=""
  local ue_iface_ip=""

  if ! _container_running "lab_open5gs"; then
    error "Open5GS is not running. Start the lab first: ./lab.sh up"
  fi
  if ! _container_running "lab_gnb"; then
    error "gNB is not running. Start the lab first: ./lab.sh up"
  fi

  _provision_subscribers

  if _container_running "lab_ue"; then
    info "UE container already running"
  else
    info "UE container is not running; starting srsUE..."
    docker compose -f "${COMPOSE_FILE}" up -d srsue >/dev/null
  fi

  info "Waiting for attach and PDU session evidence in logs (timeout: ${VALIDATION_TIMEOUT_SECONDS}s)..."
  if _wait_for_attach_evidence "${VALIDATION_TIMEOUT_SECONDS}"; then
    success "Attach evidence detected"
  else
    warn "Attach evidence timed out; collecting current diagnostics"
  fi

  gnb_line="$(_latest_log_line "ocudu-gnb" "InitialUEMessage|rrcSetupComplete" "${VALIDATION_LOG_WINDOW}")"
  if [[ -n "${gnb_line}" ]]; then
    success "gNB log evidence: ${gnb_line}"
  else
    warn "gNB log is missing InitialUEMessage/rrcSetupComplete in the last ${VALIDATION_LOG_WINDOW}"
  fi

  core_line="$(_latest_log_line "open5gs" "Registration complete" "${VALIDATION_LOG_WINDOW}")"
  if [[ -n "${core_line}" ]]; then
    success "Core log evidence: ${core_line}"
  else
    warn "Open5GS log is missing 'Registration complete' in the last ${VALIDATION_LOG_WINDOW}"
    failures=$((failures + 1))
  fi

  ue_reg_line="$(_latest_log_line "srsue" "Handling Registration Accept" "${VALIDATION_LOG_WINDOW}")"
  if [[ -n "${ue_reg_line}" ]]; then
    success "UE registration evidence: ${ue_reg_line}"
  else
    warn "UE log is missing 'Handling Registration Accept' in the last ${VALIDATION_LOG_WINDOW}"
  fi

  ue_pdu_line="$(_latest_log_line "srsue" "PDU Session Establishment successful" "${VALIDATION_LOG_WINDOW}")"
  if [[ -n "${ue_pdu_line}" ]]; then
    success "UE PDU evidence: ${ue_pdu_line}"
  else
    warn "UE log is missing 'PDU Session Establishment successful' in the last ${VALIDATION_LOG_WINDOW}"
  fi

  if docker compose -f "${COMPOSE_FILE}" exec -T srsue sh -lc "ip -4 addr show dev ${UE_TUN_IFACE} | grep -q 'inet '" >/dev/null 2>&1; then
    ue_iface_ip="$(docker compose -f "${COMPOSE_FILE}" exec -T srsue sh -lc "ip -4 -o addr show dev ${UE_TUN_IFACE} | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null | tr -d '\r')"
    success "UE tunnel interface ${UE_TUN_IFACE} is up with IP ${ue_iface_ip}"

    if _ensure_ue_upf_default_route; then
      success "UE route preference updated to use ${UE_TUN_IFACE} for internet probes"
    else
      warn "Failed to normalize UE default routes for UPF internet probe"
      failures=$((failures + 1))
    fi
  else
    warn "UE interface ${UE_TUN_IFACE} has no IPv4 address"
    failures=$((failures + 1))
  fi

  if _ue_ping "${UE_UPF_GATEWAY_IP}" "${UE_TUN_IFACE}"; then
    success "UE can reach UPF gateway ${UE_UPF_GATEWAY_IP}"
  else
    warn "UE cannot reach UPF gateway ${UE_UPF_GATEWAY_IP}"
    failures=$((failures + 1))
  fi

  local internet_target=""
  local internet_ok="false"
  for internet_target in 1.1.1.1 8.8.8.8; do
    local route_dev=""
    route_dev="$(_ue_route_device_for_target "${internet_target}")"
    if [[ "${route_dev}" != "${UE_TUN_IFACE}" ]]; then
      warn "Route to ${internet_target} is currently ${route_dev:-unknown} (expected ${UE_TUN_IFACE})"
      continue
    fi

    if _ue_ping "${internet_target}" "${UE_TUN_IFACE}"; then
      success "UE internet probe succeeded via ${internet_target}"
      internet_ok="true"
      break
    fi
  done

  if [[ "${internet_ok}" != "true" ]]; then
    warn "UE internet probe failed (tested: 1.1.1.1, 8.8.8.8)"
    failures=$((failures + 1))
  fi

  ue_pdu_ip="$(_extract_ue_pdu_ip "${VALIDATION_LOG_WINDOW}")"
  if [[ -n "${ue_pdu_ip}" ]]; then
    info "UE PDU session assigned IP: ${ue_pdu_ip}"
  fi

  echo ""
  if (( failures == 0 )); then
    success "Validation PASSED — UE attach and UPF internet path look healthy"
  else
    error "Validation FAILED — ${failures} check(s) did not pass. Review logs with: ./lab.sh logs srsue ; ./lab.sh logs ocudu-gnb ; ./lab.sh logs open5gs"
  fi
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

cmd_xapp_health() {
  info "Running xApp KPM health check (UE traffic -> gNB -> RIC -> xApp)..."

  local failures=0
  local ran_node_id=""
  local since_ts=""
  local gnb_indication_line=""
  local xapp_indication_line=""
  local xapp_nonzero_metric_line=""
  local xapp_probe_output=""
  local traffic_pid=""

  if [[ ! -d "${RIC_DIR}" ]]; then
    error "RIC directory not found. Run bootstrap.sh first."
  fi
  if ! _container_running "lab_open5gs"; then
    error "Open5GS is not running. Start the lab first: ./lab.sh up"
  fi
  if ! _container_running "lab_gnb"; then
    error "gNB is not running. Start the lab first: ./lab.sh up"
  fi
  if ! docker inspect "${RIC_DBAAS_CONTAINER}" >/dev/null 2>&1; then
    error "${RIC_DBAAS_CONTAINER} is not running. Start the RIC stack first."
  fi
  if ! docker inspect "${RIC_E2TERM_CONTAINER}" >/dev/null 2>&1; then
    error "${RIC_E2TERM_CONTAINER} is not running. Start the RIC stack first."
  fi

  _provision_subscribers
  _attach_e2term_to_lab_ran || warn "Could not auto-attach e2term to ${LAB_RAN_NETWORK}"

  info "Checking gNB <-> RIC E2 SCTP association..."
  if _wait_for_e2_association 60; then
    success "E2 SCTP association is active"
  else
    warn "E2 SCTP association was not detected within timeout"
    failures=$((failures + 1))
  fi

  if _container_running "lab_ue"; then
    info "UE container already running"
  else
    info "UE container is not running; starting srsUE..."
    docker compose -f "${COMPOSE_FILE}" up -d srsue >/dev/null
  fi

  info "Waiting for UE tunnel interface ${UE_TUN_IFACE} (timeout: 45s)..."
  if _wait_for_ue_tunnel_ip 45; then
    success "UE tunnel interface ${UE_TUN_IFACE} is up"
  else
    warn "UE tunnel interface ${UE_TUN_IFACE} did not get an IPv4 address in time"
    failures=$((failures + 1))
  fi

  if docker compose -f "${COMPOSE_FILE}" exec -T srsue sh -lc "ip -4 addr show dev ${UE_TUN_IFACE} | grep -q 'inet '" >/dev/null 2>&1; then
    if _ensure_ue_upf_default_route; then
      success "UE routing normalized for UPF traffic on ${UE_TUN_IFACE}"
    else
      warn "Could not normalize UE default routes"
      failures=$((failures + 1))
    fi
  else
    warn "UE tunnel interface ${UE_TUN_IFACE} has no IPv4 address"
    failures=$((failures + 1))
  fi

  local core_attach_line=""
  local ue_attach_line=""
  core_attach_line="$(_latest_log_line "open5gs" "Registration complete" "${VALIDATION_LOG_WINDOW}")"
  ue_attach_line="$(_latest_log_line "srsue" "PDU Session Establishment successful" "${VALIDATION_LOG_WINDOW}")"

  if [[ -n "${core_attach_line}" ]]; then
    success "Core attach evidence: ${core_attach_line}"
  else
    warn "Open5GS attach evidence not found in the last ${VALIDATION_LOG_WINDOW}"
  fi

  if [[ -n "${ue_attach_line}" ]]; then
    success "UE attach evidence: ${ue_attach_line}"
  else
    warn "UE attach evidence not found in the last ${VALIDATION_LOG_WINDOW}"
  fi

  ran_node_id="$(_wait_for_ran_node_id 90 || true)"
  if [[ -z "${ran_node_id}" ]]; then
    error "No active RAN node found in RIC state. Ensure gNB is connected first."
  fi

  info "Using RAN node ID: ${ran_node_id}"
  since_ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  info "Generating UE traffic while running foreground xApp probe..."
  _generate_ue_traffic &
  traffic_pid="$!"
  xapp_probe_output="$(_run_xapp_probe_for_ran_node "${ran_node_id}" "${XAPP_HEALTH_TIMEOUT_SECONDS}")"
  wait "${traffic_pid}" 2>/dev/null || true

  if echo "${xapp_probe_output}" | grep -Fq "Successfully subscribed with Subscription ID"; then
    success "xApp probe subscribed successfully"
  else
    warn "xApp probe did not report a successful subscription"
    failures=$((failures + 1))
  fi

  if _wait_for_gnb_indication_since "${since_ts}" "${XAPP_HEALTH_TIMEOUT_SECONDS}"; then
    gnb_indication_line="$(_latest_gnb_line_since "${since_ts}" "Sending E2 indication")"
    success "gNB indication evidence: ${gnb_indication_line}"
  else
    warn "No 'Sending E2 indication' log detected from gNB after health check start"
    failures=$((failures + 1))
  fi

  xapp_indication_line="$(echo "${xapp_probe_output}" | grep -F "RIC Indication Received" | tail -n 1 || true)"
  if [[ -n "${xapp_indication_line}" ]]; then
    success "xApp indication evidence: ${xapp_indication_line}"
  else
    warn "xApp probe did not log any RIC indication callbacks within timeout"
    failures=$((failures + 1))
  fi

  xapp_nonzero_metric_line="$(echo "${xapp_probe_output}" \
    | grep -E "Metric: DRB\\.UEThp(Dl|Ul), Value:" \
    | grep -Ev "Value: \\[ *0+(\\.0+)? *\\]$" \
    | tail -n 1 || true)"
  if [[ -n "${xapp_nonzero_metric_line}" ]]; then
    success "xApp non-zero KPI evidence: ${xapp_nonzero_metric_line}"
  else
    warn "No non-zero DRB throughput value observed during the xApp probe"
    failures=$((failures + 1))
  fi

  echo ""
  if (( failures == 0 )); then
    success "xApp health check PASSED — UE traffic is metrified by gNB and processed by xApp"
  else
    error "xApp health check FAILED — ${failures} check(s) did not pass. Review with: ./lab.sh logs ocudu-gnb ; cd repos/oran-sc-ric && docker compose logs python_xapp_runner"
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
    sh -lc "python3 -u ./kpm_mon_xapp.py \
      --metrics='${XAPP_METRICS}' \
      --kpm_report_style='${XAPP_REPORT_STYLE}' \
      --http_server_port '${XAPP_HTTP_PORT}' \
      --rmr_port '${XAPP_RMR_PORT}' \
      --e2_node_id '${ran_node_id}' \
      >> /proc/1/fd/1 2>> /proc/1/fd/2" >/dev/null
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

_latest_gnb_line_since() {
  local since_ts="$1"
  local pattern="$2"

  docker compose -f "${COMPOSE_FILE}" logs --no-color --since "${since_ts}" --tail "${XAPP_HEALTH_LOG_TAIL_LINES}" ocudu-gnb 2>/dev/null \
    | grep -E "${pattern}" \
    | tail -n 1 \
    || true
}

_wait_for_gnb_indication_since() {
  local since_ts="$1"
  local timeout="$2"
  local elapsed=0

  while true; do
    if [[ -n "$(_latest_gnb_line_since "${since_ts}" "Sending E2 indication")" ]]; then
      return 0
    fi

    sleep 3
    elapsed=$((elapsed + 3))
    if (( elapsed >= timeout )); then
      return 1
    fi
  done
}

_run_xapp_probe_for_ran_node() {
  local ran_node_id="$1"
  local probe_seconds="$2"
  local timeout_seconds=$((probe_seconds + 10))

  if command -v timeout >/dev/null 2>&1; then
    timeout -k 5 "${timeout_seconds}" docker compose -f "${RIC_COMPOSE_FILE}" exec -T "${RIC_XAPP_RUNNER_SERVICE}" \
      python3 -u ./kpm_mon_xapp.py \
      --metrics="${XAPP_METRICS}" \
      --kpm_report_style="${XAPP_REPORT_STYLE}" \
      --http_server_port "${XAPP_HEALTH_HTTP_PORT}" \
      --rmr_port "${XAPP_HEALTH_RMR_PORT}" \
      --e2_node_id "${ran_node_id}" 2>&1 \
      || true
  else
    docker compose -f "${RIC_COMPOSE_FILE}" exec -T "${RIC_XAPP_RUNNER_SERVICE}" \
      python3 -u ./kpm_mon_xapp.py \
      --metrics="${XAPP_METRICS}" \
      --kpm_report_style="${XAPP_REPORT_STYLE}" \
      --http_server_port "${XAPP_HEALTH_HTTP_PORT}" \
      --rmr_port "${XAPP_HEALTH_RMR_PORT}" \
      --e2_node_id "${ran_node_id}" 2>&1 \
      || true
  fi
}

_wait_for_ue_tunnel_ip() {
  local timeout="$1"
  local elapsed=0

  while true; do
    if docker compose -f "${COMPOSE_FILE}" exec -T srsue sh -lc "ip -4 addr show dev ${UE_TUN_IFACE} | grep -q 'inet '" >/dev/null 2>&1; then
      return 0
    fi

    sleep 3
    elapsed=$((elapsed + 3))
    if (( elapsed >= timeout )); then
      return 1
    fi
  done
}

_generate_ue_traffic() {
  docker compose -f "${COMPOSE_FILE}" exec -T srsue sh -lc "
    ping -I ${UE_TUN_IFACE} -s 1200 -i 0.05 -c ${XAPP_HEALTH_TRAFFIC_PINGS} -W 1 ${UE_UPF_GATEWAY_IP} >/dev/null 2>&1 || true
    ping -I ${UE_TUN_IFACE} -s 1200 -i 0.05 -c 20 -W 1 1.1.1.1 >/dev/null 2>&1 || true
  " >/dev/null
}

_container_running() {
  local container_name="$1"
  [[ "$(docker inspect -f '{{.State.Running}}' "${container_name}" 2>/dev/null || true)" == "true" ]]
}

_latest_log_line() {
  local service="$1"
  local pattern="$2"
  local since_window="$3"

  docker compose -f "${COMPOSE_FILE}" logs --no-color --since "${since_window}" --tail "${VALIDATION_LOG_TAIL_LINES}" "${service}" 2>/dev/null \
    | grep -Ei "${pattern}" \
    | tail -n 1 \
    || true
}

_wait_for_attach_evidence() {
  local timeout="$1"
  local elapsed=0

  while true; do
    local gnb_seen=""
    local core_seen=""
    local ue_reg_seen=""
    local ue_pdu_seen=""

    gnb_seen="$(_latest_log_line "ocudu-gnb" "InitialUEMessage|rrcSetupComplete" "${VALIDATION_LOG_WINDOW}")"
    core_seen="$(_latest_log_line "open5gs" "Registration complete" "${VALIDATION_LOG_WINDOW}")"
    ue_reg_seen="$(_latest_log_line "srsue" "Handling Registration Accept" "${VALIDATION_LOG_WINDOW}")"
    ue_pdu_seen="$(_latest_log_line "srsue" "PDU Session Establishment successful" "${VALIDATION_LOG_WINDOW}")"

    if [[ -n "${gnb_seen}" && -n "${core_seen}" && -n "${ue_reg_seen}" && -n "${ue_pdu_seen}" ]]; then
      return 0
    fi

    sleep 3
    elapsed=$((elapsed + 3))
    if (( elapsed >= timeout )); then
      return 1
    fi
  done
}

_extract_ue_pdu_ip() {
  local since_window="$1"

  docker compose -f "${COMPOSE_FILE}" logs --no-color --since "${since_window}" --tail "${VALIDATION_LOG_TAIL_LINES}" srsue 2>/dev/null \
    | sed -nE 's/.*PDU Session Establishment successful\. IP: *([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+).*/\1/p' \
    | tail -n 1
}

_ue_ping() {
  local target_ip="$1"
  local iface="${2:-}"
  local ping_cmd=""
  local ping_output=""

  if [[ -n "${iface}" ]]; then
    ping_cmd="ping -I ${iface} -c 3 -W 3 ${target_ip}"
  else
    ping_cmd="ping -c 3 -W 3 ${target_ip}"
  fi

  ping_output="$(docker compose -f "${COMPOSE_FILE}" exec -T srsue sh -lc "${ping_cmd}" 2>/dev/null || true)"
  echo "${ping_output}" | grep -q "0% packet loss"
}

_ensure_ue_upf_default_route() {
  local ran_gateway=""
  local ran_ip=""

  ran_gateway="$(docker compose -f "${COMPOSE_FILE}" exec -T srsue sh -lc "ip -4 route show default dev ${UE_RAN_IFACE} | awk 'NR==1 {print \$3}'" 2>/dev/null | tr -d '\r')"
  ran_ip="$(docker compose -f "${COMPOSE_FILE}" exec -T srsue sh -lc "ip -4 -o addr show dev ${UE_RAN_IFACE} | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null | tr -d '\r')"

  if [[ -z "${ran_gateway}" || -z "${ran_ip}" ]]; then
    return 1
  fi

  docker compose -f "${COMPOSE_FILE}" exec -T srsue sh -lc "
    ip route del default via ${ran_gateway} dev ${UE_RAN_IFACE} >/dev/null 2>&1 || true
    ip route replace default via ${UE_UPF_GATEWAY_IP} dev ${UE_TUN_IFACE} metric 50
    ip route replace default via ${ran_gateway} dev ${UE_RAN_IFACE} metric 500
    ip route replace ${UE_RAN_SUBNET} dev ${UE_RAN_IFACE} src ${ran_ip}
  " >/dev/null
}

_ue_route_device_for_target() {
  local target_ip="$1"

  docker compose -f "${COMPOSE_FILE}" exec -T srsue sh -lc "ip -4 route get ${target_ip} 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if (\$i==\"dev\") {print \$(i+1); exit}}'" 2>/dev/null | tr -d '\r'
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
  validate) cmd_validate ;;
  xapp)    cmd_xapp ;;
  xapp-health) cmd_xapp_health ;;
  clean)   cmd_clean ;;
  shell)   cmd_shell "$@" ;;
  *)       usage ;;
esac
