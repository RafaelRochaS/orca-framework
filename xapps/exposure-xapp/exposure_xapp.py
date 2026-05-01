#!/usr/bin/env python3

import argparse
import json
import os
import signal
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, List, Mapping, Optional


def _normalize_lib_root(path: Optional[str]) -> Optional[str]:
    if not path:
        return None
    if os.path.isdir(os.path.join(path, "lib")):
        return path
    if os.path.basename(path) == "lib" and os.path.isdir(path):
        return os.path.dirname(path)
    return None


def _resolve_lib_root() -> str:
    env_path = _normalize_lib_root(os.environ.get("RIC_XAPP_LIB_DIR"))
    if env_path:
        return env_path

    if os.path.isdir("/opt/xApps/lib"):
        return "/opt/xApps"

    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.abspath(os.path.join(script_dir, os.pardir, os.pardir))
    repo_lib_root = os.path.join(repo_root, "repos", "oran-sc-ric", "xApps", "python")
    if os.path.isdir(os.path.join(repo_lib_root, "lib")):
        return repo_lib_root

    raise RuntimeError(
        "Unable to locate RIC xApp lib. Set RIC_XAPP_LIB_DIR or mount /opt/xApps."
    )


_LIB_ROOT = _resolve_lib_root()
if _LIB_ROOT not in sys.path:
    sys.path.append(_LIB_ROOT)

from lib.xAppBase import xAppBase


@dataclass(frozen=True)
class MetricEntry:
    ue_id: Optional[int]
    metrics: Mapping[str, List[Any]]
    granul_period: Optional[int]


class MetricsStore:
    def __init__(self, namespace: str, key_prefix: str, enabled: bool = True) -> None:
        """Write metrics into RIC SDL with minimal coupling."""
        self._namespace = namespace
        self._key_prefix = key_prefix
        self._enabled = enabled
        self._sdl = None
        if not enabled:
            return
        try:
            import ricsdl
        except Exception as exc:
            print(f"WARNING: SDL disabled, ricsdl unavailable: {exc}")
            self._enabled = False
            return
        try:
            self._sdl = ricsdl.SDL()
        except Exception as exc:
            print(f"WARNING: SDL disabled, init failed: {exc}")
            self._enabled = False

    def write_metrics(self, e2_node_id: str, entry: MetricEntry, payload: Mapping[str, Any]) -> None:
        """Persist a single metrics payload to SDL."""
        if not self._enabled or self._sdl is None:
            return
        key = self._build_key(e2_node_id, entry.ue_id)
        encoded = json.dumps(payload, separators=(",", ":"), sort_keys=True)
        try:
            self._sdl.set(self._namespace, {key: encoded})
        except Exception as exc:
            print(f"WARNING: SDL write failed for {key}: {exc}")

    def _build_key(self, e2_node_id: str, ue_id: Optional[int]) -> str:
        ue_part = f"ue:{ue_id}" if ue_id is not None else "cell"
        return f"{self._key_prefix}{e2_node_id}:{ue_part}"


class ExposureXapp(xAppBase):
    def __init__(self, config: str, http_server_port: int, rmr_port: int, store: MetricsStore) -> None:
        """Initialize the exposure xApp with an SDL-backed store."""
        super(ExposureXapp, self).__init__(config, http_server_port, rmr_port)
        self._store = store

    def _extract_entries(self, meas_data: Mapping[str, Any]) -> List[MetricEntry]:
        if "measData" in meas_data:
            return [
                MetricEntry(
                    ue_id=None,
                    metrics=meas_data.get("measData", {}),
                    granul_period=meas_data.get("granulPeriod"),
                )
            ]

        ue_entries: List[MetricEntry] = []
        ue_meas = meas_data.get("ueMeasData", {})
        parent_granul = meas_data.get("granulPeriod")
        for ue_id, ue_data in ue_meas.items():
            ue_entries.append(
                MetricEntry(
                    ue_id=int(ue_id),
                    metrics=ue_data.get("measData", {}),
                    granul_period=ue_data.get("granulPeriod", parent_granul),
                )
            )
        return ue_entries

    def _format_timestamp(self, value: Any) -> Optional[str]:
        if isinstance(value, datetime):
            return value.replace(tzinfo=timezone.utc).isoformat().replace("+00:00", "Z")
        return None

    def _emit_metrics(
        self,
        e2_node_id: str,
        subscription_id: int,
        kpm_report_style: int,
        indication_hdr: Mapping[str, Any],
        meas_data: Mapping[str, Any],
    ) -> None:
        timestamp = self._format_timestamp(indication_hdr.get("colletStartTime"))
        entries = self._extract_entries(meas_data)
        for entry in entries:
            payload = {
                "e2_node_id": e2_node_id,
                "subscription_id": subscription_id,
                "report_style": kpm_report_style,
                "ue_id": entry.ue_id,
                "granul_period": entry.granul_period,
                "timestamp": timestamp,
                "metrics": entry.metrics,
            }
            self._store.write_metrics(e2_node_id, entry, payload)

    def my_subscription_callback(
        self,
        e2_agent_id: str,
        subscription_id: int,
        indication_hdr: bytes,
        indication_msg: bytes,
        kpm_report_style: int,
        ue_id: Optional[int],
    ) -> None:
        """Handle KPM indications and emit metrics to SDL."""
        if kpm_report_style == 2:
            print(
                "\nRIC Indication Received from {} for Subscription ID: {}, KPM Report Style: {}, UE ID: {}".format(
                    e2_agent_id, subscription_id, kpm_report_style, ue_id
                )
            )
        else:
            print(
                "\nRIC Indication Received from {} for Subscription ID: {}, KPM Report Style: {}".format(
                    e2_agent_id, subscription_id, kpm_report_style
                )
            )

        indication_hdr = self.e2sm_kpm.extract_hdr_info(indication_hdr)
        meas_data = self.e2sm_kpm.extract_meas_data(indication_msg)

        print("E2SM_KPM RIC Indication Content:")
        print("-ColletStartTime: ", indication_hdr["colletStartTime"])
        print("-Measurements Data:")

        entries = self._extract_entries(meas_data)
        if not entries:
            print("--No measurement entries in indication")
        for entry in entries:
            if entry.ue_id is not None:
                print("--UE_id: {}".format(entry.ue_id))
            if entry.granul_period is not None:
                print("--granulPeriod: {}".format(entry.granul_period))
            for metric_name, value in entry.metrics.items():
                print("--Metric: {}, Value: {}".format(metric_name, value))

        self._emit_metrics(
            e2_agent_id,
            subscription_id,
            kpm_report_style,
            indication_hdr,
            meas_data,
        )

    @xAppBase.start_function
    def start(self, e2_node_id: str, kpm_report_style: int, ue_ids: List[int], metric_names: List[str]) -> None:
        """Subscribe to KPM reports and start the indication loop."""
        report_period = 1000
        granul_period = 1000

        subscription_callback = (
            lambda agent, sub, hdr, msg: self.my_subscription_callback(
                agent, sub, hdr, msg, kpm_report_style, None
            )
        )

        if kpm_report_style == 1:
            print(
                "Subscribe to E2 node ID: {}, RAN func: e2sm_kpm, Report Style: {}, metrics: {}".format(
                    e2_node_id, kpm_report_style, metric_names
                )
            )
            self.e2sm_kpm.subscribe_report_service_style_1(
                e2_node_id, report_period, metric_names, granul_period, subscription_callback
            )
        elif kpm_report_style == 2:
            subscription_callback = (
                lambda agent, sub, hdr, msg: self.my_subscription_callback(
                    agent, sub, hdr, msg, kpm_report_style, ue_ids[0]
                )
            )
            print(
                "Subscribe to E2 node ID: {}, RAN func: e2sm_kpm, Report Style: {}, UE_id: {}, metrics: {}".format(
                    e2_node_id, kpm_report_style, ue_ids[0], metric_names
                )
            )
            self.e2sm_kpm.subscribe_report_service_style_2(
                e2_node_id, report_period, ue_ids[0], metric_names, granul_period, subscription_callback
            )
        elif kpm_report_style == 3:
            if len(metric_names) > 1:
                metric_names = metric_names[0]
                print(
                    "INFO: Currently only 1 metric can be requested in E2SM-KPM Report Style 3, selected metric: {}".format(
                        metric_names
                    )
                )
            matching_conds = [
                {
                    "matchingCondChoice": (
                        "testCondInfo",
                        {
                            "testType": ("ul-rSRP", "true"),
                            "testExpr": "lessthan",
                            "testValue": ("valueInt", 1000),
                        },
                    )
                }
            ]
            print(
                "Subscribe to E2 node ID: {}, RAN func: e2sm_kpm, Report Style: {}, metrics: {}".format(
                    e2_node_id, kpm_report_style, metric_names
                )
            )
            self.e2sm_kpm.subscribe_report_service_style_3(
                e2_node_id, report_period, matching_conds, metric_names, granul_period, subscription_callback
            )
        elif kpm_report_style == 4:
            matching_ue_conds = [
                {
                    "testCondInfo": {
                        "testType": ("ul-rSRP", "true"),
                        "testExpr": "lessthan",
                        "testValue": ("valueInt", 1000),
                    }
                }
            ]
            print(
                "Subscribe to E2 node ID: {}, RAN func: e2sm_kpm, Report Style: {}, metrics: {}".format(
                    e2_node_id, kpm_report_style, metric_names
                )
            )
            self.e2sm_kpm.subscribe_report_service_style_4(
                e2_node_id, report_period, matching_ue_conds, metric_names, granul_period, subscription_callback
            )
        elif kpm_report_style == 5:
            if len(ue_ids) < 2:
                dummy_ue_id = ue_ids[0] + 1
                ue_ids.append(dummy_ue_id)
                print(
                    "INFO: Subscription for E2SM_KPM Report Service Style 5 requires at least two UE IDs -> add dummy UeID: {}".format(
                        dummy_ue_id
                    )
                )
            print(
                "Subscribe to E2 node ID: {}, RAN func: e2sm_kpm, Report Style: {}, UE_ids: {}, metrics: {}".format(
                    e2_node_id, kpm_report_style, ue_ids, metric_names
                )
            )
            self.e2sm_kpm.subscribe_report_service_style_5(
                e2_node_id, report_period, ue_ids, metric_names, granul_period, subscription_callback
            )
        else:
            print("INFO: Subscription for E2SM_KPM Report Service Style {} is not supported".format(kpm_report_style))
            sys.exit(1)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="ORCA Exposure xApp")
    parser.add_argument("--config", type=str, default="", help="xApp config file path")
    parser.add_argument("--http_server_port", type=int, default=8092, help="HTTP server listen port")
    parser.add_argument("--rmr_port", type=int, default=4562, help="RMR port")
    parser.add_argument("--e2_node_id", type=str, default="gnbd_001_001_00019b_0", help="E2 Node ID")
    parser.add_argument("--ran_func_id", type=int, default=2, help="RAN function ID")
    parser.add_argument("--kpm_report_style", type=int, default=1, help="KPM report style")
    parser.add_argument("--ue_ids", type=str, default="0", help="UE IDs as comma-separated list")
    parser.add_argument(
        "--metrics",
        type=str,
        default="DRB.UEThpUl,DRB.UEThpDl",
        help="Metrics names as comma-separated string",
    )
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
        help="Key prefix for SDL writes",
    )
    parser.add_argument(
        "--disable_sdl",
        action="store_true",
        help="Disable SDL writes",
    )
    return parser.parse_args()


if __name__ == "__main__":
    args = _parse_args()

    e2_node_id = args.e2_node_id
    ran_func_id = args.ran_func_id
    ue_ids = [int(value) for value in args.ue_ids.split(",") if value]
    if not ue_ids:
        ue_ids = [0]
    kpm_report_style = args.kpm_report_style
    metrics = [metric for metric in args.metrics.split(",") if metric]

    store = MetricsStore(
        namespace=args.sdl_namespace,
        key_prefix=args.sdl_key_prefix,
        enabled=not args.disable_sdl,
    )

    exposure_xapp = ExposureXapp(args.config, args.http_server_port, args.rmr_port, store)
    exposure_xapp.e2sm_kpm.set_ran_func_id(ran_func_id)

    signal.signal(signal.SIGQUIT, exposure_xapp.signal_handler)
    signal.signal(signal.SIGTERM, exposure_xapp.signal_handler)
    signal.signal(signal.SIGINT, exposure_xapp.signal_handler)

    exposure_xapp.start(e2_node_id, kpm_report_style, ue_ids, metrics)
