from __future__ import annotations

import time
import urllib.error

from gateway.queue import enqueue
from gateway.metrics import METRICS
from router.router import Router
from gateway.types import Request, Response, Shed, SliceOOM

WINDOW_S = 60.0

# Token-aware admission control constants
# Approximate memory per token in bytes (KV cache for 3B model)
MEMORY_PER_TOKEN = 2048  # 2KB per token (conservative estimate)
# GPU memory utilization threshold (80% of total GPU memory)
GPU_MEMORY_THRESHOLD = 0.8
# Minimum KV free ratio to allow new requests
MIN_KV_FREE_RATIO = 0.1


class Gateway:

    def __init__(self, router: Router, tokens_per_min: int = 10_000, 
                 enable_token_aware_admission: bool = True) -> None:
        self.router = router
        self.tokens_per_min = tokens_per_min
        self.enable_token_aware_admission = enable_token_aware_admission
        self._window: dict[str, tuple[float, int]] = {}
        self._admission_queue: list[Request] = []

    def refresh_metrics(self) -> None:
        METRICS.refresh_from_router(self.router)
        # Update queue depth metrics
        METRICS.set_admission_queue_depth(len(self._admission_queue))
        
        # Update prefill/decode queue depths from router snapshots
        prefill_snaps = METRICS.replicas.get("prefill", [])
        decode_snaps = METRICS.replicas.get("decode", [])
        
        prefill_depth = sum(snap.queue_depth or 0 for snap in prefill_snaps)
        decode_depth = sum(snap.queue_depth or 0 for snap in decode_snaps)
        
        METRICS.set_prefill_queue_depth(prefill_depth)
        METRICS.set_decode_queue_depth(decode_depth)

    def handle(self, req: Request) -> Response:
        t0 = time.perf_counter()
        METRICS.inc_requests()
        
        # Track input tokens
        METRICS.inc_input_tokens(req.prompt_tokens)
        
        # Add to admission queue for tracking
        self._admission_queue.append(req)
        
        if self._over_cap(req):
            self._admission_queue.remove(req)
            METRICS.inc_shed("tenant_tokens", 429)
            METRICS.observe_duration("gateway", time.perf_counter() - t0)
            return Shed(
                status=429,
                error="rate_limit_error",
                reason="tenant_tokens",
                message="tenant tokens/min cap",
            ).to_response()

        # Token-aware admission control: check GPU memory capacity
        if self.enable_token_aware_admission and self._insufficient_gpu_memory(req):
            self._admission_queue.remove(req)
            METRICS.inc_shed("token_budget_exceeded", 503)
            METRICS.observe_duration("gateway", time.perf_counter() - t0)
            return Shed(
                status=503,
                error="insufficient_gpu_memory",
                reason="token_budget_exceeded",
                message="insufficient GPU memory for request token budget",
            ).to_response()

        result = self.router.place(req)
        if isinstance(result, Shed):
            self._admission_queue.remove(req)
            METRICS.inc_shed(result.reason, result.status)
            self.refresh_metrics()
            METRICS.observe_duration("gateway", time.perf_counter() - t0)
            return result.to_response()
        try:
            hop, completion = enqueue(result, req)
        except SliceOOM:
            self._admission_queue.remove(req)
            METRICS.inc_gpu_oom()
            METRICS.inc_shed("gpu_oom", 503)
            METRICS.observe_duration("gateway", time.perf_counter() - t0)
            return Response(
                status=503,
                error="slice_oom",
                body={"error": {"type": "slice_oom", "message": "gpumem slice exceeded"}},
            )
        except (OSError, TimeoutError, urllib.error.URLError) as e:
            self._admission_queue.remove(req)
            if isinstance(e, TimeoutError):
                METRICS.inc_upstream_timeout()
                METRICS.inc_shed("upstream_timeout", 504)
            else:
                METRICS.inc_shed("no_eligible_pod", 503)
            METRICS.observe_duration("gateway", time.perf_counter() - t0)
            return Shed(
                status=503,
                error="server_is_overloaded",
                reason="no_eligible_pod",
                message="worker unreachable",
            ).to_response()
        
        # Remove from admission queue on successful placement
        if req in self._admission_queue:
            self._admission_queue.remove(req)
            
        if req.evict_after and hop:
            bus = getattr(result.prefill, "bus", None) or getattr(result.decode, "bus", None)
            if bus is not None and hasattr(bus, "evict"):
                bus.evict(hop.get("src") or result.prefill.id, req.prefix_hash)
                bus.evict(hop.get("dst") or result.decode.id, req.prefix_hash)
        
        METRICS.inc_completed()
        METRICS.inc_place(req.capability or "text")
        
        # Track output tokens if available in completion
        if isinstance(completion, dict):
            usage = completion.get("usage", {})
            if isinstance(usage, dict):
                output_tokens = usage.get("completion_tokens")
                if output_tokens:
                    METRICS.inc_output_tokens(output_tokens)
        
        self.refresh_metrics()
        METRICS.observe_duration("gateway", time.perf_counter() - t0)
        body: dict = {"id": req.id}
        if hop:
            body["kv_hop"] = hop
        if isinstance(completion, dict):
            for key in ("choices", "model", "usage"):
                if key in completion:
                    body[key] = completion[key]
            if completion.get("id"):
                body["completion_id"] = completion["id"]
        return Response(status=200, handoff=result, body=body)

    def _over_cap(self, req: Request) -> bool:
        cost = int(req.prompt_tokens) + int(req.max_new_tokens)
        start, used = self._window.get(req.tenant, (req.arrival_t, 0))
        if req.arrival_t - start >= WINDOW_S:
            start, used = req.arrival_t, 0
        if used + cost > self.tokens_per_min:
            return True
        self._window[req.tenant] = (start, used + cost)
        return False

    def _insufficient_gpu_memory(self, req: Request) -> bool:
        """
        Token-aware admission control: check if there's sufficient GPU memory
        for the request's token budget.
        
        Returns True if insufficient memory, False otherwise.
        """
        # Refresh metrics to get latest replica information
        self.refresh_metrics()
        
        # Get prefill and decode replica snapshots
        prefill_snaps = METRICS.replicas.get("prefill", [])
        decode_snaps = METRICS.replicas.get("decode", [])
        
        # If no replicas available, reject
        if not prefill_snaps and not decode_snaps:
            return True
        
        # Calculate total KV free ratio across all replicas
        total_kv_free_ratio = 0.0
        replica_count = 0
        
        for snap in prefill_snaps:
            if snap.kv_free_ratio is not None:
                total_kv_free_ratio += snap.kv_free_ratio
                replica_count += 1
        
        for snap in decode_snaps:
            if snap.kv_free_ratio is not None:
                total_kv_free_ratio += snap.kv_free_ratio
                replica_count += 1
        
        if replica_count == 0:
            return True
        
        avg_kv_free_ratio = total_kv_free_ratio / replica_count
        
        # If KV free ratio is below threshold, reject
        if avg_kv_free_ratio < MIN_KV_FREE_RATIO:
            return True
        
        # Estimate memory required for this request
        estimated_tokens = int(req.prompt_tokens) + int(req.max_new_tokens)
        estimated_memory_bytes = estimated_tokens * MEMORY_PER_TOKEN
        
        # Get current tokens in flight
        prefill_tokens = sum(snap.tokens_in_flight or 0 for snap in prefill_snaps)
        decode_tokens = sum(snap.tokens_in_flight or 0 for snap in decode_snaps)
        total_tokens_in_flight = prefill_tokens + decode_tokens
        
        # Estimate current memory usage
        current_memory_bytes = total_tokens_in_flight * MEMORY_PER_TOKEN
        
        # Total estimated memory after admitting this request
        total_memory_after = current_memory_bytes + estimated_memory_bytes
        
        # Get available memory from KV free ratio
        # Assuming 20GB total GPU memory (NVIDIA A10)
        total_gpu_memory = 20 * 1024 * 1024 * 1024  # 20GB in bytes
        available_memory = total_gpu_memory * avg_kv_free_ratio
        
        # Check if we have enough memory
        if total_memory_after > available_memory:
            return True
        
        return False
