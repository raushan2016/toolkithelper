# GKE Cluster Setup via Google Cluster Toolkit

This folder contains everything needed to rapidly provision an AI-optimized GKE Cluster on Google Cloud Platform, tailored for High-Performance Workloads (e.g., A3/H200).

## Prerequisites
1. **Google Cloud SDK**: Make sure you have the `gcloud` CLI installed and authenticated to your GCP project.
   ```bash
   gcloud auth login
   gcloud auth application-default login
   ```
2. **Quota / Reservations**: Make sure you have the required quota and compute reservations (e.g., H200) in your selected GCP project.
3. **IAM Permissions**: The authenticated account running the deployment must have sufficient privileges in the target GCP Project. At a minimum, ensure you have the following roles:
   - `Project IAM Admin` (to manage service accounts and bindings)
   - `Kubernetes Engine Admin` (to provision the GKE cluster)
   - `Compute Admin` (to configure VPC networks and node pools)
   - `Storage Admin` (to create the Terraform state bucket)
   - `Service Usage Admin` (to automatically enable required GCP APIs)
   *(Alternatively, the `Owner` or `Editor` + `Project IAM Admin` roles will cover all of the above).*
## Instructions
1. **Configure Parameters**: 
   Open `cluster.conf` using any text editor and update the variables tailored to your environment:
   - `PROJECT_ID`: Your target Google Cloud Project ID.
   - `REGION` & `ZONE`: Location where the resources will be generated.
   - `TF_STATE_BUCKET`: An arbitrarily named Cloud Storage bucket to track deployment state. (Must be globally unique)
   - `DEPLOYMENT_NAME`: The identifier name for the created GKE cluster.
   - `RESERVATION_NAME`: The specific compute reservation name housing your GPUs.
   - `H200_NODE_COUNT`: The number of H200 nodes you wish to provision (default is 6).
   - `AUTHORIZED_CIDR`: Update to your machine's IP (e.g. `203.0.113.0/32`) if you want kubectl access securely restricted, or keep as `0.0.0.0/0` for initial open testing.

2. **Execute Deployment**:
   Run the deployment script from a terminal:
   ```bash
   chmod +x deploy.sh
   ./deploy.sh
   ```

   **What `deploy.sh` does automatically behind the scenes**:
   - Parses `cluster.conf` and prepares the cluster template (`gke-h200.yaml.template`).
   - Downloads & Configures the `gcluster` CLI Toolkit if missing.
   - Enables all necessary default GCP APIs.
   - Creates a GCS backend tracking state bucket if it does not already exist.
   - Modifies your `gke-h200.yaml` deployment schema in real-time.
   - Executes the terraform/infrastructure build!

3. **Get Kubectl Credentials**
   After the script completes successfully, retrieve your cluster credentials utilizing standard `gcloud` format:
   ```bash
   gcloud container clusters get-credentials <DEPLOYMENT_NAME> --zone <ZONE> --project <PROJECT_ID>
   ```

4. **Run Performance Diagnostics (Optional)**
   We bundled a plug-and-play script to test the interconnect bandwidth between your freshly provisioned GPUs:
   ```bash
   ./run_nccl_test.sh
   ```
   This script will dynamically adapt to the node count specified in `cluster.conf`, deploy the testing workload to your Kubernetes cluster via a native JobSet, wait for the test to complete, and print a consolidated ASCII bar chart displaying the network bandwidth (GB/s).

5. **Run Mixtral 8x7B Training (Optional)**
   We bundled a plug-and-play script to test streaming Framework TFLOPS and Model Flop Utilization via a Sparse MoE model:
   ```bash
   ./run_mixtral_test.sh
   ```
   Like the NCCL test, this will dynamically adapt to the node count specified in `cluster.conf`, provision GCS FUSE PVCs using your configured buckets, deploy a training workload using Kubernetes JobSet, and live-stream the resulting performance logs.

6. **Teardown Environment**
   To completely wipe the deployed infrastructure and save costs when you're finished experimenting, run:
   ```bash
   ./teardown.sh
   ```
   *Note: This utilizes `gcluster destroy` underneath and completely deletes the Kubernetes cluster configured in `cluster.conf`.*
