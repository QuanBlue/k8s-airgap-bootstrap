# High Availability Architecture Guide

This project supports deploying a multi-master High Availability (HA) Kubernetes cluster using a Virtual IP (VIP) to load balance requests to the Kubernetes API server.

## Architecture Diagram

```mermaid
graph TD
    subgraph "Clients"
        K[kubectl]
        W[Worker Nodes (kubelet)]
    end

    VIP((Virtual IP\n10.10.10.100:6443))

    subgraph "Master Nodes"
        subgraph "Master 1 (master-1)"
            KA1[Keepalived (MASTER)]
            HA1[HAProxy]
            API1[kube-apiserver:6443]
        end
        subgraph "Master 2 (master-2)"
            KA2[Keepalived (BACKUP)]
            HA2[HAProxy]
            API2[kube-apiserver:6443]
        end
        subgraph "Master 3 (master-3)"
            KA3[Keepalived (BACKUP)]
            HA3[HAProxy]
            API3[kube-apiserver:6443]
        end
    end

    K --> VIP
    W --> VIP

    VIP --> KA1
    KA1 --> HA1
    HA1 --> API1
    HA1 --> API2
    HA1 --> API3

    KA2 -. "VRRP heartbeat" .- KA1
    KA3 -. "VRRP heartbeat" .- KA1
```

## Component Overview

### HAProxy
HAProxy runs on every master node and is configured in TCP mode. It listens on the local API port (typically `6443` or a dedicated bind port like `16443` internally) and balances traffic across all available `kube-apiserver` instances on the master nodes.

### Keepalived
Keepalived provides the Virtual IP (VIP) using the VRRP (Virtual Router Redundancy Protocol). It runs on every master node.
- One node is elected as the `MASTER` and holds the VIP.
- The other nodes are `BACKUP`.
- Keepalived performs health checks against the local HAProxy/API server. If the health check fails, Keepalived drops the VIP, and another node assumes the `MASTER` role.

### kubeadm Configuration
When VIP is enabled, the Ansible playbooks automatically generate the `kubeadm-config.yaml` using the `controlPlaneEndpoint` configuration pointing to the VIP and port. This ensures that all components (scheduler, controller-manager, worker kubelets) communicate through the highly available endpoint.

## Configuration (group_vars/all.yml)

To enable HA, the generated variables look like this:

```yaml
k8s_ha:
  enabled: true
  vip_address: "10.10.10.100"
  vip_interface: "eth0"
  vip_port: 6443
```
