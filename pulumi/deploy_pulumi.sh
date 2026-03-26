#!/bin/bash
# Copyright 2026 "Google LLC"
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eu
# Configure headless local state so users aren't prompted for cloud SaaS logins
export PULUMI_CONFIG_PASSPHRASE=""

cd "$(dirname "$0")"

# Source the main repository cluster configuration depending on where it's located
if [ -f "./cluster.conf" ]; then
    source ./cluster.conf
else
    echo "ERROR: cluster.conf not found!"
    exit 1
fi

echo "==========================================================="
echo "   Initialize Pulumi A3 Ultra GKE Cluster Recipe          "
echo "==========================================================="

WORKSPACE_DIR=".pulumi_${DEPLOYMENT_NAME}"
echo "Creating isolated Pulumi execution environment in $WORKSPACE_DIR..."
mkdir -p "$WORKSPACE_DIR"

if [ ! -f "$WORKSPACE_DIR/Pulumi.yaml" ]; then
    echo "Bootstrapping new Pulumi gcp-python project..."
    cd "$WORKSPACE_DIR"
    
    pulumi login --local
    
    pulumi new gcp-python -y \
        --name "$DEPLOYMENT_NAME" \
        --description "A3 Ultra GKE Cluster Deployment for Mixtral 8x7B" \
        --generate-only
    
    echo "pulumi-kubernetes" >> requirements.txt
    
    # Manually provision the isolated execution environment to bypass proxy errors
    python3 -m venv venv
    source venv/bin/activate
    pip install -r requirements.txt
    cd ..
fi

# Always copy the latest template recipe and required templated manifests into the execution environment
cp __main__.py *.tftpl "$WORKSPACE_DIR/"

# Execute Pulumi inside the workspace container
cd "$WORKSPACE_DIR"
source venv/bin/activate

# Force Pulumi GCP provider to bypass the rate-limited Cloud Shell metadata service (which causes EOF panics)
# by directly seeding its environment with a short-lived OAuth token generated from the pre-authenticated CLI.
export GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth application-default print-access-token)"

# Ensure a default stack is initialized for the local backend to prevent interactive prompts
pulumi stack select dev 2>/dev/null || pulumi stack init dev

echo "Setting Pulumi Configuration bindings..."
pulumi config set prefix "$DEPLOYMENT_NAME"
pulumi config set project_id "$PROJECT_ID"
pulumi config set region "$REGION"
pulumi config set zone "$ZONE"
pulumi config set node_count "$H200_NODE_COUNT"
pulumi config set reservation_name "$RESERVATION_NAME"
pulumi config set gcp:project "$PROJECT_ID"
pulumi config set gcp:region "$REGION"
pulumi config set gcp:zone "$ZONE"

echo "Starting Pulumi IaC Deployment..."
pulumi up --yes

echo "Fetching GKE Credentials natively to ensure valid API tokens..."
CLUSTER_NAME=$(pulumi stack output cluster_name)
gcloud container clusters get-credentials "$CLUSTER_NAME" --region "$REGION" --project "$PROJECT_ID"

echo "==========================================================="
echo "Infrastructure Deployment successfully provisioned!"
echo "Triggering Kubernetes Subsystem Setup..."
echo "==========================================================="
cd ..
./install_k8s_components.sh
echo ""
echo "Credentials saved natively to your ~/.kube/config context!"
echo "You can validate the cluster's multi-NIC RDMA network instantly by executing: ./run_nccl_test.sh"
echo ""
echo "NOTE: To cleanly teardown the cluster, simply run:"
echo "cd $WORKSPACE_DIR && pulumi destroy"
echo "==========================================================="
