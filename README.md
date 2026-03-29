# ORCA — Open RAN CAMARA Abstraction Framework

> A reproducible, fully containerised testbed for developing and validating
> CAMARA APIs over an O-RAN-enabled 5G network stack.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Stack: OCUDU + Open5GS + O-RAN SC RIC + ETSI OpenOP](https://img.shields.io/badge/stack-OCUDU%20%7C%20Open5GS%20%7C%20O--RAN%20SC%20RIC%20%7C%20ETSI%20OpenOP-informational)](#architecture)
[![Target OS: Ubuntu 24.04 LTS](https://img.shields.io/badge/OS-Ubuntu%2024.04%20LTS-orange)](https://releases.ubuntu.com/24.04/)

---

## Overview

ORCA provides a single-command lab environment that instantiates a complete,
standards-compliant 5G network — including a simulated RAN, a full 5G Core,
an O-RAN Near-RT RIC, and a CAMARA API exposure layer — on a fresh Ubuntu 24.04
VM or cloud instance.

It is designed as a foundation for:

- **CAMARA API research and development** — prototype, test, and validate new or
  existing CAMARA APIs against a live 5G network without hardware
- **O-RAN xApp development** — develop and test xApps that interact with the RAN
  via E2SM-KPM (monitoring) and E2SM-RC (control), with CAMARA APIs as the
  northbound trigger
- **Closed-loop RAN control research** — explore end-to-end flows from a CAMARA
  API call through the 5G Core and down to the RAN scheduler via the RIC
- **Reproducible experiments** — the entire environment is defined in code,
  making results reproducible and shareable

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Ubuntu 24.04 VM                          │
│                                                                 │
│  ┌──────────────┐  ZMQ RF   ┌─────────────────────────────┐     │
│  │   srsUE      │◄─────────►│  OCUDU gNB                  │     │
│  │  (lab_ue)    │           │  · ZMQ RF (no SDR hardware) │     │
│  └──────────────┘           │  · E2 agent (KPM + RC)      │     │
│                             └──────────┬──────────────────┘     │
│                                        │ N2/NGAP (SCTP)         │
│                    ┌───────────────────▼──────────────────┐     │
│                    │       Open5GS 5G Core                │     │
│                    │  AMF · SMF · UPF · PCF · NEF · ...   │     │
│                    └───────────────────┬──────────────────┘     │
│                                        │                        │
│      ┌─────────────────────────────────▼──────────────────┐     │
│      │         O-RAN SC Near-RT RIC                       │     │
│      │  · E2 termination      · A1 mediator               │     │
│      │  · RMR message router  · Subscription manager      │     │
│      │  · xApp runtime  ◄── develop your xApps here       │     │
│      └─────────────────────────┬──────────────────────────┘     │
│                                │ A1 interface                   │
│      ┌─────────────────────────▼──────────────────────────┐     │
│      │           ETSI OpenOP — CAMARA Layer               │     │
│      │  ┌─────────────────┐   ┌──────────────────────┐    │     │
│      │  │  API Gateway    │   │  Orchestrator        │    │     │
│      │  │  CAMARA APIs:   │   │  CAMARA → 3GPP       │    │     │
│      │  │  · QoD ✓        │   │  → O-RAN translation │    │     │
│      │  │  · DevStatus ✓  │   │                      │    │     │
│      │  │  · [extend here]│   │                      |    │     │
│      │  └─────────────────┘   └──────────────────────┘    │     │
│      └────────────────────────────────────────────────────┘     │
│                                                                 │
│  ┌──────────────┐                                               │
│  │   Grafana    │ ← RAN + Core metrics (Prometheus)             │
│  │   :3000      │                                               │
│  └──────────────┘                                               │
└─────────────────────────────────────────────────────────────────┘
```

### Component versions

| Component | Role | Source |
|---|---|---|
| [OCUDU](https://gitlab.com/ocudu/ocudu) | 5G NR gNB with E2 agent | Built from source (ZMQ-enabled) |
| [srsRAN 4G / srsUE](https://github.com/srsran/srsRAN_4G) | ZMQ UE simulator | Built from source |
| [Open5GS](https://open5gs.org) | 5G Core (all NFs) | `gradiant/open5gs:2.2.0` |
| [O-RAN SC RIC](https://github.com/srsran/oran-sc-ric) | Near-RT RIC (i-Release) | Docker Compose (OCUDU-maintained) |
| [ETSI OpenOP](https://oop.etsi.org) | CAMARA API gateway + orchestrator | Cloned from `labs.etsi.org/rep/oop/code/` |
| MongoDB | Subscriber database | `mongo:6.0` |
| Grafana | Observability | `grafana/grafana:10.4.0` |

---

## Quick Start

### Prerequisites

**Minimum VM specs:** 8 vCPUs · 16 GB RAM · 80 GB disk
**Recommended:** 16 vCPUs · 32 GB RAM (for stable concurrent ZMQ + RIC + Compose)

Tested on: **Ubuntu 24.04 LTS** — AWS `t3.2xlarge` / GCP `n2-standard-8` or larger.

> **Note on the RIC:** ORCA uses the [OCUDU-maintained `oran-sc-ric`](https://github.com/srsran/oran-sc-ric)
> which runs the O-RAN SC Near-RT RIC as a pure Docker Compose stack — no
> Kubernetes or Helm required. If you encounter RMR issues with this image,
> see [Troubleshooting](#troubleshooting) for the fallback options.

### 1. Bootstrap (one-time host setup)

```bash
git clone https://github.com/<your-org>/orca-framework.git
cd orca-framework
chmod +x bootstrap.sh lab.sh
./bootstrap.sh
```

The bootstrap script installs Docker, required kernel modules (SCTP), ZMQ
libraries, configures host networking for UE traffic, and clones all
component repositories.

Log out and back in (or run `newgrp docker`) to apply Docker group membership.

### 2. Build images from source

```bash
./lab.sh build
```

This compiles the OCUDU gNB with ZMQ and E2 support enabled, and builds
the ORCA OOP gateway and orchestrator. **Expect 15–25 minutes on first run**;
subsequent builds use the Docker layer cache.

### 3. Start the lab

```bash
./lab.sh up
```

Services start in dependency order:

1. MongoDB + Open5GS 5G Core (waits for AMF healthcheck)
2. O-RAN SC Near-RT RIC
3. ETSI OpenOP CAMARA layer (gateway + orchestrator)
4. OCUDU gNB (connects to both 5GC via N2 and RIC via E2)

### 4. Attach a simulated UE

```bash
./lab.sh ue
```

### 5. Check status

```bash
./lab.sh status
./lab.sh logs open5gs
./lab.sh logs ocudu-gnb
```

---

## Key Endpoints

| Service | URL | Credentials |
|---|---|---|
| Open5GS WebUI | `http://localhost:9999` | admin / 1423 |
| CAMARA API Gateway | `http://localhost:8080` | — |
| Swagger UI (API docs) | `http://localhost:8080/docs` | — |
| OOP Orchestrator | `http://localhost:8090` | — |
| Grafana | `http://localhost:3000` | admin / admin |

> **Cloud VM users:** replace `localhost` with your public IP and open the
> relevant ports in your security group / firewall.

---

## CAMARA API Reference

### Quality on Demand — create a QoS session

```bash
curl -X POST http://localhost:8080/camara/quality-on-demand/v0/sessions \
  -H "Content-Type: application/json" \
  -d '{
    "device": {
      "ipv4_address": {"private_address": "10.45.0.2"}
    },
    "application_server": {"ipv4_address": "10.0.0.1"},
    "qos_profile": "QOS_L",
    "duration": 3600
  }'
```

### QoS Profiles

| Profile | DL | UL | Latency | 5QI |
|---|---|---|---|---|
| `QOS_E` | best effort | best effort | — | 9 |
| `QOS_S` | ≥ 2 Mbps | ≥ 1 Mbps | < 300 ms | 8 |
| `QOS_M` | ≥ 10 Mbps | ≥ 5 Mbps | < 100 ms | 7 |
| `QOS_L` | ≥ 50 Mbps | ≥ 25 Mbps | < 50 ms | 1 (GBR) |

The QoD → 5GC PCF + RIC A1 translation is handled by the Orchestrator.
The profile-to-5QI mapping lives in `oop/gateway/src/routers/qod.py`
(`QOS_PROFILE_MAP`) and is the primary extension point for custom profiles.

### Device Status

```bash
curl -X POST http://localhost:8080/camara/device-status/v0/connectivity \
  -H "Content-Type: application/json" \
  -d '{"ipv4_address": "10.45.0.2"}'
```

---

## Extending ORCA

### Adding a new CAMARA API

1. Create `oop/gateway/src/routers/my_api.py` following the QoD pattern in
   `qod.py`. The structure is: Pydantic models → FastAPI router → async call
   to the Orchestrator's internal API.

2. Register it in `oop/gateway/src/main.py`:
   ```python
   from .routers import my_api
   app.include_router(my_api.router, prefix="/camara/my-api/v0")
   ```

3. Add southbound translation logic in `oop/orchestrator/src/main.py` —
   map your API parameters to 3GPP NF calls (PCF, SMF, NEF) and/or
   O-RAN A1 policies.

4. Rebuild and restart:
   ```bash
   docker compose build oop-gateway oop-orchestrator
   ./lab.sh restart
   ```

### Developing an xApp

The `xapps/qod-xapp/qod_xapp.py` scaffold demonstrates the three-layer
xApp pattern used in ORCA:

1. **A1 policy listener** — receives policies from the OOP Orchestrator
2. **E2SM-KPM subscription** — monitors per-UE metrics (throughput, delay)
3. **E2SM-RC control** — adjusts RAN scheduler parameters on SLA breach

To deploy your xApp into the RIC:

```bash
cp xapps/my-xapp/my_xapp.py repos/oran-sc-ric/xApps/python/
cd repos/oran-sc-ric
docker compose exec python_xapp_runner python3 ./my_xapp.py
```

Launch the built-in KPM monitoring xApp:

```bash
./lab.sh xapp
```

---

## Project Structure

```
orca-framework/
├── bootstrap.sh                    # One-time host setup
├── lab.sh                          # Lab lifecycle control
├── docker-compose.yml              # Core stack definition
│
├── config/
│   ├── open5gs/
│   │   ├── open5gs.yaml            # 5G Core configuration
│   │   └── subscriber_db.csv       # Test UE credentials (IMSI/K/OPc)
│   ├── ocudu/
│   │   ├── gnb_zmq.yaml            # gNB — ZMQ RF + E2 agent config
│   │   └── ue_zmq.conf             # srsUE — ZMQ RF config
│   ├── oop/
│   │   ├── gateway.yaml
│   │   └── orchestrator.yaml
│   └── grafana/
│
├── oop/
│   ├── gateway/                    # CAMARA API northbound gateway (FastAPI)
│   │   └── src/
│   │       ├── main.py             # FastAPI app, router registration
│   │       └── routers/
│   │           ├── qod.py          # Quality on Demand API ← extend here
│   │           └── device_status.py
│   └── orchestrator/               # CAMARA → 5GC + RIC translation engine
│       └── src/
│           └── main.py             # PCF + A1 southbound logic ← extend here
│
├── xapps/
│   └── qod-xapp/
│       └── qod_xapp.py             # QoD xApp scaffold (KPM + RC)
│
└── repos/                          # Populated by bootstrap.sh
    ├── ocudu/                      # gNB source
    ├── srsRAN_4G/                  # srsUE source (ZMQ UE simulator)
    ├── oran-sc-ric/                # Near-RT RIC (Docker Compose)
    └── openop/                     # ETSI OpenOP components
        ├── open-exposure-gateway/
        ├── federation-manager/
        └── ...
```

---

## Design Decisions

**Why Docker Compose and not Helm/Kubernetes?**
The `oran-sc-ric` repository runs the O-RAN SC Near-RT RIC as a Docker Compose
stack, eliminating the largest deployment complexity. For single-VM research,
Docker Compose gives better debuggability and lower overhead than a full
Kubernetes cluster. The service boundaries map directly to k8s Deployments
if migration to a multi-node setup is needed later.

**Why `gradiant/open5gs` and not a custom 5GC build?**
The Gradiant image is validated in official OCUDU integration testing,
reducing integration risk. For research focused on the RAN and CAMARA layer,
a stable pre-built 5GC is the right tradeoff. Custom 5GC builds can be
swapped in by changing the `image:` reference and config mounts.

**Why ETSI OpenOP instead of a custom API gateway?**
OpenOP is the standards-body reference implementation of the GSMA Open Operator
Platform. Building on it means ORCA contributions can be aligned with the
standardisation track and potentially contributed upstream to the SDG OOP
community.

---

## Troubleshooting

**gNB fails to connect to AMF:**
```bash
./lab.sh logs ocudu-gnb    # Look for "NG setup procedure failed"
./lab.sh logs open5gs       # Check for SCTP connection errors
```
Verify `AMF_ADDR` in `docker-compose.yml` matches the Open5GS container IP
(`10.53.1.2`) and that the gNB container is attached to the `core` network.

**"Factory for radio type zmq not found":**
The gNB was built without ZMQ support. Run `./lab.sh build` to rebuild with
the correct CMake flags (`-DENABLE_EXPORT=ON -DENABLE_ZEROMQ=ON`).

**RIC E2 connection timeout:**
The O-RAN SC RIC has a ~60 second reconnection wait. After restarting the gNB,
allow up to 60 seconds for the E2 link to recover. Check with:
```bash
docker compose -f repos/oran-sc-ric/docker-compose.yml logs e2term
```

**RMR routing not working (xApp cannot receive indications):**
This is a known issue in some versions of `oran-sc-ric`. Inspect the routing
table inside the RIC:
```bash
docker compose -f repos/oran-sc-ric/docker-compose.yml exec e2term \
  cat /opt/e2/RMR_SEED_RT
```
If the table is empty or missing entries for message type `12050`, refer to
the [oran-sc-ric issues tracker](https://github.com/srsran/oran-sc-ric/issues)
for current status and workarounds. If RMR remains unusable, the fallback is
the full O-RAN SC RIC deployed via `ric-dep` on a `kind` cluster.

**UE fails to register:**
Verify the IMSI, K, and OPc in `config/open5gs/subscriber_db.csv` exactly
match `config/ocudu/ue_zmq.conf`.

**OOP Gateway returns 500:**
```bash
./lab.sh logs oop-gateway
./lab.sh logs oop-orchestrator
```
The orchestrator attempts to reach the Open5GS PCF on startup. QoD sessions
are tracked in memory and enforcement is best-effort during early startup.

<!-- ---

## Contributing

Contributions are welcome in the following areas:

- New CAMARA API implementations (routers + southbound translators)
- xApp implementations for novel RAN-level control use cases
- Integration with additional 5G Core implementations (OAI, free5GC)
- Kubernetes / Helm migration path for multi-node deployments
- Improved E2SM-RC message building in the QoD xApp scaffold
- CI pipeline and automated integration tests

Please open an issue before submitting a large PR to align on design direction.

--- -->

## Related Projects

- [CAMARA Project](https://camaraproject.org) — GSMA/LF open API definitions
- [ETSI OpenOP / SDG OOP](https://oop.etsi.org) — Open Operator Platform
- [O-RAN Software Community](https://o-ran-sc.org) — Near-RT RIC and xApp runtime
- [OCUDU Project](https://ocudu.org) — Open-source 5G NR RAN
- [Open5GS](https://open5gs.org) — Open-source 5G Core
- [SUNRISE-6G](https://sunrise6g.eu) — EU 6G testbed federation project

---

## License

Apache License 2.0 — consistent with ETSI OpenOP, OCUDU, CAMARA Project,
and O-RAN SC licensing. See [LICENSE](LICENSE) for details.
