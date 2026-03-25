#!/bin/bash
set -euo pipefail

# This script builds and provisions the GKE cluster using the Google Cluster Toolkit.
# It reads customer variables from cluster.conf and injects them into the deployment blueprint.

# Ensure we are in the external directory
cd "$(dirname "$0")"

# Ensure cluster.conf exists
if [ ! -f "cluster.conf" ]; then
    echo "Error: cluster.conf not found. Please create one based on the provided template."
    exit 1
fi

# Load variables
source cluster.conf
export PROJECT_ID
export REGION
export ZONE
export DEPLOYMENT_NAME
export TF_STATE_BUCKET
export RESERVATION_NAME
export AUTHORIZED_CIDR
export H200_NODE_COUNT

# Ensure gcluster CLI is in PATH
if ! command -v gcluster &> /dev/null; then
    echo "gcluster could not be found. Automatically downloading and installing Cluster Toolkit (v1.83.0)..."
    TAG="v1.83.0"
    TMP_DIR=$(mktemp -d)
    echo "Downloading from GitHub Releases..."
    curl -L -s "https://github.com/GoogleCloudPlatform/cluster-toolkit/releases/download/${TAG}/gcluster_bundle_linux.zip" -o "${TMP_DIR}/gcluster.zip"
    
    echo "Extracting bundle..."
    unzip -q "${TMP_DIR}/gcluster.zip" -d "${TMP_DIR}/gcluster-bundle"
    
    # Ensure local bin directory exists
    mkdir -p "$HOME/.local/bin"
    mv "${TMP_DIR}/gcluster-bundle/gcluster" "$HOME/.local/bin/"
    chmod +x "$HOME/.local/bin/gcluster"
    
    rm -rf "${TMP_DIR}"
    
    # Update PATH for the current script execution
    export PATH="$HOME/.local/bin:$PATH"
    
    if ! command -v gcluster &> /dev/null; then
        echo "Error: Installation completed but gcluster is still not in your PATH."
        exit 1
    fi
    echo "Successfully installed gcluster."
fi

# Use envsubst to replace variables in the template and generate the final yaml
TEMPLATE_FILE="gke-h200.yaml.template"
BLUEPRINT_FILE="gke-h200.yaml"

if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "Error: Blueprint template $TEMPLATE_FILE not found."
    exit 1
fi

echo "Generating $BLUEPRINT_FILE from template..."
envsubst < "$TEMPLATE_FILE" > "$BLUEPRINT_FILE"

echo "Enabling required GCP APIs in project ${PROJECT_ID}..."
gcloud services enable \
    compute.googleapis.com \
    container.googleapis.com \
    cloudresourcemanager.googleapis.com \
    iam.googleapis.com \
    iamcredentials.googleapis.com \
    serviceusage.googleapis.com \
    servicenetworking.googleapis.com \
    networkmanagement.googleapis.com \
    storage.googleapis.com \
    storage-component.googleapis.com \
    --project=$PROJECT_ID

echo "Checking if Terraform state bucket exists: gs://$TF_STATE_BUCKET"
if ! gcloud storage buckets describe gs://$TF_STATE_BUCKET --project=$PROJECT_ID &>/dev/null; then
    echo "Bucket does not exist. Creating gs://$TF_STATE_BUCKET for Terraform remote state..."
    gcloud storage buckets create gs://$TF_STATE_BUCKET --project=$PROJECT_ID --location=$REGION --uniform-bucket-level-access
    gcloud storage buckets update gs://$TF_STATE_BUCKET --versioning
else
    echo "Bucket gs://$TF_STATE_BUCKET already exists, skipping creation."
fi

echo "Deploying the infrastructure using gcluster deploy..."
gcluster deploy "$BLUEPRINT_FILE" --auto-approve -w

echo "Deployment complete! You can retrieve kubeconfig with:"
echo "gcloud container clusters get-credentials ${DEPLOYMENT_NAME} --zone ${ZONE} --project ${PROJECT_ID}"
