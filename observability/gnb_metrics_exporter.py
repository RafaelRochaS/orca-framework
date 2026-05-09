#!/usr/bin/env python3

import json
import os
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.error import URLError
from urllib.parse import parse_qs, urlencode, urlparse, urlunparse
from urllib.request import Request, urlopen

CONNECTIVITY_INSIGHTS_URL = os.environ.get(
    "CONNECTIVITY_INSIGHTS_URL",
    "http://python_xapp_runner:8093/connectivity-insights",
)
CONNECTIVITY_WINDOW_SECONDS = int(os.environ.get("CONNECTIVITY_WINDOW_SECONDS", "60"))
CONNECTIVITY_TIMEOUT_SECONDS = float(os.environ.get("CONNECTIVITY_TIMEOUT_SECONDS", "2.5"))
EXPORTER_HOST = os.environ.get("EXPORTER_HOST", "0.0.0.0")
EXPORTER_PORT = int(os.environ.get("EXPORTER_PORT", "9102"))


def _append_window(url: str, window_seconds: int) -> str:
    parsed = urlparse(url)
    query = parse_qs(parsed.query)
    query.setdefault("windowSeconds", [str(window_seconds)])
    encoded = urlencode(query, doseq=True)
    return urlunparse(parsed._replace(query=encoded))


def _to_float(value):
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _fetch_metrics():
    start = time.time()
    url = _append_window(CONNECTIVITY_INSIGHTS_URL, CONNECTIVITY_WINDOW_SECONDS)
    try:
        request = Request(url, headers={"Accept": "application/json"})
        with urlopen(request, timeout=CONNECTIVITY_TIMEOUT_SECONDS) as response:
            body = response.read().decode("utf-8")
        payload = json.loads(body)
    except (URLError, ValueError, OSError) as exc:
        return {
            "up": 0.0,
            "error": str(exc),
            "duration": time.time() - start,
        }

    additional = payload.get("additionalKPIs", {})
    return {
        "up": 1.0,
        "duration": time.time() - start,
        "downstream_kbps": _to_float(additional.get("downstreamThroughputKbps")),
        "upstream_kbps": _to_float(additional.get("upstreamThroughputKbps")),
        "packet_delay_ms": _to_float(additional.get("packetDelayMs")),
        "jitter_ms": _to_float(additional.get("jitterMs")),
        "packet_loss_pct": _to_float(additional.get("packetLossPct")),
    }


def _format_value(value):
    if value is None:
        return "nan"
    return f"{value}"


def _render_metrics(values):
    lines = [
        "# HELP orca_gnb_metrics_up Connectivity Insights scrape success (1=up, 0=down)",
        "# TYPE orca_gnb_metrics_up gauge",
        f"orca_gnb_metrics_up {values.get('up', 0.0)}",
        "# HELP orca_gnb_metrics_scrape_duration_seconds Connectivity Insights scrape duration",
        "# TYPE orca_gnb_metrics_scrape_duration_seconds gauge",
        f"orca_gnb_metrics_scrape_duration_seconds {values.get('duration', 0.0)}",
        "# HELP orca_gnb_metrics_window_seconds Metrics window requested from the xApp",
        "# TYPE orca_gnb_metrics_window_seconds gauge",
        f"orca_gnb_metrics_window_seconds {CONNECTIVITY_WINDOW_SECONDS}",
        "# HELP orca_gnb_downstream_kbps Aggregated downlink throughput in kbps",
        "# TYPE orca_gnb_downstream_kbps gauge",
        f"orca_gnb_downstream_kbps {_format_value(values.get('downstream_kbps'))}",
        "# HELP orca_gnb_upstream_kbps Aggregated uplink throughput in kbps",
        "# TYPE orca_gnb_upstream_kbps gauge",
        f"orca_gnb_upstream_kbps {_format_value(values.get('upstream_kbps'))}",
        "# HELP orca_gnb_packet_delay_ms Aggregated packet delay in ms",
        "# TYPE orca_gnb_packet_delay_ms gauge",
        f"orca_gnb_packet_delay_ms {_format_value(values.get('packet_delay_ms'))}",
        "# HELP orca_gnb_jitter_ms Aggregated jitter in ms",
        "# TYPE orca_gnb_jitter_ms gauge",
        f"orca_gnb_jitter_ms {_format_value(values.get('jitter_ms'))}",
        "# HELP orca_gnb_packet_loss_pct Aggregated packet loss in percent",
        "# TYPE orca_gnb_packet_loss_pct gauge",
        f"orca_gnb_packet_loss_pct {_format_value(values.get('packet_loss_pct'))}",
    ]
    return "\n".join(lines) + "\n"


class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return

        values = _fetch_metrics()
        body = _render_metrics(values).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        return


def main():
    server = HTTPServer((EXPORTER_HOST, EXPORTER_PORT), MetricsHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
