import pulumi
import pulumi_gcp as gcp
import pulumi_kubernetes as k8s
from pathlib import Path

# ==============================================================================
# 0. CONFIGURATION PARAMETERS (Passed via `pulumi config set`)
# ==============================================================================
config = pulumi.Config()
prefix = config.require("prefix")
project_id = config.require("project_id")
node_count = config.require_int("node_count")
reservation_name = config.require("reservation_name")
region = config.require("region")
zone = config.require("zone")
# Sizing CIDRs for massive scale (>2000 nodes possible per /12 secondary range)
pod_cidr = "10.64.0.0/12"
service_cidr = "10.96.0.0/20"
additional_node_network_configs = []
primary_net = None 
primary_subnet = None 

default_monitoring_component = [
    "SYSTEM_COMPONENTS", "POD", "DAEMONSET", "DEPLOYMENT", 
    "STATEFULSET", "STORAGE", "HPA", "CADVISOR", "KUBELET", "DCGM",
]

default_logging_component = ["SYSTEM_COMPONENTS", "WORKLOADS"]

for i in range(2):
    vpc = gcp.compute.Network(
        f"{prefix}-net-{i}",
        name=f"{prefix}-net-{i}",
        mtu=8896,
        auto_create_subnetworks=False,
    )
    # VPC 0 Subnet
    if i == 0:        
        subnet = gcp.compute.Subnetwork(
            f"{prefix}-sub-{i}",
            name=f"{prefix}-sub-{i}",
            network=vpc.id,
            ip_cidr_range="10.10.0.0/20",
            region=region,
            secondary_ip_ranges=[
                {"range_name": f"{prefix}-pods", "ip_cidr_range": pod_cidr},
                {"range_name": f"{prefix}-services", "ip_cidr_range": service_cidr},
            ],
        )
        primary_net = vpc.id
        primary_subnet = subnet.id
        gcp.compute.Firewall(
            f"{prefix}-internal-{i}",
            network=vpc.id,
            allows=[{"protocol": "tcp"}, {"protocol": "udp"}, {"protocol": "icmp"}],
            source_ranges=["10.10.0.0/20"],
        )
        
        # Cloud NAT for Private Nodes
        router = gcp.compute.Router(
            f"{prefix}-router",
            name=f"{prefix}-router",
            region=region,
            network=vpc.id,
        )
        
        nat = gcp.compute.RouterNat(
            f"{prefix}-nat",
            name=f"{prefix}-nat",
            router=router.name,
            region=region,
            nat_ip_allocate_option="AUTO_ONLY",
            source_subnetwork_ip_ranges_to_nat="ALL_SUBNETWORKS_ALL_IP_RANGES",
        )
    # VPC 1 Subnet
    else:        
        subnet = gcp.compute.Subnetwork(
            f"{prefix}-sub-{i}",
            name=f"{prefix}-sub-{i}",
            network=vpc.id,
            ip_cidr_range="192.168.64.0/18",
            region=region,
        )
        gcp.compute.Firewall(
            f"{prefix}-internal-{i}",
            network=vpc.id,
            allows=[{"protocol": "tcp"}, {"protocol": "udp"}, {"protocol": "icmp"}],
            source_ranges=["192.168.0.0/16"],
        )
        additional_node_network_configs.append(
            {"network": vpc.name, "subnetwork": subnet.name}
        )

# RDMA Networks (8 subnets)
rdma_vpc = gcp.compute.Network(
    f"{prefix}-rdma-net",
    name=f"{prefix}-rdma-net",
    mtu=8244,
    network_profile=f"https://www.googleapis.com/compute/beta/projects/{project_id}/global/networkProfiles/{zone}-vpc-roce",
    auto_create_subnetworks=False,
)
for i in range(8):
    subnet = gcp.compute.Subnetwork(
        f"{prefix}-rdma-sub-{i}",
        name=f"{prefix}-rdma-sub-{i}",
        network=rdma_vpc.id,
        ip_cidr_range=f"192.168.{128 + i*4}.0/22",
        region=region,
    )
    additional_node_network_configs.append(
        {"network": rdma_vpc.name, "subnetwork": subnet.name}
    )

# ==============================================================================
# 2. GKE CLUSTER DEFINITION
# ==============================================================================
cluster = gcp.container.Cluster(
    f"{prefix}-cluster",
    networking_mode="VPC_NATIVE",
    datapath_provider="ADVANCED_DATAPATH",
    location=region,
    deletion_protection=False,
    enable_multi_networking=True,
    ip_allocation_policy={
        "cluster_secondary_range_name": f"{prefix}-pods",
        "services_secondary_range_name": f"{prefix}-services",
    },
    network=primary_net,
    subnetwork=primary_subnet,
    initial_node_count=1,
    release_channel={"channel": "REGULAR"},
    remove_default_node_pool=True,
    workload_identity_config={
        "workload_pool": f"{project_id}.svc.id.goog",
    },
    private_cluster_config={
        "enable_private_nodes": True,
        "enable_private_endpoint": False,
        "master_ipv4_cidr_block": "172.16.0.32/28",
    },
    master_authorized_networks_config={
        "cidr_blocks": [{"cidr_block": "0.0.0.0/0", "display_name": "all"}]
    },
    cluster_autoscaling={
        "autoscaling_profile": "OPTIMIZE_UTILIZATION",
    },
    cost_management_config={"enabled": True}, 
    secret_manager_config={"enabled": True},
    addons_config={
        "dns_cache_config": {"enabled": True},
        "gce_persistent_disk_csi_driver_config": {"enabled": True},
        "gcp_filestore_csi_driver_config": {"enabled": True},
        "gcs_fuse_csi_driver_config": {"enabled": True},
    },
    node_pool_defaults={
        "node_config_defaults": {
            "gcfs_config": {
                "enabled": True
            }
        }
    },
    monitoring_config={
        "enable_components": default_monitoring_component,
        "managed_prometheus": {"enabled": True},
    },
    logging_config={
        "enable_components": default_logging_component,
    },
    maintenance_policy={
        "daily_maintenance_window": {"start_time": "09:00"},
        "maintenance_exclusions": [{
            "exclusion_name": "freeze-upgrades-1-month",
            "start_time": "2026-03-19T00:00:00Z",
            "end_time": "2026-04-16T00:00:00Z",
            "exclusion_options": {"scope": "NO_UPGRADES"},
        }],
    },
)

# ==============================================================================
# 3. NODE POOLS (A3 Ultragas & System Pool)
# ==============================================================================
nodepool = gcp.container.NodePool(
    f"{prefix}-a3ultra",
    cluster=cluster.id,
    node_locations=[zone],
    management={"auto_upgrade": True},
    node_config={
        "guest_accelerators": [{
            "count": 8, "type": "nvidia-h200-141gb",
            "gpu_driver_installation_config": {"gpu_driver_version": "DEFAULT"}
        }],
        "machine_type": "a3-ultragpu-8g",
        "gvnic": {"enabled": True},
        "oauth_scopes": ["https://www.googleapis.com/auth/cloud-platform"],
        "labels": {"gke-kdump-enabled": "true"},
        "ephemeral_storage_local_ssd_config": {"local_ssd_count": 32},
        "workload_metadata_config": {"mode": "GKE_METADATA"},
        "disk_type": "hyperdisk-balanced",
        "disk_size_gb": 100,
        "shielded_instance_config": {"enable_secure_boot": True},
        "linux_node_config": {
            "sysctls": {
                "net.ipv4.tcp_rmem": "4096 87380 16777216",
                "net.ipv4.tcp_wmem": "4096 16384 16777216"
            }
        },
        "kubelet_config": {"cpu_cfs_quota": True},
        "gcfs_config": {"enabled": True}, # IMAGE STREAMING Enabled for AI Boot Time
        "taints" : [
            {"key": "nvidia.com/gpu", "value": "present", "effect": "NO_SCHEDULE"},
        ],
        "reservation_affinity": {
            "consume_reservation_type": "SPECIFIC_RESERVATION",
            "key": "compute.googleapis.com/reservation-name",
            "values": [reservation_name],
        },
    },
    node_count=node_count,
    max_pods_per_node=110,
    network_config={"additional_node_network_configs": additional_node_network_configs},
)

cpu_nodepool = gcp.container.NodePool(
    f"{prefix}-cpu-nodepool",
    cluster=cluster.id,
    node_locations=[zone],
    node_config={
        "machine_type": "e2-standard-16", 
        "disk_size_gb": 200,
        "gvnic": {"enabled": True},
        "shielded_instance_config": {"enable_secure_boot": True},
        "oauth_scopes": ["https://www.googleapis.com/auth/cloud-platform"],
        "gcfs_config": {"enabled": True},
        "workload_metadata_config": {"mode": "GKE_METADATA"},
    },
    initial_node_count=3,
    autoscaling={"min_node_count": 2, "max_node_count": 10},
)

# ==============================================================================
# 4. KUBERNETES MANIFESTS ORCHESTRATION
# ==============================================================================

# Automatically build dynamic Kubeconfig pointing to the newly provisioned GKE cluster
kubeconfig = pulumi.Output.all(cluster.endpoint, cluster.name, cluster.master_auth).apply(
    lambda args: f"""apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: {args[2]["cluster_ca_certificate"]}
    server: https://{args[0]}
  name: {args[1]}
contexts:
- context:
    cluster: {args[1]}
    user: {args[1]}
  name: {args[1]}
current-context: {args[1]}
kind: Config
preferences: {{}}
users:
- name: {args[1]}
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: gke-gcloud-auth-plugin
      installHint: Install gke-gcloud-auth-plugin
      provideClusterInfo: true
"""
)

# Initialize Pulumi Kubernetes Provider against the cluster
k8s_provider = k8s.Provider("gke_k8s", kubeconfig=kubeconfig, opts=pulumi.ResourceOptions(depends_on=[nodepool, cpu_nodepool]))

# Map the raw bash string resources generated by the Google doc's legacy "add.sh" into native Yaml
gvnic_rdma_networks = []
gvnic_rdma_networks.append(f"""
apiVersion: networking.gke.io/v1
kind: GKENetworkParamSet
metadata:
  name: gvnic-1
spec:
  vpc: {prefix}-net-1
  vpcSubnet: {prefix}-sub-1
  deviceMode: NetDevice
---
apiVersion: networking.gke.io/v1
kind: Network
metadata:
  name: gvnic-1
spec:
  type: "Device"
  parametersRef:
    group: networking.gke.io
    kind: GKENetworkParamSet
    name: gvnic-1
""")

for i in range(8):
    gvnic_rdma_networks.append(f"""
apiVersion: networking.gke.io/v1
kind: GKENetworkParamSet
metadata:
  name: rdma-{i}
spec:
  vpc: {prefix}-rdma-net
  vpcSubnet: {prefix}-rdma-sub-{i}
  deviceMode: RDMA
---
apiVersion: networking.gke.io/v1
kind: Network
metadata:
  name: rdma-{i}
spec:
  type: "Device"
  parametersRef:
    group: networking.gke.io
    kind: GKENetworkParamSet
    name: rdma-{i}
""")

rdma_k8s = k8s.yaml.ConfigGroup(
    "rdma-networks-manifests",
    yaml=["---".join(gvnic_rdma_networks)],
    opts=pulumi.ResourceOptions(provider=k8s_provider)
)

# Dynamically parse and write our Cluster Kueue configuration
kueue_config_yaml = Path("kueue-configuration.yaml.tftpl").read_text()
kueue_config_yaml = kueue_config_yaml.replace("${accelerator_type}", "nvidia-h200-141gb").replace("${num_gpus}", str(node_count * 8))
Path("kueue-configuration.yaml").write_text(kueue_config_yaml)

# NCCL Toolkit Installer
nccl_installer = k8s.yaml.ConfigFile(
    "nccl-installer",
    file="https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/refs/heads/master/gpudirect-rdma/nccl-rdma-installer.yaml",
    opts=pulumi.ResourceOptions(provider=k8s_provider)
)

pulumi.export("cluster_id", cluster.id)
pulumi.export("cluster_name", cluster.name)
pulumi.export("kubeconfig", kubeconfig)
