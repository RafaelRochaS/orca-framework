"""
CAMARA Quality on Demand (QoD) API — v0.11.0
=============================================
Reference spec: https://github.com/camaraproject/QualityOnDemand

This router implements the QoD session lifecycle:
  POST   /sessions          — Create a QoS session
  GET    /sessions/{id}     — Retrieve session info
  DELETE /sessions/{id}     — Delete a QoS session
  GET    /sessions          — List active sessions (lab extension)

Southbound translation:
  QoD API → Open5GS PCF (via N5/Rx-like policy provisioning) via Orchestrator
  The Orchestrator can also signal the Near-RT RIC via A1 for RAN-level QoS enforcement.

This is the PRIMARY EXTENSION POINT for your research:
  - The translate_to_5gc_policy() function maps CAMARA QoD profiles to 3GPP PCC rules
  - Add your own QoD profile types or modify the mapping logic here
  - The xApp in xapps/qod-xapp/ handles the RAN-side enforcement
"""

import uuid
import httpx
from datetime import datetime, timezone, timedelta
from typing import Optional, List
from enum import Enum

from fastapi import APIRouter, HTTPException, BackgroundTasks, Header
from pydantic import BaseModel, Field, field_validator

from ..config import Settings

router = APIRouter(tags=["Quality on Demand"])
settings = Settings()

# In-memory session store (replace with Redis/DB for persistence)
_sessions: dict = {}


# =============================================================================
# CAMARA QoD Data Models
# Based on CAMARA QualityOnDemand API v0.11.0 schema
# =============================================================================

class QosProfile(str, Enum):
    """
    Standard CAMARA QoD profiles.
    Extend this enum for novel profiles (research contribution opportunity).
    """
    QOS_E = "QOS_E"   # Best effort (no guarantee)
    QOS_S = "QOS_S"   # Small (≥2 Mbps DL, ≥1 Mbps UL, latency < 300ms)
    QOS_M = "QOS_M"   # Medium (≥10 Mbps DL, ≥5 Mbps UL, latency < 100ms)
    QOS_L = "QOS_L"   # Large (≥50 Mbps DL, ≥25 Mbps UL, latency < 50ms)


class SessionStatus(str, Enum):
    REQUESTED = "REQUESTED"
    AVAILABLE = "AVAILABLE"
    UNAVAILABLE = "UNAVAILABLE"
    DELETED = "DELETED"


class DeviceIpv4Addr(BaseModel):
    public_address: Optional[str] = None
    private_address: Optional[str] = None
    public_port: Optional[int] = None


class Device(BaseModel):
    """Target device identification (CAMARA standard)."""
    ipv4_address: Optional[DeviceIpv4Addr] = None
    ipv6_address: Optional[str] = None
    phone_number: Optional[str] = None
    network_access_identifier: Optional[str] = None


class ApplicationServer(BaseModel):
    ipv4_address: Optional[str] = None
    ipv6_address: Optional[str] = None


class PortRange(BaseModel):
    from_: int = Field(alias="from")
    to: int


class PortsSpec(BaseModel):
    ranges: Optional[List[PortRange]] = None
    ports: Optional[List[int]] = None


class CreateSession(BaseModel):
    """Request body for POST /sessions (CAMARA QoD)."""
    device: Device
    application_server: ApplicationServer
    qos_profile: QosProfile
    device_ports: Optional[PortsSpec] = None
    application_server_ports: Optional[PortsSpec] = None
    duration: Optional[int] = Field(
        default=3600,
        ge=1,
        le=86400,
        description="Session duration in seconds (1s – 24h)"
    )
    notification_url: Optional[str] = None
    notification_auth_token: Optional[str] = None

    @field_validator("duration")
    @classmethod
    def validate_duration(cls, v):
        if v is not None and v > 86400:
            raise ValueError("duration cannot exceed 86400 seconds (24 hours)")
        return v


class SessionInfo(BaseModel):
    """Response model for QoD session (CAMARA QoD)."""
    session_id: str
    device: Device
    application_server: ApplicationServer
    qos_profile: QosProfile
    duration: Optional[int]
    status: SessionStatus
    started_at: Optional[datetime] = None
    expires_at: Optional[datetime] = None
    status_info: Optional[str] = None


# =============================================================================
# QoD Profile → 5GC Policy Mapping
# This is where CAMARA abstraction meets 3GPP reality.
# Modify this for your research — e.g., add new profiles, URLLC mappings, etc.
# =============================================================================

QOS_PROFILE_MAP = {
    QosProfile.QOS_E: {
        "5qi": 9,
        "max_dl_mbps": None,   # best effort
        "max_ul_mbps": None,
        "priority": 90,
    },
    QosProfile.QOS_S: {
        "5qi": 8,
        "max_dl_mbps": 2,
        "max_ul_mbps": 1,
        "priority": 70,
        "packet_delay_budget_ms": 300,
    },
    QosProfile.QOS_M: {
        "5qi": 7,
        "max_dl_mbps": 10,
        "max_ul_mbps": 5,
        "priority": 50,
        "packet_delay_budget_ms": 100,
    },
    QosProfile.QOS_L: {
        "5qi": 1,    # GBR — maps to 5QI 1 (conversational voice level priority)
        "max_dl_mbps": 50,
        "max_ul_mbps": 25,
        "priority": 20,
        "packet_delay_budget_ms": 50,
    },
}


async def translate_and_apply_policy(session_id: str, request: CreateSession):
    """
    Southbound translation: CAMARA QoD → 5GC PCF policy + RIC A1 policy.

    Flow:
      1. Map QoD profile to 3GPP PCC rule parameters
      2. POST policy to Orchestrator (which calls Open5GS PCF via N5)
      3. Orchestrator optionally signals Near-RT RIC via A1 for RAN enforcement
    """
    profile_params = QOS_PROFILE_MAP[request.qos_profile]

    orchestrator_payload = {
        "session_id": session_id,
        "device": request.device.model_dump(),
        "qos_params": profile_params,
        "duration_s": request.duration,
        "action": "create",
    }

    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.post(
                f"{settings.orchestrator_url}/internal/qod/sessions",
                json=orchestrator_payload,
            )
            resp.raise_for_status()
            _sessions[session_id]["status"] = SessionStatus.AVAILABLE
    except Exception as e:
        _sessions[session_id]["status"] = SessionStatus.UNAVAILABLE
        _sessions[session_id]["status_info"] = str(e)


# =============================================================================
# API Endpoints
# =============================================================================

@router.post("/sessions", response_model=SessionInfo, status_code=201)
async def create_session(
    request: CreateSession,
    background_tasks: BackgroundTasks,
    x_correlator: Optional[str] = Header(default=None),
):
    """
    Create a QoS session for a device.

    The session is created asynchronously — the response returns immediately
    with status REQUESTED, then transitions to AVAILABLE or UNAVAILABLE.
    """
    session_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc)
    expires_at = now + timedelta(seconds=request.duration or 3600)

    session = {
        "session_id": session_id,
        "device": request.device,
        "application_server": request.application_server,
        "qos_profile": request.qos_profile,
        "duration": request.duration,
        "status": SessionStatus.REQUESTED,
        "started_at": now,
        "expires_at": expires_at,
        "status_info": "Session is being provisioned",
    }
    _sessions[session_id] = session

    # Apply policy asynchronously (5GC + RIC signalling)
    background_tasks.add_task(translate_and_apply_policy, session_id, request)

    return SessionInfo(**session)


@router.get("/sessions/{session_id}", response_model=SessionInfo)
async def get_session(session_id: str):
    """Retrieve a QoS session by ID."""
    if session_id not in _sessions:
        raise HTTPException(
            status_code=404,
            detail={
                "status": 404,
                "code": "NOT_FOUND",
                "message": f"Session {session_id} not found",
            },
        )
    return SessionInfo(**_sessions[session_id])


@router.delete("/sessions/{session_id}", status_code=204)
async def delete_session(session_id: str):
    """Delete (revoke) a QoS session."""
    if session_id not in _sessions:
        raise HTTPException(status_code=404, detail={"code": "NOT_FOUND"})

    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            await client.delete(
                f"{settings.orchestrator_url}/internal/qod/sessions/{session_id}",
            )
    except Exception:
        pass  # Best effort on deletion

    _sessions[session_id]["status"] = SessionStatus.DELETED
    del _sessions[session_id]


@router.get("/sessions", response_model=List[SessionInfo])
async def list_sessions():
    """List all active QoS sessions (lab/debug extension — not in CAMARA spec)."""
    return [SessionInfo(**s) for s in _sessions.values()]
