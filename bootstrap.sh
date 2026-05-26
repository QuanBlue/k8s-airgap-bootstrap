#!/usr/bin/env bash
set -e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color
BACKUP_ROOT=".bootstrap-backups"

banner() {
    echo
    echo -e "${BOLD}${CYAN}========================================${NC}"
    echo -e "${BOLD}${CYAN}K8s Airgap Bootstrap${NC}"
    echo -e "${BOLD}${CYAN}========================================${NC}"
    echo
}

section() {
    echo
    echo -e "${BOLD}${BLUE}[$1]${NC}"
}

info() {
    echo -e "${DIM}$1${NC}"
}

ok() {
    echo -e "${GREEN}PASS${NC} $1"
}

note() {
    echo -e "${YELLOW}INFO${NC} $1"
}

prompt_line() {
    local label="$1"
    local default_value="$2"

    printf "${BOLD}%-32s${NC} [%s]: " "$label" "$default_value"
}

banner

prompt_with_hint() {
    local var_name="$1"
    local prompt_text="$2"
    local default_value="$3"
    local hint_text="$4"
    local input_value

    if [[ -n "$hint_text" ]]; then
        info "$hint_text"
    fi
    prompt_line "$prompt_text" "$default_value"
    read -r input_value
    printf -v "$var_name" '%s' "${input_value:-$default_value}"
}

ensure_positive_integer() {
    local value="$1"
    local field_name="$2"

    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -lt 1 ]]; then
        echo -e "${RED}Error: ${field_name} must be a positive integer.${NC}"
        exit 1
    fi
}

ensure_optional_positive_integer() {
    local value="$1"
    local field_name="$2"

    if [[ -n "$value" ]]; then
        ensure_positive_integer "$value" "$field_name"
    fi
}

ensure_ipv4() {
    local value="$1"
    local field_name="$2"

    if ! [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo -e "${RED}Error: ${field_name} must be a valid IPv4 address.${NC}"
        exit 1
    fi
}

collect_node_ips() {
    local group_name="$1"
    local role_label="$2"
    local node_count="$3"
    local __result_var="$4"
    local collected_ips=()
    local node_index=""
    local node_ip=""
    local default_ip=""

    echo -e "\n${BLUE}${group_name} node IP addresses${NC}"
    echo -e "${DIM}IP thuc te cua server. Gia tri nay se duoc ghi thang vao inventories/inventory.ini.${NC}"

    for ((node_index=1; node_index<=node_count; node_index++)); do
        if [[ "$role_label" == "Master" ]]; then
            default_ip="10.10.10.1${node_index}"
        else
            default_ip="10.10.10.2${node_index}"
        fi

        prompt_with_hint \
            node_ip \
            "${role_label} ${node_index} IP" \
            "$default_ip" \
            ""
        ensure_ipv4 "$node_ip" "${role_label} ${node_index} IP"
        collected_ips+=("$node_ip")
    done

    printf -v "$__result_var" '%s' "$(IFS=,; echo "${collected_ips[*]}")"
}

backup_file() {
    local source_file="$1"
    local backup_dir="$2"

    if [[ -f "$source_file" ]]; then
        mkdir -p "$backup_dir/$(dirname "$source_file")"
        cp "$source_file" "$backup_dir/$source_file"
        echo "$source_file|file" >> "$backup_dir/manifest.txt"
    else
        echo "$source_file|missing" >> "$backup_dir/manifest.txt"
    fi
}

# Gather Input
section "Cluster Identity"
prompt_with_hint \
    CLUSTER_NAME \
    "Cluster name" \
    "k8s-cluster" \
    "Ten logic cua cum. Gia tri nay se duoc ghi vao group_vars/all.yml va dung trong cau hinh kubeadm."

prompt_with_hint \
    PROJECT_NAME \
    "Project name" \
    "$CLUSTER_NAME" \
    "Ten du an day du. Anh huong toi app_user va thong tin metadata cua cum."

build_project_prefix() {
    local input="$1"
    local normalized
    local prefix

    normalized=$(echo "$input" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/ /g')
    prefix=$(echo "$normalized" | awk '{
        result = ""
        for (i = 1; i <= NF; i++) {
            token = $i
            if (token ~ /^[0-9]+$/) {
                result = result token
            } else {
                result = result substr(token, 1, 1)
            }
        }
        print result
    }')

    if [[ -z "$prefix" ]]; then
        prefix=$(echo "$normalized" | tr -d ' ' | cut -c1-6)
    fi

    if [[ -z "$prefix" ]]; then
        prefix="APP"
    fi

    echo "$prefix"
}

PROJECT_SHORT_NAME_DEFAULT=$(build_project_prefix "$PROJECT_NAME")

prompt_with_hint \
    PROJECT_SHORT_NAME \
    "Project short name" \
    "$PROJECT_SHORT_NAME_DEFAULT" \
    "Tien to rut gon cho hostname. Vi du DMS4-Prod-K8s-Master-01."

prompt_with_hint \
    ENVIRONMENT_NAME \
    "Environment name (e.g., Prod, Stag)" \
    "Prod" \
    "Moi truong trien khai. Anh huong truc tiep toi hostname va bien environment_name."

prompt_with_hint \
    HOSTNAME_CLUSTER_NUMBER \
    "Hostname cluster number (optional)" \
    "" \
    "Neu nhap so, hostname se co dang DMS4-Prod-K8s-Cluster1-Master-01. Bo trong de giu dang DMS4-Prod-K8s-Master-01."

section "Node Topology"
prompt_with_hint \
    MASTER_COUNT \
    "Number of master nodes" \
    "3" \
    "So node control-plane duoc sinh trong inventory nhom [masters]."

prompt_with_hint \
    WORKER_COUNT \
    "Number of worker nodes" \
    "6" \
    "So node worker duoc sinh trong inventory nhom [workers]."

ensure_positive_integer "$MASTER_COUNT" "Number of master nodes"
ensure_positive_integer "$WORKER_COUNT" "Number of worker nodes"
ensure_optional_positive_integer "$HOSTNAME_CLUSTER_NUMBER" "Hostname cluster number"
collect_node_ips "Master" "Master" "$MASTER_COUNT" MASTER_IPS
collect_node_ips "Worker" "Worker" "$WORKER_COUNT" WORKER_IPS

VIP_ENABLED="false"
VIP_ADDRESS=""
VIP_INTERFACE=""

if [ "$MASTER_COUNT" -gt 1 ]; then
    section "High Availability"
    note "Multiple master nodes detected. High Availability recommended."
    prompt_with_hint \
        ENABLE_VIP \
        "Enable VIP for Kubernetes API Server? (yes/no)" \
        "yes" \
        "Bat HA VIP cho kube-apiserver. Neu yes, playbook se dung them HAProxy va Keepalived."
    
    if [[ "$ENABLE_VIP" == "yes" || "$ENABLE_VIP" == "y" ]]; then
        VIP_ENABLED="true"
        prompt_with_hint \
            VIP_ADDRESS \
            "VIP address (e.g., 10.10.10.100)" \
            "10.10.10.100" \
            "Dia chi ao dung lam endpoint truy cap Kubernetes API Server."
        prompt_with_hint \
            VIP_INTERFACE \
            "Network interface for VIP (e.g., eth0)" \
            "eth0" \
            "Card mang tren cac master se gan VIP."
        
        if [[ -z "$VIP_ADDRESS" || -z "$VIP_INTERFACE" ]]; then
            echo -e "${RED}Error: VIP address and interface are required when VIP is enabled.${NC}"
            exit 1
        fi
    fi
fi

section "Cluster Network"
prompt_with_hint \
    K8S_VERSION \
    "Kubernetes version (e.g., 1.36.0)" \
    "1.36.0" \
    "Version dung de tai binary/image va ghi vao cau hinh kubeadm."

prompt_with_hint \
    POD_CIDR \
    "Pod CIDR" \
    "10.244.0.0/16" \
    "Dai mang cap cho Pod. Anh huong toi networking/CNI cua cluster."

prompt_with_hint \
    SERVICE_CIDR \
    "Service CIDR" \
    "10.96.0.0/12" \
    "Dai mang cap cho ClusterIP Service trong Kubernetes."

prompt_with_hint \
    DATA_PARTITION_ROOT \
    "K8s data partition root (optional)" \
    "" \
    "Neu nhap /u01/app, script se dat containerd root, offline images va kubelet pod logs ve phan vung nay. Bo trong de dung mac dinh cua Kubernetes/containerd."

if [[ -n "$DATA_PARTITION_ROOT" ]]; then
    DATA_PARTITION_ROOT="${DATA_PARTITION_ROOT%/}"
    CONTAINERD_ROOT_DIR="${DATA_PARTITION_ROOT}/lib/containerd"
    OFFLINE_IMAGES_DIR="${DATA_PARTITION_ROOT}/lib/k8s-offline-images"
    KUBELET_POD_LOGS_DIR="${DATA_PARTITION_ROOT}/log/containerd"
else
    CONTAINERD_ROOT_DIR="/var/lib/containerd"
    OFFLINE_IMAGES_DIR="/var/lib/k8s-offline-images"
    KUBELET_POD_LOGS_DIR=""
fi

section "Generate Files"
note "Creating backup and generating inventory/group_vars files."

BACKUP_TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
BACKUP_DIR="$BACKUP_ROOT/$BACKUP_TIMESTAMP"
mkdir -p "$BACKUP_DIR"
: > "$BACKUP_DIR/manifest.txt"

backup_file "inventories/inventory.ini" "$BACKUP_DIR"
backup_file "group_vars/all.yml" "$BACKUP_DIR"
backup_file "group_vars/masters.yml" "$BACKUP_DIR"
backup_file "group_vars/workers.yml" "$BACKUP_DIR"

# Call helper scripts to generate inventory
bash ./scripts/generate-inventory.sh \
    --environment-name "$ENVIRONMENT_NAME" \
    --hostname-cluster-number "$HOSTNAME_CLUSTER_NUMBER" \
    --master-count "$MASTER_COUNT" \
    --master-ips "$MASTER_IPS" \
    --worker-count "$WORKER_COUNT" \
    --worker-ips "$WORKER_IPS" \
    --project-name "$PROJECT_NAME" \
    --project-short-name "$PROJECT_SHORT_NAME"

# Generate group_vars/all.yml
cat <<EOF > group_vars/all.yml
---
cluster_name: "$CLUSTER_NAME"
project_name: "$PROJECT_NAME"
project_short_name: "$PROJECT_SHORT_NAME"
environment_name: "$ENVIRONMENT_NAME"
app_user: "app_$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/_\\+/_/g' | sed 's/^_//; s/_$//')"
kubernetes_version: "$K8S_VERSION"

# Networking
network:
  pod_cidr: "$POD_CIDR"
  service_cidr: "$SERVICE_CIDR"

# Container Runtime
container_runtime: containerd
containerd_config:
  root_dir: "$CONTAINERD_ROOT_DIR"

# Kubelet
kubelet:
  pod_logs_dir: "$KUBELET_POD_LOGS_DIR"
  volume_stats_agg_period: "0s"
  container_log_max_size: "50Mi"
  container_log_max_files: 90
  image_gc_high_threshold_percent: 65
  image_gc_low_threshold_percent: 60

# High Availability Settings
k8s_ha:
  enabled: $VIP_ENABLED
  vip_address: "$VIP_ADDRESS"
  vip_interface: "$VIP_INTERFACE"
  vip_port: 6443

# Offline/Airgap specific
airgap:
  enabled: true
  artifacts_dir: "{{ playbook_dir }}/artifacts"
  offline_images_dir: "$OFFLINE_IMAGES_DIR"
EOF

# Generate group_vars/masters.yml
cat <<EOF > group_vars/masters.yml
---
# Master node specific variables
node_role: master
EOF

# Generate group_vars/workers.yml
cat <<EOF > group_vars/workers.yml
---
# Worker node specific variables
node_role: worker
EOF

ok "Configuration generated successfully."
note "Review files in inventories/ and group_vars/ before deployment."
note "Backup saved at ${BACKUP_DIR}"
note "Rollback latest bootstrap run with ./scripts/bootstrap-clean.sh"
