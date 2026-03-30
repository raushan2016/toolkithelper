# DeepEP Benchmark Toolkit for GKE

This directory contains a complete, optimized toolkit for building, deploying, and running DeepEP (Deep Embedding Parallelism) benchmarks on Google Kubernetes Engine (GKE). It is specifically tailored for high-performance clusters utilizing A3 Ultra (H200) hardware with GPUDirect RDMA.

## Architecture

1.  **`Dockerfile`**: A highly optimized container definition that compiles NVSHMEM from source with Mellanox OFED (IBGDA) support and installs the DeepEP communication library.
2.  **`deepep-benchmark.yaml`**: A parameterized K8s `StatefulSet` and headless Service that provisions the distributed benchmark environment, guaranteeing `hostNetwork`, `hostIPC`, and proper GPU allocations.
3.  **`run-k8s-benchmark.sh`**: A wrapper script that dynamically injects variables (e.g., node count, namespace) into the YAML manifest and deploys the benchmark.

---

## 1. Building the Custom Docker Image

The benchmark relies on a custom Docker image to provide the lowest-level InfiniBand/gVNIC network bindings using NVSHMEM's IBGDA driver natively. 

The `Dockerfile` has been optimized to compile these dependencies efficiently. Unused packages (like GDRCopy, since GCP A3 Ultra leverages native DMA-Buf via IBGDA) have been removed to reduce bloat.

### Build & Push
To build the image and push it to your Artifact Registry:

```bash
export IMAGE_URI="us-central1-docker.pkg.dev/YOUR-PROJECT/YOUR-REPO/deepep-installer:latest"

# Build the image locally
docker build -t ${IMAGE_URI} .

# Push to your registry
docker push ${IMAGE_URI}
```

---

## 2. Running the Benchmark

Once your image is pushed, use the wrapper script to launch the benchmark on your GKE cluster. Ensure your `kubectl` context is mapped to an A3 Ultra node pool.

### Quick Start Deployment
```bash
# Syntax: ./run-k8s-benchmark.sh [NODES] [NAMESPACE] [GPUS_PER_NODE] [IMAGE]
./run-k8s-benchmark.sh 2 default 8 ${IMAGE_URI}
```

This script will:
1. Interpolate your variables into `deepep-benchmark.yaml`.
2. Apply the headless service and StatefulSet to the cluster.
3. Automatically stream the benchmark logs from the master node (`rank 0`).

### Monitoring & Telemetry
During the run, you can follow the logs of the secondary pods, or re-attach to the master pod:
```bash
kubectl logs -f deepep-benchmark-0 -n default
```
*Note: We have disabled verbose `NVSHMEM_DEBUG=TRACE` logging inside `deepep-benchmark.yaml` to ensure pure performance metrics are reported without I/O overhead.*

---

## 3. Configuration Customization

If you need to tweak the behavior of the benchmark, you can modify `deepep-benchmark.yaml` directly before running the launcher.

- **Disable NVLink (P2P)**: Useful to isolate and test pure network RDMA throughput. Add this environment variable:
  ```yaml
  - name: NVSHMEM_DISABLE_P2P
    value: "1"
  ```
- **Increase Shmem limit**: The benchmark requests `256Gi` of `/dev/shm`. Adjust the `dshm` volume sizes if executing larger token dispatches.

## 4. Teardown
To cleanly remove the benchmark pods and free up the GPUs:
```bash
kubectl delete -f deepep-benchmark.yaml
```
