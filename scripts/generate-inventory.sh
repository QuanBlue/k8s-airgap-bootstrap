#!/usr/bin/env bash
set -e

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --environment-name) ENVIRONMENT_NAME="$2"; shift ;;
        --hostname-cluster-number) HOSTNAME_CLUSTER_NUMBER="$2"; shift ;;
        --master-count) MASTER_COUNT="$2"; shift ;;
        --master-ips) MASTER_IPS="$2"; shift ;;
        --worker-count) WORKER_COUNT="$2"; shift ;;
        --worker-ips) WORKER_IPS="$2"; shift ;;
        --project-name) PROJECT_NAME="$2"; shift ;;
        --project-short-name) PROJECT_SHORT_NAME="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

INVENTORY_FILE="inventories/inventory.ini"
ENVIRONMENT_NAME=${ENVIRONMENT_NAME:-Prod}
PROJECT_NAME=${PROJECT_NAME:-k8s-cluster}

# Ensure directory exists
mkdir -p inventories

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

PROJECT_SHORT_NAME=${PROJECT_SHORT_NAME:-$(build_project_prefix "$PROJECT_NAME")}
IFS=',' read -r -a MASTER_IP_ARRAY <<< "${MASTER_IPS:-}"
IFS=',' read -r -a WORKER_IP_ARRAY <<< "${WORKER_IPS:-}"

format_hostname() {
    local node_role="$1"
    local index="$2"
    local role_segment="K8s"

    if [[ -n "${HOSTNAME_CLUSTER_NUMBER:-}" ]]; then
        role_segment="${role_segment}-Cluster${HOSTNAME_CLUSTER_NUMBER}"
    fi

    printf '%s-%s-%s-%s-%02d' "$PROJECT_SHORT_NAME" "$ENVIRONMENT_NAME" "$role_segment" "$node_role" "$index"
}

# Start generating inventory
cat <<EOF > "$INVENTORY_FILE"
[masters]
EOF

for ((i=1; i<=MASTER_COUNT; i++)); do
    master_ip="${MASTER_IP_ARRAY[$((i-1))]:-10.10.10.1${i}}"
    echo "$(format_hostname "Master" "$i") ansible_host=${master_ip}" >> "$INVENTORY_FILE"
done

cat <<EOF >> "$INVENTORY_FILE"

[workers]
EOF

for ((i=1; i<=WORKER_COUNT; i++)); do
    worker_ip="${WORKER_IP_ARRAY[$((i-1))]:-10.10.10.2${i}}"
    echo "$(format_hostname "Worker" "$i") ansible_host=${worker_ip}" >> "$INVENTORY_FILE"
done

cat <<EOF >> "$INVENTORY_FILE"

[k8s_cluster:children]
masters
workers

[all:vars]
ansible_user=root # REPLACE WITH YOUR SSH USER
ansible_ssh_private_key_file=~/.ssh/id_rsa # REPLACE WITH YOUR KEY
project_name=${PROJECT_NAME}
project_short_name=${PROJECT_SHORT_NAME}
environment_name=${ENVIRONMENT_NAME}
EOF

echo "Inventory generated at $INVENTORY_FILE"
