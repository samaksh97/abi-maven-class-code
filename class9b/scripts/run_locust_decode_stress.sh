#!/usr/bin/env bash
set -euo pipefail

# Locust Decode Stress Load Test
# Short input (16 tokens), long output (512 tokens)
# Stresses the decode phase and token generation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=========================================="
echo "Locust Decode Stress Load Test"
echo "=========================================="
echo ""

# Configuration
export LOCUST_PROFILE="decode_stress"
export LOCUST_CONCURRENCY="${LOCUST_CONCURRENCY:-4}"
export LOCUST_SPAWN_RATE="${LOCUST_SPAWN_RATE:-2}"
export LOCUST_DURATION="${LOCUST_DURATION:-60}"
export LOCUST_PROMPT_LENGTH="16"
export LOCUST_MAX_TOKENS="512"
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
echo "⚠️  WARNING: This test uses long outputs that may saturate decode workers."
echo "   Monitor decode queue depth and token generation rate during the test."
echo ""

# Create results directory
RESULTS_DIR="$PROJECT_ROOT/results/locust"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_FILE="$RESULTS_DIR/decode_stress_${TIMESTAMP}.json"

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
    --html "$RESULTS_DIR/decode_stress_${TIMESTAMP}.html" \
    --json "$RESULTS_FILE" \
    --exit-on-error

echo ""
echo "=========================================="
echo "Decode Stress Test Complete"
echo "=========================================="
echo "Results saved to:"
echo "  HTML: $RESULTS_DIR/decode_stress_${TIMESTAMP}.html"
echo "  JSON: $RESULTS_FILE"
echo ""
echo "Key metrics to check in Grafana:"
echo "  - Class 9b / Overview: Decode queue depth, tokens in flight"
echo "  - Class 9b / Router: Decode worker saturation"
echo "  - Class 9b / Performance Analysis: Inter-token latency, output tokens/sec"
echo "  - Class 9b / vLLM: Generation tokens/sec, running requests"
