# Failure Experiment Procedures

This document provides step-by-step procedures for reproducing and diagnosing specific failure scenarios in the Class 9b LLM inference system. Each experiment is designed to be controlled and reversible.

## Table of Contents

1. [Admission-Control Shedding](#1-admission-control-shedding)
2. [Prefill Saturation](#2-prefill-saturation)
3. [Decode Saturation](#3-decode-saturation)
4. [Queue Timeout](#4-queue-timeout)
5. [GPU-Memory Pressure](#5-gpu-memory-pressure)
6. [Cache-Unfriendly Traffic](#6-cache-unfriendly-traffic)
7. [Unhealthy Replica](#7-unhealthy-replica)

---

## 1. Admission-Control Shedding

### Objective
Test token budget enforcement by triggering rate limiting.

### Procedure

#### Step 1: Set Low Token Budget
Modify `gateway/admission.py` to reduce the token budget:

```python
# In Gateway.__init__, change from:
self.tokens_per_min = tokens_per_min

# To:
self.tokens_per_min = 100  # Very low budget for testing
```

#### Step 2: Restart Gateway
```bash
# If running locally
pkill -f "gateway.serve"
python -m gateway.serve

# If on Kubernetes
kubectl rollout restart deployment orch-serve
kubectl wait --for=condition=available --timeout=60s deployment/orch-serve
```

#### Step 3: Send High Traffic
```bash
# Generate traffic that exceeds the budget
locust -f app/locustfile_enhanced.py \
    --host http://127.0.0.1:8080 \
    --users 10 \
    --spawn-rate 5 \
    --run-time 30s \
    --headless
```

#### Step 4: Monitor Metrics
```bash
# Watch for shedding events
watch -n 1 'curl -s http://127.0.0.1:8080/metrics | grep orch_shed_total'

# Specifically check for tenant_tokens reason
curl -s http://127.0.0.1:8080/metrics | grep 'orch_shed_total{reason="tenant_tokens"'
```

### Expected Results
- HTTP 429 responses from gateway
- `orch_shed_total{reason="tenant_tokens"}` metric increases
- Gateway logs show rate limit enforcement

### Verification
```bash
# Check shed metric increased
curl -s http://127.0.0.1:8080/metrics | grep 'orch_shed_total{reason="tenant_tokens"'

# Check Grafana dashboard
# Open: Class 9b / Success and failures
# Look for: "Sheds by reason / HTTP code" panel showing tenant_tokens
```

### Reversal
```bash
# Restore original token budget
# In gateway/admission.py, change back to:
self.tokens_per_min = tokens_per_min  # or 10_000

# Restart gateway
pkill -f "gateway.serve"
python -m gateway.serve

# Or on Kubernetes
kubectl rollout restart deployment orch-serve
```

---

## 2. Prefill Saturation

### Objective
Saturate prefill KV cache with long prompts to test prefill-phase capacity limits.

### Procedure

#### Step 1: Monitor Baseline
```bash
# Open Grafana: Class 9b / Overview
# Note baseline KV free ratio and prefill queue depth
```

#### Step 2: Run Prefill Stress Test
```bash
# Use the prefill stress profile
export LOCUST_PROFILE=prefill_stress
export LOCUST_CONCURRENCY=8
export LOCUST_SPAWN_RATE=4
export LOCUST_DURATION=120

./scripts/run_locust_prefill_stress.sh
```

#### Step 3: Monitor During Test
```bash
# Watch KV free ratio drop
watch -n 2 'curl -s http://127.0.0.1:8080/metrics | grep orch_kv_free_ratio'

# Watch prefill queue depth
watch -n 2 'curl -s http://127.0.0.1:8080/metrics | grep orch_prefill_queue_depth'

# Check GPU memory
watch -n 2 'nvidia-smi --query-gpu=memory.used,memory.total --format=csv'
```

#### Step 4: Check for Shedding
```bash
# Look for kv_free shedding
curl -s http://127.0.0.1:8080/metrics | grep 'orch_shed_total{reason="kv_free"'

# Look for prefill_queue_full shedding
curl -s http://127.0.0.1:8080/metrics | grep 'orch_shed_total{reason="prefill_queue_full"'
```

### Expected Results
- KV free ratio drops significantly (approaches 0.2 saturation threshold)
- Prefill queue depth increases
- Potential shedding with `kv_free` or `prefill_queue_full` reasons
- Increased TTFT due to prefill saturation

### Verification
```bash
# Check Grafana dashboards
# - Class 9b / Overview: KV free ratio should drop
# - Class 9b / Router: Queue depth by pool should show prefill increase
# - Class 9b / HAMi slices: GPU memory allocation should be high
```

### Reversal
```bash
# Stop the load test (Ctrl-C in Locust terminal)

# Wait for system to recover
# Watch metrics return to baseline:
watch -n 5 'curl -s http://127.0.0.1:8080/metrics | grep orch_kv_free_ratio'

# If KV cache remains saturated, you may need to:
# 1. Scale up prefill replicas
kubectl scale deployment vllm-prefill --replicas=2

# 2. Or restart workers to clear cache
kubectl rollout restart deployment vllm-prefill
```

---

## 3. Decode Saturation

### Objective
Saturate decode workers with long output requests to test decode-phase capacity limits.

### Procedure

#### Step 1: Monitor Baseline
```bash
# Open Grafana: Class 9b / Overview
# Note baseline decode queue depth and tokens in flight
```

#### Step 2: Run Decode Stress Test
```bash
# Use the decode stress profile
export LOCUST_PROFILE=decode_stress
export LOCUST_CONCURRENCY=8
export LOCUST_SPAWN_RATE=4
export LOCUST_DURATION=120

./scripts/run_locust_decode_stress.sh
```

#### Step 3: Monitor During Test
```bash
# Watch decode queue depth
watch -n 2 'curl -s http://127.0.0.1:8080/metrics | grep orch_decode_queue_depth'

# Watch tokens in flight
watch -n 2 'curl -s http://127.0.0.1:8080/metrics | grep orch_tokens_in_flight'

# Check vLLM metrics directly
curl -s http://127.0.0.1:8000/metrics | grep vllm:num_requests_running
curl -s http://127.0.0.1:8001/metrics | grep vllm:num_requests_running
```

#### Step 4: Check for Shedding
```bash
# Look for decode_queue_full shedding
curl -s http://127.0.0.1:8080/metrics | grep 'orch_shed_total{reason="decode_queue_full"'
```

### Expected Results
- Decode queue depth increases significantly
- Tokens in flight increases
- Slower token generation rate
- Potential shedding with `decode_queue_full` reason
- Increased inter-token latency

### Verification
```bash
# Check Grafana dashboards
# - Class 9b / Overview: Decode queue depth should increase
# - Class 9b / Router: Queue depth by pool should show decode increase
# - Class 9b / vLLM: Running requests should be high
# - Class 9b / Performance Analysis: Inter-token latency should increase
```

### Reversal
```bash
# Stop the load test (Ctrl-C in Locust terminal)

# Wait for system to recover
# Watch metrics return to baseline:
watch -n 5 'curl -s http://127.0.0.1:8080/metrics | grep orch_decode_queue_depth'

# If decode remains saturated, scale up decode replicas:
kubectl scale deployment vllm-decode --replicas=2
```

---

## 4. Queue Timeout

### Objective
Test queue timeout shedding by creating request backlog with short timeouts.

### Procedure

#### Step 1: Set Short Request Timeout
Modify requests to have very short timeout:

```bash
# When sending requests, set timeout_s to a low value
# For example, in a test script:
export LOAD_TIMEOUT=5  # 5 second timeout
```

#### Step 2: Create Backlog
```bash
# Send burst traffic to create queue backlog
locust -f app/locustfile_enhanced.py \
    --host http://127.0.0.1:8080 \
    --users 20 \
    --spawn-rate 10 \
    --run-time 30s \
    --headless
```

#### Step 3: Monitor Queue Depths
```bash
# Watch all queue depths
watch -n 1 'curl -s http://127.0.0.1:8080/metrics | grep queue_depth'
```

#### Step 4: Check for Timeout Shedding
```bash
# Look for timeout_queue shedding
curl -s http://127.0.0.1:8080/metrics | grep 'orch_shed_total{reason="timeout_queue"'
```

### Expected Results
- Requests spend time in queue
- Queue depth increases
- HTTP 503 responses with `timeout_queue` reason
- Shed requests have timeout exceeded queue wait time

### Verification
```bash
# Check Grafana dashboards
# - Class 9b / Success and failures: Sheds by reason should show timeout_queue
# - Class 9b / Overview: Queue depths should spike
# - Class 9b / Gateway + admission: Shed ratio should increase
```

### Reversal
```bash
# Stop the burst traffic (Ctrl-C in Locust terminal)

# Restore normal timeout settings
export LOAD_TIMEOUT=30  # or remove the override

# Queue should drain naturally
# Monitor recovery:
watch -n 2 'curl -s http://127.0.0.1:8080/metrics | grep queue_depth'
```

---

## 5. GPU-Memory Pressure

### Objective
Induce GPU memory pressure by filling KV cache with large prompts.

### Procedure

#### Step 1: Monitor Baseline GPU Memory
```bash
# Check current GPU memory usage
nvidia-smi

# Or via Grafana: Class 9b / Cluster
# Note baseline framebuffer usage
```

#### Step 2: Run Extreme Prefill Stress
```bash
# Use very long prompts to fill KV cache
export LOCUST_PROFILE=prefill_stress
export LOCUST_PROMPT_LENGTH=16384  # 16K tokens
export LOCUST_CONCURRENCY=4
export LOCUST_SPAWN_RATE=2
export LOCUST_DURATION=60

locust -f app/locustfile_enhanced.py \
    --host http://127.0.0.1:8080 \
    --users $LOCUST_CONCURRENCY \
    --spawn-rate $LOCUST_SPAWN_RATE \
    --run-time ${LOCUST_DURATION}s \
    --headless
```

#### Step 3: Monitor GPU Memory
```bash
# Watch GPU memory approach limit
watch -n 1 'nvidia-smi --query-gpu=memory.used,memory.total,memory.free --format=csv'

# Watch for OOM indicators
watch -n 1 'curl -s http://127.0.0.1:8080/metrics | grep orch_gpu_oom_total'
```

#### Step 4: Check Worker Logs for OOM
```bash
# Check vLLM worker logs for OOM errors
kubectl logs vllm-prefill-0 | grep -i oom
kubectl logs vllm-decode-0 | grep -i oom
```

### Expected Results
- GPU memory usage approaches limit
- Potential OOM errors in worker logs
- `orch_gpu_oom_total` metric increases
- Shedding with `gpu_oom` reason
- Worker restarts if OOM is severe

### Verification
```bash
# Check Grafana dashboards
# - Class 9b / Cluster: DCGM framebuffer used should be high
# - Class 9b / Success and failures: GPU OOM events panel
# - Class 9b / HAMi slices: Memory allocation should be at limit
```

### Reversal
```bash
# Stop the load test immediately (Ctrl-C)

# If workers OOM'd and crashed, they should restart automatically
# Check pod status:
kubectl get pods -l app=vllm-prefill

# If workers don't recover, restart manually:
kubectl rollout restart deployment vllm-prefill
kubectl rollout restart deployment vllm-decode

# Reduce prompt length for future tests
export LOCUST_PROMPT_LENGTH=8192  # Back to 8K
```

---

## 6. Cache-Unfriendly Traffic

### Objective
Test system behavior with no cache reuse by sending unique prompts.

### Procedure

#### Step 1: Monitor Baseline Cache Hit Rate
```bash
# Open Grafana: Class 9b / Router
# Note baseline cache hit rate (sticky routing)
```

#### Step 2: Run Cache Miss Profile
```bash
# Use cache_miss profile (unique prompts)
export LOCUST_PROFILE=cache_miss
export LOCUST_CONCURRENCY=8
export LOCUST_SPAWN_RATE=4
export LOCUST_DURATION=120

./scripts/run_locust_cache_test.sh
```

#### Step 3: Monitor Cache Metrics
```bash
# Watch for low cache hit rate
watch -n 2 'curl -s http://127.0.0.1:8080/metrics | grep orch_sticky_total'

# Compare to total picks
watch -n 2 'curl -s http://127.0.0.1:8080/metrics | grep orch_pick_total'

# Calculate cache hit rate manually
# cache_hit_rate = sticky_total / pick_total
```

#### Step 4: Monitor Prefill Load
```bash
# Watch prefill queue depth increase
watch -n 2 'curl -s http://127.0.0.1:8080/metrics | grep orch_prefill_queue_depth'

# Watch prefill tokens in flight
watch -n 2 'curl -s http://127.0.0.1:8080/metrics | grep orch_tokens_in_flight | grep prefill'
```

### Expected Results
- Very low cache hit rate (near 0%)
- Higher prefill load compared to cache-friendly traffic
- Increased TTFT due to lack of cache reuse
- Higher overall latency
- Potential prefill saturation under high load

### Verification
```bash
# Check Grafana dashboards
# - Class 9b / Router: Cache hit rate should be very low
# - Class 9b / Overview: Prefill queue depth should be higher than baseline
# - Class 9b / Performance Analysis: TTFT should be higher than cache hit test
```

### Reversal
```bash
# Stop the cache miss test

# Run cache-friendly traffic to warm up cache
export LOCUST_PROFILE=cache_hit
export LOCUST_CONCURRENCY=4
export LOCUST_SPAWN_RATE=2
export LOCUST_DURATION=60

./scripts/run_locust_cache_test.sh

# Cache hit rate should recover
watch -n 2 'curl -s http://127.0.0.1:8080/metrics | grep orch_sticky_total'
```

---

## 7. Unhealthy Replica

### Objective
Test routing behavior when a worker becomes unhealthy or unavailable.

### Procedure

#### Step 1: Monitor Baseline Health
```bash
# Check current replica health
curl -s http://127.0.0.1:8080/metrics | grep orch_replica_healthy

# Note baseline routing distribution
```

#### Step 2: Mark Replica as Unhealthy
```bash
# Option A: Scale down a replica
kubectl scale deployment vllm-prefill --replicas=0

# Option B: Mark pod as unhealthy (if using custom health checks)
kubectl patch pod vllm-prefill-0 -p '{"metadata":{"labels":{"healthy":"false"}}}'

# Option C: Make worker unreachable (block port)
# On the worker node:
# iptables -A INPUT -p tcp --dport 8000 -j DROP
```

#### Step 3: Send Traffic
```bash
# Send traffic to test routing behavior
locust -f app/locustfile_enhanced.py \
    --host http://127.0.0.1:8080 \
    --users 4 \
    --spawn-rate 2 \
    --run-time 30s \
    --headless
```

#### Step 4: Monitor Routing Behavior
```bash
# Check for shedding due to no healthy replicas
curl -s http://127.0.0.1:8080/metrics | grep 'orch_shed_total{reason="no_eligible_pod"'

# Check replica health metrics
curl -s http://127.0.0.1:8080/metrics | grep orch_replica_healthy

# Check if traffic reroutes to remaining replicas
curl -s http://127.0.0.1:8080/metrics | grep orch_replica_tokens_in_flight
```

### Expected Results
- Router detects unhealthy replica
- Traffic reroutes to healthy replicas
- Potential shedding if no healthy replicas available
- `orch_replica_healthy` metric shows unhealthy state
- Possible `no_eligible_pod` shedding if all replicas unhealthy

### Verification
```bash
# Check Grafana dashboards
# - Class 9b / Pods and replicas: Replica health should show unhealthy state
# - Class 9b / Success and failures: Look for no_eligible_pod shedding
# - Class 9b / Router: Check if picks decrease due to lack of healthy replicas
```

### Reversal
```bash
# Restore replica health

# If scaled down:
kubectl scale deployment vllm-prefill --replicas=1

# If marked unhealthy:
kubectl patch pod vllm-prefill-0 -p '{"metadata":{"labels":{"healthy":"true"}}}'

# If port blocked:
# iptables -D INPUT -p tcp --dport 8000 -j DROP

# Wait for replica to become healthy
kubectl wait --for=condition=ready --timeout=60s pod -l app=vllm-prefill

# Verify health restored
curl -s http://127.0.0.1:8080/metrics | grep orch_replica_healthy
```

---

## General Notes

### Safety Guidelines

1. **Never run destructive operations on production systems**
2. **Always monitor GPU memory during stress tests**
3. **Have reversal steps ready before starting each experiment**
4. **Stop experiments immediately if system becomes unstable**
5. **Document actual results vs expected results**

### Monitoring During Experiments

Always keep these Grafana dashboards open:

1. **Class 9b / Overview** - System-wide health
2. **Class 9b / Success and failures** - Shed reasons and rates
3. **Class 9b / Router** - Routing decisions and cache effectiveness
4. **Class 9b / Pods and replicas** - Worker health
5. **Class 9b / Performance Analysis** - Latency and throughput

### Common Troubleshooting

#### Experiment Doesn't Trigger Expected Failure
- Increase load (higher concurrency, longer duration)
- Check if configuration changes were applied
- Verify metrics are being collected
- Check logs for error messages

#### System Doesn't Recover After Reversal
- Wait longer for natural recovery
- Restart affected components
- Check for cascading failures
- Verify configuration was properly restored

#### Metrics Not Updating
- Check Prometheus is scraping targets
- Verify gateway /metrics endpoint is accessible
- Check for metric name changes in code
- Restart Prometheus if needed

### Data Collection

For each experiment, collect:

1. **Before/after metrics snapshots**
   ```bash
   curl -s http://127.0.0.1:8080/metrics > before_$experiment.txt
   # Run experiment
   curl -s http://127.0.0.1:8080/metrics > after_$experiment.txt
   ```

2. **Grafana dashboard screenshots**
   - Overview dashboard
   - Success and failures dashboard
   - Relevant component-specific dashboard

3. **Load test results**
   - Locust HTML reports
   - Locust JSON results

4. **System logs**
   ```bash
   kubectl logs deployment/orch-serve > orch-serve_$experiment.log
   kubectl logs deployment/vllm-prefill > prefill_$experiment.log
   kubectl logs deployment/vllm-decode > decode_$experiment.log
   ```

### Analysis Template

For each experiment, document:

```
## [Experiment Name] Results

### Configuration
- Date/Time: [timestamp]
- Load parameters: [concurrency, spawn rate, duration]
- System state: [baseline configuration]

### Observations
- Metrics changes: [specific metric changes]
- Visual observations: [Grafana dashboard observations]
- Log messages: [relevant log entries]

### Comparison vs Expected
- Expected: [what we expected to see]
- Actual: [what actually happened]
- Differences: [explain any discrepancies]

### Lessons Learned
- [What this teaches about system behavior]
- [What surprised you]
- [What you would investigate further]
```

---

## Additional Resources

- **Main README:** Comprehensive system documentation
- **Architecture Docs:** `docs/ARCHITECTURE.md`
- **Performance Template:** `docs/PERFORMANCE_TEMPLATE.md`
- **Grafana Dashboards:** Class 9b / * dashboards
- **Load Testing:** `scripts/run_locust_*.sh` scripts
