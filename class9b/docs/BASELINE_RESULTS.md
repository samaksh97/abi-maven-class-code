# Baseline Performance Results

## Test Configuration
- **Date**: 2026-09-27
- **GPU**: NVIDIA A10 (23GB memory)
- **Model**: Qwen/Qwen2.5-3B-Instruct
- **vLLM Version**: 0.30.0
- **Setup**: Single vLLM worker on GPU, gateway on same host
- **Workload**: Baseline profile (short input, short output)
- **Test Duration**: 60 seconds
- **Concurrency**: 5 users
- **Spawn Rate**: 2 users/second

## Locust Load Test Results

### Throughput
- **Total Requests**: 221
- **Success Rate**: 100% (0 failures)
- **Requests/Second**: 3.7 req/s
- **Average Latency**: 450ms
- **Median Latency**: 540ms
- **Min Latency**: 22ms
- **Max Latency**: 587ms

### Latency Percentiles
- **p50**: 540ms
- **p66**: 560ms
- **p75**: 570ms
- **p80**: 570ms
- **p90**: 570ms
- **p95**: 580ms
- **p98**: 580ms
- **p99**: 580ms
- **p100**: 590ms

## Gateway Metrics

### Request Counts
- **Total Requests**: 223
- **Completed Requests**: 223
- **Shed Requests**: 0
- **No Eligible Pod Sheds**: 0

### Token Counts
- **Input Tokens**: 3,568
- **Output Tokens**: 5,632
- **Avg Input Tokens/Request**: 16.0
- **Avg Output Tokens/Request**: 25.3

### Latency Breakdown
- **TTFT Sum**: 28.54s
- **TTFT Average**: 128ms
- **Gateway Latency Sum**: 99.95s
- **Gateway Latency Average**: 448ms
- **Pick Latency Sum**: 2.45s
- **Pick Latency Average**: 5.5ms

### Queue Metrics
- **Admission Queue Depth**: 0
- **Prefill Queue Depth**: 0
- **Decode Queue Depth**: 0
- **Tokens in Flight (Prefill)**: 0
- **Tokens in Flight (Decode)**: 0

### Replica Health
- **Prefill Replica (engine-0)**: Healthy
- **Decode Replica (engine-0)**: Healthy
- **KV Free Ratio**: 1.0 (100% free)
- **Active Requests**: 0
- **Saturating**: 0

### Error Metrics
- **GPU OOM Count**: 0
- **Upstream Timeout Count**: 0
- **Overflow Count**: 0
- **KV Transfer Count**: 0
- **KV Evict Count**: 0

## Analysis

### Key Observations
1. **High Success Rate**: 100% success with no shedding indicates the system is not under load
2. **TTFT vs Total Latency**: TTFT is 128ms average, but total latency is 448ms, suggesting decode phase dominates
3. **No Queue Buildup**: All queue depths are 0, indicating the system can handle the current load easily
4. **Efficient Routing**: Pick latency is very low (5.5ms), showing the router is efficient
5. **GPU Memory Available**: KV free ratio is 1.0, indicating significant GPU memory headroom

### Identified Bottleneck
The primary bottleneck is **decode phase latency**. With TTFT at 128ms and total latency at 448ms, the decode phase accounts for approximately 320ms per request (71% of total latency). This is expected for a 3B model generating ~25 tokens per request.

### Optimization Opportunities
1. **Token-Aware Admission Control**: Admit requests based on available GPU memory and estimated token budget
2. **Request Batching**: Improve vLLM batching to increase throughput
3. **GPU Memory Utilization**: Current setup only uses 80% GPU memory; could increase to improve KV cache
4. **Prefill-Decode Separation**: Currently using single worker for both phases; could optimize for phase separation

## Next Steps
Based on this analysis, the most impactful improvement would be **token-aware admission control** that:
- Estimates token budget for incoming requests
- Tracks available GPU memory capacity
- Admits requests up to memory limits
- Prevents OOM errors by proactive shedding
