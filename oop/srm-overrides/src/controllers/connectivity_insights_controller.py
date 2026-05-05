import logging
import os
from typing import Any, Dict, Tuple

import connexion
import requests

logger = logging.getLogger(__name__)


def get_connectivity_insights() -> Tuple[Dict[str, Any], int]:
    """Proxy Connectivity Insights requests to the xApp HTTP endpoint."""
    base_url = os.environ.get("CONNECTIVITY_INSIGHTS_BASE_URL", "http://10.53.4.50:8093")
    timeout_seconds = float(os.environ.get("CONNECTIVITY_INSIGHTS_TIMEOUT", "5"))

    params = _extract_query_params()
    target_url = f"{base_url.rstrip('/')}/connectivity-insights"

    try:
        response = requests.get(target_url, params=params, timeout=timeout_seconds)
        return _safe_response(response)
    except requests.RequestException as exc:
        logger.warning("Connectivity Insights backend unavailable: %s", exc)
        return {
            "status": 502,
            "code": "BAD_GATEWAY",
            "message": "Connectivity Insights backend unavailable",
            "details": str(exc),
        }, 502


def _extract_query_params() -> Dict[str, str]:
    params: Dict[str, str] = {}
    if not connexion.request:
        return params

    for key in connexion.request.args:
        values = connexion.request.args.getlist(key)
        if not values:
            continue
        if len(values) == 1:
            params[key] = values[0]
        else:
            params[key] = ",".join(values)
    return params


def _safe_response(response: requests.Response) -> Tuple[Dict[str, Any], int]:
    try:
        payload = response.json()
    except ValueError:
        payload = {
            "status": response.status_code,
            "code": "INVALID_RESPONSE",
            "message": "Connectivity Insights response was not valid JSON",
            "raw": response.text,
        }
    return payload, response.status_code
