#!/usr/bin/env bash
set -euo pipefail

# Performance Comparison Automation Script
# Runs baseline and improved configurations, collects metrics, and generates comparison

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=========================================="
echo "Performance Comparison Automation"
echo "=========================================="
echo ""

# Configuration
export LOCUST_PROFILE="${LOCUST_PROFILE:-baseline}"
export LOCUST_CONCURRENCY="${LOCUST_CONCURRENCY:-4}"
export LOCUST_SPAWN_RATE="${LOCUST_SPAWN_RATE:-2}"
export LOCUST_DURATION="${LOCUST_DURATION:-60}"
export LOCUST_HOST="${LOCUST_HOST:-http://127.0.0.1:8080}"
export PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"

# Check if improvement config is provided
if [ -z "${IMPROVEMENT_CONFIG:-}" ]; then
    echo "⚠️  WARNING: No IMPROVEMENT_CONFIG specified"
    echo "   This script will run baseline configuration only."
    echo "   Set IMPROVEMENT_CONFIG to specify configuration changes for improved run."
    echo ""
    echo "   Example: IMPROVEMENT_CONFIG='gateway_tokens_per_min=20000' $0"
    echo ""
    read -p "Continue with baseline only? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted. Please specify IMPROVEMENT_CONFIG to run comparison."
        exit 1
    fi
    BASELINE_ONLY=true
else
    BASELINE_ONLY=false
    echo "Improvement configuration: $IMPROVEMENT_CONFIG"
fi

echo ""
echo "Configuration:"
echo "  Profile: $LOCUST_PROFILE"
echo "  Concurrency: $LOCUST_CONCURRENCY"
echo "  Spawn Rate: $LOCUST_SPAWN_RATE"
echo "  Duration: ${LOCUST_DURATION}s"
echo "  Host: $LOCUST_HOST"
echo "  Prometheus: $PROMETHEUS_URL"
echo ""

# Create results directory
RESULTS_DIR="$PROJECT_ROOT/results/performance"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Check dependencies
echo "Checking dependencies..."
if ! command -v locust &> /dev/null; then
    echo "✗ Locust not found. Install with: pip install locust"
    exit 1
fi

if ! command -v python3 &> /dev/null; then
    echo "✗ Python3 not found"
    exit 1
fi

echo "✓ Dependencies OK"
echo ""

# Check gateway accessibility
echo "Checking gateway health..."
if curl -sf "${LOCUST_HOST}/v1/models" > /dev/null 2>&1; then
    echo "✓ Gateway is accessible"
else
    echo "✗ Gateway is not accessible at $LOCUST_HOST"
    echo "Please ensure the gateway is running before starting performance comparison."
    exit 1
fi

# Check Prometheus accessibility
echo "Checking Prometheus health..."
if curl -sf "${PROMETHEUS_URL}/api/v1/status/config" > /dev/null 2>&1; then
    echo "✓ Prometheus is accessible"
else
    echo "✗ Prometheus is not accessible at $PROMETHEUS_URL"
    echo "Please ensure Prometheus is running for metrics collection."
    exit 1
fi

echo ""
echo "=========================================="
echo "Starting Performance Comparison"
echo "=========================================="
echo ""

# Function to run a single configuration
run_configuration() {
    local label=$1
    local config_env=$2
    
    echo "=========================================="
    echo "Running Configuration: $label"
    echo "=========================================="
    
    # Apply configuration if provided
    if [ -n "$config_env" ]; then
        echo "Applying configuration: $config_env"
        # This would need to be implemented based on how configuration is applied
        # For now, we'll just note it
        echo "   (Configuration application would happen here)"
    fi
    
    # Wait for system to stabilize after config change
    if [ -n "$config_env" ]; then
        echo "Waiting 10 seconds for system to stabilize..."
        sleep 10
    fi
    
    # Record start time
    START_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "Start time: $START_TIME"
    
    # Run load test
    echo "Starting load test..."
    cd "$PROJECT_ROOT"
    
    # Run Locust in headless mode
    locust -f app/locustfile_enhanced.py \
        --host "$LOCUST_HOST" \
        --users "$LOCUST_CONCURRENCY" \
        --spawn-rate "$LOCUST_SPAWN_RATE" \
        --run-time "${LOCUST_DURATION}s" \
        --headless \
        --html "$RESULTS_DIR/${label}_${TIMESTAMP}.html" \
        --json "$RESULTS_DIR/${label}_${TIMESTAMP}.json" \
        --exit-on-error
    
    # Allow a short buffer for metrics to be recorded
    sleep 5
    
    # Record end time
    END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "End time: $END_TIME"
    
    # Collect metrics
    echo "Collecting metrics..."
    python3 "$SCRIPT_DIR/collect_metrics.py" \
        --prometheus-url "$PROMETHEUS_URL" \
        --start "$START_TIME" \
        --end "$END_TIME" \
        --label "$label" \
        --output "$RESULTS_DIR/${label}_metrics_${TIMESTAMP}.json"
    
    echo "✓ $label configuration complete"
    echo "  Load test: $RESULTS_DIR/${label}_${TIMESTAMP}.html"
    echo "  Metrics: $RESULTS_DIR/${label}_metrics_${TIMESTAMP}.json"
    echo ""
    
    # Wait between configurations
    if [ "$label" = "baseline" ] && [ "$BASELINE_ONLY" = false ]; then
        echo "Waiting 30 seconds for system to stabilize before improved run..."
        sleep 30
    fi
}

# Run baseline configuration
run_configuration "baseline" ""

# Run improved configuration if specified
if [ "$BASELINE_ONLY" = false ]; then
    run_configuration "improved" "$IMPROVEMENT_CONFIG"
    
    # Generate comparison report
    echo "=========================================="
    echo "Generating Comparison Report"
    echo "=========================================="
    
    # Create a simple Python script for comparison
    cat > /tmp/compare_metrics.py << 'EOF'
import json
import sys
from datetime import datetime

baseline_file = sys.argv[1]
improved_file = sys.argv[2]
output_file = sys.argv[3]

try:
    with open(baseline_file, 'r') as f:
        baseline = json.load(f)
    with open(improved_file, 'r') as f:
        improved = json.load(f)
    
    comparison = {
        'comparison_timestamp': datetime.utcnow().isoformat(),
        'baseline': baseline_file,
        'improved': improved_file,
        'comparison': {}
    }
    
    baseline_metrics = baseline.get('metrics', {})
    improved_metrics = improved.get('metrics', {})
    
    for metric_name in baseline_metrics:
        baseline_value = baseline_metrics[metric_name]
        improved_value = improved_metrics.get(metric_name)
        
        if baseline_value is not None and improved_value is not None:
            change = improved_value - baseline_value
            percent_change = (change / baseline_value * 100) if baseline_value != 0 else 0
            
            comparison['comparison'][metric_name] = {
                'baseline': baseline_value,
                'improved': improved_value,
                'change': change,
                'percent_change': percent_change
            }
    
    with open(output_file, 'w') as f:
        json.dump(comparison, f, indent=2)
    
    print(f'✓ Comparison report saved to {output_file}')
    
    print('\nComparison Summary:')
    print('=' * 60)
    for metric, data in comparison['comparison'].items():
        baseline = data['baseline']
        improved = data['improved']
        change = data['change']
        percent = data['percent_change']
        
        direction = '↑' if change > 0 else '↓' if change < 0 else '='
        print(f'{metric:30s}: {baseline:8.2f} → {improved:8.2f} ({direction}{abs(percent):6.2f}%)')

except Exception as e:
    print(f'Error generating comparison: {e}', file=sys.stderr)
    sys.exit(1)
EOF
    
    python3 /tmp/compare_metrics.py \
        "$RESULTS_DIR/baseline_metrics_${TIMESTAMP}.json" \
        "$RESULTS_DIR/improved_metrics_${TIMESTAMP}.json" \
        "$RESULTS_DIR/comparison_${TIMESTAMP}.json"
    
    echo ""
    echo "=========================================="
    echo "Performance Comparison Complete"
    echo "=========================================="
    echo ""
    echo "Results saved to:"
    echo "  Baseline load test: $RESULTS_DIR/baseline_${TIMESTAMP}.html"
    echo "  Baseline metrics: $RESULTS_DIR/baseline_metrics_${TIMESTAMP}.json"
    echo "  Improved load test: $RESULTS_DIR/improved_${TIMESTAMP}.html"
    echo "  Improved metrics: $RESULTS_DIR/improved_metrics_${TIMESTAMP}.json"
    echo "  Comparison: $RESULTS_DIR/comparison_${TIMESTAMP}.json"
    echo ""
    echo "Next steps:"
    echo "  1. Review comparison JSON for detailed metrics"
    echo "  2. Use docs/PERFORMANCE_TEMPLATE.md to document findings"
    echo "  3. Analyze Grafana dashboards for visual patterns"
    echo "  4. Document root cause analysis of improvements"
else
    echo ""
    echo "=========================================="
    echo "Baseline Run Complete"
    echo "=========================================="
    echo ""
    echo "Results saved to:"
    echo "  Load test: $RESULTS_DIR/baseline_${TIMESTAMP}.html"
    echo "  Metrics: $RESULTS_DIR/baseline_metrics_${TIMESTAMP}.json"
    echo ""
    echo "To run a full comparison, set IMPROVEMENT_CONFIG and re-run this script."
fi
