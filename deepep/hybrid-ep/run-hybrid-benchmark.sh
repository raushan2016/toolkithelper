#!/bin/bash
# ==============================================================================
# Run Hybrid-EP Benchmark on Kubernetes
# ==============================================================================

export NODES=${1:-2}
export NAMESPACE=${2:-default}
export GPUS_PER_NODE=${3:-8}
export IMAGE=${4:-"us-central1-docker.pkg.dev/supercomputer-testing/raushankr/deepep-nixl:dev"}
export TEST_TYPE=${5:-"internode"}
export RUN_ID=$(date +%s)

echo "Deploying Configuration: ${NODES} Nodes, ${GPUS_PER_NODE} GPUs/Node, Run ID: ${RUN_ID} in Namespace: '${NAMESPACE}'"

echo "Cleaning up any existing benchmark run with label app=hybrid-ep..."
kubectl delete statefulset -l app=hybrid-ep -n "${NAMESPACE}" --ignore-not-found=true
kubectl delete service -l app=hybrid-ep -n "${NAMESPACE}" --ignore-not-found=true
kubectl delete deployment -l app=etcd -n "${NAMESPACE}" --ignore-not-found=true
kubectl delete service -l app=etcd -n "${NAMESPACE}" --ignore-not-found=true

echo "Waiting for pods to be fully deleted..."
kubectl wait --for=delete pod -l app=hybrid-ep -n "${NAMESPACE}" --timeout=300s || true
kubectl wait --for=delete pod -l app=etcd -n "${NAMESPACE}" --timeout=300s || true

echo "Applying Kubernetes Manifest..."

# Use envsubst to parse the template with environment variables
envsubst '$NODES,$NAMESPACE,$GPUS_PER_NODE,$IMAGE,$TEST_TYPE,$RUN_ID' < hybrid-ep-benchmark.yaml | kubectl apply -f -

echo ""
echo "Deployment applied! Waiting for StatefulSet to rollout..."
kubectl rollout status statefulset hybrid-ep-benchmark-${RUN_ID} -n "${NAMESPACE}"

echo "Benchmark is initializing. Waiting for completion to parse results..."

# Wait for the pod to be ready before trying to fetch logs
kubectl wait --for=condition=ready pod -l app=hybrid-ep -n "${NAMESPACE}" --timeout=300s > /dev/null

echo "Tailing logs from hybrid-ep-benchmark-${RUN_ID}-0..."
# Stream logs in background so we can reliably kill it when finished
kubectl logs -f hybrid-ep-benchmark-${RUN_ID}-0 -n "${NAMESPACE}" &
LOG_PID=$!

# Monitor for completion
while true; do
  if kubectl logs hybrid-ep-benchmark-${RUN_ID}-0 -n "${NAMESPACE}" --tail=50 2>/dev/null | grep -q "Benchmark Finished"; then
    kill $LOG_PID 2>/dev/null || true
    break
  fi
  sleep 5
done
wait $LOG_PID 2>/dev/null || true

echo ""
echo "======================================================================"
echo "                       HYBRID-EP BENCHMARK RESULTS                    "
echo "======================================================================"

# 1. Validate DMA-BUF (Assuming NVSHMEM is used and traced)
echo "[1] DMA-BUF VALIDATION:"
DMA_BUF_COUNT=$(kubectl logs hybrid-ep-benchmark-${RUN_ID}-0 -n "${NAMESPACE}" | grep -c "ibv_reg_dmabuf_mr" || true)

if [ "$DMA_BUF_COUNT" -gt 0 ]; then
    echo "    ✅ SUCCESS: Detected $DMA_BUF_COUNT successful DMA-BUF memory registrations ibv_reg_dmabuf_mr."
    echo "       The GCP virtual network card firmware is natively accepting DMA-BUF descriptors."
else
    echo "    ❌ FAILED: No 'ibv_reg_dmabuf_mr' registrations found in the trace logs."
    echo "       (Ensure NVSHMEM_DEBUG=TRACE is enabled in the hybrid-ep-benchmark.yaml)"
fi

# 2. Extract Performance Numbers (Assuming similar format)
echo ""
echo "[2] PERFORMANCE METRICS (From tuning phase):"
kubectl logs hybrid-ep-benchmark-${RUN_ID}-0 -n "${NAMESPACE}" | grep "\[tuning\] Best" | while read -r line; do
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
echo "    $ kubectl logs hybrid-ep-benchmark-${RUN_ID}-0 -n ${NAMESPACE}"
echo "======================================================================"
