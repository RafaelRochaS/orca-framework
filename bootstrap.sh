#!/usr/bin/env bash
# =============================================================================
# 5G Research Lab Bootstrap Script
# Ubuntu 24.04 LTS | OCUDU + Open5GS + O-RAN SC RIC + ETSI OpenOP
# =============================================================================
set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Configuration ─────────────────────────────────────────────────────────────
DOCKER_COMPOSE_VERSION="2.27.0"
MIN_RAM_GB=16
MIN_DISK_GB=60
MIN_VCPUS=8

# ── Pre-flight checks ─────────────────────────────────────────────────────────
preflight() {
  info "Running pre-flight checks..."

  # OS check
  . /etc/os-release
  if [[ "$ID" != "ubuntu" || "${VERSION_ID}" != "24.04" ]]; then
    warn "This script targets Ubuntu 24.04. Detected: ${PRETTY_NAME}. Proceeding anyway..."
  fi

  # RAM
  local ram_kb; ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  local ram_gb=$(( ram_kb / 1024 / 1024 ))
  if (( ram_gb < MIN_RAM_GB )); then
    error "Insufficient RAM: ${ram_gb}GB available, ${MIN_RAM_GB}GB required. (Recommended: 32GB)"
  fi
  success "RAM: ${ram_gb}GB"

  # Disk
  local disk_gb; disk_gb=$(df -BG / | awk 'NR==2{gsub("G",""); print $4}')
  if (( disk_gb < MIN_DISK_GB )); then
    error "Insufficient disk: ${disk_gb}GB free, ${MIN_DISK_GB}GB required."
  fi
  success "Disk: ${disk_gb}GB free"

  # vCPUs
  local vcpus; vcpus=$(nproc)
  if (( vcpus < MIN_VCPUS )); then
    warn "Only ${vcpus} vCPUs detected. ${MIN_VCPUS}+ recommended for full stack performance."
  else
    success "vCPUs: ${vcpus}"
  fi

  # Root / sudo
  if [[ $EUID -ne 0 ]]; then
    sudo -v || error "This script requires sudo privileges."
  fi
}

# ── System packages ───────────────────────────────────────────────────────────
install_system_deps() {
  info "Installing system dependencies..."
  sudo apt-get update -qq
  sudo apt-get install -y --no-install-recommends \
    git curl wget ca-certificates gnupg lsb-release \
    build-essential cmake pkg-config \
    libzmq3-dev libzmq5 python3-zmq \
    libsctp-dev lksctp-tools \
    libfftw3-dev libmbedtls-dev libboost-program-options-dev \
    libconfig++-dev libyaml-cpp-dev \
    iproute2 iptables net-tools tcpdump \
    python3 python3-pip python3-venv python3-dev \
    jq unzip socat netcat-openbsd \
    linux-tools-generic
  success "System packages installed"
}

# ── Kernel / host tuning ──────────────────────────────────────────────────────
tune_kernel() {
  info "Applying kernel and host tuning..."

  # SCTP kernel module (needed for E2 interface)
  sudo modprobe sctp 2>/dev/null || warn "Could not load SCTP module — may already be built-in"
  echo "sctp" | sudo tee /etc/modules-load.d/sctp.conf > /dev/null

  # ip_forward for UE traffic routing
  sudo sysctl -w net.ipv4.ip_forward=1
  echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-5glab.conf > /dev/null

  # ZMQ / OCUDU tuning
  sudo sysctl -w net.core.rmem_max=134217728
  sudo sysctl -w net.core.wmem_max=134217728
  cat <<EOF | sudo tee -a /etc/sysctl.d/99-5glab.conf
net.core.rmem_max=134217728
net.core.wmem_max=134217728
kernel.sched_rt_runtime_us=-1
EOF

  sudo sysctl --system -q
  success "Kernel tuning applied"
}

# ── Docker ────────────────────────────────────────────────────────────────────
install_docker() {
  if command -v docker &>/dev/null; then
    success "Docker already installed: $(docker --version)"
    return
  fi

  info "Installing Docker Engine..."
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update -qq
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  sudo systemctl enable --now docker
  sudo usermod -aG docker "${USER}" || true
  success "Docker installed"
}

# ── Docker Compose (standalone, for scripts that call it directly) ─────────────
install_docker_compose() {
  if docker compose version &>/dev/null; then
    success "Docker Compose plugin available: $(docker compose version)"
    return
  fi
  info "Installing Docker Compose plugin..."
  sudo apt-get install -y docker-compose-plugin
  success "Docker Compose installed"
}

# ── Clone component repositories ──────────────────────────────────────────────
clone_repos() {
  info "Cloning required repositories..."
  local REPOS_DIR="${SCRIPT_DIR}/repos"
  mkdir -p "${REPOS_DIR}"

  # OCUDU (gNB with E2 agent)
  if [[ ! -d "${REPOS_DIR}/ocudu" ]]; then
    info "  → Cloning OCUDU (gNB)..."
    git clone --depth 1 https://gitlab.com/ocudu/ocudu.git \
      "${REPOS_DIR}/ocudu"
  else
    warn "  OCUDU already cloned, skipping"
  fi

  # OCUDU 4G (for UE — ZMQ UE simulator)
  if [[ ! -d "${REPOS_DIR}/ocudu-4g" ]]; then
    info "  → Cloning OCUDU 4G (UE)..."
    git clone --depth 1 https://gitlab.com/ocudu/ocudu.git \
      "${REPOS_DIR}/ocudu-4g"
  else
    warn "  OCUDU 4G already cloned, skipping"
  fi

  # O-RAN SC RIC (Docker Compose — no Kubernetes needed)
  if [[ ! -d "${REPOS_DIR}/oran-sc-ric" ]]; then
    info "  → Cloning O-RAN SC RIC (Docker Compose)..."
    git clone --depth 1 https://github.com/srsran/oran-sc-ric.git \
      "${REPOS_DIR}/oran-sc-ric"
  else
    warn "  oran-sc-ric already cloned, skipping"
  fi

  # ETSI OpenOP — individual repos (the top-level group requires auth, repos do not)
  # Each repo is cloned independently and gracefully skipped if unavailable.
  # See: https://labs.etsi.org/rep/oop/code
  clone_openop_repo() {
    local name="$1"
    local slug="$2"
    local dest="${REPOS_DIR}/openop/${name}"
    if [[ -d "${dest}" ]]; then
      warn "  openop/${name} already cloned, skipping"
      return
    fi
    info "  → Cloning openop/${name}..."
    if git clone --depth 1 \
        "https://labs.etsi.org/rep/oop/code/${slug}.git" "${dest}" 2>/dev/null; then
      success "    openop/${name} cloned"
    else
      warn "    openop/${name} not accessible — skipping (lab scaffold will be used instead)"
      mkdir -p "${dest}" && touch "${dest}/.stub"
    fi
  }

  mkdir -p "${REPOS_DIR}/openop"

  # Confirmed public repos (Release 0):
  clone_openop_repo "open-exposure-gateway" "open-exposure-gateway"
  clone_openop_repo "federation-manager" "federation-manager"
  clone_openop_repo "service-resource-manager" "service-resource-manager"
  clone_openop_repo "transformation-function-sdk" "tf-sdk"

  local cloned=0; local stubbed=0
  for d in "${REPOS_DIR}/openop"/*/; do
    if [[ -f "${d}/.stub" ]]; then ((stubbed++)); else ((cloned++)); fi
  done
  info "  OpenOP repos: ${cloned} cloned, ${stubbed} unavailable (using local scaffold)"

  success "Repositories ready at ${REPOS_DIR}"
}

# ── Create tun interface for UE traffic ───────────────────────────────────────
setup_networking() {
  info "Setting up host networking for UE traffic..."

  # NAT for UE subnet (10.45.0.0/16) — required so UEs can reach internet
  local PRIMARY_IF; PRIMARY_IF=$(ip route show default | awk '/default/ {print $5; exit}')
  if [[ -z "${PRIMARY_IF}" ]]; then
    warn "Could not detect primary interface — skipping NAT rule"
    return
  fi

  sudo iptables -t nat -C POSTROUTING -s 10.45.0.0/16 -o "${PRIMARY_IF}" -j MASQUERADE 2>/dev/null || \
    sudo iptables -t nat -A POSTROUTING -s 10.45.0.0/16 -o "${PRIMARY_IF}" -j MASQUERADE

  # Persist iptables rules
  sudo apt-get install -y iptables-persistent -qq || true
  sudo netfilter-persistent save 2>/dev/null || true

  success "Host NAT configured (UE subnet → ${PRIMARY_IF})"
}

# ── Print next steps ──────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Bootstrap complete! 5G Lab is ready to launch.${NC}"
  echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  ${CYAN}Next steps:${NC}"
  echo -e "    1. ${YELLOW}newgrp docker${NC}  (or log out/in to apply Docker group)"
  echo -e "    2. ${YELLOW}./lab.sh up${NC}    (start the full lab stack)"
  echo -e "    3. ${YELLOW}./lab.sh status${NC} (check all services)"
  echo ""
  echo -e "  ${CYAN}Key endpoints (once running):${NC}"
  echo -e "    Open5GS WebUI   → http://localhost:9999"
  echo -e "    CAMARA API GW   → http://localhost:8080"
  echo -e "    OOP Orchestrator→ http://localhost:8090"
  echo -e "    RIC E2 Term     → sctp://localhost:36421"
  echo -e "    Grafana (RAN)   → http://localhost:3000"
  echo ""
  warn "Note: If this is a cloud VM, replace 'localhost' with your public IP"
  warn "      and ensure security groups allow the relevant ports."
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo -e "${CYAN}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║   5G Research Lab — Bootstrap                ║"
  echo "  ║   OCUDU · Open5GS · O-RAN RIC · ETSI OOP     ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${NC}"

  preflight
  install_system_deps
  tune_kernel
  install_docker
  install_docker_compose
  clone_repos
  setup_networking
  print_summary
}

main "$@"
