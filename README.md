# ansible-airgap-k8s

A production-grade DevOps platform engineering project to automate Kubernetes cluster deployments in fully air-gapped/offline environments using Ansible.

## Overview

This repository provides an automated, idempotent framework to deploy highly available Kubernetes clusters using `kubeadm` and `containerd` in environments without internet access. It dynamically generates topologies, supports optional VIP-based High Availability (HAProxy + Keepalived), and manages offline artifacts.

## Features

- **Air-gapped Support**: Fully offline deployment capability.
- **Dynamic Topology**: Easily configurable node counts with standardized hostname templates.
- **High Availability**: Optional VIP-based API Server HA using HAProxy and Keepalived.
- **Modern Stack**: `containerd` as the container runtime, Calico CNI.
- **Production-Ready**: Built following enterprise best practices for Ansible and Kubernetes.

## Prerequisites

- Base OS: RHEL/AlmaLinux/Rocky or Ubuntu (Debian) family.
- Ubuntu 24.04 is supported; offline package preparation uses `.deb` packages and APT-based installation.
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
   ./scripts/download-installers.sh
   ./scripts/download-artifacts.sh
   ```
3. Transfer the repository and artifacts to the air-gapped control node.
4. Run the Ansible playbook:
   ```bash
   ansible-playbook playbooks/site.yml
   ```

## Scripts

### Main workflow

- `./bootstrap.sh`
  - Interactively generates `inventories/inventory.ini` and `group_vars/*.yml`.
  - Supports project/environment naming, optional hostname cluster number, node IP input, VIP settings, and Kubernetes network settings.
- `./dry-run.sh`
  - Previews the bootstrap result without modifying real files.
  - Shows cluster summary, generated hostnames, server IPs, artifact download plan, file diffs, and Ansible syntax validation.
- `./scripts/bootstrap-clean.sh`
  - Restores the latest backup created by `bootstrap.sh`.
  - Useful when you want to discard a bootstrap run and return to the previous generated state.

### Artifact preparation

- `./scripts/download-installers.sh`
  - Downloads offline installer binaries and package files into `artifacts/`.
  - Includes `containerd`, `runc`, `crictl`, `helm`, `kubeadm`, `kubelet`, `kubectl`, and offline RPM dependencies when available.
- `./scripts/download-artifacts.sh`
  - Downloads the full air-gap bundle.
  - Reuses `download-installers.sh`, downloads Calico manifest files, and saves Kubernetes and Calico container images into `artifacts/images/`.
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
3. `./scripts/download-installers.sh`
4. `./scripts/download-artifacts.sh`
5. `ansible-playbook playbooks/site.yml`

If you want to undo the latest bootstrap-generated config:

```bash
./scripts/bootstrap-clean.sh
```

## Documentation

- [Quick Start Guide](docs/quickstart.md)
- [Airgap Preparation Guide](docs/airgap-guide.md)
- [High Availability Architecture Guide](docs/ha-architecture.md)

## Structure

- `playbooks/`: Ansible playbooks for different stages of deployment.
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

The bootstrap flow also generates `project_short_name` and a default application user variable in `group_vars/all.yml` as `app_<project_name>`.
