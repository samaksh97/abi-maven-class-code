# Class 9b - Production LLM Inference System

## Problem Statement

Building a production-style LLM inference system requires addressing several key challenges:

1. **Scalability:** Handling concurrent requests efficiently across multiple GPU workers
2. **Resource Allocation:** Optimally splitting GPU resources between prefill (prompt processing) and decode (token generation) phases
3. **Admission Control:** Preventing system overload through intelligent request shedding
4. **Cache Utilization:** Maximizing KV cache reuse to reduce redundant computation
5. **Observability:** Comprehensive monitoring for performance analysis and debugging
6. **Fault Tolerance:** Graceful degradation under failure conditions

This implementation demonstrates a complete production-grade system with disaggregated prefill/decode workers, Mooncake KV cache transfer, HAMi GPU slicing, KEDA autoscaling, and comprehensive observability.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Client Requests                              │
│                    (Open WebUI / Direct API)                         │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      Gateway (orch-serve)                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │   Admission  │  │    Router    │  │   Overflow   │              │
│  │   Control    │  │  (p2c +      │  │   Fallback   │              │
│  │  (token cap) │  │   sticky)    │  │              │              │
│  └──────────────┘  └──────────────┘  └──────────────┘              │
└──────────┬───────────────────────┬───────────────────────┬───────────┘
           │                       │                       │
           ▼                       ▼                       ▼
    ┌──────────┐           ┌──────────┐           ┌──────────┐
    │ Prefill  │           │  Decode  │           │ Mooncake │
    │ Workers  │◄──────────│ Workers  │           │  KV Store│
    │ (HAMi)   │   KV Hop  │ (HAMi)   │           │          │
    └──────────┘           └──────────┘           └──────────┘
           │                       │                       │
           └───────────┬───────────┘                       │
                       ▼                                 │
                ┌──────────┐                            │
                │   KEDA   │                            │
                │Autoscaler│                            │
                └──────────┘                            │
                       │                                 │
                       ▼                                 ▼
              ┌─────────────────┐              ┌─────────────────┐
              │  GPU Resources  │              │   Observability │
              │  (HAMi Slices)  │              │                 │
              └─────────────────┘              │  ┌──────────┐   │
                                               │  │Prometheus│   │
                                               │  └──────────┘   │
                                               │  ┌──────────┐   │
                                               │  │ Grafana  │   │
                                               │  └──────────┘   │
                                               │  ┌──────────┐   │
                                               │  │ DCGM     │   │
                                               │  └──────────┘   │
                                               └─────────────────┘
```

## Component Responsibilities

### Gateway (orch-serve)
- **Admission Control:** Enforces per-tenant token budgets (10,000 tokens/min default)
- **Request Routing:** Implements power-of-two-choices (p2c) algorithm with cache-aware scoring
- **Overflow Handling:** Fallback to external services when local workers are saturated
- **Metrics Export:** Prometheus-compatible `/metrics` endpoint
- **OpenAI Compatibility:** Standard `/v1/chat/completions` and `/v1/models` endpoints

### Router
- **Scoring Functions:** 
  - Prefix cache hit rate (prioritizes workers with cached KV)
  - Token load (balances active work)
  - Active request count (queue depth awareness)
  - KV utilization (memory efficiency)
  - Queue depth (latency optimization)
- **Sticky Routing:** Routes requests with >80% prefix overlap to same worker
- **Capability Routing:** Separates text and vision model traffic
- **Queue Timeout:** Sheds requests that would wait too long

### Worker Pools
- **Prefill Workers:** Process input prompts, build KV cache (HAMi GPU slices)
- **Decode Workers:** Generate output tokens using cached KV (HAMi GPU slices)
- **KVBus:** In-memory cache sharing and transfer coordination
- **Mooncake Integration:** Distributed KV cache for prefill→decode handoff

### HAMi (GPU Slicing)
- **Resource Allocation:** Splits single GPU into multiple vGPU slices
- **Prefill Allocation:** 22GB memory, 60% GPU cores for prompt processing
- **Decode Allocation:** 22GB memory, 60% GPU cores for token generation
- **Dynamic Scheduling:** Efficient GPU utilization across phases

### KEDA (Autoscaling)
- **Metric Trigger:** Scales based on `orch_tokens_in_flight` per phase
- **Scaling Bounds:** 1-2 replicas for both prefill and decode
- **Cooldown Period:** Prevents thrashing during load spikes

### Observability Stack
- **Prometheus:** Metrics collection and storage
- **Grafana:** 10 pre-configured dashboards for system monitoring
- **DCGM Exporter:** GPU utilization, memory, power metrics
- **Custom Metrics:** Application-level performance indicators

## Setup Instructions

### Prerequisites
- Lambda Labs GPU instance (or similar Kubernetes cluster with GPUs)
- SSH access to Lambda instance
- Local machine with kubectl (for cluster management)
- Python 3.12+ (for local testing)

### Environment Configuration

Create `.env` file in the class9b directory:

```bash
# Lambda SSH Configuration
export LAMBDA=ubuntu@YOUR_LAMBDA_IP
export LAMBDA_SSH_KEY=$HOME/.ssh/YOUR_LAMBDA_KEY

# Model Configuration
export TEXT_MODEL=Qwen/Qwen2.5-3B-Instruct
export VISION_MODEL=Qwen/Qwen2.5-VL-3B-Instruct
export LOCAL_MODEL=Qwen/Qwen2.5-3B-Instruct

# Service Endpoints (Local Testing)
export LOCAL_BASE_URL=http://127.0.0.1:8000/v1
export PREFILL_URLS=http://127.0.0.1:8000
export DECODE_URLS=http://127.0.0.1:8001

# Topology Configuration
export LAB_TOPOLOGY=disaggregated
export LAB_SPLIT=capability
export KV_BACKEND=mooncake
export MOONCAKE_URL=http://127.0.0.1:50051

# Gateway Configuration
export ORCH_URL=http://127.0.0.1:8080/v1
export LOCUST_HOST=http://127.0.0.1:8080

# Overflow Configuration (Optional)
export OVERFLOW_BACKEND=superlinked
export OVERFLOW_BASE_URL=https://api.superlinked.com/v1
export OVERFLOW_MODEL=Qwen/Qwen3.5-4B
export OVERFLOW_API_KEY=
export OVERFLOW_MAX_TOKENS=64
export OVERFLOW_MAX_REQS=20

# Tracing
export TRACE_PATH=traces/requests.jsonl
```

### Local Development Setup

```bash
# 1. Navigate to class9b directory
cd class-code/class9b

# 2. Create virtual environment
python3 -m venv .venv
source .venv/bin/activate

# 3. Install dependencies
pip install -r requirements.txt

# 4. Run tests
pytest tests/

# 5. Start local gateway (uses fake workers)
python -m gateway.serve
```

### Lambda Cluster Deployment

#### Step 1: Sync Code to Lambda
```bash
# Mac terminal
cd class-code/class9b
bash setup/sync_to_lambda.sh
```

#### Step 2: Establish SSH Tunnel
```bash
# Same Mac terminal - this is the ONLY SSH session
bash setup/ssh.sh
# Leave this terminal open for the entire session
```

#### Step 3: Lambda Setup
```bash
# SSH terminal (now on Lambda)
bash setup/lambda_setup.sh
```

#### Step 4: Deploy Cluster
```bash
# Same SSH terminal
bash setup/lambda_cluster.sh
```

#### Step 5: Verify Deployment
```bash
# Same SSH terminal
kubectl get deploy,svc,scaledobject
```

Expected output:
- `orch-serve` deployment: 1 replica
- `vllm-prefill` deployment: 1 replica  
- `vllm-decode` deployment: 1 replica
- `mooncake-store` deployment: 1 replica
- `open-webui` deployment: 1 replica
- NodePort services for external access
- KEDA ScaledObjects for autoscaling

#### Step 6: Run Smoke Test
```bash
# Same SSH terminal
bash setup/smoke_sliced.sh
```

Expected output: `SLICED SMOKE PASS`

## Smoke Test Instructions

### Comprehensive Health Check

The enhanced smoke test (`setup/smoke_comprehensive.sh`) validates:

1. **Component Health:** All services respond to health checks
2. **Capability Routing:** Text and vision requests route correctly
3. **KV Transfer:** Prefill→decode handoff functions
4. **Metrics Export:** Prometheus endpoints accessible
5. **GPU Allocation:** HAMi slices properly allocated
6. **Pod Status:** All pods running and healthy

### Manual Smoke Test

If the automated script fails, manually verify:

```bash
# Check all pods are running
kubectl get pods -A

# Check GPU allocation
nvidia-smi

# Test text capability
curl -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"text","messages":[{"role":"user","content":"Test"}],"max_tokens":4}'

# Test vision capability  
curl -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"vision","messages":[{"role":"user","content":[{"type":"text","text":"What color?"},{"type":"image_url","image_url":{"url":"data:image/png;base64,iVBORw0KG..."}}]}],"max_tokens":4}'

# Check metrics
curl -s http://127.0.0.1:8080/metrics | head -20
```

## Load Testing

### Locust Workload Profiles

The system includes 5 configurable workload profiles:

1. **Baseline:** Short input (16 tokens), short output (32 tokens)
2. **Prefill Stress:** Long input (8K tokens), short output (32 tokens)  
3. **Decode Stress:** Short input (16 tokens), long output (512 tokens)
4. **Cache Hit:** Repeated prefix prompts (same first 256 chars)
5. **Cache Miss:** Unique random prompts

### Running Load Tests

#### Install Load Testing Dependencies
```bash
pip install -r requirements-load.txt
```

#### Basic Locust Test
```bash
# Start Locust (holds terminal)
locust -f app/locustfile.py --host http://127.0.0.1:8080

# Open browser to http://127.0.0.1:8089
# Set users=4, spawn rate=2, run for 1+ minutes
```

#### Enhanced Locust Profiles
```bash
# Baseline profile
LOCUST_PROFILE=baseline locust -f app/locustfile_enhanced.py --host http://127.0.0.1:8080

# Prefill stress test
LOCUST_PROFILE=prefill_stress locust -f app/locustfile_enhanced.py --host http://127.0.0.1:8080

# Decode stress test  
LOCUST_PROFILE=decode_stress locust -f app/locustfile_enhanced.py --host http://127.0.0.1:8080

# Cache effectiveness test
LOCUST_PROFILE=cache_hit locust -f app/locustfile_enhanced.py --host http://127.0.0.1:8080
```

#### Crew Flood Test
```bash
# Multi-role concurrent load
ORCH_URL=http://127.0.0.1:8080/v1 python -m app.crew_flood --rounds 48 --workers 8
```

### Configuration Options

Control load test behavior via environment variables:

```bash
export LOCUST_CONCURRENCY=4        # Number of concurrent users
export LOCUST_SPAWN_RATE=2         # Users per second
export LOCUST_DURATION=60          # Test duration in seconds
export LOCUST_PROMPT_LENGTH=16     # Input token count
export LOCUST_MAX_TOKENS=32        # Output token count
export LOCUST_PROFILE=baseline     # Workload profile
```

## Metrics and Dashboards

### Grafana Setup

```bash
# Install observability stack (Day 2)
bash setup/day2_observability.sh

# Get Grafana password
kubectl -n monitoring get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo

# Access Grafana
open http://127.0.0.1:31495
# Login: admin / <password from above>
```

### Available Dashboards

1. **Class 9b / Overview** - System-wide metrics and health
2. **Class 9b / Success and failures** - Request success rates and shed reasons
3. **Class 9b / Gateway + admission** - Admission control performance
4. **Class 9b / Router** - Routing decisions and cache effectiveness
5. **Class 9b / Pods and replicas** - Pod health and scaling
6. **Class 9b / vLLM** - Worker-level performance metrics
7. **Class 9b / KEDA** - Autoscaling activity
8. **Class 9b / HAMi slices** - GPU resource allocation
9. **Class 9b / Mooncake KV** - KV cache transfer metrics
10. **Class 9b / Cluster** - Node-level resources

### Key Metrics

#### Request Metrics
- `orch_requests_total` - Total requests received
- `orch_completed_total` - Successfully completed requests
- `orch_shed_total{reason="..."}` - Shed requests by reason
- `orch_overflow_total` - Requests sent to overflow

#### Latency Metrics
- `orch_request_duration_seconds{stage="..."}` - Latency by stage (gateway, pick, local, overflow, e2e)
- Request stages: gateway → pick → local/overflow → e2e

#### Queue Metrics
- `orch_tokens_in_flight{phase="..."}` - Active tokens by phase (prefill/decode)
- `orch_replica_queue_depth{pool="...",pod="..."}` - Queue depth per replica
- `orch_replica_waiting{pool="...",pod="..."}` - Waiting requests per replica
- `orch_replica_running{pool="...",pod="..."}` - Running requests per replica

#### Cache Metrics
- `orch_kv_transfer_total` - Total KV cache transfers
- `orch_kv_transfer_tokens` - Total tokens transferred
- `orch_kv_evict_total` - Total cache evictions
- `orch_sticky_total` - Sticky routing hits
- `mooncake_hops_total` - Mooncake transfer count

#### GPU Metrics
- `DCGM_FI_DEV_GPU_UTIL` - GPU utilization percentage
- `DCGM_FI_DEV_FB_USED` - Framebuffer memory usage
- `vllm:kv_cache_usage_perc` - KV cache utilization
- `hami_gpu_memory_allocated_bytes` - HAMi memory allocation

### Shed Reasons

The system sheds requests for these detectable reasons:

- `tenant_tokens` - Per-tenant token budget exceeded (429)
- `timeout_queue` - Queue wait time exceeds half request timeout (503)
- `kv_free` - All workers have insufficient KV cache space (503)
- `p99_spread` - P99 latency spread too high (503)
- `no_eligible_pod` - No healthy workers available (503)

## Failure Scenarios

### 1. Admission-Control Shedding

**Objective:** Test token budget enforcement

**Procedure:**
```bash
# Set low token budget in gateway/admission.py
# tokens_per_min=100 (instead of 10_000)

# Send high traffic
locust -f app/locustfile.py --host http://127.0.0.1:8080 --users 10 --spawn-rate 5

# Monitor metrics
curl -s http://127.0.0.1:8080/metrics | grep orch_shed_total
```

**Expected:** 429 responses with `reason="tenant_tokens"`

**Verification:** 
```bash
# Check shed metric
curl -s http://127.0.0.1:8080/metrics | grep 'orch_shed_total{reason="tenant_tokens"'
```

**Reversal:** Restore token budget to 10,000

### 2. Prefill Saturation

**Objective:** Saturate prefill KV cache with long prompts

**Procedure:**
```bash
# Send long-prompt requests
export LOAD_PROMPT_LENGTH=8192
export LOAD_MAX_TOKENS=32
locust -f app/locustfile_enhanced.py --host http://127.0.0.1:8080 --users 4
```

**Expected:** Increased prefill queue, potential `kv_free` shedding

**Verification:**
```bash
# Check prefill queue depth
curl -s http://127.0.0.1:8080/metrics | grep orch_replica_queue_depth | grep prefill

# Check KV free ratio
curl -s http://127.0.0.1:8080/metrics | grep orch_kv_free_ratio
```

**Reversal:** Reduce prompt length or add prefill replicas

### 3. Decode Saturation

**Objective:** Saturate decode workers with long outputs

**Procedure:**
```bash
# Send short-prompt, long-output requests
export LOAD_PROMPT_LENGTH=16
export LOAD_MAX_TOKENS=512
locust -f app/locustfile_enhanced.py --host http://127.0.0.1:8080 --users 4
```

**Expected:** Increased decode queue, slower generation

**Verification:**
```bash
# Check decode queue depth
curl -s http://127.0.0.1:8080/metrics | grep orch_replica_queue_depth | grep decode
```

**Reversal:** Reduce max_tokens or add decode replicas

### 4. Queue Timeout

**Objective:** Test queue timeout shedding

**Procedure:**
```bash
# Set short timeout in requests
export LOAD_TIMEOUT=5

# Create backlog by sending burst traffic
locust -f app/locustfile.py --host http://127.0.0.1:8080 --users 20 --spawn-rate 10
```

**Expected:** 503 responses with `reason="timeout_queue"`

**Verification:**
```bash
curl -s http://127.0.0.1:8080/metrics | grep 'orch_shed_total{reason="timeout_queue"'
```

**Reversal:** Increase timeout or reduce spawn rate

### 5. GPU-Memory Pressure

**Objective:** Induce GPU memory pressure

**Procedure:**
```bash
# Send very long prompts to fill KV cache
export LOAD_PROMPT_LENGTH=16384
locust -f app/locustfile_enhanced.py --host http://127.0.0.1:8080 --users 2

# Monitor GPU memory
watch -n 1 nvidia-smi
```

**Expected:** GPU memory usage approaches limit, potential OOM

**Verification:**
```bash
# Check GPU memory
nvidia-smi --query-gpu=memory.used,memory.total --format=csv

# Check for OOM in logs
kubectl logs vllm-prefill-xxxxx | grep -i oom
```

**Reversal:** Reduce prompt length or increase GPU allocation

### 6. Cache-Unfriendly Traffic

**Objective:** Test system with no cache reuse

**Procedure:**
```bash
# Send unique prompts (cache miss profile)
export LOCUST_PROFILE=cache_miss
locust -f app/locustfile_enhanced.py --host http://127.0.0.1:8080 --users 4
```

**Expected:** Low cache hit rate, higher prefill load

**Verification:**
```bash
# Check cache hit rate
curl -s http://127.0.0.1:8080/metrics | grep orch_sticky_total

# Check prefill load
curl -s http://127.0.0.1:8080/metrics | grep orch_tokens_in_flight | grep prefill
```

**Reversal:** Send cache-friendly traffic

### 7. Unhealthy Replica

**Objective:** Test routing behavior with unhealthy worker

**Procedure:**
```bash
# Mark a replica as unhealthy
kubectl patch pod vllm-prefill-0 -p '{"metadata":{"labels":{"healthy":"false"}}}'

# Send traffic
locust -f app/locustfile.py --host http://127.0.0.1:8080 --users 4
```

**Expected:** Router sheds requests to unhealthy replica

**Verification:**
```bash
# Check replica health
curl -s http://127.0.0.1:8080/metrics | grep orch_replica_healthy

# Check shed reasons
curl -s http://127.0.0.1:8080/metrics | grep orch_shed_total
```

**Reversal:** Restore replica health
```bash
kubectl patch pod vllm-prefill-0 -p '{"metadata":{"labels":{"healthy":"true"}}}'
```

## Performance Comparison

### Metrics Collection

Use the metrics collection script to gather performance data:

```bash
# Collect metrics for a time range
python scripts/collect_metrics.py --start 2024-01-01T00:00:00 --end 2024-01-01T01:00:00 --label baseline
```

### Performance Template

See `docs/PERFORMANCE_TEMPLATE.md` for the standardized comparison format.

### Key Performance Indicators

- **Requests/sec** - System throughput
- **Output tokens/sec** - Generation throughput  
- **Success rate** - Request completion percentage
- **Latency percentiles** - p50, p95, p99 response times
- **TTFT** - Time to first token
- **Decode time/token** - Per-token generation speed
- **Queue depth** - Average queue length
- **Cache hit rate** - KV cache effectiveness
- **Peak GPU memory** - Memory utilization

## Improvement Implementation

### Baseline Measurement

Before implementing improvements, establish baseline performance:

```bash
# Run each workload profile
scripts/run_locust_baseline.sh
scripts/run_locust_prefill_stress.sh  
scripts/run_locust_decode_stress.sh
scripts/run_locust_cache_test.sh

# Collect metrics
python scripts/collect_metrics.py --label baseline
```

### Bottleneck Analysis

Analyze baseline data to identify primary bottleneck:
- High prefill queue → prefill capacity or cache effectiveness
- High decode queue → decode capacity or batching efficiency
- Low cache hit rate → routing or traffic patterns
- High latency → admission control or resource allocation

### Improvement Areas

Based on analysis, consider:

1. **Phase-aware admission control** - Different token budgets for prefill vs decode
2. **Cache-aware routing** - Enhanced scoring based on KV transfer costs
3. **KEDA threshold optimization** - Better autoscaling triggers
4. **Resource allocation tuning** - Adjust HAMi GPU slice allocation

### Validation

After implementing improvement:

```bash
# Run same workload profiles
scripts/run_performance_comparison.sh

# Compare results
# Use docs/PERFORMANCE_TEMPLATE.md format
```

## Root Cause Analysis Template

### Issue Description
[Describe the performance problem or failure]

### Symptoms
- Observable metrics (specific values)
- User impact (latency, errors, etc.)
- Timeline (when it started, duration)

### Investigation
1. **Metrics Analysis**
   - Dashboard observations
   - Metric queries used
   - Thresholds breached

2. **Log Analysis**
   - Relevant log entries
   - Error patterns
   - Correlation with metrics

3. **Component Isolation**
   - Which component(s) affected
   - Dependency analysis
   - Failure propagation path

### Root Cause
[Identify the fundamental cause]

### Resolution
- Immediate fix applied
- Configuration changes
- Code changes (if any)

### Prevention
- Monitoring improvements
- Configuration changes
- Process changes

## Stage 7: Performance Improvement

### Baseline Measurements

Baseline performance was measured on NVIDIA A10 GPU with Qwen/Qwen2.5-3B-Instruct:

**Configuration:**
- GPU: NVIDIA A10 (23GB memory)
- Model: Qwen/Qwen2.5-3B-Instruct
- Workload: Baseline profile (short input, short output)
- Test Duration: 60 seconds
- Concurrency: 5 users

**Results:**
- **Throughput**: 3.7 req/s
- **Success Rate**: 100%
- **Average Latency**: 450ms
- **Median Latency**: 540ms
- **TTFT**: 128ms
- **Output Tokens**: 5,632

**Detailed Analysis:** See `docs/BASELINE_RESULTS.md`

### Bottleneck Analysis

The primary bottleneck identified was **decode phase latency**:
- TTFT: 128ms (29% of total latency)
- Decode phase: ~320ms (71% of total latency)
- GPU memory utilization: Only 80% configured, actual usage lower
- No queue buildup under baseline load

### Implemented Improvement: Token-Aware Admission Control

**What It Does:**
- Estimates GPU memory requirements for incoming requests based on token budget
- Monitors available GPU memory via KV free ratio metrics
- Proactively sheds requests when GPU memory is insufficient
- Prevents OOM errors by enforcing memory limits before placement

**Implementation:**
- **File**: `gateway/admission.py`
- **New Method**: `_insufficient_gpu_memory()`
- **New Shed Reason**: `token_budget_exceeded`
- **Configuration Constants**:
  - `MEMORY_PER_TOKEN`: 2KB per token (conservative estimate)
  - `MIN_KV_FREE_RATIO`: 10% minimum KV free ratio

**Results After Improvement:**
- **Throughput**: 3.68 req/s (-0.45%)
- **Average Latency**: 472ms (+4.9%)
- **Median Latency**: 560ms (+3.7%)
- **Success Rate**: 100% (unchanged)
- **Shed Requests**: 0 (no memory pressure under baseline load)

**Detailed Analysis:** See `docs/IMPROVEMENT_RESULTS.md`

### Impact Assessment

**Under Light Load (Baseline Test):**
- Slight performance decrease (~5% latency) due to safety check overhead
- No memory pressure, so proactive shedding never activated
- Trade-off: Acceptable small overhead for proactive memory management

**Under High Load (Expected Behavior):**
- Prevents OOM errors by rejecting high-token requests when memory is constrained
- Maintains system stability under memory pressure
- Enables graceful degradation instead of cascading failures
- Prioritizes smaller requests when GPU memory is limited

### Recommendation

The token-aware admission control should be **enabled in production** because:
1. The ~5% latency overhead under light load is acceptable
2. It provides critical protection against GPU memory exhaustion
3. It enables graceful degradation under memory pressure
4. It prevents cascading failures that would crash the entire system

### Future Optimization Opportunities

To reduce the overhead under light load:
1. **Adaptive Activation**: Only enable the check when KV free ratio drops below a threshold
2. **Cached Memory Estimates**: Cache replica memory metrics to reduce metric refresh frequency
3. **Optimized Calculation**: Streamline the memory estimation algorithm
4. **Async Admission**: Perform memory checks asynchronously when possible

## Limitations

1. **GPU Dependency:** Full system requires GPU cluster; local testing uses fake workers
2. **Model Size:** Current implementation uses 3B models; larger models may require different resource allocation
3. **Single Region:** No multi-region deployment or geographic routing
4. **Token Budget:** Fixed per-tenant limits; no dynamic adjustment
5. **Cache Scope:** KV cache shared within cluster only; no distributed cache
6. **Observability:** No distributed tracing (only metrics and logs)

## Next Steps

1. **Dynamic Token Budgets:** Adjust per-tenant limits based on system load
2. **Multi-Model Support:** Efficient routing between multiple model sizes
3. **Advanced Caching:** Hierarchical cache with LRU eviction policies
4. **Predictive Autoscaling:** ML-based scaling prediction
5. **Distributed Tracing:** OpenTelemetry integration for request tracing
6. **Multi-Region:** Geographic routing and cache replication

## Access URLs (After Deployment)

- **Open WebUI:** http://127.0.0.1:30030 (no auth)
- **Gateway API:** http://127.0.0.1:8080
- **Gateway Metrics:** http://127.0.0.1:8080/metrics
- **Grafana:** http://127.0.0.1:31495 (admin / <password>)
- **Locust UI:** http://127.0.0.1:8089 (during load tests)
- **Mooncake Store:** http://127.0.0.1:50051/metrics

## Troubleshooting

### SSH Tunnel Issues
If browser URLs don't load:
- Ensure Step 2 SSH session is still running
- Check SSH tunnel is established: `ps aux | grep ssh`
- Restart SSH tunnel if needed

### Pod Not Starting
```bash
# Check pod status
kubectl describe pod <pod-name>

# Check logs
kubectl logs <pod-name>

# Check events
kubectl get events --sort-by=.metadata.creationTimestamp
```

### GPU Allocation Issues
```bash
# Check GPU status
nvidia-smi

# Check HAMi allocation
kubectl get pods -o wide

# Check HAMi scheduler logs
kubectl logs -n hami-system <hami-scheduler-pod>
```

### Metrics Not Appearing
```bash
# Check Prometheus targets
kubectl port-forward -n monitoring svc/prometheus-server 9090:80
# Open http://localhost:9090/targets

# Check gateway metrics endpoint
curl -v http://127.0.0.1:8080/metrics

# Check Prometheus scraping
kubectl logs -n monitoring prometheus-server-xxxxx | grep gateway
```

### Load Test Failures
```bash
# Check gateway is accessible
curl -v http://127.0.0.1:8080/v1/models

# Check workers are healthy
curl -v http://127.0.0.1:8000/health
curl -v http://127.0.0.1:8001/health

# Check admission control isn't blocking
curl -v http://127.0.0.1:8080/metrics | grep orch_shed_total
```

## Development Workflow

### Local Testing with Fake Workers
```bash
# Set up environment without PREFILL_URLS/DECODE_URLS
unset PREFILL_URLS DECODE_URLS

# Run gateway with fake workers
python -m gateway.serve

# Test with REPL
python -m gateway.repl
```

### Testing with Real vLLM Workers
```bash
# Start vLLM workers locally
vllm serve Qwen/Qwen2.5-3B-Instruct --port 8000
vllm serve Qwen/Qwen2.5-3B-Instruct --port 8001

# Configure gateway
export PREFILL_URLS=http://127.0.0.1:8000
export DECODE_URLS=http://127.0.0.1:8001

# Run gateway
python -m gateway.serve
```

### Running Tests
```bash
# Unit tests
pytest tests/

# Integration tests (requires cluster)
pytest tests/ -k "not vllm_worker"

# Specific test
pytest tests/test_router.py::test_sticky_routing
```

## Additional Documentation

- **Architecture Details:** `docs/ARCHITECTURE.md`
- **Failure Experiments:** `docs/FAILURE_EXPERIMENTS.md`
- **Performance Template:** `docs/PERFORMANCE_TEMPLATE.md`
- **Quick Start:** `QUICKSTART.md`

## License

This is educational courseware for the Maven LLM Inference Engineering class.
