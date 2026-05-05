import logging
import os
from typing import Any, Dict, Tuple

import connexion
import requests
from edge_cloud_management_api.configs.env_config import config

logger = logging.getLogger(__name__)


def get_connectivity_insights() -> Tuple[Dict[str, Any], int]:
    """Proxy Connectivity Insights requests to the SRM endpoint."""
    base_url = os.environ.get("CONNECTIVITY_INSIGHTS_SRM_BASE_URL")
    if not base_url:
        base_url = os.environ.get("SRM_HOST") or config.SRM_HOST or "http://10.53.3.40:8080/srm/1.0.0"
        if not base_url.rstrip("/").endswith("/insights"):
            base_url = f"{base_url.rstrip('/')}/insights"
    timeout_seconds = float(os.environ.get("CONNECTIVITY_INSIGHTS_TIMEOUT", "5"))

    params = _extract_query_params()
    target_url = f"{base_url.rstrip('/')}/connectivity-insights"

    try:
        response = requests.get(target_url, params=params, timeout=timeout_seconds, verify=False)
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

    request = connexion.request
    args = None
    if hasattr(request, "args"):
        args = request.args
    elif hasattr(request, "query_params"):
        args = request.query_params

    if not args:
        return params

    for key in args:
        if hasattr(args, "getlist"):
            values = args.getlist(key)
        else:
            value = args.get(key)
            values = [] if value is None else [value]
        if not values:
            continue
        if len(values) == 1:
            params[key] = str(values[0])
        else:
            params[key] = ",".join(str(value) for value in values)
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
