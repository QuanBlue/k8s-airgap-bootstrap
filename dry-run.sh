#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_PLAYBOOK="playbooks/site.yml"
DEFAULT_INVENTORY="inventories/inventory.ini"
MODE="syntax"
PLAYBOOK="$DEFAULT_PLAYBOOK"
INVENTORY_OVERRIDE=""
ANSIBLE_TMP_BASE="${TMPDIR:-/tmp}/ansible-dry-run"

usage() {
    cat <<EOF
Usage: ./dry-run.sh [options]

Options:
  --mode <syntax|check>     Validation mode. Default: syntax
  --playbook <path>         Playbook to validate. Default: $DEFAULT_PLAYBOOK
  --inventory <path>        Real inventory for --mode check
  --help                    Show this help message

Examples:
  ./dry-run.sh
  ./dry-run.sh --mode check --inventory inventories/inventory.ini
EOF
}

log() {
    echo -e "${BLUE}==>${NC} $1"
}

section() {
    echo
    echo -e "${BOLD}${CYAN}========================================${NC}"
    echo -e "${BOLD}${CYAN}$1${NC}"
    echo -e "${BOLD}${CYAN}========================================${NC}"
}

kv() {
    printf "  %-22s %s\n" "$1" "$2"
}

bullet() {
    printf "  - %s\n" "$1"
}

success() {
    echo -e "${GREEN}PASS${NC} $1"
}

warn() {
    echo -e "${YELLOW}WARN${NC} $1"
}

fail() {
    echo -e "${RED}FAIL${NC} $1"
    exit 1
}

prompt_value() {
    local __var_name="$1"
    local prompt_text="$2"
    local default_value="$3"
    local input_value

    read -r -p "$prompt_text [$default_value]: " input_value
    printf -v "$__var_name" '%s' "${input_value:-$default_value}"
}

prompt_value_with_hint() {
    local __var_name="$1"
    local prompt_text="$2"
    local default_value="$3"
    local hint_text="$4"
    local input_value

    if [[ -n "$hint_text" ]]; then
        echo -e "${DIM}${hint_text}${NC}"
    fi
    read -r -p "$prompt_text [$default_value]: " input_value
    printf -v "$__var_name" '%s' "${input_value:-$default_value}"
}

ensure_positive_integer() {
    local value="$1"
    local field_name="$2"

    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -lt 1 ]]; then
        fail "$field_name must be a positive integer."
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
        fail "$field_name must be a valid IPv4 address."
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

    echo
    echo -e "${BOLD}${group_name} node IP addresses${NC}"
    echo -e "${DIM}IP thuc te cua server. Dry-run se preview gia tri nay trong inventories/inventory.ini.${NC}"

    for ((node_index=1; node_index<=node_count; node_index++)); do
        if [[ "$role_label" == "Master" ]]; then
            default_ip="10.10.10.1${node_index}"
        else
            default_ip="10.10.10.2${node_index}"
        fi

        prompt_value_with_hint \
            node_ip \
            "${role_label} ${node_index} IP" \
            "$default_ip" \
            ""
        ensure_ipv4 "$node_ip" "${role_label} ${node_index} IP"
        collected_ips+=("$node_ip")
    done

    printf -v "$__result_var" '%s' "$(IFS=,; echo "${collected_ips[*]}")"
}

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
        prefix=$(echo "$normalized" | tr -d " " | cut -c1-6)
    fi

    if [[ -z "$prefix" ]]; then
        prefix="APP"
    fi

    echo "$prefix"
}

describe_file() {
    case "$1" in
        "inventories/inventory.ini")
            echo "Danh sach node, hostname, ansible_host va bien inventory"
            ;;
        "group_vars/all.yml")
            echo "Bien dung chung cho toan cum: project, app_user, network, HA"
            ;;
        "group_vars/masters.yml")
            echo "Bien rieng cho nhom master"
            ;;
        "group_vars/workers.yml")
            echo "Bien rieng cho nhom worker"
            ;;
        *)
            echo "Generated file"
            ;;
    esac
}

print_diff() {
    local current_file="$1"
    local generated_file="$2"

    if [[ -f "$current_file" ]]; then
        diff -u "$current_file" "$generated_file" || true
    else
        sed '1s/^/--- current file does not exist\n+++ generated preview\n/' "$generated_file"
    fi
}

print_node_summary() {
    local inventory_file="$1"
    local section=""
    local hostname=""
    local node_role=""
    local host_ip=""

    while IFS= read -r line; do
        case "$line" in
            "[masters]")
                section="master"
                continue
                ;;
            "[workers]")
                section="worker"
                continue
                ;;
            "[k8s_cluster:children]"|"[all:vars]")
                section=""
                continue
                ;;
            ""|\#*)
                continue
                ;;
        esac

        if [[ "$section" == "master" || "$section" == "worker" ]]; then
            hostname=${line%% *}
            host_ip=$(echo "$line" | sed -n 's/.*ansible_host=\([^ ]*\).*/\1/p')
            if [[ "$section" == "master" ]]; then
                node_role="control-plane"
            else
                node_role="worker"
            fi

            bullet "$hostname [$node_role] - $host_ip"
        fi
    done < "$inventory_file"
}

print_download_plan() {
    local artifacts_dir="$ROOT_DIR/artifacts"
    local calico_version="v3.32.0"
    local containerd_version="2.3.1"
    local runc_version="1.4.0"
    local crictl_version="v1.36.0"
    local helm_version="3.20.1"
    local k9s_version="v0.50.18"

    kv "script" "./scripts/download-artifacts.sh"
    kv "bin_dir" "$artifacts_dir/bin"
    kv "packages_dir" "$artifacts_dir/packages"
    kv "images_dir" "$artifacts_dir/images"
    kv "manifests_dir" "$artifacts_dir/manifests"
    echo
    echo -e "  ${BOLD}Binary Files${NC}"
    bullet "containerd-${containerd_version}-linux-amd64.tar.gz"
    bullet "runc.amd64"
    bullet "crictl-${crictl_version}-linux-amd64.tar.gz"
    bullet "helm (v${helm_version})"
    bullet "k9s (${k9s_version})"
    bullet "kubeadm"
    bullet "kubelet"
    bullet "kubectl"
    echo
    echo -e "  ${BOLD}Package Files${NC}"
    bullet "$artifacts_dir/packages/*.rpm"
    kv "includes" "containerd.io, kubeadm, kubelet, kubectl, kubernetes-cni, haproxy, keepalived, socat, conntrack-tools, ipset, ipvsadm"
    echo
    echo -e "  ${BOLD}Manifest Files${NC}"
    bullet "$artifacts_dir/manifests/calico.yaml"
    bullet "$artifacts_dir/manifests/installers-manifest.txt"
    echo
    echo -e "  ${BOLD}Image Files${NC}"
    bullet "$artifacts_dir/images/*.tar"
    kv "includes" "Kubernetes control-plane images for v${K8S_VERSION} and Calico images from ${calico_version}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="${2:-}"
            shift 2
            ;;
        --playbook)
            PLAYBOOK="${2:-}"
            shift 2
            ;;
        --inventory)
            INVENTORY_OVERRIDE="${2:-}"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "Unknown argument: $1"
            ;;
    esac
done

if [[ "$MODE" != "syntax" && "$MODE" != "check" ]]; then
    fail "Unsupported mode '$MODE'. Use 'syntax' or 'check'."
fi

cd "$ROOT_DIR"
[[ -f "$PLAYBOOK" ]] || fail "Playbook not found: $PLAYBOOK"

mkdir -p "$ANSIBLE_TMP_BASE/local" "$ANSIBLE_TMP_BASE/remote"
export ANSIBLE_LOCAL_TEMP="$ANSIBLE_TMP_BASE/local"
export ANSIBLE_REMOTE_TEMP="$ANSIBLE_TMP_BASE/remote"

log "Nhap thong tin preview giong bootstrap.sh"
prompt_value_with_hint CLUSTER_NAME "Cluster name" "k8s-cluster" "Ten logic cua cum. Dry-run se preview group_vars/all.yml va cau hinh kubeadm theo ten nay."
prompt_value_with_hint PROJECT_NAME "Project name" "$CLUSTER_NAME" "Ten du an day du. Anh huong toi app_user va metadata cua cum."
PROJECT_SHORT_NAME_DEFAULT=$(build_project_prefix "$PROJECT_NAME")
prompt_value_with_hint PROJECT_SHORT_NAME "Project short name" "$PROJECT_SHORT_NAME_DEFAULT" "Tien to hostname, vi du DMS4-Prod-K8s-Worker-01."
prompt_value_with_hint ENVIRONMENT_NAME "Environment name (e.g., Prod, Stag)" "Prod" "Moi truong trien khai. Anh huong truc tiep toi hostname va environment_name."
prompt_value_with_hint HOSTNAME_CLUSTER_NUMBER "Hostname cluster number (optional)" "" "Neu nhap so, hostname se co dang DMS4-Prod-K8s-Cluster1-Master-01. Bo trong de giu dang DMS4-Prod-K8s-Master-01."
prompt_value_with_hint MASTER_COUNT "Number of master nodes" "3" "So node control-plane duoc preview trong inventory [masters]."
prompt_value_with_hint WORKER_COUNT "Number of worker nodes" "6" "So node worker duoc preview trong inventory [workers]."

ensure_optional_positive_integer "$HOSTNAME_CLUSTER_NUMBER" "Hostname cluster number"
ensure_positive_integer "$MASTER_COUNT" "Number of master nodes"
ensure_positive_integer "$WORKER_COUNT" "Number of worker nodes"
collect_node_ips "Master" "Master" "$MASTER_COUNT" MASTER_IPS
collect_node_ips "Worker" "Worker" "$WORKER_COUNT" WORKER_IPS
IFS=',' read -r -a MASTER_IP_ARRAY <<< "$MASTER_IPS"
IFS=',' read -r -a WORKER_IP_ARRAY <<< "$WORKER_IPS"

echo
prompt_value_with_hint ANSIBLE_USER "SSH user" "root" "Tai khoan SSH de Ansible dang nhap vao tat ca node."
prompt_value_with_hint ANSIBLE_SSH_PRIVATE_KEY_FILE "SSH private key file (optional)" "" "De trong neu may hien tai da SSH duoc bang agent hoac ~/.ssh/config."

VIP_ENABLED="false"
VIP_ADDRESS=""
VIP_INTERFACE=""

if (( MASTER_COUNT > 1 )); then
    echo -e "\n${YELLOW}Multiple master nodes detected. High Availability recommended.${NC}"
    prompt_value_with_hint ENABLE_VIP "Enable VIP for Kubernetes API Server? (yes/no)" "yes" "Bat HA VIP cho kube-apiserver. Dry-run se preview them thong tin HAProxy/Keepalived."

    if [[ "$ENABLE_VIP" == "yes" || "$ENABLE_VIP" == "y" ]]; then
        VIP_ENABLED="true"
        prompt_value_with_hint VIP_ADDRESS "VIP address (e.g., 10.10.10.100)" "10.10.10.100" "Dia chi ao dung lam endpoint API Server cho cum HA."
        prompt_value_with_hint VIP_INTERFACE "Network interface for VIP (e.g., eth0)" "eth0" "Card mang tren cac master de gan VIP."

        if [[ -z "$VIP_ADDRESS" || -z "$VIP_INTERFACE" ]]; then
            fail "VIP address and interface are required when VIP is enabled."
        fi
    fi
fi

prompt_value_with_hint K8S_VERSION "Kubernetes version (e.g., 1.36.0)" "1.36.0" "Version dung de preview binary, image va tham so kubeadm."
prompt_value_with_hint POD_CIDR "Pod CIDR" "10.244.0.0/16" "Dai mang cap cho Pod. Anh huong toi networking/CNI."
prompt_value_with_hint SERVICE_CIDR "Service CIDR" "10.96.0.0/12" "Dai mang cap cho ClusterIP Service."
prompt_value_with_hint DATA_PARTITION_ROOT "K8s data partition root (optional)" "" "Neu nhap /u01/app, dry-run se preview containerd root, offline images va kubelet pod logs theo phan vung nay."

if [[ -n "$DATA_PARTITION_ROOT" ]]; then
    DATA_PARTITION_ROOT="${DATA_PARTITION_ROOT%/}"
    CONTAINERD_ROOT_DIR="${DATA_PARTITION_ROOT}/lib/containerd"
    OFFLINE_IMAGES_DIR="${DATA_PARTITION_ROOT}/lib/k8s-offline-images"
    KUBELET_POD_LOGS_DIR="${DATA_PARTITION_ROOT}/log/containerd"
else
    CONTAINERD_ROOT_DIR="/var/lib/containerd"
    OFFLINE_IMAGES_DIR="/var/lib/k8s-offline-images"
    KUBELET_POD_LOGS_DIR="kubelet default"
fi

log "Running shell syntax validation"
bash -n bootstrap.sh
bash -n scripts/generate-inventory.sh
bash -n dry-run.sh
success "Shell scripts passed syntax check"

TMP_DIR=$(mktemp -d /tmp/k8s-airgap-dry-run.XXXXXX)
SANDBOX_DIR="$TMP_DIR/workspace"

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$SANDBOX_DIR"
cp -R ansible.cfg bootstrap.sh playbooks roles scripts inventories group_vars "$SANDBOX_DIR"

log "Generating preview in isolated sandbox"
BOOTSTRAP_INPUT="$TMP_DIR/bootstrap-input.txt"

{
    printf '%s\n' "$CLUSTER_NAME"
    printf '%s\n' "$PROJECT_NAME"
    printf '%s\n' "$PROJECT_SHORT_NAME"
    printf '%s\n' "$ENVIRONMENT_NAME"
    printf '%s\n' "$HOSTNAME_CLUSTER_NUMBER"
    printf '%s\n' "$MASTER_COUNT"
    printf '%s\n' "$WORKER_COUNT"
    for ip in "${MASTER_IP_ARRAY[@]}"; do
        printf '%s\n' "$ip"
    done
    for ip in "${WORKER_IP_ARRAY[@]}"; do
        printf '%s\n' "$ip"
    done
    printf '%s\n' "$ANSIBLE_USER"
    printf '%s\n' "$ANSIBLE_SSH_PRIVATE_KEY_FILE"

    if (( MASTER_COUNT > 1 )); then
        if [[ "$VIP_ENABLED" == "true" ]]; then
            printf '%s\n' "yes"
            printf '%s\n' "$VIP_ADDRESS"
            printf '%s\n' "$VIP_INTERFACE"
        else
            printf '%s\n' "no"
        fi
    fi

    printf '%s\n' "$K8S_VERSION"
    printf '%s\n' "$POD_CIDR"
    printf '%s\n' "$SERVICE_CIDR"
    printf '%s\n' "$DATA_PARTITION_ROOT"
} > "$BOOTSTRAP_INPUT"

if ! (cd "$SANDBOX_DIR" && bash ./bootstrap.sh < "$BOOTSTRAP_INPUT" > "$TMP_DIR/bootstrap.log" 2>&1); then
    cat "$TMP_DIR/bootstrap.log"
    fail "Bootstrap preview failed in sandbox."
fi

GENERATED_INVENTORY="$SANDBOX_DIR/$DEFAULT_INVENTORY"
GENERATED_ALL_VARS="$SANDBOX_DIR/group_vars/all.yml"

APP_USER=$(awk -F'"' '/app_user:/ {print $2}' "$GENERATED_ALL_VARS")

section "Cluster Preview"
kv "cluster_name" "$CLUSTER_NAME"
kv "project_name" "$PROJECT_NAME"
kv "project_short_name" "$PROJECT_SHORT_NAME"
kv "environment_name" "$ENVIRONMENT_NAME"
kv "app_user" "$APP_USER"
kv "ssh_user" "$ANSIBLE_USER"
if [[ -n "$ANSIBLE_SSH_PRIVATE_KEY_FILE" ]]; then
    kv "ssh_key_file" "$ANSIBLE_SSH_PRIVATE_KEY_FILE"
else
    kv "ssh_key_file" "SSH default or agent"
fi
kv "kubernetes_version" "$K8S_VERSION"
kv "vip_enabled" "$VIP_ENABLED"
if [[ "$VIP_ENABLED" == "true" ]]; then
    kv "vip_address" "$VIP_ADDRESS"
    kv "vip_interface" "$VIP_INTERFACE"
fi
kv "cluster_cidr" "$POD_CIDR"
kv "service_cidr" "$SERVICE_CIDR"
kv "containerd_root_dir" "$CONTAINERD_ROOT_DIR"
kv "offline_images_dir" "$OFFLINE_IMAGES_DIR"
kv "kubelet_pod_logs_dir" "$KUBELET_POD_LOGS_DIR"
echo
echo -e "  ${BOLD}Server Hostnames${NC}"
print_node_summary "$GENERATED_INVENTORY"
section "Artifact Download Plan"
print_download_plan
success "Sandbox generation completed. No real file was modified."

section "Files That Would Change"
FILES_TO_COMPARE=(
    "inventories/inventory.ini"
    "group_vars/all.yml"
    "group_vars/masters.yml"
    "group_vars/workers.yml"
)

for relative_path in "${FILES_TO_COMPARE[@]}"; do
    CURRENT_FILE="$ROOT_DIR/$relative_path"
    GENERATED_FILE="$SANDBOX_DIR/$relative_path"
    PURPOSE=$(describe_file "$relative_path")

    if [[ ! -f "$CURRENT_FILE" ]]; then
        STATUS="would be created"
    elif cmp -s "$CURRENT_FILE" "$GENERATED_FILE"; then
        STATUS="no change"
    else
        STATUS="would be updated"
    fi

    echo
    case "$STATUS" in
        "would be created")
            echo -e "${GREEN}[CREATE]${NC} $relative_path"
            ;;
        "would be updated")
            echo -e "${YELLOW}[UPDATE]${NC} $relative_path"
            ;;
        *)
            echo -e "${BLUE}[NO CHANGE]${NC} $relative_path"
            ;;
    esac
    kv "purpose" "$PURPOSE"

    if [[ "$STATUS" != "no change" ]]; then
        print_diff "$CURRENT_FILE" "$GENERATED_FILE"
    fi
done

if ! command -v ansible-playbook >/dev/null 2>&1; then
    warn "ansible-playbook is not installed. Skipping Ansible validation."
    exit 0
fi

section "Validation"
log "Running ansible-playbook validation in '$MODE' mode"

if [[ "$MODE" == "syntax" ]]; then
    (cd "$SANDBOX_DIR" && ansible-playbook -i "$DEFAULT_INVENTORY" --syntax-check "$PLAYBOOK")
else
    if [[ -z "$INVENTORY_OVERRIDE" ]]; then
        if [[ -f "$ROOT_DIR/$DEFAULT_INVENTORY" ]]; then
            INVENTORY_OVERRIDE="$ROOT_DIR/$DEFAULT_INVENTORY"
        else
            warn "Check mode needs a real inventory with reachable hosts. Use --inventory <path>."
            exit 0
        fi
    fi

    [[ -f "$INVENTORY_OVERRIDE" ]] || fail "Inventory not found: $INVENTORY_OVERRIDE"
    warn "Check mode still needs SSH access to target hosts and may not fully simulate command-based tasks."
    ansible-playbook -i "$INVENTORY_OVERRIDE" --check --diff "$PLAYBOOK"
fi

success "Ansible validation completed"
