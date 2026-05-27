# ansible-airgap-k8s

A production-grade DevOps platform engineering project to automate Kubernetes cluster deployments in fully air-gapped/offline environments using Ansible.

## Overview

This repository provides an automated, idempotent framework to deploy highly available Kubernetes clusters using `kubeadm` and `containerd` in environments without internet access. It dynamically generates topologies, supports optional VIP-based High Availability (HAProxy + Keepalived), and manages offline artifacts.

## Features

- **Air-gapped Support**: Fully offline deployment capability.
- **Dynamic Topology**: Easily configurable node counts with standardized hostname templates.
- **High Availability**: Optional VIP-based API Server HA using HAProxy and Keepalived.
- **Modern Stack**: `containerd` as the container runtime, Calico CNI.
- **Cluster Operations UX**: `k9s` is installed on master nodes for both `root` and `app_user`.
- **Node Role Labels**: Master nodes are automatically labeled `control-plane` + `master`; worker nodes are labeled `worker`.
- **Full Teardown**: A dedicated playbook to cleanly remove everything installed by `site.yml`.
- **Production-Ready**: Built following enterprise best practices for Ansible and Kubernetes.

## Prerequisites

- Base OS: RHEL/AlmaLinux/Rocky or Ubuntu (Debian) family.
- Ubuntu 24.04 is supported; offline package preparation uses `.deb` packages and APT-based installation.
- On Ubuntu 24.04, the artifact download script can prepare Kubernetes `.deb` packages without requiring you to preconfigure the Kubernetes APT repo on the host.
- Ansible installed on the control node.
- SSH key-based authentication to all target nodes.
- Offline artifacts downloaded (see [Airgap Preparation Guide](docs/airgap-guide.md)).

## Quickstart

1. Run the bootstrap script to interactively generate your inventory and variables:
   ```bash
   ./bootstrap.sh
   ```
2. Download offline artifacts on an internet-connected machine:
   ```bash
   ./scripts/download-artifacts.sh
   ```
3. Transfer the repository and artifacts to the air-gapped control node.
4. Deploy the cluster:
   ```bash
   ansible-playbook playbooks/site.yml
   ```
5. To tear down everything installed by step 4:
   ```bash
   # Keep the app user
   ansible-playbook playbooks/teardown.yml

   # Also remove the app user
   ansible-playbook playbooks/teardown.yml -e remove_app_user=true
   ```

## Scripts

### Main workflow

- `./bootstrap.sh`
  - Interactively generates `inventories/inventory.ini` and `group_vars/*.yml`.
  - Supports project/environment naming, optional hostname cluster number, node IP input, VIP settings, Kubernetes network settings, and optional custom storage partition paths for containerd and kubelet logs.
- `./dry-run.sh`
  - Previews the bootstrap result without modifying real files.
  - Shows cluster summary, generated hostnames, server IPs, artifact download plan, file diffs, and Ansible syntax validation.
- `./scripts/bootstrap-clean.sh`
  - Restores the latest backup created by `bootstrap.sh`.
  - Useful when you want to discard a bootstrap run and return to the previous generated state.

### Artifact preparation

- `./scripts/download-artifacts.sh`
  - Downloads the full air-gap bundle.
  - Downloads installer binaries, offline OS packages, Calico manifests, and Kubernetes/Calico container images into `artifacts/`.
  - Includes `k9s` in the binary bundle so master nodes can inspect the cluster locally with `root` and `app_user`.
  - Container images are pulled for `linux/amd64` to match the target cluster nodes and avoid multi-arch import issues in `containerd`.
  - This is the only artifact preparation command you need to run on the internet-connected machine.
- `./scripts/load-images.sh`
  - Loads offline image tar files into `containerd`.
  - This script is copied and executed by Ansible on target nodes during deployment.

### Inventory helper

- `./scripts/generate-inventory.sh`
  - Helper script used by `bootstrap.sh` to generate `inventories/inventory.ini`.
  - You usually do not need to run it manually unless you want to automate inventory generation yourself.

### Recommended usage order

1. `./dry-run.sh`
2. `./bootstrap.sh`
3. `./scripts/download-artifacts.sh`
4. `ansible-playbook playbooks/site.yml`

To undo the latest bootstrap-generated config:
```bash
./scripts/bootstrap-clean.sh
```

To tear down the entire cluster and all installed components:
```bash
ansible-playbook playbooks/teardown.yml
```

## Documentation

- [Quick Start Guide](docs/quickstart.md)
- [Airgap Preparation Guide](docs/airgap-guide.md)
- [High Availability Architecture Guide](docs/ha-architecture.md)

## Structure

- `playbooks/`: Ansible playbooks — `site.yml` (deploy), `teardown.yml` (remove), `prepare.yml`, `ha.yml`, `kubernetes.yml`.
- `roles/`: Reusable Ansible roles (`common`, `containerd`, `kubernetes`, etc.).
- `inventories/`: Generated host inventories.
- `group_vars/` / `host_vars/`: Configuration variables.
- `scripts/`: Helper scripts for bootstrapping and artifact management.
- `docs/`: Detailed documentation.

## Naming Convention

Generated hostnames follow the template `<ProjectShortName>-<Env>-<Role>-<Num>`, where `ProjectShortName` is provided during bootstrap, for example:

- `DMS4-Prod-K8s-Master-01`
- `DMS4-Prod-K8s-Worker-01`
- `DMS4-Prod-Mariadb-01`
- `DMS4-Stag-Mongodb-01`

The bootstrap flow also generates `project_short_name` and a default application user variable (`app_user`) in `group_vars/all.yml`. The default value is `app`; you can change it during `./bootstrap.sh`. If an `app` user already exists on the nodes and you choose a different name, Ansible will automatically rename the user and move its home directory.
