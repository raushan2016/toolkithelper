#!/bin/bash
# install_k8s_components.sh
# Handles Kubernetes component installation independently of Pulumi IaC.

# Load parameters
source cluster.conf

# Kubectl natively uses the ~/.kube/config context configured by the deployment script.

echo "==========================================================="
echo "   Installing Kubernetes Subsystems                        "
echo "==========================================================="

echo "-> Installing JobSet Operator (v0.11.1)..."
kubectl apply --server-side -f https://github.com/kubernetes-sigs/jobset/releases/download/v0.11.1/manifests.yaml

echo "-> Installing Kueue Operator (v0.16.4)..."
kubectl apply --server-side -f https://github.com/kubernetes-sigs/kueue/releases/download/v0.16.4/manifests.yaml

echo "-> Awaiting Kubernetes API CRD Establishment..."
kubectl wait --for=condition=established --timeout=60s crd/clusterqueues.kueue.x-k8s.io
kubectl wait --for=condition=established --timeout=60s crd/resourceflavors.kueue.x-k8s.io
kubectl wait --for=condition=established --timeout=60s crd/topologies.kueue.x-k8s.io

echo "-> Awaiting Kueue Controller Webhook Readiness..."
kubectl -n kueue-system wait --for=condition=available --timeout=180s deployment/kueue-controller-manager

echo "-> Applying Kueue Local Cluster Resource Flavors..."
kubectl apply -f .pulumi_${DEPLOYMENT_NAME}/kueue-configuration.yaml

echo ""
echo "==========================================================="
echo "   Kubernetes Architecture Validation Complete!            "
echo "==========================================================="
