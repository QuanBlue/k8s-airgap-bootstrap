# Quick Start Guide

This guide provides a rapid walkthrough for deploying a Kubernetes cluster using the `ansible-airgap-k8s` project.

## 1. Bootstrap the Configuration

Run the interactive bootstrap script to generate your inventory and variables:

```bash
./bootstrap.sh
```

You will be prompted for:
- Cluster name
- Project name
- Project short name
- Environment name
- Master and worker node counts
- VIP/HA requirements (if >1 master)
- Network CIDRs

The script generates `inventories/inventory.ini`, `group_vars/all.yml`, `group_vars/masters.yml`, and `group_vars/workers.yml`.
Generated hostnames follow `<ProjectShortName>-<Env>-<Role>-<Num>`, such as `DMS4-Prod-K8s-Master-01`.

## 2. Prepare Offline Artifacts

On a machine with internet access, run the installer and artifact download scripts:

```bash
./scripts/download-installers.sh
./scripts/download-artifacts.sh
```

This will download:
- Installer binaries used directly by Ansible
- Container images (saved as tarballs)
- RPM/DEB packages for containerd, kubelet, kubeadm, kubectl
- Helm binaries
- CNI manifests

Transfer the `artifacts/` folder to your air-gapped Ansible control node.

## 3. Review Configuration

Check your generated inventory and variables:

```bash
cat inventories/inventory.ini
cat group_vars/all.yml
```

Ensure SSH access is configured for all target nodes:

```bash
ansible all -m ping -i inventories/inventory.ini
```

## 4. Run the Deployment

Execute the main playbook to deploy the cluster:

```bash
ansible-playbook -i inventories/inventory.ini playbooks/site.yml
```

This will automatically:
1. Prepare the OS (disable swap, configure networking).
2. Install and load container images into `containerd`.
3. Configure HAProxy/Keepalived (if VIP is enabled).
4. Initialize the first master and join subsequent nodes.
5. Deploy the Calico CNI.

## 5. Verify the Cluster

Once the playbook completes, verify the cluster from the first master node:

```bash
kubectl get nodes
kubectl get pods -A
```
