#!/usr/bin/env python3
"""
Prometheus Metrics Collection Script

Collects performance metrics from Prometheus for a given time range.
Used for baseline vs improved performance comparisons.
"""

import argparse
import json
import sys
from datetime import datetime, timedelta
from typing import Any
import urllib.request
import urllib.error
import urllib.parse


class PrometheusClient:
    """Simple Prometheus HTTP client"""
    
    def __init__(self, base_url: str = "http://127.0.0.1:9090"):
        self.base_url = base_url.rstrip("/")
    
    def query(self, query: str, time_str: str | None = None) -> dict[str, Any]:
        """
        Execute a PromQL query
        
        Args:
            query: PromQL query string
            time_str: Optional timestamp for the query (RFC3339 or Unix timestamp)
        
        Returns:
            Query result as dictionary
        """
        params = {"query": query}
        if time_str:
            params["time"] = time_str
        
        url = f"{self.base_url}/api/v1/query"
        encoded_params = urllib.parse.urlencode(params)
        full_url = f"{url}?{encoded_params}"
        
        try:
            with urllib.request.urlopen(full_url, timeout=30) as response:
                data = json.loads(response.read().decode())
                
            if data.get("status") != "success":
                raise ValueError(f"Query failed: {data.get('error', 'Unknown error')}")
            
            return data.get("data", {})
        except urllib.error.URLError as e:
            raise ConnectionError(f"Failed to connect to Prometheus at {self.base_url}: {e}")
    
    def query_range(self, query: str, start: str, end: str, step: str = "15s") -> dict[str, Any]:
        """
        Execute a range query over a time period
        
        Args:
            query: PromQL query string
            start: Start timestamp (RFC3339 or Unix timestamp)
            end: End timestamp (RFC3339 or Unix timestamp)
            step: Query resolution step
        
        Returns:
            Query result as dictionary
        """
        params = {
            "query": query,
            "start": start,
            "end": end,
            "step": step
        }
        
        url = f"{self.base_url}/api/v1/query_range"
        encoded_params = urllib.parse.urlencode(params)
        full_url = f"{url}?{encoded_params}"
        
        try:
            with urllib.request.urlopen(full_url, timeout=30) as response:
                data = json.loads(response.read().decode())
                
            if data.get("status") != "success":
                raise ValueError(f"Query failed: {data.get('error', 'Unknown error')}")
            
            return data.get("data", {})
        except urllib.error.URLError as e:
            raise ConnectionError(f"Failed to connect to Prometheus at {self.base_url}: {e}")


def extract_metric_value(result: dict[str, Any]) -> float:
    """Extract scalar value from Prometheus query result"""
    if result.get("resultType") == "vector":
        values = result.get("result", [])
        if not values:
            return 0.0
        # Sum all values in the vector
        total = 0.0
        for item in values:
            value = item.get("value", [0, "0"])[1]
            try:
                total += float(value)
            except (ValueError, TypeError):
                pass
        return total
    elif result.get("resultType") == "scalar":
        value = result.get("result", [0, "0"])[1]
        try:
            return float(value)
        except (ValueError, TypeError):
            return 0.0
    return 0.0


def extract_rate(result: dict[str, Any]) -> float:
    """Extract rate value from a range query result"""
    if result.get("resultType") != "matrix":
        return 0.0
    
    values = result.get("result", [])
    if not values:
        return 0.0
    
    # Calculate average rate from the time series
    total_rate = 0.0
    count = 0
    
    for series in values:
        series_values = series.get("values", [])
        if len(series_values) < 2:
            continue
        
        # Calculate rate from the last two points
        try:
            last_value = float(series_values[-1][1])
            prev_value = float(series_values[-2][1])
            rate = last_value - prev_value
            total_rate += rate
            count += 1
        except (ValueError, TypeError, IndexError):
            continue
    
    return total_rate / count if count > 0 else 0.0


def collect_metrics(client: PrometheusClient, start: str, end: str, label: str) -> dict[str, Any]:
    """
    Collect comprehensive performance metrics
    
    Args:
        client: Prometheus client instance
        start: Start timestamp
        end: End timestamp
        label: Label for this collection (e.g., "baseline", "improved")
    
    Returns:
        Dictionary of collected metrics
    """
    metrics = {
        "label": label,
        "start_time": start,
        "end_time": end,
        "collection_time": datetime.utcnow().isoformat(),
        "metrics": {}
    }
    
    # Define queries for each metric
    queries = {
        # Throughput metrics
        "requests_per_second": 'sum(rate(orch_requests_total[5m]))',
        "output_tokens_per_second": 'sum(rate(orch_output_tokens_total[5m]))',
        
        # Success metrics
        "success_rate": 'sum(rate(orch_completed_total[5m])) / clamp_min(sum(rate(orch_requests_total[5m])), 1e-9)',
        "error_rate": 'sum(rate(orch_shed_total[5m])) / clamp_min(sum(rate(orch_requests_total[5m])), 1e-9)',
        
        # Latency metrics
        "p50_latency_ms": 'histogram_quantile(0.50, sum by (le) (rate(orch_request_duration_seconds_bucket[5m]))) * 1000',
        "p95_latency_ms": 'histogram_quantile(0.95, sum by (le) (rate(orch_request_duration_seconds_bucket[5m]))) * 1000',
        "p99_latency_ms": 'histogram_quantile(0.99, sum by (le) (rate(orch_request_duration_seconds_bucket[5m]))) * 1000',
        
        # TTFT metrics
        "p50_ttft_ms": 'histogram_quantile(0.50, sum by (le) (rate(orch_ttft_seconds_bucket[5m]))) * 1000',
        "p95_ttft_ms": 'histogram_quantile(0.95, sum by (le) (rate(orch_ttft_seconds_bucket[5m]))) * 1000',
        
        # Decode metrics
        "decode_time_per_token_ms": 'histogram_quantile(0.95, sum by (le) (rate(orch_inter_token_latency_seconds_bucket[5m]))) * 1000',
        
        # Queue metrics
        "avg_admission_queue_depth": 'avg(orch_admission_queue_depth)',
        "avg_prefill_queue_depth": 'avg(orch_prefill_queue_depth)',
        "avg_decode_queue_depth": 'avg(orch_decode_queue_depth)',
        
        # Cache metrics
        "cache_hit_rate": 'orch_sticky_total / clamp_min(orch_pick_total, 1)',
        
        # GPU metrics
        "peak_gpu_memory_bytes": 'max(DCGM_FI_DEV_FB_USED) * 1024 * 1024',
        
        # Shed reasons
        "shed_rate_total": 'sum(rate(orch_shed_total[5m]))',
        "shed_rate_tenant_tokens": 'sum(rate(orch_shed_total{reason="tenant_tokens"}[5m]))',
        "shed_rate_timeout_queue": 'sum(rate(orch_shed_total{reason="timeout_queue"}[5m]))',
        "shed_rate_kv_free": 'sum(rate(orch_shed_total{reason="kv_free"}[5m]))',
    }
    
    # Execute each query
    for metric_name, query in queries.items():
        try:
            result = client.query_range(query, start, end, step="30s")
            value = extract_rate(result)
            metrics["metrics"][metric_name] = value
        except Exception as e:
            print(f"Warning: Failed to collect {metric_name}: {e}", file=sys.stderr)
            metrics["metrics"][metric_name] = None
    
    return metrics


def main():
    parser = argparse.ArgumentParser(
        description="Collect performance metrics from Prometheus for comparison"
    )
    parser.add_argument(
        "--prometheus-url",
        default="http://127.0.0.1:9090",
        help="Prometheus server URL (default: http://127.0.0.1:9090)"
    )
    parser.add_argument(
        "--start",
        required=True,
        help="Start timestamp (RFC3339 or Unix timestamp)"
    )
    parser.add_argument(
        "--end",
        required=True,
        help="End timestamp (RFC3339 or Unix timestamp)"
    )
    parser.add_argument(
        "--label",
        required=True,
        help="Label for this collection (e.g., baseline, improved)"
    )
    parser.add_argument(
        "--output",
        help="Output file path (default: stdout)"
    )
    parser.add_argument(
        "--duration",
        type=int,
        help="Duration in minutes before now (alternative to --start/--end)"
    )
    
    args = parser.parse_args()
    
    # Handle duration shorthand
    if args.duration:
        end_time = datetime.utcnow()
        start_time = end_time - timedelta(minutes=args.duration)
        start = start_time.strftime("%Y-%m-%dT%H:%M:%SZ")
        end = end_time.strftime("%Y-%m-%dT%H:%M:%SZ")
    else:
        start = args.start
        end = args.end
    
    # Create Prometheus client
    client = PrometheusClient(args.prometheus_url)
    
    # Collect metrics
    print(f"Collecting metrics from {start} to {end} with label '{args.label}'...")
    metrics = collect_metrics(client, start, end, args.label)
    
    # Output results
    output = json.dumps(metrics, indent=2)
    
    if args.output:
        with open(args.output, "w") as f:
            f.write(output)
        print(f"Metrics saved to {args.output}")
    else:
        print(output)
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
