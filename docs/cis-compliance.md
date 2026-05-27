# CIS Kubernetes Benchmark Compliance

Mapping of items in the [CIS Kubernetes Benchmark v1.9.0](https://www.cisecurity.org/benchmark/kubernetes) against what this repo configures.

Status:
- ✅ **Implemented** — automatically applied by Ansible
- ⚠️ **Partial** — partially applied (see notes)
- ❌ **Not implemented** — admin should configure further

---

## 1. Control Plane Components

### 1.2 API Server

| ID | Recommendation | Status | Implementation |
|---|---|---|---|
| 1.2.1 | `--anonymous-auth=false` | ✅ | The `kubernetes-hardening` role patches it after the cluster is up (two-phase: init with `true` so `kubeadm join` works, then flip to `false`). It also converts the apiserver probes from `httpGet` to `tcpSocket` so kubelet probes don't need auth |
| 1.2.5 | `--kubelet-https=true` | ✅ | kubeadm default |
| 1.2.6 | `--kubelet-client-certificate / --kubelet-client-key` | ✅ | kubeadm default — `/etc/kubernetes/pki/apiserver-kubelet-client.*` |
| 1.2.7 | `--kubelet-certificate-authority` | ✅ | kubeadm default (cluster CA) |
| 1.2.18 | `--audit-log-path` | ✅ | `kubernetes_audit.log_dir` in group_vars (default `/u01/app/log/kubernetes/audit/audit.log`) |
| 1.2.19 | `--audit-log-maxage` | ✅ | `kubernetes_audit.max_age: 90` (days) |
| 1.2.20 | `--audit-log-maxbackup` | ✅ | `kubernetes_audit.max_backup: 20` |
| 1.2.21 | `--audit-log-maxsize` | ✅ | `kubernetes_audit.max_size: 100` (MB) |
| 1.2.22 | Reasonable `--request-timeout` | ✅ | 60s (kubeadm default) |
| 1.2.23 | `--service-account-lookup=true` | ✅ | Default in 1.31+ |
| 1.2.25 | `--encryption-provider-config` | ❌ | Recommended: provide an `EncryptionConfig` for Secrets. Not implemented yet |

### 1.3 Controller Manager

| ID | Recommendation | Status | Implementation |
|---|---|---|---|
| 1.3.1 | `--terminated-pod-gc-threshold` | ⚠️ | Default 12500 (acceptable). Tune if needed |
| 1.3.2 | `--profiling=false` | ❌ | Default is true. Can be added via `controllerManager.extraArgs` in kubeadm-init |
| 1.3.5 | `--root-ca-file` | ✅ | kubeadm default |
| 1.3.6 | `RotateKubeletServerCertificate=true` | ✅ | Set in KubeletConfiguration via kubeadm-init |
| 1.3.7 | `--bind-address=127.0.0.1` | ✅ | kubeadm default (modern versions) |

### 1.4 Scheduler

| ID | Recommendation | Status | Implementation |
|---|---|---|---|
| 1.4.1 | `--profiling=false` | ❌ | Can be added via `scheduler.extraArgs` |
| 1.4.2 | `--bind-address=127.0.0.1` | ✅ | kubeadm default |

### 1.5 etcd

| ID | Recommendation | Status | Implementation |
|---|---|---|---|
| 1.5.1 | `--cert-file` / `--key-file` | ✅ | kubeadm default |
| 1.5.2 | `--client-cert-auth=true` | ✅ | kubeadm default |
| 1.5.3 | `--auto-tls=false` | ✅ | Default (disabled) |
| 1.5.4 | `--peer-cert-file` / `--peer-key-file` | ✅ | kubeadm default |
| 1.5.5 | `--peer-client-cert-auth=true` | ✅ | kubeadm default |
| 1.5.6 | `--peer-auto-tls=false` | ✅ | Default |
| 1.5.7 | `--trusted-ca-file` for peer | ✅ | kubeadm default |

---

## 2. etcd Node Configuration Files

| ID | Recommendation | Status |
|---|---|---|
| 2.1-2.7 | etcd file permissions | ✅ kubeadm sets owner root:root and mode 0600 by default |

---

## 3. Control Plane Configuration

### 3.1 Authentication & Authorization

| ID | Recommendation | Status | Implementation |
|---|---|---|---|
| 3.1.1 | Client cert auth over tokens | ✅ | kubeadm uses client certs by default for admin.conf |
| 3.1.2 | Service account token volume projection | ⚠️ | Default since v1.20. Can fine-tune `--service-account-issuer` |

### 3.2 Logging

| ID | Recommendation | Status | Implementation |
|---|---|---|---|
| 3.2.1 | Audit policy file | ✅ | `roles/kubernetes/files/audit-policy.yaml` — production-tuned: drops noisy URLs/events, Metadata for secrets/configmaps, full RequestResponse for mutations |
| 3.2.2 | Audit log level Metadata or higher | ✅ | Policy provides Metadata + RequestResponse for mutations |

---

## 4. Worker Nodes

### 4.1 Worker Node Configuration Files

| ID | Recommendation | Status |
|---|---|---|
| 4.1.1-4.1.10 | kubelet config file permissions/ownership | ✅ kubeadm default — kubeconfig owned by root, mode 0600 |

### 4.2 Kubelet

| ID | Recommendation | Status | Implementation |
|---|---|---|---|
| 4.2.1 | `--anonymous-auth=false` for kubelet | ✅ | kubeadm KubeletConfiguration default |
| 4.2.2 | `--authorization-mode=Webhook` for kubelet | ✅ | kubeadm default |
| 4.2.3 | `--client-ca-file` for kubelet | ✅ | kubeadm default |
| 4.2.4 | `--read-only-port=0` | ✅ | Default disabled in modern kubeadm |
| 4.2.5 | `--streaming-connection-idle-timeout` | ⚠️ | Default 4h. Can be tuned in KubeletConfiguration |
| 4.2.6 | `--make-iptables-util-chains=true` | ✅ | Default true |
| 4.2.7 | `--hostname-override` unset | ✅ | Default (uses node name) |
| 4.2.8 | Reasonable `--event-qps` | ✅ | Default |
| 4.2.9 | `--tls-cert-file` / `--tls-private-key-file` | ✅ | Auto-generated via serverTLSBootstrap |
| 4.2.10 | `--rotate-certificates=true` | ✅ | Default since 1.27+ |
| 4.2.11 | `--rotate-kubelet-server-certificate=true` | ✅ | `featureGates.RotateKubeletServerCertificate: true` |
| 4.2.12 | `serverTLSBootstrap=true` | ✅ | `KubeletConfiguration.serverTLSBootstrap: true` + hardening role auto-approves kubelet-serving CSRs |
| 4.2.13 | `--tls-cipher-suites` restricted to strong ciphers | ❌ | Can add `tlsCipherSuites` to KubeletConfiguration |

---

## 5. Policies (cluster-level)

### 5.1 RBAC

| ID | Recommendation | Status | Implementation |
|---|---|---|---|
| 5.1.1 | Grant `cluster-admin` sparingly | ⚠️ | Admin responsibility — kubeadm provisions admin.conf with cluster-admin |
| 5.1.2-5.1.6 | Fine-grained RBAC | ❌ | Admin should review per workload |

### 5.2 Pod Security Standards

| ID | Recommendation | Status | Implementation |
|---|---|---|---|
| 5.2.x | Apply Pod Security Admission `restricted` profile | ❌ | Not implemented. Can be added via `apiServer.extraArgs --admission-control-config-file` |

### 5.3 Network Policies

| ID | Recommendation | Status | Implementation |
|---|---|---|---|
| 5.3.1 | CNI supporting NetworkPolicy | ✅ | Calico CNI |
| 5.3.2 | Default deny-all NetworkPolicy | ❌ | Admin should apply per namespace |

### 5.4 Secrets

| ID | Recommendation | Status |
|---|---|---|
| 5.4.1 | Encryption at rest | ❌ Not implemented |
| 5.4.2 | External secret store (Vault) | ❌ Out of scope |

### 5.7 General

| ID | Recommendation | Status | Implementation |
|---|---|---|---|
| 5.7.1 | Namespace isolation | ⚠️ | Default kube-system / kube-public / default — admin should partition further |
| 5.7.4 | Default namespace unused | ⚠️ | Admin to enforce |

---

## Audit Logging

Policy file at `roles/kubernetes/files/audit-policy.yaml`:

| Rule | Level | Applies to |
|---|---|---|
| Health/metrics URLs (`/healthz*`, `/livez*`, `/readyz*`, `/metrics*`, `/version`, `/swagger*`) | None | Dropped entirely |
| Events | None | Dropped (very high volume) |
| kube-controller-manager / scheduler / endpoint-controller on kube-system | None | Drops internal control loops |
| `system:nodes` reads | None | Drops kubelet heartbeats |
| Secrets / configmaps / serviceaccount tokens | Metadata | Body NOT logged |
| Mutating verbs (create/update/patch/delete) | RequestResponse | Full log |
| Everything else | Metadata | Metadata only |

Retention:
- `--audit-log-maxage=90` days
- `--audit-log-maxbackup=20` files
- `--audit-log-maxsize=100` MB / file
- ~2 GB total rolling, kept for 90 days

---

## Quick verify

```bash
# CIS 1.2.1
ansible masters -b -o -a "grep anonymous-auth /etc/kubernetes/manifests/kube-apiserver.yaml"
# Expect: - --anonymous-auth=false

# CIS 1.2.18-21 audit
ansible masters -b -o -a "grep audit-log /etc/kubernetes/manifests/kube-apiserver.yaml"
# Expect: --audit-log-path / --audit-log-maxage=90 / etc.

# CIS 4.2.12 kubelet serving cert rotation
ansible all -b -o -a "grep -E 'serverTLSBootstrap|RotateKubeletServerCertificate' /var/lib/kubelet/config.yaml"
# Expect: serverTLSBootstrap: true / RotateKubeletServerCertificate: true

# Audit logs are being written
ansible masters -b -o -a "ls -lh /u01/app/log/kubernetes/audit/"
ansible masters[0] -b -a "tail -5 /u01/app/log/kubernetes/audit/audit.log"

# Anonymous requests are rejected
ansible masters -b -o -a "curl -sk -o /dev/null -w '%{http_code}' https://localhost:6443/api/v1/namespaces"
# Expect: 401
```

---

## Roadmap (not yet implemented)

- [ ] CIS 1.2.25 — EncryptionConfig for etcd secrets
- [ ] CIS 1.3.2 / 1.4.1 — `--profiling=false` for controller-manager + scheduler
- [ ] CIS 4.2.13 — `tlsCipherSuites` for kubelet
- [ ] CIS 5.2.x — Pod Security Admission `restricted` profile
- [ ] CIS 5.3.2 — Default deny-all NetworkPolicy
