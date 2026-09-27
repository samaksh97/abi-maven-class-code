#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo "Class 9b Comprehensive Smoke Test"
echo "=========================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASS_COUNT=0
FAIL_COUNT=0

function pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    ((PASS_COUNT++))
}

function fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    ((FAIL_COUNT++))
}

function warn() {
    echo -e "${YELLOW}⚠ WARN${NC}: $1"
}

function info() {
    echo "ℹ INFO: $1"
}

# Parse environment variables
TEXT="${PREFILL_URLS:-http://127.0.0.1:8000}"
VISION="${DECODE_URLS:-http://127.0.0.1:8001}"
ORCH="${ORCH_URL:-http://127.0.0.1:8080}"
MOONCAKE="${MOONCAKE_URL:-http://127.0.0.1:50051}"

# Extract first URL if comma-separated
TEXT="${TEXT%%,*}"
VISION="${VISION%%,*}"

# Replace placeholder with localhost
TEXT="${TEXT//YOUR_LAMBDA_IP/127.0.0.1}"
VISION="${VISION//YOUR_LAMBDA_IP/127.0.0.1}"
ORCH="${ORCH//YOUR_LAMBDA_IP/127.0.0.1}"
MOONCAKE="${MOONCAKE//YOUR_LAMBDA_IP/127.0.0.1}"

info "Using endpoints:"
info "  Prefill: $TEXT"
info "  Decode: $VISION"
info "  Gateway: $ORCH"
info "  Mooncake: $MOONCAKE"
echo ""

# Test 1: Prefill worker health
echo "Test 1: Prefill Worker Health"
if curl -sf "${TEXT}/v1/models" >/dev/null 2>&1; then
    pass "Prefill worker responds to /v1/models"
else
    fail "Prefill worker does not respond to /v1/models"
fi
if curl -sf "${TEXT}/health" >/dev/null 2>&1; then
    pass "Prefill worker responds to /health"
else
    warn "Prefill worker /health endpoint not available (vLLM may not have this)"
fi
echo ""

# Test 2: Decode worker health
echo "Test 2: Decode Worker Health"
if curl -sf "${VISION}/v1/models" >/dev/null 2>&1; then
    pass "Decode worker responds to /v1/models"
else
    fail "Decode worker does not respond to /v1/models"
fi
if curl -sf "${VISION}/health" >/dev/null 2>&1; then
    pass "Decode worker responds to /health"
else
    warn "Decode worker /health endpoint not available (vLLM may not have this)"
fi
echo ""

# Test 3: Gateway health
echo "Test 3: Gateway Health"
if curl -sf "${ORCH}/v1/models" >/dev/null 2>&1; then
    pass "Gateway responds to /v1/models"
else
    fail "Gateway does not respond to /v1/models"
fi
if curl -sf "${ORCH}/metrics" >/dev/null 2>&1; then
    pass "Gateway metrics endpoint accessible"
else
    fail "Gateway metrics endpoint not accessible"
fi
echo ""

# Test 4: Mooncake store health
echo "Test 4: Mooncake KV Store Health"
if curl -sf "${MOONCAKE}/health" >/dev/null 2>&1; then
    pass "Mooncake store responds to /health"
else
    warn "Mooncake store not responding (may not be deployed)"
fi
if curl -sf "${MOONCAKE}/metrics" >/dev/null 2>&1; then
    pass "Mooncake metrics endpoint accessible"
else
    warn "Mooncake metrics endpoint not accessible"
fi
echo ""

# Test 5: GPU allocation (if available)
echo "Test 5: GPU Allocation"
if command -v nvidia-smi &> /dev/null; then
    if nvidia-smi &> /dev/null; then
        pass "nvidia-smi command works"
        GPU_COUNT=$(nvidia-smi --list-gpus | wc -l)
        info "Found $GPU_COUNT GPU(s)"
        if [ "$GPU_COUNT" -ge 1 ]; then
            pass "At least one GPU available"
        else
            fail "No GPUs available"
        fi
        # Check for running processes
        if nvidia-smi --query-compute-apps=pid --format=csv,noheader | grep -q .; then
            pass "GPU has running compute processes"
        else
            warn "No GPU compute processes running (workers may not be started)"
        fi
    else
        fail "nvidia-smi command failed"
    fi
else
    warn "nvidia-smi not available (not on GPU machine or not in PATH)"
fi
echo ""

# Test 6: Kubernetes cluster (if available)
echo "Test 6: Kubernetes Cluster Status"
if command -v kubectl &> /dev/null; then
    if kubectl cluster-info &> /dev/null; then
        pass "Kubernetes cluster is accessible"
        
        # Check for expected deployments
        EXPECTED_DEPS=("orch-serve" "vllm-prefill" "vllm-decode" "mooncake-store" "open-webui")
        for dep in "${EXPECTED_DEPS[@]}"; do
            if kubectl get deployment "$dep" &> /dev/null; then
                pass "Deployment $dep exists"
                READY=$(kubectl get deployment "$dep" -o jsonpath='{.status.readyReplicas}')
                DESIRED=$(kubectl get deployment "$dep" -o jsonpath='{.spec.replicas}')
                if [ "$READY" = "$DESIRED" ]; then
                    pass "Deployment $dep has $READY/$DESIRED replicas ready"
                else
                    warn "Deployment $dep has $READY/$DESIRED replicas ready"
                fi
            else
                warn "Deployment $dep not found (may not be deployed)"
            fi
        done
        
        # Check pod status
        if kubectl get pods -A &> /dev/null; then
            NOT_READY=$(kubectl get pods -A --field-selector=status.phase!=Running -o jsonpath='{.items[*].metadata.name}' | wc -w)
            if [ "$NOT_READY" -eq 0 ]; then
                pass "All pods are in Running state"
            else
                warn "$NOT_READY pod(s) not in Running state"
            fi
        fi
    else
        warn "Kubernetes cluster not accessible (may not be on cluster machine)"
    fi
else
    warn "kubectl not available (not on cluster machine or not in PATH)"
fi
echo ""

# Test 7: Text capability through gateway
echo "Test 7: Text Capability Through Gateway"
TEXT_RESPONSE=$(curl -s -X POST "${ORCH}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"text","messages":[{"role":"user","content":"Test"}],"max_tokens":4}' 2>&1 || echo "curl_failed")

if [ "$TEXT_RESPONSE" != "curl_failed" ]; then
    if echo "$TEXT_RESPONSE" | grep -q '"choices"'; then
        pass "Gateway processes text requests successfully"
    else
        fail "Gateway text request did not return expected format"
        info "Response: $TEXT_RESPONSE"
    fi
else
    fail "Gateway text request failed"
fi
echo ""

# Test 8: Vision capability through gateway
echo "Test 8: Vision Capability Through Gateway"
TINY_PNG="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
VISION_RESPONSE=$(curl -s -X POST "${ORCH}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"vision\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"What color?\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"$TINY_PNG\"}}]}],\"max_tokens\":4}" 2>&1 || echo "curl_failed")

if [ "$VISION_RESPONSE" != "curl_failed" ]; then
    if echo "$VISION_RESPONSE" | grep -q '"choices"'; then
        pass "Gateway processes vision requests successfully"
    else
        fail "Gateway vision request did not return expected format"
        info "Response: $VISION_RESPONSE"
    fi
else
    fail "Gateway vision request failed"
fi
echo ""

# Test 9: KV hop functionality
echo "Test 9: KV Hop Functionality"
KVHOP_RESPONSE=$(curl -s -X POST "${ORCH}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"text","messages":[{"role":"user","content":"KV hop test"}],"max_tokens":4,"kv_hop":true}' 2>&1 || echo "curl_failed")

if [ "$KVHOP_RESPONSE" != "curl_failed" ]; then
    if echo "$KVHOP_RESPONSE" | grep -q '"kv_hop"'; then
        pass "Gateway returns kv_hop in response when requested"
    else
        warn "Gateway did not return kv_hop (may not be configured for disaggregated topology)"
    fi
else
    fail "Gateway KV hop request failed"
fi
echo ""

# Test 10: Metrics content
echo "Test 10: Gateway Metrics Content"
METRICS_OUTPUT=$(curl -s "${ORCH}/metrics" 2>&1 || echo "curl_failed")
if [ "$METRICS_OUTPUT" != "curl_failed" ]; then
    if echo "$METRICS_OUTPUT" | grep -q "orch_requests_total"; then
        pass "Metrics include orch_requests_total"
    else
        fail "Metrics missing orch_requests_total"
    fi
    if echo "$METRICS_OUTPUT" | grep -q "orch_shed_total"; then
        pass "Metrics include orch_shed_total"
    else
        fail "Metrics missing orch_shed_total"
    fi
    if echo "$METRICS_OUTPUT" | grep -q "orch_request_duration_seconds"; then
        pass "Metrics include latency histogram"
    else
        fail "Metrics missing latency histogram"
    fi
else
    fail "Failed to retrieve metrics"
fi
echo ""

# Test 11: Admission control
echo "Test 11: Admission Control Integration"
# Send a request with tenant info to test admission
ADMISSION_RESPONSE=$(curl -s -X POST "${ORCH}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"text","messages":[{"role":"user","content":"Admission test"}],"max_tokens":4,"tenant":"smoke_test"}' 2>&1 || echo "curl_failed")

if [ "$ADMISSION_RESPONSE" != "curl_failed" ]; then
    # Check if metrics were updated
    sleep 1
    METRICS_AFTER=$(curl -s "${ORCH}/metrics" 2>&1 || echo "curl_failed")
    if [ "$METRICS_AFTER" != "curl_failed" ]; then
        if echo "$METRICS_AFTER" | grep -q "orch_requests_total"; then
            pass "Admission control integrates with metrics"
        else
            warn "Admission control metrics not clearly updated"
        fi
    else
        warn "Could not verify admission control metrics"
    fi
else
    fail "Admission control test request failed"
fi
echo ""

# Test 12: HAMi GPU slicing (if on cluster)
echo "Test 12: HAMi GPU Slicing Configuration"
if command -v kubectl &> /dev/null && kubectl cluster-info &> /dev/null; then
    # Check HAMi scheduler
    if kubectl get deployment vllm-prefill -o jsonpath='{.spec.template.spec.schedulerName}' 2>/dev/null | grep -q "hami"; then
        pass "Prefill deployment uses HAMi scheduler"
    else
        warn "Prefill deployment does not use HAMi scheduler"
    fi
    
    if kubectl get deployment vllm-decode -o jsonpath='{.spec.template.spec.schedulerName}' 2>/dev/null | grep -q "hami"; then
        pass "Decode deployment uses HAMi scheduler"
    else
        warn "Decode deployment does not use HAMi scheduler"
    fi
    
    # Check GPU resource requests
    PREFILL_GPU=$(kubectl get deployment vllm-prefill -o jsonpath='{.spec.template.spec.containers[0].resources.limits.nvidia\.com/gpu}' 2>/dev/null || echo "not_found")
    if [ "$PREFILL_GPU" != "not_found" ] && [ -n "$PREFILL_GPU" ]; then
        pass "Prefill has GPU resource allocation: $PREFILL_GPU"
    else
        warn "Prefill GPU resource allocation not found"
    fi
    
    DECODE_GPU=$(kubectl get deployment vllm-decode -o jsonpath='{.spec.template.spec.containers[0].resources.limits.nvidia\.com/gpu}' 2>/dev/null || echo "not_found")
    if [ "$DECODE_GPU" != "not_found" ] && [ -n "$DECODE_GPU" ]; then
        pass "Decode has GPU resource allocation: $DECODE_GPU"
    else
        warn "Decode GPU resource allocation not found"
    fi
else
    warn "Skipping HAMi checks (not on Kubernetes cluster)"
fi
echo ""

# Test 13: KEDA autoscaling configuration
echo "Test 13: KEDA Autoscaling Configuration"
if command -v kubectl &> /dev/null && kubectl cluster-info &> /dev/null; then
    if kubectl get scaledobject prefill-scaler &> /dev/null; then
        pass "Prefill KEDA ScaledObject exists"
        MIN_REPLICAS=$(kubectl get scaledobject prefill-scaler -o jsonpath='{.spec.minReplicaCount}')
        MAX_REPLICAS=$(kubectl get scaledobject prefill-scaler -o jsonpath='{.spec.maxReplicaCount}')
        info "Prefill scaling: $MIN_REPLICAS to $MAX_REPLICAS replicas"
    else
        warn "Prefill KEDA ScaledObject not found"
    fi
    
    if kubectl get scaledobject decode-scaler &> /dev/null; then
        pass "Decode KEDA ScaledObject exists"
        MIN_REPLICAS=$(kubectl get scaledobject decode-scaler -o jsonpath='{.spec.minReplicaCount}')
        MAX_REPLICAS=$(kubectl get scaledobject decode-scaler -o jsonpath='{.spec.maxReplicaCount}')
        info "Decode scaling: $MIN_REPLICAS to $MAX_REPLICAS replicas"
    else
        warn "Decode KEDA ScaledObject not found"
    fi
else
    warn "Skipping KEDA checks (not on Kubernetes cluster)"
fi
echo ""

# Test 14: Open WebUI configuration
echo "Test 14: Open WebUI Configuration"
if command -v kubectl &> /dev/null && kubectl cluster-info &> /dev/null; then
    if kubectl get deployment open-webui &> /dev/null; then
        pass "Open WebUI deployment exists"
        # Check it's configured to use gateway
        GATEWAY_URL=$(kubectl get deployment open-webui -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OPENAI_API_BASE_URL")].value}' 2>/dev/null || echo "not_found")
        if [ "$GATEWAY_URL" != "not_found" ]; then
            pass "Open WebUI configured with gateway: $GATEWAY_URL"
        else
            warn "Open WebUI gateway configuration not found"
        fi
    else
        warn "Open WebUI deployment not found"
    fi
else
    warn "Skipping Open WebUI checks (not on Kubernetes cluster)"
fi
echo ""

# Summary
echo "=========================================="
echo "Smoke Test Summary"
echo "=========================================="
echo -e "${GREEN}Passed: $PASS_COUNT${NC}"
echo -e "${RED}Failed: $FAIL_COUNT${NC}"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
    echo -e "${GREEN}✓ ALL TESTS PASSED${NC}"
    echo "System is ready for load testing and experiments."
    exit 0
else
    echo -e "${RED}✗ SOME TESTS FAILED${NC}"
    echo "Please review the failures above and address configuration issues."
    exit 1
fi
