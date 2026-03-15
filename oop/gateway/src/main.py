"""
ETSI OpenOP — CAMARA API Gateway
=================================
Northbound CAMARA-compliant API exposure layer.

This scaffold implements the CAMARA Quality on Demand (QoD) API as the
primary research target, with stubs for other CAMARA APIs. The translation
logic (southbound calls to Open5GS NEF/PCF) lives in the routers.

Reference: https://github.com/camaraproject/QualityOnDemand
CAMARA API Design Guide: https://github.com/camaraproject/Commonalities
"""

from contextlib import asynccontextmanager
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
import httpx
import logging
import yaml
import os

from .routers import qod, device_status, health
from .config import Settings

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("oop-gateway")

settings = Settings()


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup / shutdown lifecycle."""
    logger.info("OOP Gateway starting up...")
    # Verify connectivity to orchestrator
    async with httpx.AsyncClient() as client:
        try:
            resp = await client.get(f"{settings.orchestrator_url}/healthz", timeout=5)
            logger.info(f"Orchestrator reachable: {resp.status_code}")
        except Exception as e:
            logger.warning(f"Orchestrator not reachable at startup: {e} — will retry per-request")
    yield
    logger.info("OOP Gateway shutting down...")


app = FastAPI(
    title="ETSI OpenOP — CAMARA API Gateway",
    description="""
## 5G Research Lab — CAMARA API Exposure Layer

This gateway implements CAMARA-compliant APIs over an Open5GS 5G Core.
It translates standardised northbound CAMARA API calls into southbound
3GPP NEF/PCF API calls.

### Implemented APIs
- **Quality on Demand (QoD)** — create/retrieve/delete QoS sessions
- **Device Status** — reachability and connectivity status

### Research Extension Points
- Add new CAMARA APIs by creating routers in `src/routers/`
- Modify southbound translation in `src/translators/`
- The orchestrator handles RAN-level control via A1 to the Near-RT RIC
""",
    version="0.1.0",
    docs_url="/docs",
    redoc_url="/redoc",
    openapi_url="/openapi.json",
    lifespan=lifespan,
)

# CORS — permissive for lab use; tighten in production
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Routers ───────────────────────────────────────────────────────────────────
# CAMARA API path structure: /camara/{api-name}/{version}/
app.include_router(health.router)
app.include_router(qod.router, prefix="/camara/quality-on-demand/v0")
app.include_router(device_status.router, prefix="/camara/device-status/v0")


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    logger.error(f"Unhandled exception: {exc}", exc_info=True)
    return JSONResponse(
        status_code=500,
        content={
            "status": 500,
            "code": "INTERNAL",
            "message": "An unexpected error occurred in the CAMARA gateway.",
        },
    )


@app.get("/", include_in_schema=False)
async def root():
    return {
        "service": "ETSI OpenOP CAMARA Gateway",
        "version": "0.1.0",
        "apis": {
            "quality-on-demand": "/camara/quality-on-demand/v0",
            "device-status": "/camara/device-status/v0",
        },
        "docs": "/docs",
    }
