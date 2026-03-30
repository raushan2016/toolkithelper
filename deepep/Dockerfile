ARG CUDA_VERSION=12.9.1
FROM nvidia/cuda:${CUDA_VERSION}-cudnn-devel-ubuntu22.04 AS base

ARG DEEPEP_COMMIT=73b6ea4a439ba03a695563f9fd242c8e4b02b37c
ENV NVSHMEM_HOME=/workspace/nvshmem/install
ENV MPI_HOME=/usr/lib/x86_64-linux-gnu/openmpi
ENV PATH="${PATH}:/usr/local/nvidia/bin" \
    LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:/usr/local/nvidia/lib:/usr/local/nvidia/lib64:${NVSHMEM_HOME}/lib"

# Required for NVSHMEM build
ENV CUDA_ARCH="90;100"
ARG NVSHMEM_VERSION=3.4.5
ARG GDRCOPY_VERSION=2.5.1
# Required for DeepEP build
ENV TORCH_CUDA_ARCH_LIST="9.0 10.0"
ENV NVSHMEM_DIR=${NVSHMEM_HOME}

# Install dependencies and Mellanox OFED drivers
RUN apt-get update && apt-get install -y --no-install-recommends wget gnupg ca-certificates \
 && wget -qO - https://www.mellanox.com/downloads/ofed/RPM-GPG-KEY-Mellanox | gpg --dearmor -o /usr/share/keyrings/mellanox-archive-keyring.gpg \
 && wget -O /etc/apt/sources.list.d/mellanox_mlnx_ofed.list https://linux.mellanox.com/public/repo/mlnx_ofed/24.10-0.7.0.0/ubuntu22.04/mellanox_mlnx_ofed.list \
 && sed -i 's|^deb \(.*\)|deb [signed-by=/usr/share/keyrings/mellanox-archive-keyring.gpg] \1|' /etc/apt/sources.list.d/mellanox_mlnx_ofed.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
     ibverbs-utils libibverbs-dev libibumad3 libibumad-dev librdmacm-dev rdmacm-utils infiniband-diags \
     software-properties-common python3.10-dev python3.10-venv python-is-python3 \
     git-lfs curl build-essential cmake openmpi-bin libopenmpi-dev libfabric-dev \
     devscripts pkg-config debhelper dkms pip ninja-build \
 && rm -rf /var/lib/apt/lists/*

# Install NVSHMEM
WORKDIR /workspace
RUN wget https://developer.download.nvidia.com/compute/redist/nvshmem/${NVSHMEM_VERSION}/source/nvshmem_src_cuda12-all-all-${NVSHMEM_VERSION}.tar.gz \
    && tar -xf nvshmem_src_cuda12-all-all-${NVSHMEM_VERSION}.tar.gz \
    && mv nvshmem_src nvshmem \
    && rm -f /workspace/nvshmem_src_cuda12-all-all-${NVSHMEM_VERSION}.tar.gz \
    && mkdir nvshmem/build
WORKDIR /workspace/nvshmem
ENV CPATH=${MPI_HOME}/include:${CPATH}
ENV CMAKE_BUILD_PARALLEL_LEVEL=64
# Build NVSHMEM from source using Mellanox OFED for IBGDA natively.
# Notice: GDRCopy (NVSHMEM_USE_GDRCOPY=0) has been intentionally stripped from this image.
# Since A3 Ultra environments and DeepEP map the NIC QPs directly into the SMs (GPU memory)
# via IBGDA, the host CPU is entirely bypassed. CPU-driven copy libraries like GDRCopy 
# are unnecessary bloat for MoE dispatch on this infrastructure.
RUN export CC=/usr/bin/mpicc CXX=/usr/bin/mpicxx && \
    NVSHMEM_PMIX_SUPPORT=0 \
    NVSHMEM_LIBFABRIC_SUPPORT=0 \
    NVSHMEM_IBDEVX_SUPPORT=0 \
    NVSHMEM_SHMEM_SUPPORT=0 \
    NVSHMEM_UCX_SUPPORT=0 \
    NVSHMEM_USE_NCCL=0 \
    NVSHMEM_IBGDA_SUPPORT=1 \
    NVSHMEM_TIMEOUT_DEVICE_POLLING=0 \
    NVSHMEM_USE_GDRCOPY=0 \
    NVSHMEM_BUILD_EXAMPLES=0 \
    NVSHMEM_DISABLE_CUDA_VMM=1 \
    NVSHMEM_MPI_SUPPORT=0 \
    cmake -S . -B build/ -DCMAKE_INSTALL_PREFIX=${NVSHMEM_HOME} -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCH} \
        -DCMAKE_CXX_COMPILER=${CXX} -DCMAKE_C_COMPILER=${CC} &&\
    cmake --build build --target install -j${CMAKE_BUILD_PARALLEL_LEVEL} &&\
    # install python wheels that are built along with nvshmem
    CUDA_MAJOR=$(echo ${CUDA_VERSION} | cut -d'.' -f1) && \
    pip install build/dist/nvshmem4py_cu${CUDA_MAJOR}*-many*.whl

# Install PyTorch and Numpy
RUN CUDA_MAJOR=$(echo ${CUDA_VERSION} | cut -d'.' -f1) && CUDA_MINOR=$(echo ${CUDA_VERSION} | cut -d'.' -f2) && \
    pip install torch numpy --no-build-isolation --index-url https://download.pytorch.org/whl/cu${CUDA_MAJOR}${CUDA_MINOR}

# Uninstsall nvdia-nvshmem-cu12 so that it use the one built above is ued.
# Otherwise, IBGDA will not work with nvshmem installed as part of torch package.
RUN CUDA_MAJOR=$(echo ${CUDA_VERSION} | cut -d'.' -f1) && pip uninstall nvidia-nvshmem-cu${CUDA_MAJOR} -y

# Install DeepEP
WORKDIR /workspace
RUN git clone https://github.com/deepseek-ai/DeepEP.git && cd DeepEP && git checkout ${DEEPEP_COMMIT}
WORKDIR /workspace/DeepEP
# Modify DeepEP to enable NIC PE mapping for NVSHMEM (Deprecate when DeepEP fixes in upstream))
RUN    sed -i "/'NVSHMEM_IBGDA_NUM_RC_PER_PE'/a \\            os.environ['NVSHMEM_ENABLE_NIC_PE_MAPPING'] = '1'\n            local_rank = os.environ['LOCAL_RANK'] if 'LOCAL_RANK' in os.environ else self.rank % 8\n            os.environ['NVSHMEM_HCA_LIST'] = f'mlx5_{local_rank}:1'\n            print(f\"Setting {self.rank} to use {local_rank}\", flush=True)" deep_ep/buffer.py 
RUN pip install . --no-build-isolation

# Set workspace directory
WORKDIR /workspace