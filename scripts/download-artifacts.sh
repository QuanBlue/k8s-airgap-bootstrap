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
HAPROXY_VERSION="${HAPROXY_VERSION:-3.2.0}"
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-v0.8.1}"
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

require_ubuntu_24_04_or_newer() {
    local id="" version_id="" major=""

    if [[ ! -r /etc/os-release ]]; then
        log "ERROR: /etc/os-release not found — this script only supports Ubuntu 24.04+."
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-}"
    version_id="${VERSION_ID:-}"

    if [[ "$id" != "ubuntu" ]]; then
        log "ERROR: detected '${id}' but only Ubuntu is supported."
        exit 1
    fi

    major="${version_id%%.*}"
    if [[ -z "$major" || "$major" -lt 24 ]]; then
        log "ERROR: detected Ubuntu ${version_id} but 24.04 or newer is required."
        exit 1
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        log "ERROR: apt-get not found — cannot download DEB packages."
        exit 1
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

    # shellcheck disable=SC1091
    . /etc/os-release
    os_codename="${VERSION_CODENAME:-}"

    if [[ -z "$os_codename" ]]; then
        log "ERROR: Unable to detect Ubuntu codename from /etc/os-release."
        exit 1
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
        install --download-only -y --reinstall \
        kubeadm \
        kubelet \
        kubectl \
        kubernetes-cni \
        keepalived \
        socat \
        conntrack \
        ipset \
        ipvsadm \
        libipset13 \
        libnfnetlink0 \
        libnl-3-200 \
        libnl-genl-3-200
    # HAProxy is installed from a pre-built binary tarball at
    # $BIN_DIR/haproxy-*.tar.gz — provide it manually (the role expects a
    # tarball containing a 'haproxy' executable somewhere inside).
    # --reinstall forces apt to re-download packages even if they're already
    # installed on the build machine, ensuring transitive deps are captured.
}

build_haproxy_tarball() {
    local haproxy_major="${HAPROXY_VERSION%.*}"
    local src_tar="$TMP_DIR/haproxy-${HAPROXY_VERSION}.tar.gz"
    local src_dir="$TMP_DIR/haproxy-${HAPROXY_VERSION}"
    local pkg_dir="$TMP_DIR/haproxy-${HAPROXY_VERSION}-pkg"
    local out_tar="$BIN_DIR/haproxy-${HAPROXY_VERSION}.tar.gz"
    local missing=()
    local pkg=""

    if [[ -f "$out_tar" ]]; then
        log "HAProxy tarball already exists: $(basename "$out_tar")"
        return 0
    fi

    local -a missing_apt=()

    # Tools check
    command -v gcc >/dev/null 2>&1        || missing_apt+=(build-essential)
    command -v make >/dev/null 2>&1       || missing_apt+=(build-essential)
    command -v pkg-config >/dev/null 2>&1 || missing_apt+=(pkg-config)

    # Dev libs check via pkg-config
    if command -v pkg-config >/dev/null 2>&1; then
        pkg-config --exists openssl     2>/dev/null || missing_apt+=(libssl-dev)
        pkg-config --exists libpcre2-8  2>/dev/null || missing_apt+=(libpcre2-dev)
        pkg-config --exists zlib        2>/dev/null || missing_apt+=(zlib1g-dev)
        pkg-config --exists libsystemd  2>/dev/null || missing_apt+=(libsystemd-dev)
    else
        # pkg-config itself missing — schedule all dev libs too
        missing_apt+=(libssl-dev libpcre2-dev zlib1g-dev libsystemd-dev)
    fi

    if [[ ${#missing_apt[@]} -gt 0 ]]; then
        # Dedupe
        local -A seen=()
        local -a uniq=()
        for pkg in "${missing_apt[@]}"; do
            if [[ -z "${seen[$pkg]:-}" ]]; then
                seen[$pkg]=1
                uniq+=("$pkg")
            fi
        done

        log "Installing missing build deps: ${uniq[*]}"
        local sudo_cmd=""
        if [[ $EUID -ne 0 ]]; then
            if ! command -v sudo >/dev/null 2>&1; then
                log "ERROR: not root and sudo not available. Install manually: apt-get install -y ${uniq[*]}"
                exit 1
            fi
            sudo_cmd="sudo"
        fi

        # apt-get update may fail due to broken third-party PPAs — don't abort,
        # the packages we need are in Ubuntu's main repos and may already be
        # cached locally.
        $sudo_cmd apt-get update -qq || log "WARN: apt-get update had errors (likely a broken PPA) — continuing."
        $sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y "${uniq[@]}"
    fi

    log "Downloading HAProxy ${HAPROXY_VERSION} source"
    download_file \
        "https://www.haproxy.org/download/${haproxy_major}/src/haproxy-${HAPROXY_VERSION}.tar.gz" \
        "$src_tar"

    log "Extracting HAProxy source"
    tar -xzf "$src_tar" -C "$TMP_DIR"

    log "Building HAProxy ${HAPROXY_VERSION} (full: OpenSSL + PCRE2 JIT + zlib + systemd)"
    (
        cd "$src_dir"
        make -j"$(nproc)" \
            TARGET=linux-glibc \
            USE_OPENSSL=1 \
            USE_PCRE2=1 \
            USE_PCRE2_JIT=1 \
            USE_ZLIB=1 \
            USE_SYSTEMD=1 \
            USE_LINUX_TPROXY=1 \
            USE_GETADDRINFO=1 \
            USE_TFO=1 \
            >/dev/null
    )

    log "Packaging HAProxy binary into $(basename "$out_tar")"
    mkdir -p "$pkg_dir"
    cp "$src_dir/haproxy" "$pkg_dir/haproxy"
    chmod 0755 "$pkg_dir/haproxy"
    tar -czf "$out_tar" -C "$TMP_DIR" "$(basename "$pkg_dir")"
}

download_manifests() {
    log "Downloading manifests"
    download_file \
        "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" \
        "$MANIFESTS_DIR/calico.yaml"
    download_file \
        "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml" \
        "$MANIFESTS_DIR/metrics-server.yaml"
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

    metrics_images=$(grep 'image:' "$MANIFESTS_DIR/metrics-server.yaml" | awk '{print $2}' | sed 's/"//g' | sort -u)
    for image in $metrics_images; do
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
        echo "HAPROXY_VERSION=$HAPROXY_VERSION"
        echo "METRICS_SERVER_VERSION=$METRICS_SERVER_VERSION"
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

usage() {
    cat <<EOF
Usage: $(basename "$0") [STEP ...]

Run individual steps (default: run all):
  binaries   Download k8s/containerd/runc/crictl/helm/k9s binaries
  haproxy    Download HAProxy source and build binary tarball
  deb        Download offline DEB packages (kubeadm, keepalived, ...)
  manifests  Download Calico/etc. YAML manifests
  images     Pull and save container images
  manifest   Write installers-manifest.txt summary

Examples:
  $(basename "$0")                # run everything
  $(basename "$0") haproxy        # only build HAProxy
  $(basename "$0") haproxy deb    # HAProxy + DEB packages
EOF
}

run_step() {
    case "$1" in
        binaries)  download_binary_bundle ;;
        haproxy)   build_haproxy_tarball ;;
        deb)       download_deb_packages ;;
        manifests) download_manifests ;;
        images)    download_container_images ;;
        manifest)  write_manifest ;;
        -h|--help) usage; exit 0 ;;
        *)         log "ERROR: unknown step '$1'"; usage; exit 1 ;;
    esac
}

require_ubuntu_24_04_or_newer

if [[ $# -eq 0 ]]; then
    log "Preparing full air-gap bundle in $ARTIFACTS_DIR"
    download_binary_bundle
    build_haproxy_tarball
    download_deb_packages
    download_manifests
    download_container_images
    write_manifest
    log "Artifact bundle is ready. Manifest: $MANIFEST_FILE"
else
    log "Running selected steps: $*"
    for step in "$@"; do
        run_step "$step"
    done
    log "Selected steps complete."
fi
