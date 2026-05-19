import logging
import os
from typing import Any, Dict, List, Tuple

import connexion
import requests
from edge_cloud_management_api.configs.env_config import config

logger = logging.getLogger(__name__)


def retrieve_qos_profiles() -> Tuple[List[Dict[str, Any]], int]:
    """Proxy QoS Profiles retrieval requests to the SRM endpoint."""
    base_url = _resolve_srm_base_url()
    target_url = f"{base_url.rstrip('/')}/qos-profiles/v1/retrieve-qos-profiles"
    timeout_seconds = float(os.environ.get("QOS_PROFILES_TIMEOUT", "5"))

    payload = _get_json_body()
    headers = _forward_headers(["authorization", "x-correlator"])

    try:
        response = requests.post(
            target_url,
            json=payload,
            headers=headers,
            timeout=timeout_seconds,
            verify=False,
        )
        return _safe_response(response)
    except requests.RequestException as exc:
        logger.warning("QoS Profiles backend unavailable: %s", exc)
        return (
            {
                "status": 502,
                "code": "BAD_GATEWAY",
                "message": "QoS Profiles backend unavailable",
                "details": str(exc),
            },
            502,
        )


def get_qos_profile(name: str) -> Tuple[Dict[str, Any], int]:
    """Proxy QoS Profile lookup requests to the SRM endpoint."""
    base_url = _resolve_srm_base_url()
    target_url = f"{base_url.rstrip('/')}/qos-profiles/v1/qos-profiles/{name}"
    timeout_seconds = float(os.environ.get("QOS_PROFILES_TIMEOUT", "5"))

    headers = _forward_headers(["authorization", "x-correlator"])

    try:
        response = requests.get(target_url, headers=headers, timeout=timeout_seconds, verify=False)
        return _safe_response(response)
    except requests.RequestException as exc:
        logger.warning("QoS Profiles backend unavailable: %s", exc)
        return (
            {
                "status": 502,
                "code": "BAD_GATEWAY",
                "message": "QoS Profiles backend unavailable",
                "details": str(exc),
            },
            502,
        )


def _resolve_srm_base_url() -> str:
    base_url = os.environ.get("QOS_PROFILES_SRM_BASE_URL")
    if base_url:
        return base_url

    base_url = os.environ.get("SRM_HOST") or config.SRM_HOST or "http://10.53.3.40:8080/srm/1.0.0"
    return base_url


def _get_json_body() -> Dict[str, Any]:
    if not connexion.request:
        return {}
    payload = connexion.request.get_json(silent=True)
    if payload is None:
        return {}
    if isinstance(payload, dict):
        return payload
    return {"value": payload}


def _forward_headers(allowed: List[str]) -> Dict[str, str]:
    if not connexion.request:
        return {}

    outgoing: Dict[str, str] = {}
    for header in allowed:
        value = connexion.request.headers.get(header)
        if value:
            outgoing[header] = value
    return outgoing


def _safe_response(response: requests.Response) -> Tuple[Dict[str, Any], int]:
    try:
        payload = response.json()
    except ValueError:
        payload = {
            "status": response.status_code,
            "code": "INVALID_RESPONSE",
            "message": "QoS Profiles response was not valid JSON",
            "raw": response.text,
        }
    return payload, response.status_code
