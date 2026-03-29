# AGENTS.md — ORCA Framework

Instructions for AI agents (Claude Code and others) working in this repository.
Read this file fully before making any changes.

---

## What this project is

ORCA (Open RAN CAMARA Abstraction) is a containerised 5G research testbed that
wires together OCUDU (gNB + UE), Open5GS (5G Core), the O-RAN SC Near-RT RIC,
and ETSI OpenOP (CAMARA API layer) into a single `./lab.sh up` environment.

The primary research surface is the **CAMARA API layer** (`oop/`) and the
**xApp layer** (`xapps/`). Everything else (5GC config, RAN config, Docker
networking) is infrastructure — change it carefully and only when necessary.

Full research context: read `PROJECT_CONTEXT.md` before working on
research-facing code.

---

## Repository layout

```
orca-framework/
├── bootstrap.sh          # One-time host setup — rarely needs changes
├── lab.sh                # Lab lifecycle (up/down/build/status/logs/ue/xapp)
├── docker-compose.yml    # Core stack — Open5GS, gNB, UE, OOP, Grafana
│
├── config/
│   ├── open5gs/          # 5GC config + subscriber DB (IMSI/K/OPc)
│   ├── ocudu/            # gNB ZMQ config + UE config
│   └── grafana/          # Datasource provisioning
│
├── xapps/
│   └── qod-xapp/
│       └── qod_xapp.py   # QoD xApp scaffold — A1 + KPM + RC control
│
└── repos/                # Cloned by bootstrap.sh — DO NOT edit files here
    ├── ocudu/            # gNB + UE source (single build, both binaries)
    ├── oran-sc-ric/      # O-RAN SC RIC (has its own docker-compose.yml)
    └── openop/           # ETSI OpenOP repos (built by lab.sh build)
        ├── open-exposure-gateway/        # OEG — CAMARA northbound gateway
        └── service-resource-manager/     # SRM — CAMARA→5GC/RAN translation
```

---

## Key commands

```bash
# First-time setup on a fresh VM
./bootstrap.sh

# Build all source images (15-25 min on first run, cached after)
./lab.sh build

# Lab lifecycle
./lab.sh up          # Start everything in correct dependency order
./lab.sh down        # Stop everything
./lab.sh restart     # down + up
./lab.sh status      # Table of container health and ports
./lab.sh logs [svc]  # Tail logs (omit service name for all)
./lab.sh ue          # Start OCUDU UE and attach to network
./lab.sh xapp        # Launch KPM monitoring xApp in RIC
./lab.sh clean       # Destroy all containers + volumes (destructive)
./lab.sh shell [svc] # Open bash in a running container

# Rebuild only OOP services (fast — no C++ compile)
docker compose build oop-gateway oop-orchestrator

# RIC-specific (its own compose stack)
cd repos/oran-sc-ric
docker compose up -d
docker compose logs -f e2term
docker compose exec python_xapp_runner python3 ./kpm_mon_xapp.py
```

---

## Network topology

Three Docker bridge networks:

| Network | Subnet | Purpose |
|---|---|---|
| `core` | `10.53.1.0/24` | 5GC NFs + gNB N2/N3 |
| `ran` | `10.53.2.0/24` | gNB↔UE ZMQ RF + gNB↔RIC E2 |
| `oop` | `10.53.3.0/24` | OOP↔5GC southbound (NEF/PCF) |

**Fixed IPs — do not change without updating all referencing configs:**

| Container | Network | IP | Why fixed |
|---|---|---|---|
| `lab_mongodb` | core | `10.53.1.10` | Open5GS Mongo connection |
| `lab_open5gs` | core | `10.53.1.2` | gNB AMF_ADDR must match |
| `lab_open5gs` | ran | `10.53.2.20` | N3 GTP-U endpoint |
| `lab_gnb` | core | `10.53.1.30` | Needs core net to reach AMF |
| `lab_gnb` | ran | `10.53.2.30` | ZMQ TX socket |
| `lab_ue` | ran | `10.53.2.40` | ZMQ TX socket |
| RIC e2term | ran | `10.53.2.100` | gNB E2 connects here |
| `lab_oop_gateway` | oop | `10.53.3.30` | — |
| `lab_oop_orchestrator` | oop | `10.53.3.40` | — |

The `ran` network is named `lab_ran` explicitly in docker-compose.yml because
`repos/oran-sc-ric/docker-compose.yml` references it as an external network.
Do not rename it.

---

## ZMQ RF wiring

gNB and UE communicate over ZMQ TCP sockets:

- **gNB TX** (downlink): binds `tcp://*:2000` → UE connects to `tcp://10.53.2.30:2000`
- **UE TX** (uplink): binds `tcp://*:2001` → gNB connects to `tcp://10.53.2.40:2001`

One side must bind (`*`), the other connect (by IP). Getting this backwards
causes silent RF failure — no errors, no traffic.

---

## CAMARA API layer (ETSI OpenOP)

The CAMARA layer uses the upstream ETSI OpenOP components, built from repos
cloned into `repos/openop/` by `bootstrap.sh`:

- **Open Exposure Gateway (OEG)** — Connexion/Flask app that exposes the
  northbound CAMARA APIs (Edge Cloud LCM, QoD, Traffic Influence). Swagger UI
  at `http://localhost:8080/docs/`. Source: `repos/openop/open-exposure-gateway/`.
- **Service Resource Manager (SRM)** — Connexion/Flask app that translates
  CAMARA requests into southbound calls to the 5GC and RAN adapters. The OEG
  forwards requests to the SRM at `SRM_HOST`. Source:
  `repos/openop/service-resource-manager/service-resource-manager-implementation/`.

Both images are built during `./lab.sh build`. Do not edit files inside
`repos/` — patch via volume mounts if needed.

---

## Open5GS subscriber management

Test UE credentials: `config/open5gs/subscriber_db.csv`
Format: `IMSI, K, OPc, AMF, SQN`

Default test UE:
- IMSI: `001010123456780`
- K: `00112233445566778899aabbccddeeff`
- OPc: `63bfa50ee6523365ff14c1f45f88737d`
- Algorithm: Milenage

Values must match `config/ocudu/ue_zmq.conf` exactly (case-insensitive hex).
After editing the CSV, restart `lab_open5gs`.

---

## Known issues

### RMR in oran-sc-ric (status: OPEN)
The `oran-sc-ric` image may have incomplete RMR routing table entries,
causing xApp indications to not be delivered. Before developing xApp logic,
verify:

```bash
cd repos/oran-sc-ric
docker compose exec e2term cat /opt/e2/RMR_SEED_RT
# Should show entries for mtype 12050 (RIC_INDICATION)
```

If broken, the fallback is the full O-RAN SC RIC via `ric-dep` on a `kind`
cluster. Update this section when the issue is resolved or the fallback
is implemented.

### ETSI OpenOP repos (status: ACTIVE)
The CAMARA layer uses the upstream ETSI OpenOP repos cloned into `repos/openop/`:
- `open-exposure-gateway` — OEG, CAMARA northbound (Edge Cloud LCM + QoD)
- `service-resource-manager` — SRM, CAMARA→infrastructure translation

Both are built from source during `./lab.sh build` and used directly as
Docker services (`oop-gateway`, `oop-orchestrator`).

### OCUDU gNB ZMQ build (status: RESOLVED)
Must be built with `-DENABLE_EXPORT=ON -DENABLE_ZEROMQ=ON`.
This is set in `docker-compose.yml` under `ocudu-gnb.build.args.EXTRA_CMAKE_ARGS`.
If you see "Factory for radio type zmq not found", rebuild with `./lab.sh build`.

---

## Hard rules

- **Never edit files inside `repos/`** — they are cloned dependencies.
  Patch via volume mounts if needed, and document the patch here.
- **Never change fixed container IPs** without updating every config that
  references them.
- **Never add `privileged: true`** to new containers without a documented reason.
  Currently only `lab_open5gs` needs it (UPF TUN device).
- **Never commit real credentials** — subscriber DB contains test-only values.
- **Never rename the `lab_ran` network** — referenced externally by oran-sc-ric.

---

## Adding a new CAMARA API

The OEG and SRM are upstream ETSI OpenOP components built from `repos/openop/`.
Do not edit files inside `repos/` directly — instead, extend via volume mounts
or contribute upstream. To rebuild after changes:

```bash
docker compose build oop-gateway oop-orchestrator && ./lab.sh restart
```