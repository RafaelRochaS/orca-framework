#!/usr/bin/env python3

import argparse
import asyncio
import json
import logging
import os
import signal
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Iterable, List, Mapping, Optional, Tuple
from urllib.parse import parse_qs, urlparse

try:
    from pydantic import BaseModel, Field

    _PYDANTIC_AVAILABLE = True
except Exception as exc:  # pragma: no cover - only used if pydantic is unavailable
    _PYDANTIC_AVAILABLE = False

    class BaseModel:  # type: ignore[misc]
        def __init__(self, **data: Any) -> None:
            self.__dict__.update(data)

        def model_dump(self) -> Dict[str, Any]:
            return dict(self.__dict__)

    def Field(default: Any, **_: Any) -> Any:  # type: ignore[misc]
        return default


logger = logging.getLogger("connectivity-insights-xapp")


@dataclass(frozen=True)
class DeviceDefaults:
    phone_number: str
    network_access_identifier: str
    ipv4_public_address: str
    ipv4_public_port: int
    ipv6_address: str


@dataclass(frozen=True)
class MetricsPayload:
    e2_node_id: str
    ue_id: Optional[int]
    timestamp: Optional[datetime]
    metrics: Mapping[str, Any]


class IPv4Address(BaseModel):
    publicAddress: str = Field(...)
    publicPort: int = Field(...)


class DeviceInfo(BaseModel):
    phoneNumber: str = Field(...)
    networkAccessIdentifier: str = Field(...)
    ipv4Address: IPv4Address = Field(...)
    ipv6Address: str = Field(...)


class ConnectivityInsightsResponse(BaseModel):
    packetDelayBudget: str = Field(...)
    targetMinDownstreamRate: str = Field(...)
    targetMinUpstreamRate: str = Field(...)
    packetlossErrorRate: str = Field(...)
    jitter: str = Field(...)
    additionalKPIs: Dict[str, str] = Field(...)
    device: DeviceInfo = Field(...)


class SdlMetricsClient:
    def __init__(self, namespace: str, key_prefix: str) -> None:
        """Wrap SDL access for metrics retrieval."""
        self._namespace = namespace
        self._key_prefix = key_prefix
        self._enabled = True
        self._sdl = None
        try:
            import ricsdl

            self._sdl = ricsdl.SDL()
        except Exception as exc:
            logger.warning("SDL disabled: %s", exc)
            self._enabled = False

    async def fetch_metrics(
        self, e2_node_id: Optional[str], ue_ids: Optional[List[int]]
    ) -> List[MetricsPayload]:
        """Fetch the latest metrics payloads from SDL."""
        if not self._enabled or self._sdl is None:
            return []

        raw_entries: Dict[str, Any] = {}
        if e2_node_id:
            keys = self._build_keys(e2_node_id, ue_ids)
            raw_entries = self._get_by_keys(keys)
        else:
            raw_entries = self._find_by_prefix(self._key_prefix)

        payloads: List[MetricsPayload] = []
        for value in raw_entries.values():
            payload = self._decode_payload(value)
            if payload:
                payloads.append(payload)
        return payloads

    def _build_keys(self, e2_node_id: str, ue_ids: Optional[List[int]]) -> List[str]:
        keys = [f"{self._key_prefix}{e2_node_id}:cell"]
        for ue_id in ue_ids or []:
            keys.append(f"{self._key_prefix}{e2_node_id}:ue:{ue_id}")
        return keys

    def _find_by_prefix(self, prefix: str) -> Dict[str, Any]:
        pattern = f"{prefix}*"
        for name in ("find_and_get", "findAndGet"):
            finder = getattr(self._sdl, name, None)
            if finder:
                try:
                    return finder(self._namespace, pattern)
                except Exception as exc:
                    logger.warning("SDL find failed: %s", exc)
                    return {}

        keys = self._list_keys()
        if not keys:
            return {}
        filtered = [key for key in keys if key.startswith(prefix)]
        return self._get_by_keys(filtered)

    def _list_keys(self) -> List[str]:
        for name in ("keys", "get_keys", "getKeyNames", "get_key_names"):
            method = getattr(self._sdl, name, None)
            if method:
                try:
                    result = method(self._namespace)
                except TypeError:
                    result = method()
                except Exception as exc:
                    logger.warning("SDL list keys failed: %s", exc)
                    return []
                if isinstance(result, list):
                    return [str(item) for item in result]
                return list(result or [])
        return []

    def _get_by_keys(self, keys: List[str]) -> Dict[str, Any]:
        if not keys:
            return {}
        try:
            return self._sdl.get(self._namespace, keys)
        except Exception as exc:
            logger.warning("SDL get failed: %s", exc)
            return {}

    def _decode_payload(self, value: Any) -> Optional[MetricsPayload]:
        if value is None:
            return None
        if isinstance(value, (bytes, bytearray)):
            raw = value.decode("utf-8", errors="ignore")
        else:
            raw = str(value)
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            logger.warning("SDL payload decode failed")
            return None

        timestamp = _parse_timestamp(payload.get("timestamp"))
        return MetricsPayload(
            e2_node_id=str(payload.get("e2_node_id", "")),
            ue_id=payload.get("ue_id"),
            timestamp=timestamp,
            metrics=payload.get("metrics", {}),
        )


@dataclass(frozen=True)
class Thresholds:
    min_downstream_kbps: float
    min_upstream_kbps: float
    max_delay_ms: float
    max_jitter_ms: float
    max_packet_loss_pct: float


@dataclass(frozen=True)
class ServiceConfig:
    host: str
    port: int
    namespace: str
    key_prefix: str
    window_seconds: int
    thresholds: Thresholds
    device_defaults: DeviceDefaults


class ConnectivityInsightsService:
    def __init__(self, config: ServiceConfig, sdl_client: SdlMetricsClient) -> None:
        """Serve aggregated connectivity insights based on SDL metrics."""
        self._config = config
        self._sdl_client = sdl_client

    async def get_connectivity_insights(
        self, query: Mapping[str, List[str]]
    ) -> ConnectivityInsightsResponse:
        """Aggregate metrics in the requested time window and format the response."""
        window_seconds = _parse_int(query, ["windowSeconds", "window_seconds"], self._config.window_seconds)
        e2_node_id = _parse_str(query, ["e2NodeId", "e2_node_id"], None)
        ue_ids = _parse_int_list(query, ["ueIds", "ue_ids", "ueId", "ue_id"], None)

        thresholds = Thresholds(
            min_downstream_kbps=_parse_float(
                query,
                ["minDownstreamKbps", "min_downstream_kbps"],
                self._config.thresholds.min_downstream_kbps,
            ),
            min_upstream_kbps=_parse_float(
                query,
                ["minUpstreamKbps", "min_upstream_kbps"],
                self._config.thresholds.min_upstream_kbps,
            ),
            max_delay_ms=_parse_float(
                query,
                ["maxDelayMs", "max_delay_ms"],
                self._config.thresholds.max_delay_ms,
            ),
            max_jitter_ms=_parse_float(
                query,
                ["maxJitterMs", "max_jitter_ms"],
                self._config.thresholds.max_jitter_ms,
            ),
            max_packet_loss_pct=_parse_float(
                query,
                ["maxPacketLossPct", "max_packet_loss_pct"],
                self._config.thresholds.max_packet_loss_pct,
            ),
        )

        entries = await self._sdl_client.fetch_metrics(e2_node_id, ue_ids)
        entries = _filter_by_window(entries, window_seconds)
        aggregates = _aggregate_metrics(entries)

        additional_kpis = {
            "signalStrength": "excellent",
            "connectivityType": "5G-SA",
        }

        if aggregates.downstream_kbps is not None:
            additional_kpis["downstreamThroughputKbps"] = f"{aggregates.downstream_kbps:.2f}"
        if aggregates.upstream_kbps is not None:
            additional_kpis["upstreamThroughputKbps"] = f"{aggregates.upstream_kbps:.2f}"
        if aggregates.delay_ms is not None:
            additional_kpis["packetDelayMs"] = f"{aggregates.delay_ms:.2f}"
        if aggregates.jitter_ms is not None:
            additional_kpis["jitterMs"] = f"{aggregates.jitter_ms:.2f}"
        if aggregates.packet_loss_pct is not None:
            additional_kpis["packetLossPct"] = f"{aggregates.packet_loss_pct:.4f}"

        device_info = _build_device_info(query, self._config.device_defaults)

        return ConnectivityInsightsResponse(
            packetDelayBudget=_evaluate_max_metric(aggregates.delay_ms, thresholds.max_delay_ms),
            targetMinDownstreamRate=_evaluate_min_metric(
                aggregates.downstream_kbps,
                thresholds.min_downstream_kbps,
            ),
            targetMinUpstreamRate=_evaluate_min_metric(
                aggregates.upstream_kbps,
                thresholds.min_upstream_kbps,
            ),
            packetlossErrorRate=_evaluate_max_metric(
                aggregates.packet_loss_pct,
                thresholds.max_packet_loss_pct,
            ),
            jitter=_evaluate_max_metric(aggregates.jitter_ms, thresholds.max_jitter_ms),
            additionalKPIs=additional_kpis,
            device=device_info,
        )


@dataclass(frozen=True)
class AggregatedMetrics:
    downstream_kbps: Optional[float]
    upstream_kbps: Optional[float]
    delay_ms: Optional[float]
    jitter_ms: Optional[float]
    packet_loss_pct: Optional[float]


async def _handle_client(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    service: ConnectivityInsightsService,
) -> None:
    try:
        request_data = await reader.readuntil(b"\r\n\r\n")
    except asyncio.IncompleteReadError:
        writer.close()
        await writer.wait_closed()
        return
    except asyncio.LimitOverrunError:
        await _send_response(writer, 414, {"error": "request too large"})
        return

    request_line = request_data.decode("ascii", errors="ignore").split("\r\n", 1)[0]
    parts = request_line.split()
    if len(parts) < 2:
        await _send_response(writer, 400, {"error": "malformed request"})
        return

    method, target = parts[0], parts[1]
    parsed = urlparse(target)
    path = parsed.path
    query = parse_qs(parsed.query)

    if method != "GET":
        await _send_response(writer, 405, {"error": "method not allowed"})
        return

    if path == "/health":
        await _send_response(writer, 200, {"status": "ok"})
        return

    if path != "/connectivity-insights":
        await _send_response(writer, 404, {"error": "not found"})
        return

    response = await service.get_connectivity_insights(query)
    payload = response.model_dump() if _PYDANTIC_AVAILABLE else response.model_dump()
    await _send_response(writer, 200, payload)


async def _send_response(writer: asyncio.StreamWriter, status: int, payload: Mapping[str, Any]) -> None:
    """Write a JSON response and close the connection."""
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    reason = {
        200: "OK",
        400: "Bad Request",
        404: "Not Found",
        405: "Method Not Allowed",
        414: "URI Too Long",
        500: "Internal Server Error",
    }.get(status, "OK")
    headers = [
        f"HTTP/1.1 {status} {reason}",
        "Content-Type: application/json",
        f"Content-Length: {len(body)}",
        "Connection: close",
        "",
        "",
    ]
    writer.write("\r\n".join(headers).encode("ascii") + body)
    await writer.drain()
    writer.close()
    await writer.wait_closed()


def _parse_timestamp(value: Any) -> Optional[datetime]:
    if not value:
        return None
    if isinstance(value, datetime):
        return value
    raw = str(value)
    try:
        if raw.endswith("Z"):
            raw = raw.replace("Z", "+00:00")
        return datetime.fromisoformat(raw)
    except ValueError:
        return None


def _filter_by_window(entries: List[MetricsPayload], window_seconds: int) -> List[MetricsPayload]:
    if window_seconds <= 0:
        return entries
    cutoff = datetime.now(tz=timezone.utc) - timedelta(seconds=window_seconds)
    filtered: List[MetricsPayload] = []
    for entry in entries:
        if entry.timestamp is None:
            filtered.append(entry)
            continue
        timestamp = entry.timestamp
        if timestamp.tzinfo is None:
            timestamp = timestamp.replace(tzinfo=timezone.utc)
        if timestamp >= cutoff:
            filtered.append(entry)
    return filtered


def _aggregate_metrics(entries: List[MetricsPayload]) -> AggregatedMetrics:
    downstream_values = _collect_metric_values(entries, ["DRB.UEThpDl"])
    upstream_values = _collect_metric_values(entries, ["DRB.UEThpUl"])
    delay_values = _collect_metric_values(entries, ["DRB.RlcSduDelayDl", "DRB.RlcSduDelayUl"])
    packet_loss_values = _collect_metric_values(
        entries,
        ["DRB.PacketLossRate", "DRB.PktLossRate", "DRB.ULPacketLossRate"],
    )

    delay_mean = _mean(delay_values)
    jitter = _stddev(delay_values) if delay_values else None

    return AggregatedMetrics(
        downstream_kbps=_mean(downstream_values),
        upstream_kbps=_mean(upstream_values),
        delay_ms=delay_mean,
        jitter_ms=jitter,
        packet_loss_pct=_mean(packet_loss_values),
    )


def _collect_metric_values(entries: List[MetricsPayload], names: Iterable[str]) -> List[float]:
    values: List[float] = []
    for entry in entries:
        for name in names:
            values.extend(_extract_numeric(entry.metrics.get(name)))
    return values


def _extract_numeric(value: Any) -> List[float]:
    if value is None:
        return []
    if isinstance(value, (int, float)):
        return [float(value)]
    if isinstance(value, str):
        try:
            return [float(value)]
        except ValueError:
            return []
    if isinstance(value, Mapping):
        values: List[float] = []
        for item in value.values():
            values.extend(_extract_numeric(item))
        return values
    if isinstance(value, Iterable):
        values = []
        for item in value:
            values.extend(_extract_numeric(item))
        return values
    return []


def _mean(values: List[float]) -> Optional[float]:
    if not values:
        return None
    return sum(values) / len(values)


def _stddev(values: List[float]) -> Optional[float]:
    if len(values) < 2:
        return None
    mean = _mean(values)
    if mean is None:
        return None
    variance = sum((value - mean) ** 2 for value in values) / (len(values) - 1)
    return variance ** 0.5


def _evaluate_min_metric(value: Optional[float], minimum: float) -> str:
    if value is None:
        return "meets the application requirements"
    if value >= minimum:
        return "meets the application requirements"
    return "does not meet the application requirements"


def _evaluate_max_metric(value: Optional[float], maximum: float) -> str:
    if value is None:
        return "meets the application requirements"
    if value <= maximum:
        return "meets the application requirements"
    return "does not meet the application requirements"


def _parse_str(query: Mapping[str, List[str]], keys: List[str], default: Optional[str]) -> Optional[str]:
    for key in keys:
        if key in query and query[key]:
            return query[key][0]
    return default


def _parse_int(query: Mapping[str, List[str]], keys: List[str], default: int) -> int:
    for key in keys:
        if key in query and query[key]:
            try:
                return int(query[key][0])
            except ValueError:
                return default
    return default


def _parse_float(query: Mapping[str, List[str]], keys: List[str], default: float) -> float:
    for key in keys:
        if key in query and query[key]:
            try:
                return float(query[key][0])
            except ValueError:
                return default
    return default


def _parse_int_list(
    query: Mapping[str, List[str]],
    keys: List[str],
    default: Optional[List[int]],
) -> Optional[List[int]]:
    for key in keys:
        if key in query and query[key]:
            values: List[int] = []
            for entry in ",".join(query[key]).split(","):
                entry = entry.strip()
                if not entry:
                    continue
                try:
                    values.append(int(entry))
                except ValueError:
                    continue
            return values
    return default


def _build_device_info(query: Mapping[str, List[str]], defaults: DeviceDefaults) -> DeviceInfo:
    phone_number = _parse_str(query, ["phoneNumber", "phone_number"], defaults.phone_number)
    nai = _parse_str(query, ["networkAccessIdentifier", "network_access_identifier"], defaults.network_access_identifier)
    ipv4_address = _parse_str(query, ["ipv4PublicAddress", "ipv4_public_address"], defaults.ipv4_public_address)
    ipv4_port = _parse_int(query, ["ipv4PublicPort", "ipv4_public_port"], defaults.ipv4_public_port)
    ipv6_address = _parse_str(query, ["ipv6Address", "ipv6_address"], defaults.ipv6_address)

    return DeviceInfo(
        phoneNumber=phone_number or defaults.phone_number,
        networkAccessIdentifier=nai or defaults.network_access_identifier,
        ipv4Address=IPv4Address(publicAddress=ipv4_address or defaults.ipv4_public_address, publicPort=ipv4_port),
        ipv6Address=ipv6_address or defaults.ipv6_address,
    )


async def _run_server(config: ServiceConfig, service: ConnectivityInsightsService) -> None:
    """Run the async HTTP server until interrupted."""
    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop_event.set)

    server = await asyncio.start_server(
        lambda r, w: _handle_client(r, w, service),
        host=config.host,
        port=config.port,
    )

    addresses = ", ".join(str(sock.getsockname()) for sock in server.sockets or [])
    logger.info("Connectivity Insights xApp listening on %s", addresses)

    async with server:
        await stop_event.wait()


def _parse_args() -> argparse.Namespace:
    """Parse CLI arguments for the xApp."""
    parser = argparse.ArgumentParser(description="ORCA Connectivity Insights xApp")
    parser.add_argument("--host", type=str, default="0.0.0.0", help="HTTP listen host")
    parser.add_argument("--port", type=int, default=8093, help="HTTP listen port")
    parser.add_argument(
        "--sdl_namespace",
        type=str,
        default="orca_exposure_metrics",
        help="SDL namespace for metrics",
    )
    parser.add_argument(
        "--sdl_key_prefix",
        type=str,
        default="kpm:",
        help="SDL key prefix for metrics",
    )
    parser.add_argument(
        "--window_seconds",
        type=int,
        default=int(os.environ.get("CONNECTIVITY_WINDOW_SECONDS", "60")),
        help="Default metrics window in seconds",
    )
    parser.add_argument(
        "--min_downstream_kbps",
        type=float,
        default=float(os.environ.get("CONNECTIVITY_MIN_DL_KBPS", "1000")),
        help="Minimum downstream throughput in kbps",
    )
    parser.add_argument(
        "--min_upstream_kbps",
        type=float,
        default=float(os.environ.get("CONNECTIVITY_MIN_UL_KBPS", "1000")),
        help="Minimum upstream throughput in kbps",
    )
    parser.add_argument(
        "--max_delay_ms",
        type=float,
        default=float(os.environ.get("CONNECTIVITY_MAX_DELAY_MS", "200")),
        help="Maximum delay in ms",
    )
    parser.add_argument(
        "--max_jitter_ms",
        type=float,
        default=float(os.environ.get("CONNECTIVITY_MAX_JITTER_MS", "50")),
        help="Maximum jitter in ms",
    )
    parser.add_argument(
        "--max_packet_loss_pct",
        type=float,
        default=float(os.environ.get("CONNECTIVITY_MAX_PACKET_LOSS_PCT", "1.0")),
        help="Maximum packet loss in percent",
    )
    parser.add_argument("--phone_number", type=str, default="+123456789", help="Default phone number")
    parser.add_argument(
        "--network_access_identifier",
        type=str,
        default="123456789@domain.com",
        help="Default network access identifier",
    )
    parser.add_argument(
        "--ipv4_public_address",
        type=str,
        default="84.125.93.10",
        help="Default IPv4 public address",
    )
    parser.add_argument(
        "--ipv4_public_port",
        type=int,
        default=59765,
        help="Default IPv4 public port",
    )
    parser.add_argument(
        "--ipv6_address",
        type=str,
        default="2001:db8:85a3:8d3:1319:8a2e:370:7344",
        help="Default IPv6 address",
    )
    return parser.parse_args()


def main() -> None:
    """Entrypoint for the Connectivity Insights xApp."""
    logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
    args = _parse_args()

    if not _PYDANTIC_AVAILABLE:
        logger.warning("Pydantic is not available; using a minimal fallback model")

    thresholds = Thresholds(
        min_downstream_kbps=args.min_downstream_kbps,
        min_upstream_kbps=args.min_upstream_kbps,
        max_delay_ms=args.max_delay_ms,
        max_jitter_ms=args.max_jitter_ms,
        max_packet_loss_pct=args.max_packet_loss_pct,
    )

    device_defaults = DeviceDefaults(
        phone_number=args.phone_number,
        network_access_identifier=args.network_access_identifier,
        ipv4_public_address=args.ipv4_public_address,
        ipv4_public_port=args.ipv4_public_port,
        ipv6_address=args.ipv6_address,
    )

    config = ServiceConfig(
        host=args.host,
        port=args.port,
        namespace=args.sdl_namespace,
        key_prefix=args.sdl_key_prefix,
        window_seconds=args.window_seconds,
        thresholds=thresholds,
        device_defaults=device_defaults,
    )

    sdl_client = SdlMetricsClient(config.namespace, config.key_prefix)
    service = ConnectivityInsightsService(config, sdl_client)

    asyncio.run(_run_server(config, service))


if __name__ == "__main__":
    main()
