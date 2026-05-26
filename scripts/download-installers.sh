#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT_DIR/artifacts}"
BIN_DIR="$ARTIFACTS_DIR/bin"
PKGS_DIR="$ARTIFACTS_DIR/packages"
MANIFEST_DIR="$ARTIFACTS_DIR/manifests"
MANIFEST_FILE="$MANIFEST_DIR/installers-manifest.txt"

K8S_VERSION="${K8S_VERSION:-1.36.0}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.3.1}"
RUNC_VERSION="${RUNC_VERSION:-1.4.0}"
CRICTL_VERSION="${CRICTL_VERSION:-v1.36.0}"
HELM_VERSION="${HELM_VERSION:-3.20.1}"

mkdir -p "$BIN_DIR" "$PKGS_DIR" "$MANIFEST_DIR"

TMP_DIR=$(mktemp -d /tmp/k8s-installers.XXXXXX)
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log() {
    printf '[download-installers] %s\n' "$1"
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
    local apt_sources_dir="$TMP_DIR/apt-sources.list.d"
    local apt_sources_file="$TMP_DIR/sources.list"
    local os_codename=""
    local k8s_repo_found="false"

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

    mkdir -p "$apt_lists_dir/partial" "$apt_sources_dir"

    cat > "$apt_sources_file" <<EOF
deb http://archive.ubuntu.com/ubuntu ${os_codename} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${os_codename}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${os_codename}-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu ${os_codename}-security main restricted universe multiverse
EOF

    while IFS= read -r repo_file; do
        cp "$repo_file" "$apt_sources_dir/$(basename "$repo_file")"
        k8s_repo_found="true"
    done < <(grep -RIl "pkgs.k8s.io\|apt.kubernetes.io" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true)

    if [[ "$k8s_repo_found" != "true" ]]; then
        log "Kubernetes APT repository was not found on this machine."
        log "Please configure the Kubernetes pkgs.k8s.io repository for v${K8S_VERSION} before running this script."
        return 1
    fi

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

write_manifest() {
    {
        echo "K8S_VERSION=$K8S_VERSION"
        echo "CONTAINERD_VERSION=$CONTAINERD_VERSION"
        echo "RUNC_VERSION=$RUNC_VERSION"
        echo "CRICTL_VERSION=$CRICTL_VERSION"
        echo "HELM_VERSION=$HELM_VERSION"
        echo
        echo "[bin]"
        find "$BIN_DIR" -maxdepth 1 -type f | sort
        echo
        echo "[packages]"
        find "$PKGS_DIR" -maxdepth 1 -type f | sort
    } > "$MANIFEST_FILE"
}

log "Preparing local installer bundle in $ARTIFACTS_DIR"
download_binary_bundle

if command -v apt-get >/dev/null 2>&1; then
    download_deb_packages
else
    download_rpm_packages
fi

write_manifest
log "Installer bundle is ready. Manifest: $MANIFEST_FILE"
