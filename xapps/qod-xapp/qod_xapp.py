#!/usr/bin/env python3
"""
QoD xApp — Quality on Demand RAN Enforcement
=============================================
Runs on the O-RAN SC Near-RT RIC and enforces QoD policies at the RAN level.

This xApp:
  1. Receives A1 policies from the OOP Orchestrator (policy type 20008)
  2. Subscribes to E2SM-KPM reports to monitor per-UE throughput
  3. Uses E2SM-RC to adjust scheduler weights for UEs under active QoD sessions

How to run (from oran-sc-ric directory):
  docker compose exec python_xapp_runner python3 /xapps/qod_xapp.py

References:
  - O-RAN E2SM-KPM v3: KPM measurement collection
  - O-RAN E2SM-RC v1: RAN control (scheduler configuration)
  - O-RAN A1AP v4: Policy management interface

Extension points for research:
  - Modify _compute_scheduler_action() for novel scheduling algorithms
  - Add CAMARA-specific metrics collection for publication evaluation
  - Implement feedback loop: KPM measurements → QoD SLA verification → A1 update
"""

import os
import sys
import json
import time
import logging
import threading
import requests
from typing import Dict, Optional, Any

# xApp framework (from oran-sc-ric)
try:
    from ricxappframe.xapp_frame import RMRXapp, config_handler
    from ricxappframe.entities.rnib.nb_id_pb2 import NbIdentity
except ImportError:
    print("ERROR: ricxappframe not found. This xApp must run inside the RIC environment.")
    print("Run: docker compose exec python_xapp_runner python3 /xapps/qod_xapp.py")
    sys.exit(1)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
logger = logging.getLogger("qod-xapp")


# =============================================================================
# Configuration
# =============================================================================
A1_POLICY_TYPE_ID = 20008          # Custom policy type for QoD
E2SM_KPM_FUNC_ID = 2               # KPM function ID (as advertised by OCUDU gNB)
E2SM_RC_FUNC_ID = 3                # RC function ID

# Metrics to monitor for QoD SLA verification
KPM_METRICS = [
    "DRB.UEThpDl",    # DL throughput per UE
    "DRB.UEThpUl",    # UL throughput per UE
    "DRB.RlcSduDelayDl",  # DL packet delay
]

REPORT_PERIOD_MS = 1000  # KPM measurement period


# =============================================================================
# QoD xApp
# =============================================================================

class QoDXapp:
    def __init__(self):
        self._active_policies: Dict[str, Any] = {}  # policy_id → policy
        self._ue_metrics: Dict[str, Any] = {}        # ue_id → latest metrics
        self._lock = threading.Lock()

        # Start A1 policy listener (polls A1 mediator for new policies)
        self._a1_thread = threading.Thread(target=self._a1_policy_loop, daemon=True)
        self._a1_thread.start()

    def _a1_policy_loop(self):
        """Poll A1 mediator for QoD policies and update local state."""
        a1_base = os.environ.get("A1_MEDIATOR_URL", "http://service-ricplt-a1mediator-http:10000")
        while True:
            try:
                resp = requests.get(
                    f"{a1_base}/a1-p/policytypes/{A1_POLICY_TYPE_ID}/policies",
                    timeout=5
                )
                if resp.ok:
                    policy_ids = resp.json()
                    for pid in policy_ids:
                        if pid not in self._active_policies:
                            pol_resp = requests.get(
                                f"{a1_base}/a1-p/policytypes/{A1_POLICY_TYPE_ID}/policies/{pid}",
                                timeout=5
                            )
                            if pol_resp.ok:
                                with self._lock:
                                    self._active_policies[pid] = pol_resp.json()
                                logger.info(f"New A1 policy received: {pid}")

                    # Remove expired policies
                    current_ids = set(policy_ids)
                    with self._lock:
                        expired = [p for p in self._active_policies if p not in current_ids]
                        for p in expired:
                            del self._active_policies[p]
                            logger.info(f"A1 policy expired/deleted: {p}")

            except Exception as e:
                logger.warning(f"A1 poll error: {e}")

            time.sleep(5)

    def handle_kpm_indication(self, summary, sbuf):
        """
        Handle E2SM-KPM RIC INDICATION message.

        Parses per-UE throughput metrics and checks against active QoD policies.
        If a UE is underperforming relative to its QoD profile, trigger RC control.
        """
        try:
            # Parse indication (format depends on KPM report style)
            # Style 5 gives per-UE granularity
            indication = json.loads(sbuf)  # simplified — use ASN1/protobuf in production

            ue_id = indication.get("ue_id")
            metrics = indication.get("measurements", {})

            if ue_id:
                with self._lock:
                    self._ue_metrics[ue_id] = metrics
                    self._check_qod_sla(ue_id, metrics)

        except Exception as e:
            logger.error(f"KPM indication parse error: {e}")

    def _check_qod_sla(self, ue_id: str, metrics: Dict[str, Any]):
        """
        Check if a UE is meeting its QoD SLA and trigger RC if not.

        This is the core research logic — modify for novel control strategies.
        """
        with self._lock:
            for policy_id, policy in self._active_policies.items():
                scope = policy.get("scope", {})
                if scope.get("ueId") != ue_id:
                    continue

                resources = policy.get("resources", {})
                guaranteed_dl = resources.get("guaranteedDlMbps")
                if guaranteed_dl is None:
                    continue

                actual_dl = metrics.get("DRB.UEThpDl", 0)  # kbps
                actual_dl_mbps = actual_dl / 1000.0

                if actual_dl_mbps < guaranteed_dl * 0.8:  # 80% SLA threshold
                    logger.warning(
                        f"QoD SLA breach for UE {ue_id}: "
                        f"actual={actual_dl_mbps:.2f}Mbps < "
                        f"guaranteed={guaranteed_dl}Mbps. "
                        f"Triggering RC control..."
                    )
                    self._trigger_rc_control(ue_id, resources)

    def _trigger_rc_control(self, ue_id: str, resources: Dict[str, Any]):
        """
        Send E2SM-RC control message to adjust scheduler weight for a UE.

        In a full implementation:
          - Build RIC CONTROL REQUEST with E2SM-RC IE
          - Set scheduler parameters (e.g., PRB allocation, priority)
          - Send via RMR to e2term → gNB E2 agent → CU/DU scheduler

        This is a stub — the full implementation requires the E2SM-RC
        ASN.1 encoding and RMR message routing.
        """
        scheduler_weight = resources.get("schedulerWeight", 50)
        logger.info(
            f"RC CONTROL: UE={ue_id}, "
            f"scheduler_weight={scheduler_weight}, "
            f"5QI={resources.get('5qi', 9)}"
        )
        # TODO: implement full E2SM-RC control message building
        # Reference: repos/oran-sc-ric/xApps/python/rc_control_xapp.py

    def get_status(self) -> Dict[str, Any]:
        with self._lock:
            return {
                "active_policies": len(self._active_policies),
                "monitored_ues": len(self._ue_metrics),
                "policy_ids": list(self._active_policies.keys()),
            }


# =============================================================================
# xApp entry point
# =============================================================================

def default_handler(summary, sbuf):
    logger.debug(f"Unhandled RMR message type: {summary.get('mtype')}")


def main():
    logger.info("QoD xApp starting...")
    xapp = QoDXapp()

    # RMR message type for KPM indications (12050 = RIC_INDICATION)
    handlers = {
        12050: xapp.handle_kpm_indication,
    }

    rmr_xapp = RMRXapp(
        default_handler=default_handler,
        config_handler=config_handler,
        rmr_port=4560,
        post_init=lambda: logger.info("QoD xApp RMR initialized"),
    )

    for msg_type, handler in handlers.items():
        rmr_xapp.register_callback(handler, msg_type)

    logger.info(f"QoD xApp running. Status: {xapp.get_status()}")
    rmr_xapp.run()


if __name__ == "__main__":
    main()
