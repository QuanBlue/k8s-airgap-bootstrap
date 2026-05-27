# ansible-airgap-k8s

A production-grade DevOps platform engineering project to automate Kubernetes cluster deployments in fully air-gapped/offline environments using Ansible.

## Overview

This repository provides an automated, idempotent framework to deploy highly available Kubernetes clusters using `kubeadm` and `containerd` in environments without internet access. It dynamically generates topologies, supports optional VIP-based High Availability (HAProxy + Keepalived), and manages offline artifacts.

## Features

- **Air-gapped Support**: Fully offline deployment (DEB packages + container images + binaries + HAProxy source build).
- **Dynamic Topology**: Configurable master/worker counts and IP addresses with templated hostnames.
- **High Availability**: HAProxy (built from source v3.2.0) + Keepalived VIP, port-split (VIP:8443 → masters:6443) to avoid collision on shared master nodes.
- **Modern Stack**: `containerd` runtime, Calico CNI (VXLAN mode), metrics-server with 2 replicas + resource limits.
- **CIS Hardening**: anonymous-auth disabled (CIS 1.2.1), API audit logging (CIS 1.2.18-22, 3.2.1), kubelet serving cert rotation (CIS 4.2.12) — applied automatically as the last play. See [`docs/cis-compliance.md`](docs/cis-compliance.md) for the full mapping.
- **Configurable Data Partition**: All filesystem-heavy paths (containerd, offline images, kubelet logs, audit logs) can be relocated to a custom partition (e.g. `/u01/app`) in one wizard prompt.
- **Idempotent**: Re-runs are safe — playbooks detect stale state and self-heal (auto-reset+init on dead apiserver, dedupe app user rename, skip already-applied hardening patches).
- **Cluster Operations UX**: `k9s` installed on every master for both `root` and the application user.
- **Node Role Labels**: Masters auto-labeled `control-plane` + `master`; workers labeled `worker`.
- **Full Teardown**: Dedicated playbook removes everything installed by `site.yml`.

## Prerequisites

- **Ubuntu 24.04 LTS or newer ONLY** — no RPM/yum/dnf support.
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

Full reference (args, idempotency, env vars, output paths): [`docs/scripts.md`](docs/scripts.md).

| Script | Purpose |
|---|---|
| `./bootstrap.sh` | Interactive wizard — generates inventory + group_vars |
| `./scripts/bootstrap-clean.sh` | Rolls bootstrap back to the latest snapshot |
| `./scripts/generate-inventory.sh` | Generates inventory.ini from CLI args (called by `bootstrap.sh`) |
| `./scripts/download-artifacts.sh` | Downloads every offline artifact (DEBs, binaries, HAProxy source build, images) |
| `./scripts/load-images.sh` | Imports container image tarballs into containerd (run by Ansible) |

### Recommended workflow

```bash
# 1. On the build machine (with internet, Ubuntu 24.04+):
./scripts/download-artifacts.sh

# 2. Copy the repo + artifacts to the airgap control node, then:
./bootstrap.sh
ansible-playbook playbooks/site.yml
```

### Cleanup

```bash
# Roll back bootstrap (config only — does not touch the cluster):
./scripts/bootstrap-clean.sh

# Tear down the cluster:
ansible-playbook playbooks/teardown.yml
ansible-playbook playbooks/teardown.yml -e remove_app_user=true   # also removes the app user
```

## Documentation

- [Quick Start Guide](docs/quickstart.md) — fast walkthrough
- [Scripts Reference](docs/scripts.md) — per-script details
- [Features Reference](docs/features.md) — every feature and fix
- [CIS Compliance](docs/cis-compliance.md) — CIS Kubernetes Benchmark mapping
- [Airgap Preparation Guide](docs/airgap-guide.md)
- [HA Architecture Guide](docs/ha-architecture.md)

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
