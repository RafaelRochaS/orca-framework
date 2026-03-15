"""
ETSI OpenOP — Service Orchestrator
====================================
Receives CAMARA API requests from the Gateway and translates them to:
  1. Open5GS PCF (N5 interface) — for 5GC-level QoS enforcement
  2. O-RAN SC Near-RT RIC (A1 interface) — for RAN-level QoS enforcement
     via the QoD xApp running on the RIC

This is the critical southbound translation layer for your research.
The CAMARA → 3GPP → O-RAN mapping logic lives here.
"""

from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from pydantic_settings import BaseSettings
from typing import Optional, Dict, Any
import httpx
import logging
import uuid

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("oop-orchestrator")


class Settings(BaseSettings):
    open5gs_pcf_url: str = "http://10.53.3.20:7000"
    open5gs_smf_url: str = "http://10.53.3.20:7001"
    ric_a1_url: str = "http://10.53.2.100:10000"    # Near-RT RIC A1 mediator
    log_level: str = "INFO"

    class Config:
        env_file = ".env"


settings = Settings()

# In-memory state (replace with Redis for multi-instance)
_active_policies: Dict[str, Any] = {}


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("OOP Orchestrator starting up...")
    yield
    logger.info("OOP Orchestrator shutting down...")


app = FastAPI(
    title="ETSI OpenOP Orchestrator",
    description="CAMARA API southbound translation — 5GC PCF + O-RAN RIC A1",
    version="0.1.0",
    lifespan=lifespan,
)


# =============================================================================
# Internal API (called by the Gateway — not exposed externally)
# =============================================================================

class QoSSessionRequest(BaseModel):
    session_id: str
    device: Dict[str, Any]
    qos_params: Dict[str, Any]
    duration_s: Optional[int] = 3600
    action: str = "create"   # "create" | "delete"


@app.post("/internal/qod/sessions", status_code=201)
async def create_qod_policy(request: QoSSessionRequest):
    """
    Translate a QoD session request into:
    1. Open5GS PCF policy (N5/Gy-like provisioning)
    2. A1 policy to Near-RT RIC (for RAN-side enforcement via xApp)
    """
    results = {}

    # ── Step 1: Open5GS PCF Policy ───────────────────────────────────────────
    pcf_policy = _build_pcf_policy(request)
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.post(
                f"{settings.open5gs_pcf_url}/npcf-policyauthorization/v1/app-sessions",
                json=pcf_policy,
            )
            results["pcf"] = {"status": resp.status_code, "ok": resp.is_success}
            if not resp.is_success:
                logger.warning(f"PCF returned {resp.status_code}: {resp.text}")
    except Exception as e:
        logger.warning(f"PCF unreachable: {e} — policy applied in-memory only")
        results["pcf"] = {"status": "unreachable", "ok": False}

    # ── Step 2: A1 Policy to Near-RT RIC ────────────────────────────────────
    # This signals the QoD xApp on the RIC to enforce RAN-level QoS
    a1_policy = _build_a1_policy(request)
    policy_id = str(uuid.uuid4())
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.put(
                f"{settings.ric_a1_url}/a1-p/policytypes/20008/policies/{policy_id}",
                json=a1_policy,
            )
            results["ric_a1"] = {"policy_id": policy_id, "status": resp.status_code, "ok": resp.is_success}
            if not resp.is_success:
                logger.warning(f"RIC A1 returned {resp.status_code}: {resp.text}")
    except Exception as e:
        logger.warning(f"RIC A1 unreachable: {e} — RAN-level QoS enforcement skipped")
        results["ric_a1"] = {"status": "unreachable", "ok": False}

    _active_policies[request.session_id] = {
        "qos_params": request.qos_params,
        "a1_policy_id": policy_id,
        "pcf_result": results.get("pcf"),
    }

    logger.info(f"QoD policy created for session {request.session_id}: {results}")
    return {"session_id": request.session_id, "results": results}


@app.delete("/internal/qod/sessions/{session_id}", status_code=204)
async def delete_qod_policy(session_id: str):
    """Revoke QoS policies for a deleted session."""
    if session_id not in _active_policies:
        raise HTTPException(status_code=404)

    policy = _active_policies.pop(session_id)
    a1_policy_id = policy.get("a1_policy_id")

    if a1_policy_id:
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                await client.delete(
                    f"{settings.ric_a1_url}/a1-p/policytypes/20008/policies/{a1_policy_id}"
                )
        except Exception as e:
            logger.warning(f"Could not delete A1 policy {a1_policy_id}: {e}")

    logger.info(f"QoD policy revoked for session {session_id}")


@app.get("/internal/policies")
async def list_policies():
    """Debug endpoint — list all active policies."""
    return _active_policies


@app.get("/healthz", include_in_schema=False)
async def health():
    return {"status": "ok", "service": "oop-orchestrator"}


# =============================================================================
# Translation helpers
# =============================================================================

def _build_pcf_policy(request: QoSSessionRequest) -> Dict[str, Any]:
    """
    Build an Open5GS PCF (Npcf_PolicyAuthorization) policy request.
    Maps CAMARA QoD parameters to 3GPP PCC rules.

    Reference: 3GPP TS 29.514 (Npcf_PolicyAuthorization)
    """
    qp = request.qos_params
    media_component = {
        "medCompN": 1,
        "medType": "DATA",
        "fDescs": [
            {"fDir": "DOWNLINK", "ipFlowDescs": []},
            {"fDir": "UPLINK", "ipFlowDescs": []},
        ],
    }

    if qp.get("max_dl_mbps"):
        media_component["marBwDl"] = f"{qp['max_dl_mbps'] * 1000000}"  # bps
    if qp.get("max_ul_mbps"):
        media_component["marBwUl"] = f"{qp['max_ul_mbps'] * 1000000}"

    return {
        "supi": _extract_device_id(request.device),
        "medComponents": {"1": media_component},
        "reqQosAlt": {
            "altQosParamIndex": 1,
            "5qi": qp.get("5qi", 9),
            "arp": {
                "prioLvl": qp.get("priority", 90),
                "preemptCap": "NOT_PREEMPT",
                "preemptVuln": "NOT_PREEMPTABLE",
            },
        },
        "resPrio": "PRIO_1" if qp.get("priority", 90) < 50 else "PRIO_2",
    }


def _build_a1_policy(request: QoSSessionRequest) -> Dict[str, Any]:
    """
    Build an A1 policy for the Near-RT RIC.
    The QoD xApp (running on the RIC) subscribes to this policy type
    and enforces RAN-level scheduling priority via E2SM-RC.

    Policy Type ID: 20008 (custom — register this in the RIC)
    Reference: O-RAN.WG2.A1AP-v04.00
    """
    qp = request.qos_params
    device_id = _extract_device_id(request.device)

    return {
        "scope": {
            "ueId": device_id,
        },
        "resources": {
            "schedulerWeight": max(0, 100 - qp.get("priority", 90)),  # inverse of 3GPP priority
            "5qi": qp.get("5qi", 9),
            "guaranteedDlMbps": qp.get("max_dl_mbps"),
            "guaranteedUlMbps": qp.get("max_ul_mbps"),
            "packetDelayBudgetMs": qp.get("packet_delay_budget_ms"),
        },
        "expireTime": None,  # governed by QoD session duration
    }


def _extract_device_id(device: Dict[str, Any]) -> str:
    """Best-effort device identifier extraction from CAMARA Device object."""
    ipv4 = device.get("ipv4_address", {})
    if isinstance(ipv4, dict) and ipv4.get("private_address"):
        return ipv4["private_address"]
    if device.get("phone_number"):
        return device["phone_number"]
    if device.get("network_access_identifier"):
        return device["network_access_identifier"]
    return "unknown"
