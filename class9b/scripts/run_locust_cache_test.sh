#!/usr/bin/env bash
set -euo pipefail

# Locust Cache Effectiveness Test
# Compares cache hit vs cache miss performance
# Runs two tests: cache_hit profile and cache_miss profile

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=========================================="
echo "Locust Cache Effectiveness Test"
echo "=========================================="
echo ""

# Configuration
export LOCUST_CONCURRENCY="${LOCUST_CONCURRENCY:-4}"
export LOCUST_SPAWN_RATE="${LOCUST_SPAWN_RATE:-2}"
export LOCUST_DURATION="${LOCUST_DURATION:-60}"
export LOCUST_MAX_TOKENS="64"
export LOCUST_HOST="${LOCUST_HOST:-http://127.0.0.1:8080}"

echo "Configuration:"
echo "  Concurrency: $LOCUST_CONCURRENCY"
echo "  Spawn Rate: $LOCUST_SPAWN_RATE"
echo "  Duration: ${LOCUST_DURATION}s per test"
echo "  Max Tokens: $LOCUST_MAX_TOKENS"
echo "  Host: $LOCUST_HOST"
echo ""
echo "This test will run two profiles sequentially:"
echo "  1. Cache Hit - Repeated prefix prompts"
echo "  2. Cache Miss - Unique random prompts"
echo ""

# Create results directory
RESULTS_DIR="$PROJECT_ROOT/results/locust"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

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

# Function to run a single profile
run_profile() {
    local profile=$1
    local prompt_length=$2
    
    echo "=========================================="
    echo "Running Profile: $profile"
    echo "=========================================="
    
    export LOCUST_PROFILE="$profile"
    export LOCUST_PROMPT_LENGTH="$prompt_length"
    
    RESULTS_FILE="$RESULTS_DIR/cache_${profile}_${TIMESTAMP}.json"
    
    cd "$PROJECT_ROOT"
    locust -f app/locustfile_enhanced.py \
        --host "$LOCUST_HOST" \
        --users "$LOCUST_CONCURRENCY" \
        --spawn-rate "$LOCUST_SPAWN_RATE" \
        --run-time "${LOCUST_DURATION}s" \
        --headless \
        --html "$RESULTS_DIR/cache_${profile}_${TIMESTAMP}.html" \
        --json "$RESULTS_FILE" \
        --exit-on-error
    
    echo ""
    echo "✓ $profile test complete"
    echo "  Results: $RESULTS_FILE"
    echo ""
    
    # Wait between tests to let system stabilize
    if [ "$profile" = "cache_hit" ]; then
        echo "Waiting 10 seconds for system to stabilize before cache_miss test..."
        sleep 10
    fi
}

# Run cache hit test
run_profile "cache_hit" "256"

# Run cache miss test
run_profile "cache_miss" "64"

echo "=========================================="
echo "Cache Effectiveness Test Complete"
echo "=========================================="
echo ""
echo "Results saved to:"
echo "  Cache Hit: $RESULTS_DIR/cache_cache_hit_${TIMESTAMP}.html"
echo "  Cache Miss: $RESULTS_DIR/cache_cache_miss_${TIMESTAMP}.html"
echo ""
echo "Compare the results to evaluate cache effectiveness:"
echo "  - Class 9b / Router: Cache hit rate, sticky routing"
echo "  - Class 9b / Overview: KV free ratio, KV transfers"
echo "  - Class 9b / Performance Analysis: TTFT, latency"
echo ""
echo "Expected: Cache hit should show lower TTFT and higher throughput"
echo "         compared to cache miss due to KV cache reuse."
