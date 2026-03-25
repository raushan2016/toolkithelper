# GKE A3 Ultra Cluster - Pulumi Recipe

This directory provides a fully parameterized, production-ready recipe for provisioning high-performance AI supercomputers (A3 Ultra H200 nodes) on Google Kubernetes Engine (GKE) using **Pulumi**.

It transforms static configurations into a unified Infrastructure-as-Code pipeline, drastically simplifying the setup of complex topologies like multi-NIC RDMA, Kueue/JobSet orchestration, and Workload Identity.

## Core Capabilities
- **A3 Ultra & RDMA**: Inherently provisions A3 Ultra compute pools, constructs GPUDirect-TCPXO networks (8x NICs), and injects the NCCL network installers.
- **Intelligent Workload Orchestration**: Autonomously bootstraps `Kueue` (v0.10.1) and `JobSet` (v0.7.2) for distributed PyTorch/Jax workloads.
- **Advanced AI Storage**: Maps GCS FUSE CSI drivers, Local NVMe SSD capacities, and GCFS (Image Streaming) uniformly across nodes to guarantee rapid model weights loading.

## Prerequisites
1. **Pulumi CLI**: Install Pulumi via the official script and add it to your local path:
   ```bash
   curl -fsSL https://get.pulumi.com | sh
   export PATH=$PATH:~/.pulumi/bin
   ```
2. **Google Cloud SDK**: [Install gcloud](https://cloud.google.com/sdk/docs/install) and authenticate with sufficient IAM privileges.
3. **Python 3.9+**: Installed natively on the deployment machine.

---

## 🚀 Quick Start Guide

### 1. Configuration (`cluster.conf`)
Ensure that your `cluster.conf` file is present in the directory and populated with your environment limits. The primary values accessed by Pulumi are:
- `PROJECT_ID`
- `REGION` & `ZONE`
- `DEPLOYMENT_NAME` (Determines cluster naming schema)
- `H200_NODE_COUNT` (Number of physical H200 nodes)
- `RESERVATION_NAME` (Required GCP reservation reference to locate A3 hardware)

### 2. Execution
You do not need to manually configure the Python environment or map the variables. Use the provided wrapper script to automate the entire lifecycle:

```bash
cd pulumi
chmod +x deploy_pulumi.sh
./deploy_pulumi.sh
```

### What Happens Behind the Scenes?
1. The bash wrapper initializes a pristine Pulumi `gcp-python` workspace natively.
2. Variables extracted from `cluster.conf` are piped into Pulumi's local execution configuration (`pulumi config set`).
3. Pulumi executes the graph logic defined in `__main__.py`, standing up the VPCs, GKE Cluster, and Node Pools.
4. Using the newly created cluster's credentials, the native `pulumi-kubernetes` provider synchronously applies all JobSet/Kueue/RDMA CRD resources straight onto the cluster.

### 3. Fetching Credentials
After the script completes successfully, retrieve your cluster credentials utilizing standard `gcloud` format:
```bash
gcloud container clusters get-credentials <DEPLOYMENT_NAME> --region <REGION> --project <PROJECT_ID>
```

### 4. Validating Network Performance (NCCL)
Once your cluster is active and your `KUBECONFIG` is exported, you can dynamically validate the RDMA interconnect bandwidth directly from the `pulumi` directory:

```bash
./run_nccl_test.sh
```

This automated bash script autonomously bootstraps a distributed PyTorch `JobSet` across your multi-NIC workers and aggregates the physical bus bandwidth.

### 5. Teardown
To cleanly destroy the cluster and release the A3 Ultra reservations, you must execute Pulumi from inside the isolated workspace directory it created:

```bash
cd .pulumi_${DEPLOYMENT_NAME}
pulumi destroy
```
