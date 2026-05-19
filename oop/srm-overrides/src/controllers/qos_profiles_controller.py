from typing import Any, Dict, List, Tuple

import connexion


def retrieve_qos_profiles() -> Tuple[List[Dict[str, Any]], int]:
    """Return mock QoS profiles for early integration testing."""
    request_body = _get_json_body()
    name_filter = request_body.get("name") if isinstance(request_body, dict) else None
    status_filter = request_body.get("status") if isinstance(request_body, dict) else None

    profiles = _mock_profiles()
    if name_filter:
        profiles = [profile for profile in profiles if profile["name"] == name_filter]
    if status_filter:
        profiles = [profile for profile in profiles if profile["status"] == status_filter]

    return profiles, 200


def get_qos_profile(name: str) -> Tuple[Dict[str, Any], int]:
    """Return a single mock QoS profile by name."""
    for profile in _mock_profiles():
        if profile["name"] == name:
            return profile, 200

    return {
        "status": 404,
        "code": "NOT_FOUND",
        "message": "QoS profile not found",
    }, 404


def _get_json_body() -> Dict[str, Any]:
    if not connexion.request:
        return {}
    payload = connexion.request.get_json(silent=True)
    if payload is None:
        return {}
    if isinstance(payload, dict):
        return payload
    return {"value": payload}


def _mock_profiles() -> List[Dict[str, Any]]:
    return [
        {
            "name": "voice",
            "description": "QoS profile for high-quality interactive voice",
            "status": "ACTIVE",
            "targetMinUpstreamRate": {"value": 100, "unit": "kbps"},
            "targetMinDownstreamRate": {"value": 100, "unit": "kbps"},
            "minDuration": {"value": 1, "unit": "Days"},
            "maxDuration": {"value": 10, "unit": "Days"},
            "priority": 10,
            "packetDelayBudget": {"value": 50, "unit": "Milliseconds"},
            "jitter": {"value": 5, "unit": "Milliseconds"},
            "packetErrorLossRate": 3,
            "l4sQueueType": "non-l4s-queue",
        },
        {
            "name": "video",
            "description": "QoS profile for adaptive video streaming",
            "status": "ACTIVE",
            "targetMinUpstreamRate": {"value": 500, "unit": "kbps"},
            "targetMinDownstreamRate": {"value": 1500, "unit": "kbps"},
            "minDuration": {"value": 5, "unit": "Minutes"},
            "maxDuration": {"value": 2, "unit": "Hours"},
            "priority": 20,
            "packetDelayBudget": {"value": 100, "unit": "Milliseconds"},
            "jitter": {"value": 10, "unit": "Milliseconds"},
            "packetErrorLossRate": 4,
            "l4sQueueType": "mixed-queue",
        },
    ]
