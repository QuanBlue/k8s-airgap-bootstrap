# Airgap Preparation Guide

Deploying a Kubernetes cluster in a completely offline (air-gapped) environment requires pre-downloading every dependency on an internet-connected build machine. **Both the build machine and the target nodes must run Ubuntu 24.04 LTS or newer** — this repo dropped RPM/yum support.

## Overview of offline artifacts

| Kind | Location in the repo | Contents |
|---|---|---|
| OS DEB packages | `artifacts/packages/*.deb` | kubeadm, kubelet, kubectl, kubernetes-cni, keepalived, iptables-persistent, socat, conntrack, ipset, ipvsadm + transitive deps (libipset13, libnl-*, libnfnetlink0) |
| Pre-built binaries | `artifacts/bin/` | `containerd-<ver>-linux-amd64.tar.gz`, `runc.amd64`, `crictl-<ver>-linux-amd64.tar.gz`, `helm`, `k9s`, `kubeadm`, `kubelet`, `kubectl`, `etcdctl` (for etcd backups) |
| HAProxy compiled binary | `artifacts/bin/haproxy-<ver>.tar.gz` | Source from haproxy.org, compiled with OpenSSL, PCRE2 JIT, zlib, systemd |
| Container images | `artifacts/images/*.tar` | Every Kubernetes control-plane image, Calico images, the metrics-server image |
| Manifests | `artifacts/manifests/` | `calico.yaml`, `metrics-server.yaml`, `installers-manifest.txt` (version summary) |

## Step 1: Download artifacts on the build machine

Requirements:
- Ubuntu 24.04+
- Internet access
- `gcc`, `make` for the HAProxy build — the script auto-installs them via `sudo apt-get` (when running as root or with sudo)

```bash
# Download everything
./scripts/download-artifacts.sh

# Or run individual steps (see help)
./scripts/download-artifacts.sh --help
./scripts/download-artifacts.sh binaries haproxy deb manifests images manifest
```

What the script does:
- Verifies the host OS is Ubuntu 24.04+ (fails fast otherwise)
- Sets up isolated APT sources (Ubuntu official + Kubernetes `pkgs.k8s.io`) — broken third-party PPAs on the host do not affect the build
- Uses `apt-get install --download-only --reinstall` so transitive deps are force-downloaded (avoiding the "already on the build host, so skipped" trap)
- Compiles HAProxy from source (full feature flags) and packages the binary as a tarball
- Pulls container images via `ctr` (if available) or `docker`, saves to tar
- Verifies tar integrity after saving (up to 3 retries)
- Skips steps whose output already exists (re-runs are safe)

Override versions via env vars:
```bash
K8S_VERSION=1.36.0 \
CALICO_VERSION=v3.32.0 \
HAPROXY_VERSION=3.2.0 \
METRICS_SERVER_VERSION=v0.8.1 \
./scripts/download-artifacts.sh
```

Full args / env / output reference: [`scripts.md`](./scripts.md).

## Step 2: Transfer artifacts to the airgap control node

```bash
tar -czvf k8s-airgap-bundle.tar.gz k8s-airgap-bootstrap/
```

Move the archive over a USB drive, secure file-transfer gateway, or a private network to the control node.

## Step 3: On the airgap control node

Requirements:
- Ubuntu 24.04+
- SSH key-based access to every master and worker
- Ansible installed (`apt-get install -y ansible` from an ISO or local mirror if fully offline)

```bash
tar -xzvf k8s-airgap-bundle.tar.gz
cd k8s-airgap-bootstrap

# Generate inventory + group_vars
./scripts/bootstrap.sh

# Deploy
ansible-playbook playbooks/site.yml
```

The `containerd` role automatically copies `scripts/helpers/load-images.sh` and the entire `artifacts/images/` directory to every node, then runs the script to `ctr -n k8s.io images import` every tar before `kubeadm init` / `join`.

## Troubleshooting

### Image load fails (corrupt tar)
Re-pull the specific image on the build machine and retry:
```bash
rm artifacts/images/<bad-image>.tar
./scripts/download-artifacts.sh images
```

### DEB dependency conflict (ipset, libipset13)
The build machine already has the lib installed → `--download-only` skips it. Fixed by passing `--reinstall` and listing the transitive libs explicitly. If something else is still missing, add the package name to `download_deb_packages()`.

### HAProxy build fails
Missing dev libs. The script auto-installs them, but if the build host is locked down:
```bash
sudo apt-get install -y build-essential pkg-config libssl-dev libpcre2-dev zlib1g-dev libsystemd-dev
```
