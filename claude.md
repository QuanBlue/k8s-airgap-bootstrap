# CLAUDE.md

## Project Name

ansible-airgap-k8s

---

# Project Context

This repository is a production-grade DevOps platform engineering project.

The purpose of this repository is to automate Kubernetes cluster deployment in fully air-gapped/offline environments using Ansible.

This project must follow real-world enterprise standards and Kubernetes best practices.

This is NOT a tutorial repository.

All generated code, architecture, repository structure, automation logic, scripts, and documentation must look like a real enterprise platform engineering project used in production environments.

---

# Primary Goals

Build a reusable Ansible automation framework that can:

- Deploy Kubernetes clusters in fully air-gapped environments
- Support both single-master and multi-master HA clusters
- Dynamically generate cluster topology
- Allow configurable hostname patterns
- Support optional VIP-based Kubernetes API HA
- Automatically install HAProxy + Keepalived when VIP is enabled
- Configure kube-apiserver behind a Virtual IP
- Manage offline packages and container images
- Support future extensibility

---

# Kubernetes Requirements

The Kubernetes cluster must be deployed using:

- kubeadm
- containerd

Support:

- Single-master cluster
- Multi-master HA cluster
- Calico CNI
- Metrics Server
- ingress-nginx (optional)
- MetalLB (optional)

The project should be production-oriented.

---

# Dynamic Cluster Topology

The user must be able to configure:

- Number of master nodes
- Number of worker nodes
- Hostname pattern for masters
- Hostname pattern for workers
- Starting index

Example configuration:

```yaml
masters:
  count: 3
  pattern: "k8s-master"
  start_index: 1

workers:
  count: 5
  pattern: "k8s-worker"
  start_index: 1
```

Generated hostnames:

```text
k8s-master-1
k8s-master-2
k8s-master-3

k8s-worker-1
k8s-worker-2
k8s-worker-3
k8s-worker-4
k8s-worker-5
```

---

# HA / VIP Requirements

If the cluster contains more than one master node:

The bootstrap process must ask:

```text
Enable VIP for Kubernetes API Server? (yes/no)
```

If the user enables VIP:

Automatically install and configure:

- HAProxy
- Keepalived

on all master nodes.

---

# VIP Architecture Requirements

Example:

```text
VIP: 10.10.10.100
API Endpoint: https://10.10.10.100:6443
```

Requirements:

- HAProxy load balances kube-apiserver traffic
- Keepalived manages Virtual IP failover
- kubeadm init uses the VIP endpoint
- kubeconfig files use VIP endpoint
- Automatic MASTER/BACKUP assignment
- VRRP health checks
- VIP failover support

---

# Airgap Requirements

The project MUST support fully offline deployment.

Support offline installation for:

- kubeadm
- kubelet
- kubectl
- containerd
- runc
- CNI plugins
- crictl
- nerdctl
- Helm
- Calico images
- ingress-nginx images
- metrics-server images

---

# Offline Artifact Management

Create workflows/scripts for:

- Downloading RPM/DEB packages
- Pulling container images
- Saving images as tar files
- Importing images offline
- Local package repository
- Local image registry
- Offline Helm chart management

Example scripts:

```bash
./scripts/download-artifacts.sh
./scripts/helpers/load-images.sh
```

---

# Bootstrap Workflow

Create an interactive bootstrap script:

```bash
./bootstrap.sh
```

The script must ask for:

```text
Cluster name
Number of masters
Number of workers
Master hostname pattern
Worker hostname pattern
Enable HA/VIP?
VIP address
Network interface for VIP
Kubernetes version
Pod CIDR
Service CIDR
Container runtime
```

Then automatically generate:

- inventory.ini
- group_vars
- host_vars
- kubeadm configs
- HAProxy configs
- Keepalived configs

---

# Repository Structure

Use enterprise repository structure:

```text
ansible-airgap-k8s/
├── inventories/
├── playbooks/
├── roles/
├── templates/
├── group_vars/
├── host_vars/
├── scripts/
├── docs/
├── artifacts/
├── offline/
├── hack/
├── .github/
└── README.md
```

---

# Ansible Best Practices

Use:

- Roles
- Tags
- Handlers
- Templates
- Jinja2
- Idempotent tasks
- Dynamic inventory generation
- Reusable tasks
- Separation of concerns

---

# Required Roles

Create roles such as:

```text
common/
containerd/
kubernetes/
haproxy/
keepalived/
calico/
registry/
helm/
ingress-nginx/
metallb/
```

Each role should contain:

```text
tasks/
handlers/
templates/
defaults/
vars/
files/
meta/
```

---

# OS Preparation Tasks

Automate:

- Disable swap
- Configure sysctl
- Configure kernel modules
- Configure time sync
- Install dependencies
- Configure networking
- Configure hosts file

---

# Container Runtime Requirements

Install and configure:

- containerd
- SystemdCgroup
- Registry mirrors
- Offline image loading

---

# Kubernetes Automation Requirements

Automate:

- kubeadm installation
- kubelet installation
- kubectl installation
- kubeadm init
- Join control plane nodes
- Join worker nodes
- Generate kubeconfig
- Export kubeconfig

---

# HAProxy Requirements

Generate HAProxy TCP configuration for kube-apiserver.

Requirements:

- TCP mode
- Health checks
- Load balancing across masters
- Automatic configuration generation

Example:

```text
backend kube-apiserver
    balance roundrobin
```

---

# Keepalived Requirements

Generate Keepalived VRRP configuration.

Requirements:

- MASTER/BACKUP mode
- Priority assignment
- VIP failover
- API health checks

---

# Configuration Management

Use centralized configuration.

Example:

```yaml
cluster_name: production

kubernetes_version: "1.36.0"

vip:
  enabled: true
  address: 10.10.10.100
  interface: ens160

network:
  pod_cidr: 10.244.0.0/16
  service_cidr: 10.96.0.0/12
```

Avoid hardcoded values.

---

# Documentation Requirements

Generate:

- README.md
- Quick Start Guide
- Airgap Preparation Guide
- HA Architecture Guide
- Troubleshooting Guide
- Offline Registry Guide
- Repository Structure Guide

Include architecture diagrams in markdown.

---

# CI/CD Requirements

Add GitHub Actions for:

- ansible-lint
- yamllint
- markdownlint
- shellcheck

---

# Coding Standards

Requirements:

- Production-grade quality
- Enterprise naming conventions
- Modular architecture
- Reusable components
- Secure defaults
- Well-commented code
- Maintainable structure
- Minimal hardcoding

---

# Deliverables

Generate:

1. Full repository structure
2. README.md
3. Bootstrap shell script
4. Dynamic inventory generator
5. Example inventories
6. Example playbooks
7. Example roles
8. HAProxy templates
9. Keepalived templates
10. kubeadm templates
11. Offline artifact scripts
12. GitHub Actions workflows
13. Architecture documentation

---

# Target OS

**Ubuntu 24.04 LTS or newer ONLY.**

- Do NOT write RPM, yum, dnf, or any RedHat/CentOS/AlmaLinux/Rocky code
- All package installation uses `dpkg -i` (offline .deb) or `apt-get`
- All OS-level checks assume Debian/Ubuntu conventions
- `ansible_os_family == "Debian"` is always assumed — do not add `when: ansible_os_family == "RedHat"` branches

---

# Important Instructions

This repository must resemble a real enterprise DevOps platform engineering project.

Avoid tutorial-style implementation.

Focus heavily on:

- Scalability
- Maintainability
- Reusability
- Airgap reliability
- HA Kubernetes architecture
- Clean automation design
- Production readiness

All generated code must be clean, modular, reusable, and follow modern DevOps best practices.
