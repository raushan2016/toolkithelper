#!/bin/bash
set -euo pipefail

# Change to the directory where this script is located
cd "$(dirname "${BASH_SOURCE[0]}")"

if [ ! -f "cluster.conf" ]; then
    echo "Error: cluster.conf not found. Please ensure your configuration file is present."
    exit 1
fi
source cluster.conf

export KUEUE_NAME="a3-ultra"

# Number of nodes requested for the test (defaults to H200_NODE_COUNT if not specifically passed)
NUM_NODES=${1:-${H200_NODE_COUNT:-6}}
# Fallbacks for env variables if somehow empty
export NUM_NODES=$(echo "${NUM_NODES}" | grep -v '\$' || echo "6")
export NUM_GPUS=$((NUM_NODES * 8))

echo "Configuring Mixtral-8x7B Training for $NUM_NODES nodes ($NUM_GPUS GPUs total)."

# Extract mathematical Megatron constraint mappings dynamically
export GLOBAL_BATCH_SIZE=$((16 * NUM_NODES))

echo "Verifying GCS Prerequisites (HNS Enabled Regional Buckets)..."
for BUCKET in "$GCS_TRAINING_BUCKET" "$GCS_CHECKPOINT_BUCKET"; do
    if ! gcloud storage buckets describe "gs://${BUCKET}" --project="$PROJECT_ID" &>/dev/null; then
        echo "Creating bucket gs://${BUCKET} with HNS enabled in region ${REGION}..."
        gcloud storage buckets create "gs://${BUCKET}" \
            --project="$PROJECT_ID" \
            --location="$REGION" \
            --enable-hierarchical-namespace
    else
        echo "Bucket gs://${BUCKET} already exists."
    fi
done

echo "Ensuring dataset is present in training bucket..."
if ! gcloud storage ls "gs://${GCS_TRAINING_BUCKET}/training-data/" &>/dev/null; then
    echo "Initiating dataset transfer for Mixtral (this may take a few minutes)..."
    gcloud storage cp -r "gs://nemo-megatron-demo/training-data/" "gs://${GCS_TRAINING_BUCKET}/"
else
    echo "Dataset already exists in gs://${GCS_TRAINING_BUCKET}."
fi

export USER_PREFIX=$(echo "$USER" | grep -v '\$' || echo "testuser")
USER_SHORT=$(echo "$USER_PREFIX" | head -c 3)
export JOB_PREFIX="${USER_SHORT}-mx-$(tr -dc a-z0-9 </dev/urandom | head -c 4)"
export JOB_TIMESTAMP="$(date +%Y-%m-%d-%H-%M-%S)"
export JOB_UUID="$(uuidgen)"

SCRIPT_DIR="$(dirname "$(realpath "$0")")"

echo "Applying GCS FUSE Profile volumes from $SCRIPT_DIR/mixtral-volumes.yaml.tftpl"
# Ensure the dynamic PV/PVC volumes for the specific job prefix are created
envsubst '${JOB_PREFIX} ${GCS_TRAINING_BUCKET} ${GCS_CHECKPOINT_BUCKET}' < "$SCRIPT_DIR/mixtral-volumes.yaml.tftpl" | kubectl apply -f -

echo "Applying native rendered JobSet from $SCRIPT_DIR/mixtral-jobset.yaml"

# Safely inject variable bounds across the JobSet avoiding local state drift
envsubst '${JOB_PREFIX} ${KUEUE_NAME} ${NUM_NODES} ${NUM_GPUS} ${GLOBAL_BATCH_SIZE} ${JOB_TIMESTAMP} ${JOB_UUID} ${GCS_BUCKET}' < "$SCRIPT_DIR/mixtral-jobset.yaml" | kubectl apply -f -

echo "Job submitted successfully! Waiting for the lead pod to instantiate..."

# Find the main driver pod.
LEAD_POD=""
while [ -z "$LEAD_POD" ]; do
  LEAD_POD=$(kubectl get pods | grep "$JOB_PREFIX.*workload-0-0" | awk '{print $1}' || true)
  if [ -z "$LEAD_POD" ]; then
    sleep 2
  fi
done

echo "Found lead pod: $LEAD_POD. Waiting for it to become Ready..."
kubectl wait --for=condition=Ready pod/$LEAD_POD --timeout=1200s || { echo "Pod failed to become ready!"; exit 1; }

echo "Training initialized. Streaming Progressive Results..."
echo ""
echo "========================================================================"
echo "          Mixtral 8x7B (Sparse MoE) on ${NUM_GPUS}x H200 (a3-ultra)"
echo "========================================================================"
printf "%-8s | %-10s | %-12s | %-10s | %-10s | %-8s\n" "STEP" "TIME (s)" "TOK/S/CHIP" "AWK MFU(%)" "NEMO TFLOPS" "LOSS"
echo "--------------------------------------------------------------------------------"

# Parse logs live via awk
kubectl logs -f pod/$LEAD_POD | awk -v gpus="$NUM_GPUS" -v gbs="$GLOBAL_BATCH_SIZE" '
BEGIN {
    # =========================================================================================
    # Native TFLOPS & MFU (%) (Model Flop Utilization) Calculation
    # =========================================================================================
    # Hardware Peak Compute: 989 TFLOPs (theoretical max for BF16 Dense on H200s)
    # 
    # MFU (%) is calculated by directly dividing the framework native 
    # tflops_per_sec_per_gpu output by 989.
    # =========================================================================================

    seq = 4096
    peak_tflops = 989
}
/tflops_per_sec_per_gpu :/ {
    for (i=1; i<=NF; i++) {
        if ($i == "tflops_per_sec_per_gpu" && $(i+1) == ":") {
            cached_tflops = $(i+2)
        }
    }
}
/reduced_train_loss :/ {
    loss = 0; step = 0; time = 0; nemo_tflops = cached_tflops;
    
    # Parse keys from log line dynamically
    for (i=1; i<=NF; i++) {
        if ($i == "reduced_train_loss" && $(i+1) == ":") { loss = $(i+2) }
        else if ($i == "global_step" && $(i+1) == ":") { step = $(i+2) }
        else if ($i == "train_step_timing" && $(i+1) == "in" && $(i+2) == "s" && $(i+3) == ":") { time = $(i+4) }
    }

    if (time > 0) {
        tokens_per_step = gbs * seq
        sys_tok_s = tokens_per_step / time
        tok_s_chip = sys_tok_s / gpus

        mfu = 0
        if (nemo_tflops != "N/A" && nemo_tflops > 0) {
            mfu = (nemo_tflops / peak_tflops) * 100
        }

        printf "%-8d | %-10.3f | %-12.0f | %-10.2f | %-10s | %-8.3f\n", step, time, tok_s_chip, mfu, nemo_tflops, loss
        fflush(stdout)
    }
}
/Training completed/ {
    print "========================================================================"
    print "                    TRAINING COMPLETED SUCCESSFULLY                     "
    print "========================================================================"
    fflush(stdout)
}
'
