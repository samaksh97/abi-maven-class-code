#!/usr/bin/env bash
set -euo pipefail

# Locust Baseline Load Test
# Short input (16 tokens), short output (32 tokens)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=========================================="
echo "Locust Baseline Load Test"
echo "=========================================="
echo ""

# Configuration
export LOCUST_PROFILE="baseline"
export LOCUST_CONCURRENCY="${LOCUST_CONCURRENCY:-4}"
export LOCUST_SPAWN_RATE="${LOCUST_SPAWN_RATE:-2}"
export LOCUST_DURATION="${LOCUST_DURATION:-60}"
export LOCUST_PROMPT_LENGTH="16"
export LOCUST_MAX_TOKENS="32"
export LOCUST_HOST="${LOCUST_HOST:-http://127.0.0.1:8080}"

echo "Configuration:"
echo "  Profile: $LOCUST_PROFILE"
echo "  Concurrency: $LOCUST_CONCURRENCY"
echo "  Spawn Rate: $LOCUST_SPAWN_RATE"
echo "  Duration: ${LOCUST_DURATION}s"
echo "  Prompt Length: $LOCUST_PROMPT_LENGTH tokens"
echo "  Max Tokens: $LOCUST_MAX_TOKENS"
echo "  Host: $LOCUST_HOST"
echo ""

# Create results directory
RESULTS_DIR="$PROJECT_ROOT/results/locust"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_FILE="$RESULTS_DIR/baseline_${TIMESTAMP}.json"

echo "Results will be saved to: $RESULTS_FILE"
echo ""

# Check if gateway is accessible
echo "Checking gateway health..."
if curl -sf "${LOCUST_HOST}/v1/models" > /dev/null 2>&1; then
    echo "✓ Gateway is accessible"
else
    echo "✗ Gateway is not accessible at $LOCUST_HOST"
    echo "Please ensure the gateway is running before starting the load test."
    exit 1
fi
echo ""

# Run Locust
echo "Starting Locust..."
cd "$PROJECT_ROOT"
locust -f app/locustfile_enhanced.py \
    --host "$LOCUST_HOST" \
    --users "$LOCUST_CONCURRENCY" \
    --spawn-rate "$LOCUST_SPAWN_RATE" \
    --run-time "${LOCUST_DURATION}s" \
    --headless \
    --html "$RESULTS_DIR/baseline_${TIMESTAMP}.html" \
    --json "$RESULTS_FILE" \
    --exit-on-error

echo ""
echo "=========================================="
echo "Baseline Test Complete"
echo "=========================================="
echo "Results saved to:"
echo "  HTML: $RESULTS_DIR/baseline_${TIMESTAMP}.html"
echo "  JSON: $RESULTS_FILE"
echo ""
echo "To view metrics during the test, check Grafana dashboards:"
echo "  - Class 9b / Overview"
echo "  - Class 9b / Success and failures"
echo "  - Class 9b / Performance Analysis"
