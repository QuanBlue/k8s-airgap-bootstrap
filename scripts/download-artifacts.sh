#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT_DIR/artifacts}"
BIN_DIR="$ARTIFACTS_DIR/bin"
PKGS_DIR="$ARTIFACTS_DIR/packages"
IMAGES_DIR="$ARTIFACTS_DIR/images"
MANIFESTS_DIR="$ARTIFACTS_DIR/manifests"
MANIFEST_FILE="$MANIFESTS_DIR/installers-manifest.txt"

K8S_VERSION="${K8S_VERSION:-1.36.0}"
CALICO_VERSION="${CALICO_VERSION:-v3.32.0}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.3.1}"
RUNC_VERSION="${RUNC_VERSION:-1.4.0}"
CRICTL_VERSION="${CRICTL_VERSION:-v1.36.0}"
HELM_VERSION="${HELM_VERSION:-3.20.1}"
K9S_VERSION="${K9S_VERSION:-v0.50.18}"
IMAGE_PLATFORM="${IMAGE_PLATFORM:-linux/amd64}"

mkdir -p "$BIN_DIR" "$PKGS_DIR" "$IMAGES_DIR" "$MANIFESTS_DIR"

TMP_DIR=$(mktemp -d /tmp/k8s-artifacts.XXXXXX)
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log() {
    printf '[download-artifacts] %s\n' "$1"
}

download_file() {
    local url="$1"
    local destination="$2"

    log "Downloading $(basename "$destination")"
    curl -fL --retry 3 --retry-delay 2 "$url" -o "$destination"
}

extract_tar_entry() {
    local archive_file="$1"
    local entry_name="$2"
    local destination="$3"

    tar -xzf "$archive_file" -C "$TMP_DIR"
    cp "$TMP_DIR/$entry_name" "$destination"
    chmod 0755 "$destination"
    rm -rf "$TMP_DIR"/*
}

download_binary_bundle() {
    download_file \
        "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz" \
        "$BIN_DIR/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"

    download_file \
        "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64" \
        "$BIN_DIR/runc.amd64"
    chmod 0755 "$BIN_DIR/runc.amd64"

    download_file \
        "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" \
        "$BIN_DIR/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"

    download_file \
        "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" \
        "$TMP_DIR/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
    extract_tar_entry "$TMP_DIR/helm-v${HELM_VERSION}-linux-amd64.tar.gz" "linux-amd64/helm" "$BIN_DIR/helm"

    download_file \
        "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz" \
        "$TMP_DIR/k9s_Linux_amd64.tar.gz"
    extract_tar_entry "$TMP_DIR/k9s_Linux_amd64.tar.gz" "k9s" "$BIN_DIR/k9s"

    download_file \
        "https://dl.k8s.io/release/v${K8S_VERSION}/bin/linux/amd64/kubeadm" \
        "$BIN_DIR/kubeadm"
    chmod 0755 "$BIN_DIR/kubeadm"

    download_file \
        "https://dl.k8s.io/release/v${K8S_VERSION}/bin/linux/amd64/kubelet" \
        "$BIN_DIR/kubelet"
    chmod 0755 "$BIN_DIR/kubelet"

    download_file \
        "https://dl.k8s.io/release/v${K8S_VERSION}/bin/linux/amd64/kubectl" \
        "$BIN_DIR/kubectl"
    chmod 0755 "$BIN_DIR/kubectl"
}

download_rpm_packages() {
    local downloader=""

    if command -v yumdownloader >/dev/null 2>&1; then
        downloader="yumdownloader"
    elif command -v dnf >/dev/null 2>&1; then
        downloader="dnf download"
    else
        log "Skipping RPM packages because neither yumdownloader nor dnf is available."
        return 0
    fi

    log "Downloading offline RPM packages into $PKGS_DIR"

    if [[ "$downloader" == "yumdownloader" ]]; then
        yumdownloader --resolve --destdir "$PKGS_DIR" \
            containerd.io \
            kubeadm \
            kubelet \
            kubectl \
            kubernetes-cni \
            haproxy \
            keepalived \
            socat \
            conntrack-tools \
            ipset \
            ipvsadm
    else
        dnf download --resolve --alldeps --destdir "$PKGS_DIR" \
            containerd.io \
            kubeadm \
            kubelet \
            kubectl \
            kubernetes-cni \
            haproxy \
            keepalived \
            socat \
            conntrack-tools \
            ipset \
            ipvsadm
    fi
}

download_deb_packages() {
    local apt_lists_dir="$TMP_DIR/apt-lists"
    local apt_cache_dir="$PKGS_DIR"
    local apt_partial_dir="$PKGS_DIR/partial"
    local apt_sources_dir="$TMP_DIR/apt-sources.list.d"
    local apt_sources_file="$TMP_DIR/sources.list"
    local k8s_keyring="$TMP_DIR/kubernetes-apt-keyring.gpg"
    local k8s_minor_version=""
    local os_codename=""

    if ! command -v apt-get >/dev/null 2>&1; then
        log "Skipping DEB packages because apt-get is not available."
        return 0
    fi

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_codename="${VERSION_CODENAME:-}"
    fi

    if [[ -z "$os_codename" ]]; then
        log "Unable to detect Ubuntu codename from /etc/os-release."
        return 1
    fi

    mkdir -p "$apt_lists_dir/partial" "$apt_sources_dir" "$apt_partial_dir"
    chmod 0755 "$TMP_DIR" "$apt_lists_dir" "$apt_lists_dir/partial" "$apt_sources_dir" "$PKGS_DIR" "$apt_partial_dir"

    cat > "$apt_sources_file" <<EOF
deb http://archive.ubuntu.com/ubuntu ${os_codename} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${os_codename}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${os_codename}-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu ${os_codename}-security main restricted universe multiverse
EOF

    k8s_minor_version=$(echo "$K8S_VERSION" | awk -F. '{printf "v%s.%s", $1, $2}')
    download_file \
        "https://pkgs.k8s.io/core:/stable:/${k8s_minor_version}/deb/Release.key" \
        "$TMP_DIR/Release.key"
    gpg --dearmor --batch --yes -o "$k8s_keyring" "$TMP_DIR/Release.key"

    cat > "$apt_sources_dir/kubernetes.list" <<EOF
deb [signed-by=${k8s_keyring}] https://pkgs.k8s.io/core:/stable:/${k8s_minor_version}/deb/ /
EOF

    log "Downloading offline DEB packages into $PKGS_DIR"

    apt-get \
        -o Dir::Etc::sourcelist="$apt_sources_file" \
        -o Dir::Etc::sourceparts="$apt_sources_dir" \
        -o Dir::State::lists="$apt_lists_dir" \
        -o APT::Get::List-Cleanup=0 \
        update

    apt-get \
        -o Dir::Etc::sourcelist="$apt_sources_file" \
        -o Dir::Etc::sourceparts="$apt_sources_dir" \
        -o Dir::State::lists="$apt_lists_dir" \
        -o Dir::Cache::archives="$apt_cache_dir" \
        install --download-only -y \
        kubeadm \
        kubelet \
        kubectl \
        kubernetes-cni \
        haproxy \
        keepalived \
        socat \
        conntrack \
        ipset \
        ipvsadm
}

download_manifests() {
    log "Downloading manifests"
    download_file \
        "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" \
        "$MANIFESTS_DIR/calico.yaml"
}

pull_and_save() {
    local image="$1"
    local name
    local tar_file
    local max_attempts=3
    local attempt

    name=$(echo "$image" | awk -F'/' '{print $NF}' | tr ':' '-')
    tar_file="$IMAGES_DIR/${name}.tar"

    for attempt in $(seq 1 $max_attempts); do
        if command -v ctr >/dev/null 2>&1; then
            log "Pulling $image with ctr (attempt $attempt/$max_attempts)"
            ctr -n k8s.io images pull --all-platforms "$image"
            log "Exporting ${name}.tar with ctr for ${IMAGE_PLATFORM}"
            rm -f "$tar_file"
            ctr -n k8s.io images export --platform "$IMAGE_PLATFORM" "$tar_file" "$image"
        else
            log "Pulling $image with docker for ${IMAGE_PLATFORM} (attempt $attempt/$max_attempts)"
            docker pull --platform "$IMAGE_PLATFORM" "$image"
            log "Saving ${name}.tar with docker save"
            docker save "$image" -o "$tar_file"
        fi

        if tar -tf "$tar_file" >/dev/null 2>&1; then
            return 0
        fi

        log "WARNING: $tar_file failed integrity check, retrying..."
        rm -f "$tar_file"
    done

    log "ERROR: Failed to export valid tar for $image after $max_attempts attempts"
    return 1
}

download_container_images() {
    local kube_images=""
    local calico_images=""
    local image=""
    local kubeadm_binary="$BIN_DIR/kubeadm"

    log "Downloading and saving container images"

    if [[ ! -x "$kubeadm_binary" ]]; then
        log "Expected kubeadm binary was not found at $kubeadm_binary"
        return 1
    fi

    kube_images=$("$kubeadm_binary" config images list --kubernetes-version "v${K8S_VERSION}")
    for image in $kube_images; do
        pull_and_save "$image"
    done

    calico_images=$(grep 'image:' "$MANIFESTS_DIR/calico.yaml" | awk '{print $2}' | sed 's/"//g' | sort -u)
    for image in $calico_images; do
        pull_and_save "$image"
    done
}

write_manifest() {
    {
        echo "K8S_VERSION=$K8S_VERSION"
        echo "CALICO_VERSION=$CALICO_VERSION"
        echo "CONTAINERD_VERSION=$CONTAINERD_VERSION"
        echo "RUNC_VERSION=$RUNC_VERSION"
        echo "CRICTL_VERSION=$CRICTL_VERSION"
        echo "HELM_VERSION=$HELM_VERSION"
        echo "K9S_VERSION=$K9S_VERSION"
        echo "IMAGE_PLATFORM=$IMAGE_PLATFORM"
        echo
        echo "[bin]"
        find "$BIN_DIR" -maxdepth 1 -type f | sort
        echo
        echo "[packages]"
        find "$PKGS_DIR" -maxdepth 1 -type f | sort
        echo
        echo "[images]"
        find "$IMAGES_DIR" -maxdepth 1 -type f | sort
        echo
        echo "[manifests]"
        find "$MANIFESTS_DIR" -maxdepth 1 -type f | sort
    } > "$MANIFEST_FILE"
}

log "Preparing full air-gap bundle in $ARTIFACTS_DIR"
download_binary_bundle

if command -v apt-get >/dev/null 2>&1; then
    download_deb_packages
else
    download_rpm_packages
fi

download_manifests
download_container_images
write_manifest
log "Artifact bundle is ready. Manifest: $MANIFEST_FILE"
