# High Availability Architecture Guide

This project supports two independent High Availability (HA) VIP paths:
- a control-plane VIP on `masters` for the Kubernetes API server
- an optional ingress VIP on `workers` for application traffic

## Architecture Diagram

```mermaid
graph TD
    subgraph "Clients"
        K[kubectl]
        W[Worker Nodes (kubelet)]
    end

    VIP((API VIP\n10.10.10.100:8443))

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
For the control-plane VIP, HAProxy runs on every master node in TCP mode, listens on `8443`, and balances traffic across all available `kube-apiserver` instances on `masters:6443`.

When `worker_ha.enabled=true`, HAProxy also runs on every worker node and exposes two additional TCP frontends:
- `worker VIP:80 -> workers:30080`
- `worker VIP:443 -> workers:30443`

### Keepalived
Keepalived provides the Virtual IP (VIP) using the VRRP (Virtual Router Redundancy Protocol).
- For the API VIP, it runs on every master node.
- For the optional worker VIP, it runs on every worker node.
- One node is elected as the `MASTER` and holds the VIP.
- The other nodes are `BACKUP`.
- Keepalived performs TCP health checks against the local HAProxy listeners. If the health check fails, Keepalived drops the VIP, and another node assumes the `MASTER` role.

### kubeadm Configuration
When VIP is enabled, the Ansible playbooks automatically generate the `kubeadm-config.yaml` using the `controlPlaneEndpoint` configuration pointing to the VIP and port. This ensures that all components (scheduler, controller-manager, worker kubelets) communicate through the highly available endpoint.

## Configuration (group_vars/all.yml)

To enable HA, the generated variables look like this:

```yaml
master_ha:
  enabled: true
  vip_address: "10.10.10.100"
  vip_interface: "eth0"
  vip_port: 8443

worker_ha:
  enabled: false
  vip_address: ""
  vip_interface: ""
  http_port: 80
  https_port: 443
  backend_http_port: 30080
  backend_https_port: 30443
```
