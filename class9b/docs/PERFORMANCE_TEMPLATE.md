# Performance Comparison Template

Use this template to document and compare performance measurements between baseline and improved configurations.

## Performance Comparison

### Test Configuration
- **Date:** [YYYY-MM-DD HH:MM:SS]
- **Duration:** [seconds] (e.g., 120s)
- **Concurrency:** [number] (e.g., 8 concurrent users)
- **Profile:** [baseline/prefill_stress/decode_stress/cache_hit/cache_miss]
- **Environment:** [local/Lambda cluster]
- **Model:** [e.g., Qwen/Qwen2.5-3B-Instruct]
- **GPU Configuration:** [e.g., 1x H100, HAMi slices]

### System Configuration

#### Baseline Configuration
- Gateway settings: [token budget, timeout, etc.]
- Router policy: [p2c, random, least_loaded]
- Worker configuration: [number of replicas, GPU allocation]
- KEDA settings: [min/max replicas, thresholds]
- Cache configuration: [enabled/disabled, backend]

#### Improved Configuration
- What was changed: [specific modifications]
- Why this change: [rationale for improvement]
- Configuration details: [new settings]

### Results

| Metric | Baseline | Improved | Change | % Change |
|--------|----------|----------|--------|----------|
| **Throughput** | | | | |
| Requests/sec | [value] | [value] | [+/- value] | [+/- %] |
| Output tokens/sec | [value] | [value] | [+/- value] | [+/- %] |
| **Success & Errors** | | | | |
| Success rate | [value] | [value] | [+/- value] | [+/- %] |
| Error rate | [value] | [value] | [+/- value] | [+/- %] |
| Shed rate | [value] | [value] | [+/- value] | [+/- %] |
| **Latency** | | | | |
| p50 latency (ms) | [value] | [value] | [+/- value] | [+/- %] |
| p95 latency (ms) | [value] | [value] | [+/- value] | [+/- %] |
| p99 latency (ms) | [value] | [value] | [+/- value] | [+/- %] |
| **TTFT** | | | | |
| p50 TTFT (ms) | [value] | [value] | [+/- value] | [+/- %] |
| p95 TTFT (ms) | [value] | [value] | [+/- value] | [+/- %] |
| **Token Generation** | | | | |
| Decode time/token (ms) | [value] | [value] | [+/- value] | [+/- %] |
| **Queue Behavior** | | | | |
| Avg admission queue depth | [value] | [value] | [+/- value] | [+/- %] |
| Avg prefill queue depth | [value] | [value] | [+/- value] | [+/- %] |
| Avg decode queue depth | [value] | [value] | [+/- value] | [+/- %] |
| **Cache Effectiveness** | | | | |
| Cache hit rate | [value] | [value] | [+/- value] | [+/- %] |
| **Resource Utilization** | | | | |
| Peak GPU memory (GB) | [value] | [value] | [+/- value] | [+/- %] |
| Avg GPU utilization (%) | [value] | [value] | [+/- value] | [+/- %] |

### Detailed Metrics Breakdown

#### Shed Reasons Breakdown

| Reason | Baseline Rate | Improved Rate | Change |
|--------|---------------|---------------|--------|
| tenant_tokens | [value] | [value] | [+/- %] |
| timeout_queue | [value] | [value] | [+/- %] |
| kv_free | [value] | [value] | [+/- %] |
| prefill_queue_full | [value] | [value] | [+/- %] |
| decode_queue_full | [value] | [value] | [+/- %] |
| gpu_oom | [value] | [value] | [+/- %] |
| upstream_timeout | [value] | [value] | [+/- %] |
| no_eligible_pod | [value] | [value] | [+/- %] |

#### Latency Distribution

| Percentile | Baseline (ms) | Improved (ms) | Change |
|-----------|---------------|---------------|--------|
| p50 | [value] | [value] | [+/- %] |
| p75 | [value] | [value] | [+/- %] |
| p90 | [value] | [value] | [+/- %] |
| p95 | [value] | [value] | [+/- %] |
| p99 | [value] | [value] | [+/- %] |
| p99.9 | [value] | [value] | [+/- %] |

### Analysis

#### What Improved

**Primary Improvements:**
- [Metric A]: [description of improvement]
- [Metric B]: [description of improvement]
- [Metric C]: [description of improvement]

**Secondary Improvements:**
- [Metric D]: [description of improvement]
- [Metric E]: [description of improvement]

#### What Degraded

**Degradations:**
- [Metric X]: [description of degradation]
- [Metric Y]: [description of degradation]

**Trade-offs:**
- [Explain if any metrics got worse as a side effect]

#### Root Cause Analysis

**Why the improvement worked:**
- [Technical explanation of the improvement mechanism]
- [How it addresses the specific bottleneck]
- [Why this approach was effective]

**Why any degradations occurred:**
- [Explanation of any negative side effects]
- [Whether these are acceptable trade-offs]

### Grafana Dashboard Observations

#### Key Dashboard Panels

**Class 9b / Overview:**
- [Observations about overall system health]
- [Notable patterns in the data]

**Class 9b / Success and failures:**
- [Shed rate changes]
- [Error pattern analysis]

**Class 9b / Performance Analysis:**
- [Latency improvements]
- [Throughput changes]
- [TTFT improvements]

**Class 9b / Router:**
- [Cache hit rate changes]
- [Routing behavior differences]
- [Queue depth changes]

**Class 9b / [Other relevant dashboard]:**
- [Additional observations]

### Load Test Results

#### Locust Statistics

**Baseline Run:**
- Total requests: [number]
- Request/sec: [number]
- Failure rate: [%]
- Average response time: [ms]
- Min response time: [ms]
- Max response time: [ms]

**Improved Run:**
- Total requests: [number]
- Request/sec: [number]
- Failure rate: [%]
- Average response time: [ms]
- Min response time: [ms]
- Max response time: [ms]

### Resource Utilization

#### GPU Utilization

**Baseline:**
- Average GPU utilization: [%]
- Peak GPU utilization: [%]
- Average GPU memory: [GB]
- Peak GPU memory: [GB]

**Improved:**
- Average GPU utilization: [%]
- Peak GPU utilization: [%]
- Average GPU memory: [GB]
- Peak GPU memory: [GB]

#### CPU/Memory

**Baseline:**
- Average CPU usage: [%]
- Peak CPU usage: [%]
- Average memory usage: [GB]
- Peak memory usage: [GB]

**Improved:**
- Average CPU usage: [%]
- Peak CPU usage: [%]
- Average memory usage: [GB]
- Peak memory usage: [GB]

### Conclusion

#### Overall Assessment

**Was the improvement successful?**
- [Yes/No/Partially]

**Key achievements:**
- [Most significant improvement]
- [Secondary benefits]

**Limitations:**
- [What didn't improve as expected]
- [Trade-offs that were made]

#### Recommendations

**For production deployment:**
- [Recommendation based on results]
- [Any caveats or conditions]

**For further optimization:**
- [Next bottleneck to address]
- [Potential additional improvements]

#### Statistical Significance

**Confidence in results:**
- [High/Medium/Low]
- [Number of test runs]
- [Consistency across runs]

**Potential confounding factors:**
- [Environmental factors that may have affected results]
- [Variables that weren't controlled]

### Appendix

#### Data Collection Details

**Prometheus Queries Used:**
- [List of specific queries for each metric]

**Time Windows:**
- Baseline: [start_time] to [end_time]
- Improved: [start_time] to [end_time]

**Prometheus URL:**
- [Prometheus server URL]

#### Raw Data Files

**Baseline Data:**
- File: [path to baseline metrics JSON]
- Locust report: [path to baseline HTML report]

**Improved Data:**
- File: [path to improved metrics JSON]
- Locust report: [path to improved HTML report]

#### Screenshots

**Baseline Screenshots:**
- [Grafana dashboard screenshots]
- [Locust UI screenshots]

**Improved Screenshots:**
- [Grafana dashboard screenshots]
- [Locust UI screenshots]

---

## Notes

- Fill in all [bracketed] fields with actual measured values
- Use consistent units across all measurements
- Include both absolute values and percentage changes
- Document any anomalies or unexpected results
- Attach supporting data files and screenshots
