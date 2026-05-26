# Airgap Preparation Guide

Deploying a Kubernetes cluster in a completely offline (air-gapped) environment requires careful preparation of all necessary dependencies, including packages, binaries, and container images.

## Overview of Offline Artifacts

To successfully install the cluster, the following artifacts must be pre-downloaded and transferred to the offline environment:

1. **OS Packages (RPM/DEB):** containerd, kubeadm, kubelet, kubectl, keepalived, haproxy.
2. **Container Images:** Kubernetes control plane images (API server, controller manager, scheduler, proxy, pause, etcd, coredns), Calico images, and other optional components (ingress-nginx, metallb).
3. **Binaries:** Helm, crictl, nerdctl.
4. **Manifests:** Calico CNI manifests.

## Step 1: Downloading Artifacts (Internet-Connected Machine)

We provide a helper script to automate the download process. Run it on a machine that has internet access and the same OS family as your target nodes.

For Ubuntu 24.04, the script is expected to run on an Ubuntu-based machine with internet access. It uses an isolated APT source set for Ubuntu packages and automatically adds the Kubernetes `pkgs.k8s.io` repository for the target Kubernetes minor version, so unrelated broken PPAs on the host do not block artifact preparation.

```bash
./scripts/download-artifacts.sh
```

### What the script does:
- Downloads installer binaries used directly by Ansible into `artifacts/bin/` such as `containerd` 2.3.1, `runc` 1.4.0, `crictl` v1.36.0, `helm` v3.20.1, `kubeadm`, `kubelet`, and `kubectl`.
- Downloads offline OS packages into `artifacts/packages/` for components that still require package-managed dependencies or systemd integration.
- Creates an `artifacts/` directory.
- Uses the host package manager to download required system packages.
- On Ubuntu 24.04, downloads offline `.deb` packages using `apt-get`.
- Uses `docker pull --platform linux/amd64` to download required container images for the target cluster architecture.
- Uses `docker save` or `ctr image export` to package images into `.tar` files.
- Downloads required binaries and manifests via `curl` or `wget`.

## Step 2: Transfer Artifacts

Once the download script completes, package the repository and the `artifacts/` folder:

```bash
tar -czvf k8s-airgap-bundle.tar.gz ansible-airgap-k8s/
```

Transfer `k8s-airgap-bundle.tar.gz` to your offline Ansible control node using a secure method (e.g., USB drive, secure file transfer gateway).

## Step 3: Loading Artifacts (Offline Machine)

Extract the bundle on your offline Ansible control node:

```bash
tar -xzvf k8s-airgap-bundle.tar.gz
cd ansible-airgap-k8s
```

The Ansible playbooks will automatically handle the installation of local binaries, packages, and the loading of container images onto the target nodes. 

Specifically, the `roles/containerd` role uses the `scripts/load-images.sh` script (executed remotely) to import the `.tar` image files into the containerd runtime before `kubeadm init` or `kubeadm join` is run.

```bash
ansible-playbook -i inventories/inventory.ini playbooks/site.yml
```
