from __future__ import annotations

import time
from gateway.types import Handoff, Request
from gateway.metrics import METRICS

def enqueue(handoff: Handoff, req: Request) -> tuple[dict | None, dict | None]:
    enqueue_start = time.perf_counter()

    if handoff.decode is handoff.prefill:
        out = handoff.prefill.enqueue(req, phase="both")
        ttft = _estimate_ttft(req, enqueue_start)
        if ttft:
            METRICS.observe_ttft(ttft)
        return None, out if isinstance(out, dict) else None
    
    out_p = handoff.prefill.enqueue(req, phase="prefill")
    hop = None
    bus = getattr(handoff.prefill, "bus", None) or getattr(handoff.decode, "bus", None)
    if bus is not None and hasattr(bus, "transfer"):
        hop = bus.transfer(handoff.prefill.id, handoff.decode.id, req)
    out_d = handoff.decode.enqueue(req, phase="decode")
    completion = out_d if isinstance(out_d, dict) else out_p if isinstance(out_p, dict) else None
    
    # Estimate TTFT from completion
    ttft = _estimate_ttft(req, enqueue_start)
    if ttft:
        METRICS.observe_ttft(ttft)
    
    # Estimate inter-token latency if we have completion with token count
    if completion and isinstance(completion, dict):
        itl = _estimate_inter_token_latency(req, completion, enqueue_start)
        if itl:
            METRICS.observe_inter_token_latency(itl)
    
    return hop, completion

def _estimate_ttft(req: Request, enqueue_start: float) -> float | None:
    """Estimate Time-to-First-Token from request timing"""
    if hasattr(req, '_timing') and 'total_duration' in req._timing:
        # Use actual duration from worker if available
        # Assume TTFT is ~30% of total duration for estimation
        return req._timing['total_duration'] * 0.3
    # Fallback: estimate based on prompt tokens (very rough approximation)
    # TTFT roughly scales with prompt length
    return max(0.01, req.prompt_tokens * 0.0005)  # Very rough estimate

def _estimate_inter_token_latency(req: Request, completion: dict, enqueue_start: float) -> float | None:
    """Estimate inter-token latency from completion and timing"""
    if not isinstance(completion, dict):
        return None
    
    usage = completion.get("usage", {})
    if not isinstance(usage, dict):
        return None
    
    completion_tokens = usage.get("completion_tokens")
    if not completion_tokens or completion_tokens <= 1:
        return None
    
    # Estimate total time from start
    total_time = time.perf_counter() - enqueue_start
    
    # Subtract estimated TTFT (30% of total time)
    ttft = total_time * 0.3
    decode_time = total_time - ttft
    
    # Inter-token latency = decode time / (completion tokens - 1)
    # (subtract 1 because we want time between tokens, not including first)
    if decode_time > 0 and completion_tokens > 1:
        return decode_time / (completion_tokens - 1)
    
    return None
