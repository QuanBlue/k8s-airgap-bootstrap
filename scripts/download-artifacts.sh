#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Configuration
K8S_VERSION="${K8S_VERSION:-1.36.0}"
CALICO_VERSION="${CALICO_VERSION:-v3.32.0}"

ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT_DIR/artifacts}"
IMAGES_DIR="$ARTIFACTS_DIR/images"
MANIFESTS_DIR="$ARTIFACTS_DIR/manifests"

echo "Creating artifact directories..."
mkdir -p "$IMAGES_DIR" "$MANIFESTS_DIR"

echo "Downloading installer binaries and offline packages..."
"$ROOT_DIR/scripts/download-installers.sh"

# 2. Download Manifests
echo "Downloading manifests..."
curl -fL --retry 3 --retry-delay 2 \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" \
    -o "$MANIFESTS_DIR/calico.yaml"

# 3. Download Container Images
echo "Downloading and saving container images..."

# Function to pull and save image
pull_and_save() {
    local img=$1
    local name=$(echo $img | awk -F'/' '{print $NF}' | tr ':' '-')
    echo "Pulling $img..."
    docker pull $img
    echo "Saving to ${name}.tar..."
    docker save $img -o "$IMAGES_DIR/${name}.tar"
}

# K8s control plane images
KUBE_IMAGES=$(kubeadm config images list --kubernetes-version v${K8S_VERSION})
for img in $KUBE_IMAGES; do
    pull_and_save "$img"
done

# Calico images (extracting from manifest)
CALICO_IMAGES=$(grep 'image:' "$MANIFESTS_DIR/calico.yaml" | awk '{print $2}' | sed 's/"//g' | sort -u)
for img in $CALICO_IMAGES; do
    pull_and_save "$img"
done

echo "Artifact download complete! Artifacts saved in $ARTIFACTS_DIR"
