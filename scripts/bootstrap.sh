#!/usr/bin/env bash
set -e

# ─── Colors ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Always operate from the repository root so relative paths below
# (inventories/, .bootstrap-backups/, scripts/helpers/) resolve no matter
# where the user invokes the script from.
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

BACKUP_ROOT=".bootstrap-backups"
_STEP=0
_TOTAL=5  # reduced to 4 if single master (no HA section)

# ─── UI Helpers ───────────────────────────────────────────────────────────────
banner() {
    echo
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}☸  K8s Airgap Bootstrap${NC}                                         ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}     Kubernetes Cluster Setup Wizard                              ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo
}

section() {
    _STEP=$((_STEP + 1))
    local title="$1"
    local label="  ${_STEP} / ${_TOTAL}  ·  ${title}  "
    local total=68
    local pad_left=$(( (total - ${#label}) / 2 ))
    local pad_right=$(( total - ${#label} - pad_left ))
    local left right
    left=$(printf '━%.0s' $(seq 1 $pad_left))
    right=$(printf '━%.0s' $(seq 1 $pad_right))
    echo
    echo -e "${BOLD}${BLUE}${left}${label}${right}${NC}"
    echo
}

# Prompt with multi-line hint, label on its own line, input on next line
ask() {
    local var_name="$1"
    local label="$2"
    local default_value="$3"
    local hint_text="$4"
    local annotation="$5"
    local input_value

    if [[ -n "$annotation" ]]; then
        echo -e "  ${BOLD}◆ ${label}${NC}  ${DIM}${annotation}${NC}"
    else
        echo -e "  ${BOLD}◆ ${label}${NC}"
    fi

    if [[ -n "$hint_text" ]]; then
        echo -e "    ${DIM}${hint_text}${NC}"
    fi

    if [[ -n "$default_value" ]]; then
        printf "    ${CYAN}❯${NC} [${DIM}${default_value}${NC}]: "
    else
        printf "    ${CYAN}❯${NC} [${DIM}none${NC}]: "
    fi

    read -r input_value || true
    printf -v "$var_name" '%s' "${input_value:-$default_value}"
    echo
}

# Compact single-line prompt (label + input on same line)
ask_inline() {
    local var_name="$1"
    local label="$2"
    local default_value="$3"
    local input_value

    if [[ -n "$default_value" ]]; then
        printf "  ${BOLD}◆ %-30s${NC}${CYAN}❯${NC} [${DIM}${default_value}${NC}]: " "$label"
    else
        printf "  ${BOLD}◆ %-30s${NC}${CYAN}❯${NC} [${DIM}none${NC}]: " "$label"
    fi

    read -r input_value || true
    printf -v "$var_name" '%s' "${input_value:-$default_value}"
}

info_line() {
    echo -e "  ${YELLOW}ℹ${NC}  $1"
}

err() {
    echo -e "  ${RED}✗  $1${NC}"
    exit 1
}

divider() {
    echo -e "  ${DIM}$(printf '╌%.0s' $(seq 1 64))${NC}"
}

# ─── Validation ───────────────────────────────────────────────────────────────
ensure_positive_integer() {
    local value="$1" label="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -lt 1 ]]; then
        err "${label} phải là số nguyên dương."
    fi
}

ensure_optional_positive_integer() {
    local value="$1" label="$2"
    if [[ -n "$value" ]]; then ensure_positive_integer "$value" "$label"; fi
}

ensure_ipv4() {
    local value="$1" label="$2"
    if ! [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        err "${label}: '${value}' không phải IPv4 hợp lệ."
    fi
}

# ─── Helpers ──────────────────────────────────────────────────────────────────
build_project_prefix() {
    local input="$1"
    local normalized prefix
    normalized=$(echo "$input" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/ /g')
    prefix=$(echo "$normalized" | awk '{
        r=""
        for(i=1;i<=NF;i++) {
            if ($i~/^[0-9]+$/) r=r$i
            else r=r substr($i,1,1)
        }
        print r
    }')
    if [[ -z "$prefix" ]]; then prefix=$(echo "$normalized" | tr -d ' ' | cut -c1-6); fi
    if [[ -z "$prefix" ]]; then prefix="APP"; fi
    echo "$prefix"
}

collect_node_ips() {
    local role_label="$1"
    local node_count="$2"
    local __result_var="$3"
    local collected_ips=()
    local node_ip default_ip

    echo -e "  ${BOLD}${BLUE}▸ ${role_label} node IP addresses${NC}"
    divider
    for ((i=1; i<=node_count; i++)); do
        if [[ "$role_label" == "Master" ]]; then
            default_ip="10.0.6.1${i}"
        else
            default_ip="10.0.6.2${i}"
        fi
        ask_inline node_ip "${role_label} ${i}" "$default_ip"
        ensure_ipv4 "$node_ip" "${role_label} ${i}"
        collected_ips+=("$node_ip")
    done

    printf -v "$__result_var" '%s' "$(IFS=,; echo "${collected_ips[*]}")"
}

backup_file() {
    local src="$1" bdir="$2"
    if [[ -f "$src" ]]; then
        mkdir -p "$bdir/$(dirname "$src")"
        cp "$src" "$bdir/$src"
        echo "$src|file" >> "$bdir/manifest.txt"
    else
        echo "$src|missing" >> "$bdir/manifest.txt"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════

banner

# ─── 1 / 5  Cluster Identity ──────────────────────────────────────────────────
section "Cluster Identity"

ask CLUSTER_NAME "Cluster name" "k8s-cluster" \
    "Tên logic của cụm. Dùng trong kubeadm config và sinh các giá trị khác."

PROJECT_NAME="$CLUSTER_NAME"

ask APP_USER "App user" "app" \
    "Linux user được tạo trên tất cả node."

PROJECT_SHORT_NAME_DEFAULT=$(build_project_prefix "$PROJECT_NAME")

ask PROJECT_SHORT_NAME "Short name" "$PROJECT_SHORT_NAME_DEFAULT" \
    "Prefix trong hostname của từng node.\n    Nhập DMS4  →  DMS4-Prod-K8s-Master-01" \
    "(hostname prefix)"

ask ENVIRONMENT_NAME "Environment" "Prod" \
    "Tên môi trường, xuất hiện trực tiếp trong hostname.\n    Nhập Prod  →  DMS4-Prod-K8s-Master-01" \
    "(e.g. Prod, Stag)"

ask HOSTNAME_CLUSTER_NUMBER "Cluster number" "" \
    "Số thứ tự cluster, dùng khi có nhiều cụm cùng dự án.\n    Để trống  →  DMS4-Prod-K8s-Master-01\n    Nhập 1    →  DMS4-Prod-K8s-Cluster1-Master-01" \
    "(optional)"

# ─── 2 / 5  Node Topology ─────────────────────────────────────────────────────
section "Node Topology"

ask_inline MASTER_COUNT "Master nodes" "3"
ask_inline WORKER_COUNT "Worker nodes" "6"

ensure_positive_integer "$MASTER_COUNT" "Master nodes"
ensure_positive_integer "$WORKER_COUNT"  "Worker nodes"
ensure_optional_positive_integer "$HOSTNAME_CLUSTER_NUMBER" "Cluster number"

if [[ "$MASTER_COUNT" -le 1 ]]; then _TOTAL=4; fi

echo
collect_node_ips "Master" "$MASTER_COUNT" MASTER_IPS
echo
collect_node_ips "Worker" "$WORKER_COUNT" WORKER_IPS

# ─── 3 / 5  SSH Access ────────────────────────────────────────────────────────
section "SSH Access"

ask ANSIBLE_USER "SSH user" "root" \
    "Tài khoản Ansible dùng để SSH vào tất cả node."

ask ANSIBLE_SSH_PRIVATE_KEY_FILE "SSH private key" "" \
    "Để trống nếu đã dùng SSH agent hoặc ~/.ssh/config.\n    Ví dụ: /root/.ssh/id_ed25519" \
    "(optional)"

# ─── 4 / 5  High Availability ─────────────────────────────────────────────────
VIP_ENABLED="false"
VIP_ADDRESS=""
VIP_INTERFACE=""

if [ "$MASTER_COUNT" -gt 1 ]; then
    section "High Availability"
    info_line "${MASTER_COUNT} master nodes detected — HA recommended."
    echo

    ask ENABLE_VIP "Enable VIP?" "yes" \
        "Bật HA VIP cho kube-apiserver.\n    Playbook sẽ dùng thêm HAProxy và Keepalived." \
        "(yes/no)"

    if [[ "$ENABLE_VIP" == "yes" || "$ENABLE_VIP" == "y" ]]; then
        VIP_ENABLED="true"

        ask VIP_ADDRESS "VIP address" "10.0.6.100" \
            "Địa chỉ ảo làm endpoint truy cập Kubernetes API Server."

        ask VIP_INTERFACE "VIP interface" "eth0" \
            "Card mạng trên các master sẽ gán VIP."

        if [[ -z "$VIP_ADDRESS" || -z "$VIP_INTERFACE" ]]; then
            err "VIP address và interface là bắt buộc khi bật VIP."
        fi
    fi
fi

# ─── 5 / 5  Cluster Network ───────────────────────────────────────────────────
section "Cluster Network"

ask_inline K8S_VERSION "Kubernetes version" "1.36.0";
ask_inline POD_CIDR     "Pod CIDR"           "10.244.0.0/16";
ask_inline SERVICE_CIDR "Service CIDR"       "10.96.0.0/12"; 
echo

ask CALICO_IP_AUTODETECTION "Calico IP autodetection" "first-found" \
    "Cách Calico chọn IP node khi có nhiều interface.\n    · interface=eth0       — chỉ định tên interface\n    · cidr=10.129.0.0/16   — chọn interface có IP thuộc dải này  ← khuyên dùng\n    · first-found          — lấy interface đầu tiên (dễ chọn sai)"

ask DATA_PARTITION_ROOT "Data partition root" "" \
    "Phân vùng riêng để chứa dữ liệu K8s. Ví dụ nhập /u01/app:\n      · /u01/app/lib/containerd        — containerd root dir\n      · /u01/app/lib/k8s-offline-images — offline image store\n      · /u01/app/log/containerd        — kubelet pod logs\n    Để trống → dùng mặc định: /var/lib/containerd, /var/lib/k8s-offline-images" \
    "(optional)"

if [[ -n "$DATA_PARTITION_ROOT" ]]; then
    DATA_PARTITION_ROOT="${DATA_PARTITION_ROOT%/}"
    CONTAINERD_ROOT_DIR="${DATA_PARTITION_ROOT}/lib/containerd"
    OFFLINE_IMAGES_DIR="${DATA_PARTITION_ROOT}/lib/k8s-offline-images"
    KUBELET_POD_LOGS_DIR="${DATA_PARTITION_ROOT}/log/containerd"
    AUDIT_LOG_DIR="${DATA_PARTITION_ROOT}/log/kubernetes/audit"
else
    CONTAINERD_ROOT_DIR="/var/lib/containerd"
    OFFLINE_IMAGES_DIR="/var/lib/k8s-offline-images"
    KUBELET_POD_LOGS_DIR=""
    AUDIT_LOG_DIR="/var/log/kubernetes/audit"
fi

# ─── Generate Files ───────────────────────────────────────────────────────────
BACKUP_TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
BACKUP_DIR="$BACKUP_ROOT/$BACKUP_TIMESTAMP"
mkdir -p "$BACKUP_DIR"
: > "$BACKUP_DIR/manifest.txt"

backup_file "inventories/inventory.ini" "$BACKUP_DIR"
backup_file "inventories/group_vars/all.yml"        "$BACKUP_DIR"
backup_file "inventories/group_vars/masters.yml"    "$BACKUP_DIR"
backup_file "inventories/group_vars/workers.yml"    "$BACKUP_DIR"

bash ./scripts/helpers/generate-inventory.sh \
    --environment-name             "$ENVIRONMENT_NAME" \
    --hostname-cluster-number      "$HOSTNAME_CLUSTER_NUMBER" \
    --master-count                 "$MASTER_COUNT" \
    --master-ips                   "$MASTER_IPS" \
    --worker-count                 "$WORKER_COUNT" \
    --worker-ips                   "$WORKER_IPS" \
    --project-name                 "$PROJECT_NAME" \
    --project-short-name           "$PROJECT_SHORT_NAME" \
    --ansible-user                 "$ANSIBLE_USER" \
    --ansible-ssh-private-key-file "$ANSIBLE_SSH_PRIVATE_KEY_FILE"

cat <<EOF > inventories/group_vars/all.yml
---
cluster_name: "$CLUSTER_NAME"
project_name: "$PROJECT_NAME"
project_short_name: "$PROJECT_SHORT_NAME"
environment_name: "$ENVIRONMENT_NAME"
app_user: "$APP_USER"
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
  vip_port: 8443

# Calico CNI
calico_networking_backend: vxlan
calico_ip_autodetection_method: "$CALICO_IP_AUTODETECTION"

# Offline/Airgap specific
airgap:
  enabled: true
  artifacts_dir: "{{ playbook_dir | dirname }}/artifacts"
  offline_images_dir: "$OFFLINE_IMAGES_DIR"

# Kubernetes API Server audit logging
kubernetes_audit:
  enabled: true
  log_dir: "$AUDIT_LOG_DIR"
  policy_file: "/etc/kubernetes/audit/policy.yaml"
  max_age: 90        # days
  max_backup: 20     # rotated files
  max_size: 100      # MB per file
EOF

cat <<EOF > inventories/group_vars/masters.yml
---
node_role: master
EOF

cat <<EOF > inventories/group_vars/workers.yml
---
node_role: worker
EOF

# ─── Summary ──────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${BLUE}$(printf '━%.0s' $(seq 1 68))${NC}"
echo
echo -e "  ${GREEN}✔${NC}  inventories/inventory.ini"
echo -e "  ${GREEN}✔${NC}  inventories/group_vars/all.yml"
echo -e "  ${DIM}  Backup → ${BACKUP_DIR}${NC}"
echo
echo -e "  ${BOLD}➜  Chạy tiếp:${NC}  ansible-playbook playbooks/site.yml"
echo
echo -e "${BOLD}${BLUE}$(printf '━%.0s' $(seq 1 68))${NC}"
echo
