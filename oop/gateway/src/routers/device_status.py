"""
CAMARA Device Status API — stub implementation
==============================================
Reference: https://github.com/camaraproject/DeviceStatus

Provides connectivity and reachability status for devices.
Southbound: queries Open5GS AMF (via NEF) for UE registration state.
"""

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from typing import Optional
from enum import Enum
import httpx
from ..config import Settings

router = APIRouter(tags=["Device Status"])
settings = Settings()


class ConnectivityStatus(str, Enum):
    CONNECTED_SMS = "CONNECTED_SMS"
    CONNECTED_DATA = "CONNECTED_DATA"
    NOT_CONNECTED = "NOT_CONNECTED"


class ReachabilityStatus(str, Enum):
    REACHABLE = "REACHABLE"
    NOT_REACHABLE = "NOT_REACHABLE"


class Device(BaseModel):
    ipv4_address: Optional[str] = None
    phone_number: Optional[str] = None
    network_access_identifier: Optional[str] = None


class DeviceStatusResponse(BaseModel):
    connectivity_status: ConnectivityStatus
    reachability_status: Optional[ReachabilityStatus] = None


@router.post("/connectivity", response_model=DeviceStatusResponse)
async def get_connectivity_status(device: Device):
    """
    Get the connectivity status of a device.
    Queries Open5GS AMF (via NEF) for UE registration state.

    Research note: This API is a good candidate for O-RAN enrichment —
    the Near-RT RIC KPM xApp can provide more granular per-UE metrics
    than what the 5GC NEF alone exposes.
    """
    # TODO: implement real NEF query when Open5GS NEF is available
    # For now, return a stub response
    return DeviceStatusResponse(
        connectivity_status=ConnectivityStatus.CONNECTED_DATA,
        reachability_status=ReachabilityStatus.REACHABLE,
    )
