#!/bin/bash
# ==============================================================================
# Run DeepEP Benchmark on Kubernetes
# ==============================================================================

export NODES=${1:-2}
export NAMESPACE=${2:-default}
export GPUS_PER_NODE=${3:-8}
export IMAGE=${4:-"us-central1-docker.pkg.dev/supercomputer-testing/raushankr/deepep:dev"}

echo "Deploying Configuration: ${NODES} Nodes, ${GPUS_PER_NODE} GPUs/Node in Namespace: '${NAMESPACE}'"

echo "Cleaning up any existing benchmark run..."
kubectl delete statefulset deepep-benchmark -n "${NAMESPACE}" --ignore-not-found=true

echo "Applying Kubernetes Manifest..."

# Use envsubst to parse the template with environment variables
envsubst '$NODES,$NAMESPACE,$GPUS_PER_NODE,$IMAGE' < deepep-benchmark.yaml | kubectl apply -f -

echo ""
echo "Deployment applied! Waiting for StatefulSet to rollout..."
kubectl rollout status statefulset deepep-benchmark -n "${NAMESPACE}"

echo "Benchmark is initializing. Waiting for completion to parse results..."

# Wait for the pod to be ready before trying to fetch logs
kubectl wait --for=condition=ready pod -l app=deepep -n "${NAMESPACE}" --timeout=300s > /dev/null

echo "Tailing logs from deepep-benchmark-0..."
# Stream logs in background so we can reliably kill it when finished
kubectl logs -f deepep-benchmark-0 -n "${NAMESPACE}" &
LOG_PID=$!

# Monitor for completion
while true; do
  if kubectl logs deepep-benchmark-0 -n "${NAMESPACE}" --tail=50 2>/dev/null | grep -q "Benchmark Finished"; then
    kill $LOG_PID 2>/dev/null || true
    break
  fi
  sleep 5
done
wait $LOG_PID 2>/dev/null || true

echo ""
echo "======================================================================"
echo "                       DEEP-EP BENCHMARK RESULTS                      "
echo "======================================================================"

# 1. Validate DMA-BUF
echo "[1] DMA-BUF VALIDATION:"
DMA_BUF_COUNT=$(kubectl logs deepep-benchmark-0 -n "${NAMESPACE}" | grep -c "ibv_reg_dmabuf_mr" || true)

if [ "$DMA_BUF_COUNT" -gt 0 ]; then
    echo "    ✅ SUCCESS: Detected $DMA_BUF_COUNT successful DMA-BUF memory registrations (ibv_reg_dmabuf_mr)."
    echo "       The GCP virtual network card firmware is natively accepting DMA-BUF descriptors."
else
    echo "    ❌ FAILED: No 'ibv_reg_dmabuf_mr' registrations found in the trace logs."
    echo "       (Ensure NVSHMEM_DEBUG=TRACE is enabled in the deepep-benchmark.yaml)"
fi

# 2. Extract Performance Numbers
echo ""
echo "[2] PERFORMANCE METRICS (From tuning phase):"
kubectl logs deepep-benchmark-0 -n "${NAMESPACE}" | grep "\[tuning\] Best" | while read -r line; do
    # Extract the key benchmark metrics to display cleanly
    if [[ "$line" == *"dispatch (FP8)"* ]]; then
        METRICS=$(echo "$line" | sed -nE 's/.*[:,] ([0-9.+* ]* us), ([0-9.]* GB\/s) \(RDMA\), ([0-9.]* GB\/s) \(NVL\)/\2 (RDMA) | \3 (NVL) | \1/p')
        echo "    🚀 FP8 Dispatch...: $METRICS"
    elif [[ "$line" == *"dispatch (BF16)"* ]]; then
        METRICS=$(echo "$line" | sed -nE 's/.*[:,] ([0-9.+* ]* us), ([0-9.]* GB\/s) \(RDMA\), ([0-9.]* GB\/s) \(NVL\)/\2 (RDMA) | \3 (NVL) | \1/p')
        echo "    🚀 BF16 Dispatch..: $METRICS"
    elif [[ "$line" == *"combine"* ]]; then
        METRICS=$(echo "$line" | sed -nE 's/.*[:,] ([0-9.+* ]* us), ([0-9.]* GB\/s) \(RDMA\), ([0-9.]* GB\/s) \(NVL\)/\2 (RDMA) | \3 (NVL) | \1/p')
        echo "    🚀 BF16 Combine...: $METRICS"
    fi
done

echo "======================================================================"
echo "    Full trace logs are still available via:"
echo "    $ kubectl logs deepep-benchmark-0 -n ${NAMESPACE}"
echo "======================================================================"
