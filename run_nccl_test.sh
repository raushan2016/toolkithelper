#!/bin/bash
set -euo pipefail

# Change to the directory where this script is located
cd "$(dirname "${BASH_SOURCE[0]}")"

if [ ! -f "cluster.conf" ]; then
    echo "Error: cluster.conf not found. Please ensure your configuration file is present."
    exit 1
fi
source cluster.conf

# Default queue name created by the toolkit for a3-ultra/h200 configurations.
export KUEUE_NAME="a3-ultra"

# Number of nodes requested for the test (defaults to H200_NODE_COUNT if not specifically passed)
NUM_NODES=${1:-${H200_NODE_COUNT:-6}}
# Fallbacks for env variables if somehow empty
export NUM_NODES=$(echo "${NUM_NODES}" | grep -v '\$' || echo "6")
export NUM_GPUS=$((NUM_NODES * 8))

echo "Configuring NCCL test for $NUM_NODES nodes ($NUM_GPUS GPUs total) using native JobSet."

echo "Setting default project..."
gcloud config set project $PROJECT_ID

echo "Getting cluster credentials..."
# In GKE, region controls regional clusters or zone controls zonal. 
gcloud container clusters get-credentials $DEPLOYMENT_NAME --zone $ZONE --project $PROJECT_ID || \
gcloud container clusters get-credentials $DEPLOYMENT_NAME --region $REGION --project $PROJECT_ID

export USER_PREFIX=$(echo "$USER" | grep -v '\$' || echo "testuser")
# Shorten prefix to respect 64-character FQDN Kubernetes limit
USER_SHORT=$(echo "$USER_PREFIX" | head -c 3)
export JOB_PREFIX="${USER_SHORT}-n$(tr -dc a-z0-9 </dev/urandom | head -c 3)"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"

echo "Applying native rendered JobSet from $SCRIPT_DIR/nccl-jobset.yaml"
envsubst '${JOB_PREFIX} ${KUEUE_NAME} ${NUM_NODES}' < "$SCRIPT_DIR/nccl-jobset.yaml" | kubectl apply -f -

echo "JobSet submitted successfully! Waiting for the lead pod to instantiate..."

# Find the main driver pod (rank 0 of the JobSet)
LEAD_POD=""
while [ -z "$LEAD_POD" ]; do
  LEAD_POD=$(kubectl get pods | grep "$JOB_PREFIX-w-0-0" | awk '{print $1}' || true)
  if [ -z "$LEAD_POD" ]; then
    sleep 2
  fi
done

echo "Found lead pod: $LEAD_POD. Waiting for it to become Ready..."
kubectl wait --for=condition=Ready pod/$LEAD_POD --timeout=1200s || { echo "Pod failed to become ready!"; exit 1; }

echo "Waiting for NCCL tests to finish (this may take several minutes)..."
kubectl wait --for=condition=complete job.batch/${JOB_PREFIX}-w-0 --timeout=1200s || { echo "Job failed or timed out!"; exit 1; }

echo "Tests completed! Fetching and parsing results..."
LOG_FILE="/tmp/nccl_test_output.txt"
# Extract logs from the lead pod
kubectl logs pod/$LEAD_POD > $LOG_FILE

echo ""
echo "================================================================================"
echo "                 NCCL BUS BANDWIDTH (GB/s) ACROSS $NUM_GPUS H200 GPUs                  "
echo "================================================================================"
echo "MESSAGE SIZE   | SPEED (GB/s)| BANDWIDTH GRAPH (█ = 10 GB/s)"
echo "--------------------------------------------------------------------------------"

# Use awk to parse the NCCL log table and print an ASCII bar chart for busbw
awk '
BEGIN { avg_bbw = "0.00" }
/^[ \t]*[0-9]+/ {
    if (NF >= 12 && $3 == "float" && $2 != "count") {
        size = $1
        busbw = $8
        
        # Parse sizes smoothly for display
        if (size >= 1073741824) {
            display_size = sprintf("%.1f GB", size/1073741824)
        } else if (size >= 1048576) {
            display_size = sprintf("%.1f MB", size/1048576)
        } else if (size >= 1024) {
            display_size = sprintf("%.1f KB", size/1024)
        } else {
            display_size = sprintf("%d B", size)
        }

        # Scale for the ascii bar: 1 block = ~10 GB/s
        bars = int(busbw / 10)
        bar_str = ""
        for (i=0; i<bars; i++) bar_str = bar_str "█"
        
        printf "%14s | %6.2f GB/s | \033[92m%s\033[0m\n", display_size, busbw, bar_str
    }
}
/^# Avg bus bandwidth/ {
    # In format "# Avg bus bandwidth    : 112.509", the value is the 6th field
    avg_bbw = $6
}
END {
    print "================================================================================"
    printf " \033[1;96m>> AVERAGE BUS BANDWIDTH: %s GB/s <<\033[0m\n", avg_bbw
    print "================================================================================"
}
' $LOG_FILE

echo "Done! Full log saved to $LOG_FILE"
