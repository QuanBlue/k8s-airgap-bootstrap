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

# ─── CLI ──────────────────────────────────────────────────────────────────────
usage() {
    echo -e "${BOLD}usage:${NC} ${CYAN}bootstrap.sh${NC} [${GREEN}-h${NC}] [${GREEN}--rollback${NC}]"
    echo
    echo "Interactive wizard that generates Ansible inventory and group_vars for the airgap"
    echo "Kubernetes cluster. Previous versions of generated files are snapshotted to"
    echo -e "${DIM}.bootstrap-backups/<timestamp>/${NC} before being overwritten."
    echo
    echo -e "${BOLD}options:${NC}"
    echo -e "  ${GREEN}-h${NC}, ${GREEN}--help${NC}            show this help message and exit"
    echo -e "  ${GREEN}--rollback${NC}            restore the latest snapshot, undoing the most recent"
    echo -e "                        wizard run; no prompts and does not touch any cluster"
    echo -e "                        state"
}

MODE="wizard"
case "${1:-}" in
    "")             MODE="wizard" ;;
    --rollback)     MODE="rollback" ;;
    -h|--help)      usage; exit 0 ;;
    *)              echo "Unknown argument: $1" >&2; usage; exit 1 ;;
esac

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

ask_inline_non_negative_integer() {
    local var_name="$1"
    local label="$2"
    local default_value="$3"
    local prompt_value=""

    while true; do
        ask_inline prompt_value "$label" "$default_value"
        if [[ "$prompt_value" =~ ^[0-9]+$ ]]; then
            printf -v "$var_name" '%s' "$prompt_value"
            return
        fi
        echo -e "  ${YELLOW}✗  ${label} phải là số nguyên không âm. Vui lòng nhập lại.${NC}"
    done
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

ensure_non_negative_integer() {
    local value="$1" label="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        err "${label} phải là số nguyên không âm."
    fi
}

ensure_ipv4() {
    local value="$1" label="$2"
    if ! [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        err "${label}: '${value}' không phải IPv4 hợp lệ."
    fi
}

ensure_cidr() {
    local value="$1" label="$2"
    if ! [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]; then
        err "${label}: '${value}' không phải CIDR IPv4 hợp lệ."
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

collect_ip_list() {
    local list_label="$1"
    local count="$2"
    local __result_var="$3"
    local collected_ips=()
    local item_ip
    local default_ip="10.0.0.10"

    if [[ "$count" -eq 0 ]]; then
        printf -v "$__result_var" '%s' ""
        return
    fi

    echo -e "  ${BOLD}${BLUE}▸ ${list_label}${NC}"
    divider
    for ((i=1; i<=count; i++)); do
        ask_inline item_ip "${list_label} ${i}" "$default_ip"
        ensure_ipv4 "$item_ip" "${list_label} ${i}"
        collected_ips+=("$item_ip")
    done

    printf -v "$__result_var" '%s' "$(IFS=,; echo "${collected_ips[*]}")"
}

collect_ip_list_with_defaults() {
    local list_label="$1"
    local count="$2"
    local defaults_csv="$3"
    local __result_var="$4"
    local collected_ips=()
    local default_ips=()
    local item_ip default_ip

    if [[ "$count" -eq 0 ]]; then
        printf -v "$__result_var" '%s' ""
        return
    fi

    IFS=',' read -r -a default_ips <<< "$defaults_csv"

    echo -e "  ${BOLD}${BLUE}▸ ${list_label}${NC}"
    divider
    for ((i=1; i<=count; i++)); do
        default_ip="${default_ips[$((i-1))]:-10.0.0.10}"
        ask_inline item_ip "${list_label} ${i}" "$default_ip"
        ensure_ipv4 "$item_ip" "${list_label} ${i}"
        collected_ips+=("$item_ip")
    done

    printf -v "$__result_var" '%s' "$(IFS=,; echo "${collected_ips[*]}")"
}

csv_to_yaml_inline_list() {
    local csv="$1"
    local output=""
    local item

    if [[ -z "$csv" ]]; then
        echo "[]"
        return
    fi

    IFS=',' read -r -a _items <<< "$csv"
    for item in "${_items[@]}"; do
        if [[ -n "$output" ]]; then
            output+=", "
        fi
        output+="\"$item\""
    done
    echo "[$output]"
}

csv_to_bash_array() {
    local csv="$1"
    local output=""
    local item

    if [[ -z "$csv" ]]; then
        echo "()"
        return
    fi

    IFS=',' read -r -a _items <<< "$csv"
    for item in "${_items[@]}"; do
        output+=" \"$item\""
    done
    echo "(${output# })"
}

render_iptables_scripts() {
    local worker_script="scripts/servers/iptables/k8s-worker-iptables-rules.sh"
    local master_script="scripts/servers/iptables/k8s-master-iptables-rules.sh"
    local master_vip_value=""
    local worker_vip_value=""
    local haproxy_8443_allow_array=""
    local prometheus_scraper_array=""
    local teleport_proxy_array=""
    local ntp_server_array=""
    local soc_nsm_array=""
    local soc_forwarder_array=""
    local mongodb_array=""
    local mariadb_array=""
    local dorisdb_array=""
    local begin_marker="# BEGIN BOOTSTRAP VALUES"
    local end_marker="# END BOOTSTRAP VALUES"
    local master_values_file=""
    local worker_values_file=""

    mkdir -p "scripts/servers/iptables"

    if [[ "$VIP_ENABLED" == "true" ]]; then
        master_vip_value="$VIP_ADDRESS"
    fi

    if [[ "$WORKER_HA_ENABLED" == "true" ]]; then
        worker_vip_value="$WORKER_HA_ADDRESS"
    fi

    prometheus_scraper_array=$(csv_to_bash_array "$PROMETHEUS_SCRAPER_IPS")
    haproxy_8443_allow_array=$(csv_to_bash_array "$HAPROXY_8443_ALLOW_IPS")
    teleport_proxy_array=$(csv_to_bash_array "$TELEPORT_PROXY_IPS")
    ntp_server_array=$(csv_to_bash_array "$NTP_SERVER_IPS")
    soc_nsm_array=$(csv_to_bash_array "$SOC_NSM_IPS")
    soc_forwarder_array=$(csv_to_bash_array "$SOC_FORWARDER_IPS")
    mongodb_array=$(csv_to_bash_array "$MONGODB_IPS")
    mariadb_array=$(csv_to_bash_array "$MARIADB_IPS")
    dorisdb_array=$(csv_to_bash_array "$DORISDB_IPS")

    write_master_iptables_values() {
        cat <<EOF
NODE_CIDR="$NODE_CIDR"
POD_CIDR="$POD_CIDR"
SVC_CIDR="$SERVICE_CIDR"
MASTER_VIP="$master_vip_value"
WORKER_VIP="$worker_vip_value"
HAPROXY_8443_ALLOW_IPS=$haproxy_8443_allow_array
PROMETHEUS_SCRAPER_IPS=$prometheus_scraper_array
TELEPORT_PROXY_IPS=$teleport_proxy_array
NTP_SERVER_IPS=$ntp_server_array
SOC_NSM_IPS=$soc_nsm_array
SOC_FORWARDER_IPS=$soc_forwarder_array
EOF
    }

    write_worker_iptables_values() {
        cat <<EOF
NODE_CIDR="$NODE_CIDR"
POD_CIDR="$POD_CIDR"
SVC_CIDR="$SERVICE_CIDR"
MASTER_VIP="$master_vip_value"
WORKER_VIP="$worker_vip_value"
MONGODB_IPS=$mongodb_array
MARIADB_IPS=$mariadb_array
DORISDB_IPS=$dorisdb_array
PROMETHEUS_SCRAPER_IPS=$prometheus_scraper_array
TELEPORT_PROXY_IPS=$teleport_proxy_array
NTP_SERVER_IPS=$ntp_server_array
SOC_NSM_IPS=$soc_nsm_array
SOC_FORWARDER_IPS=$soc_forwarder_array
EOF
    }

    replace_managed_block() {
        local target_file="$1"
        local replacement_file="$2"
        local tmp_file

        [[ -f "$target_file" ]] || err "Missing firewall source-of-truth script: $target_file"
        grep -qF "$begin_marker" "$target_file" || err "Missing begin marker in $target_file"
        grep -qF "$end_marker" "$target_file" || err "Missing end marker in $target_file"

        tmp_file=$(mktemp)
        awk \
            -v begin="$begin_marker" \
            -v end="$end_marker" \
            -v replacement="$replacement_file" '
                BEGIN {
                    while ((getline line < replacement) > 0) {
                        replacement_lines[++replacement_count] = line
                    }
                    close(replacement)
                }
                $0 == begin {
                    print
                    for (i = 1; i <= replacement_count; i++) {
                        print replacement_lines[i]
                    }
                    in_block = 1
                    next
                }
                $0 == end {
                    in_block = 0
                    print
                    next
                }
                !in_block {
                    print
                }
            ' "$target_file" > "$tmp_file"
        mv "$tmp_file" "$target_file"
    }

    master_values_file=$(mktemp)
    worker_values_file=$(mktemp)
    trap 'rm -f "$master_values_file" "$worker_values_file"' RETURN

    write_master_iptables_values > "$master_values_file"
    write_worker_iptables_values > "$worker_values_file"

    replace_managed_block "$master_script" "$master_values_file"
    replace_managed_block "$worker_script" "$worker_values_file"

    chmod 0755 "$master_script" "$worker_script"
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

# ─── Rollback helpers ─────────────────────────────────────────────────────────
rollback_log()     { echo -e "${BLUE}INFO${NC} $1"; }
rollback_success() { echo -e "${GREEN}PASS${NC} $1"; }
rollback_fail()    { echo -e "${RED}FAIL${NC} $1"; exit 1; }

latest_backup_dir() {
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1
}

restore_from_backup() {
    local backup_dir="$1"
    local manifest_file="$backup_dir/manifest.txt"

    [[ -f "$manifest_file" ]] || rollback_fail "Backup manifest not found: $manifest_file"

    while IFS='|' read -r relative_path entry_type; do
        [[ -n "$relative_path" ]] || continue
        if [[ "$entry_type" == "file" ]]; then
            mkdir -p "$(dirname "$relative_path")"
            cp "$backup_dir/$relative_path" "$relative_path"
            echo -e "${GREEN}RESTORE${NC} $relative_path"
        else
            rm -f "$relative_path"
            echo -e "${YELLOW}REMOVE${NC}  $relative_path"
        fi
    done < "$manifest_file"
}

run_rollback() {
    echo
    echo -e "${BOLD}${CYAN}========================================${NC}"
    echo -e "${BOLD}${CYAN}Bootstrap Rollback${NC}"
    echo -e "${BOLD}${CYAN}========================================${NC}"

    [[ -d "$BACKUP_ROOT" ]] || rollback_fail "No bootstrap backup directory found. Nothing to rollback."

    local latest
    latest=$(latest_backup_dir)
    [[ -n "$latest" ]] || rollback_fail "No bootstrap backup found. Nothing to rollback."

    rollback_log "Rolling back bootstrap changes from $(basename "$latest")"
    restore_from_backup "$latest"
    rollback_success "Bootstrap rollback completed. Repository files are back to the state before the latest bootstrap run."
}

# ═══════════════════════════════════════════════════════════════════════════════

if [[ "$MODE" == "rollback" ]]; then
    run_rollback
    exit 0
fi

# ─── Wizard ───────────────────────────────────────────────────────────────────

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
WORKER_HA_ENABLED="false"
WORKER_HA_ADDRESS=""
WORKER_HA_INTERFACE=""
HAS_PROMETHEUS="true"
PROMETHEUS_SCRAPER_IPS="10.129.0.158,10.129.0.159,10.129.0.160,10.129.0.163,10.129.0.164,10.129.0.165"
DEFAULT_PROMETHEUS_SCRAPER_IPS="$PROMETHEUS_SCRAPER_IPS"
HAS_TELEPORT="true"
TELEPORT_PROXY_IPS="10.129.0.232"
DEFAULT_TELEPORT_PROXY_IPS="$TELEPORT_PROXY_IPS"
HAS_NTP_SERVERS="false"
NTP_SERVER_IPS=""
HAS_SOC="false"
SOC_NSM_IPS=""
SOC_FORWARDER_IPS=""
HAS_EXTERNAL_DB="false"
MONGODB_IPS=""
MARIADB_IPS=""
DORISDB_IPS=""
HAPROXY_8443_ALLOW_IPS=""

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

if [ "$WORKER_COUNT" -gt 0 ]; then
    ask ENABLE_WORKER_HA "Enable worker VIP?" "no" \
        "Bật VIP riêng cho ingress/application traffic trên nhóm worker.\n    Keepalived + HAProxy sẽ chạy trên mọi worker và mở ${BOLD}80/443${NC}." \
        "(yes/no)"

    if [[ "$ENABLE_WORKER_HA" == "yes" || "$ENABLE_WORKER_HA" == "y" ]]; then
        WORKER_HA_ENABLED="true"

        ask WORKER_HA_ADDRESS "Worker VIP address" "10.0.6.200" \
            "Địa chỉ ảo ingress nằm trên nhóm worker, tách biệt với VIP của master."

        ask WORKER_HA_INTERFACE "Worker VIP interface" "eth0" \
            "Card mạng trên các worker sẽ gán worker VIP."

        if [[ -z "$WORKER_HA_ADDRESS" || -z "$WORKER_HA_INTERFACE" ]]; then
            err "Worker VIP address và interface là bắt buộc khi bật worker VIP."
        fi
    fi
fi

# ─── 5 / 5  Cluster Network ───────────────────────────────────────────────────
section "Cluster Network"

ask_inline K8S_VERSION "Kubernetes version" "1.36.0";
ask_inline POD_CIDR     "Pod CIDR"           "10.244.0.0/16";
ask_inline SERVICE_CIDR "Service CIDR"       "10.96.0.0/12"; 
ask_inline NODE_CIDR    "Node CIDR"          "10.0.6.0/24";
echo

ensure_cidr "$NODE_CIDR" "Node CIDR"

ask CALICO_IP_AUTODETECTION "Calico IP autodetection" "first-found" \
    "Cách Calico chọn IP node khi có nhiều interface.\n    · interface=eth0       — chỉ định tên interface\n    · cidr=10.129.0.0/16   — chọn interface có IP thuộc dải này  ← khuyên dùng\n    · first-found          — lấy interface đầu tiên (dễ chọn sai)"

ask DATA_PARTITION_ROOT "Data partition root" "" \
    "Phân vùng riêng để chứa dữ liệu K8s. Ví dụ nhập /u01/app:\n      · /u01/app/lib/containerd        — containerd root dir\n      · /u01/app/lib/k8s-offline-images — offline image store\n      · /u01/app/log/containerd        — kubelet pod logs\n    Để trống → dùng mặc định: /var/lib/containerd, /var/lib/k8s-offline-images" \
    "(optional)"

ask ENABLE_FIREWALL "Configure host firewall (iptables)?" "yes" \
    "Bảo vệ port control-plane/etcd/kubelet bằng iptables.\n    · 6443 (API) chỉ truy cập từ trong cụm — quản trị ngoài qua HAProxy ${VIP_ADDRESS:-VIP}:8443\n    · SSH (22), NodePort vẫn mở\n    Tắt nếu firewall do hạ tầng/Cloud SG đảm nhiệm." \
    "(yes/no)"

if [[ "$ENABLE_FIREWALL" == "yes" || "$ENABLE_FIREWALL" == "y" ]]; then
    FIREWALL_ENABLED="true"
else
    FIREWALL_ENABLED="false"
fi

if [[ "$FIREWALL_ENABLED" == "true" ]]; then
    ask RESTRICT_HAPROXY_8443_PROMPT "Restrict external access to HAProxy public 8443 by IP?" "no" \
        "Nếu trả lời yes, wizard sẽ render allowlist inbound TCP 8443 trên master chỉ cho các external IP đã nhập.\n    Dù chọn no hay để danh sách rỗng, 8443 vẫn chỉ cho node trong cụm và các IP được allow rõ ràng truy cập, không mở all." \
        "(yes/no)"

    if [[ "$RESTRICT_HAPROXY_8443_PROMPT" == "yes" || "$RESTRICT_HAPROXY_8443_PROMPT" == "y" ]]; then
        ask_inline_non_negative_integer HAPROXY_8443_ALLOW_COUNT "Number of Allowed external IPs for HAProxy (8443)" "1"
        echo
        collect_ip_list "Allowed external IP for 8443" "$HAPROXY_8443_ALLOW_COUNT" HAPROXY_8443_ALLOW_IPS
        echo
    else
        HAPROXY_8443_ALLOW_IPS=""
    fi
else
    HAPROXY_8443_ALLOW_IPS=""
fi

ask HAS_PROMETHEUS_PROMPT "Has Prometheus scrapers?" "yes" \
    "Nếu có Prometheus ngoài cụm scrape node, wizard sẽ render allowlist inbound TCP 9000:9300.\n    Mặc định dùng các IP Prometheus chuẩn hiện tại: ${PROMETHEUS_SCRAPER_IPS}." \
    "(yes/no)"

if [[ "$HAS_PROMETHEUS_PROMPT" == "yes" || "$HAS_PROMETHEUS_PROMPT" == "y" ]]; then
    HAS_PROMETHEUS="true"

    ask_inline PROMETHEUS_SCRAPER_COUNT "Prometheus scrapers" "6"
    ensure_non_negative_integer "$PROMETHEUS_SCRAPER_COUNT" "Prometheus scrapers"
    echo
    collect_ip_list_with_defaults "Prometheus scraper IP" "$PROMETHEUS_SCRAPER_COUNT" "$DEFAULT_PROMETHEUS_SCRAPER_IPS" PROMETHEUS_SCRAPER_IPS
    echo

    if [[ -z "$PROMETHEUS_SCRAPER_IPS" ]]; then
        HAS_PROMETHEUS="false"
    fi
else
    HAS_PROMETHEUS="false"
    PROMETHEUS_SCRAPER_IPS=""
fi

ask HAS_TELEPORT_PROMPT "Has Teleport?" "yes" \
    "Nếu node chạy Teleport agent/client, wizard sẽ hỏi IP Teleport Proxy/Auth ngoài cụm.\n    Mặc định dùng ${TELEPORT_PROXY_IPS}, rule outbound TCP cố định là 443/3080/3024." \
    "(yes/no)"

if [[ "$HAS_TELEPORT_PROMPT" == "yes" || "$HAS_TELEPORT_PROMPT" == "y" ]]; then
    HAS_TELEPORT="true"

    ask_inline TELEPORT_PROXY_COUNT "Teleport Proxy/Auth servers" "1"
    ensure_non_negative_integer "$TELEPORT_PROXY_COUNT" "Teleport Proxy/Auth servers"
    echo
    collect_ip_list_with_defaults "Teleport Proxy/Auth IP" "$TELEPORT_PROXY_COUNT" "$DEFAULT_TELEPORT_PROXY_IPS" TELEPORT_PROXY_IPS
    echo

    if [[ -z "$TELEPORT_PROXY_IPS" ]]; then
        HAS_TELEPORT="false"
    fi
else
    TELEPORT_PROXY_IPS=""
fi

ask HAS_NTP_PROMPT "Use fixed NTP servers?" "no" \
    "Nếu muốn siết NTP egress, wizard sẽ hỏi IP NTP server và chỉ allow UDP 123 tới các IP đó.\n    Trả lời no để giữ fallback DNS/NTP outbound hiện tại." \
    "(yes/no)"

if [[ "$HAS_NTP_PROMPT" == "yes" || "$HAS_NTP_PROMPT" == "y" ]]; then
    HAS_NTP_SERVERS="true"

    ask_inline NTP_SERVER_COUNT "NTP servers" "1"
    ensure_non_negative_integer "$NTP_SERVER_COUNT" "NTP servers"
    echo
    collect_ip_list "NTP server IP" "$NTP_SERVER_COUNT" NTP_SERVER_IPS
    echo

    if [[ -z "$NTP_SERVER_IPS" ]]; then
        HAS_NTP_SERVERS="false"
    fi
fi

ask HAS_SOC_PROMPT "Has SOC?" "no" \
    "Nếu có hệ SOC ngoài cụm, wizard sẽ hỏi IP cho SOC NSM và SOC Forwarder.\n    Mỗi IP sẽ được render thành rule outbound riêng trong script iptables." \
    "(yes/no)"

if [[ "$HAS_SOC_PROMPT" == "yes" || "$HAS_SOC_PROMPT" == "y" ]]; then
    HAS_SOC="true"

    ask_inline SOC_NSM_COUNT "Number of SOC NSM servers" "1"
    ensure_non_negative_integer "$SOC_NSM_COUNT" "SOC NSM servers"
    echo
    collect_ip_list "SOC NSM IP" "$SOC_NSM_COUNT" SOC_NSM_IPS
    echo

    ask_inline SOC_FORWARDER_COUNT "Number of SOC Forwarders" "1"
    ensure_non_negative_integer "$SOC_FORWARDER_COUNT" "SOC Forwarders"
    echo
    collect_ip_list "SOC Forwarder IP" "$SOC_FORWARDER_COUNT" SOC_FORWARDER_IPS
    echo

    if [[ -z "$SOC_NSM_IPS" && -z "$SOC_FORWARDER_IPS" ]]; then
        HAS_SOC="false"
    fi
fi

ask HAS_EXTERNAL_DB_PROMPT "Has DB connection?" "no" \
    "Nếu worker cần đi ra DB ngoài cụm, wizard sẽ hỏi số lượng và IP theo từng loại: MongoDB, MariaDB, DorisDB." \
    "(yes/no)"

if [[ "$HAS_EXTERNAL_DB_PROMPT" == "yes" || "$HAS_EXTERNAL_DB_PROMPT" == "y" ]]; then
    HAS_EXTERNAL_DB="true"

    ask_inline MONGODB_COUNT "Number of ongoDB servers" "1"
    ensure_non_negative_integer "$MONGODB_COUNT" "MongoDB servers"
    echo
    collect_ip_list "MongoDB IP" "$MONGODB_COUNT" MONGODB_IPS
    echo

    ask_inline MARIADB_COUNT "Number of MariaDB servers" "1"
    ensure_non_negative_integer "$MARIADB_COUNT" "MariaDB servers"
    echo
    collect_ip_list "MariaDB IP" "$MARIADB_COUNT" MARIADB_IPS
    echo

    ask_inline DORISDB_COUNT "Number of DorisDB servers" "1"
    ensure_non_negative_integer "$DORISDB_COUNT" "DorisDB servers"
    echo
    collect_ip_list "DorisDB IP" "$DORISDB_COUNT" DORISDB_IPS
    echo

    if [[ -z "$MONGODB_IPS" && -z "$MARIADB_IPS" && -z "$DORISDB_IPS" ]]; then
        HAS_EXTERNAL_DB="false"
    fi
fi

if [[ -n "$DATA_PARTITION_ROOT" ]]; then
    DATA_PARTITION_ROOT="${DATA_PARTITION_ROOT%/}"
    CONTAINERD_ROOT_DIR="${DATA_PARTITION_ROOT}/lib/containerd"
    OFFLINE_IMAGES_DIR="${DATA_PARTITION_ROOT}/lib/k8s-offline-images"
    KUBELET_POD_LOGS_DIR="${DATA_PARTITION_ROOT}/log/containerd"
    AUDIT_LOG_DIR="${DATA_PARTITION_ROOT}/log/kubernetes/audit"
    BACKUP_SCRIPTS_DIR="${DATA_PARTITION_ROOT}/scripts/backup"
    BACKUP_DEST_ROOT="${DATA_PARTITION_ROOT}/backup"
    FIREWALL_SCRIPTS_DIR="${DATA_PARTITION_ROOT}/scripts/iptables"
else
    CONTAINERD_ROOT_DIR="/var/lib/containerd"
    OFFLINE_IMAGES_DIR="/var/lib/k8s-offline-images"
    KUBELET_POD_LOGS_DIR=""
    AUDIT_LOG_DIR="/var/log/kubernetes/audit"
    BACKUP_SCRIPTS_DIR="/opt/k8s-backup/scripts/backup"
    BACKUP_DEST_ROOT="/var/backups/k8s"
    FIREWALL_SCRIPTS_DIR="/opt/k8s-firewall/scripts/iptables"
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

SOC_NSM_YAML=$(csv_to_yaml_inline_list "$SOC_NSM_IPS")
SOC_FORWARDER_YAML=$(csv_to_yaml_inline_list "$SOC_FORWARDER_IPS")
PROMETHEUS_SCRAPER_YAML=$(csv_to_yaml_inline_list "$PROMETHEUS_SCRAPER_IPS")
TELEPORT_PROXY_YAML=$(csv_to_yaml_inline_list "$TELEPORT_PROXY_IPS")
NTP_SERVER_YAML=$(csv_to_yaml_inline_list "$NTP_SERVER_IPS")
MONGODB_YAML=$(csv_to_yaml_inline_list "$MONGODB_IPS")
MARIADB_YAML=$(csv_to_yaml_inline_list "$MARIADB_IPS")
DORISDB_YAML=$(csv_to_yaml_inline_list "$DORISDB_IPS")
HAPROXY_8443_ALLOW_YAML=$(csv_to_yaml_inline_list "$HAPROXY_8443_ALLOW_IPS")

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
  node_cidr: "$NODE_CIDR"
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
master_ha:
  enabled: $VIP_ENABLED
  vip_address: "$VIP_ADDRESS"
  vip_interface: "$VIP_INTERFACE"
  vip_port: 8443

worker_ha:
  enabled: $WORKER_HA_ENABLED
  vip_address: "$WORKER_HA_ADDRESS"
  vip_interface: "$WORKER_HA_INTERFACE"
  http_port: 80
  https_port: 443
  backend_http_port: 30080
  backend_https_port: 30443

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

# Backup: etcd snapshot (masters) + k8s config (all nodes), cron lúc 23:55
backup:
  enabled: true
  scripts_dir: "$BACKUP_SCRIPTS_DIR"
  dest_root: "$BACKUP_DEST_ROOT"
  retention_days: 90
  schedule:
    minute: 55
    hour: 23

# Host firewall (iptables) — bảo vệ port control-plane/etcd/kubelet
firewall:
  enabled: $FIREWALL_ENABLED
  scripts_dir: "$FIREWALL_SCRIPTS_DIR"
  nodeport_open: true
  admin_cidrs: []
  haproxy_8443_allow_ips: $HAPROXY_8443_ALLOW_YAML

external_services:
  prometheus:
    enabled: $HAS_PROMETHEUS
    scraper_ips: $PROMETHEUS_SCRAPER_YAML
  teleport:
    enabled: $HAS_TELEPORT
    proxy_ips: $TELEPORT_PROXY_YAML
  ntp:
    enabled: $HAS_NTP_SERVERS
    server_ips: $NTP_SERVER_YAML
  soc:
    enabled: $HAS_SOC
    nsm_ips: $SOC_NSM_YAML
    forwarder_ips: $SOC_FORWARDER_YAML

external_databases:
  enabled: $HAS_EXTERNAL_DB
  mongodb_ips: $MONGODB_YAML
  mariadb_ips: $MARIADB_YAML
  dorisdb_ips: $DORISDB_YAML
EOF

cat <<EOF > inventories/group_vars/masters.yml
---
node_role: master
EOF

cat <<EOF > inventories/group_vars/workers.yml
---
node_role: worker
EOF

render_iptables_scripts

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
