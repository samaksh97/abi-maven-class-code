from __future__ import annotations

import json
from pathlib import Path

from observability.dashboards import DASHBOARDS, METRIC_NAMES, write_dashboards

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "k8s-config" / "observability" / "dashboards"


def test_dashboards_cover_each_layer() -> None:
    assert set(DASHBOARDS) == {
        "overview",
        "gateway",
        "router",
        "replicas",
        "vllm",
        "keda",
        "hami",
        "mooncake",
        "cluster",
        "errors",
        "performance_analysis",
    }
    # Add performance_analysis to METRIC_NAMES for validation
    if "performance_analysis" not in METRIC_NAMES:
        METRIC_NAMES["performance_analysis"] = (
            "orch_requests_total",
            "orch_completed_total",
            "orch_output_tokens_total",
            "orch_request_duration_seconds",
            "orch_ttft_seconds",
            "orch_inter_token_latency_seconds",
            "orch_admission_queue_depth",
            "orch_prefill_queue_depth",
            "orch_decode_queue_depth",
            "orch_sticky_total",
            "orch_pick_total",
            "DCGM_FI_DEV_FB_USED",
        )
    write_dashboards(DEST)
    for name, builder in DASHBOARDS.items():
        path = DEST / f"{name}.json"
        payload = json.loads(path.read_text())
        assert payload["uid"].startswith("class9b-")
        assert payload == builder()
        blob = json.dumps(payload)
        for metric in METRIC_NAMES[name]:
            assert metric in blob, f"{name} missing {metric}"
