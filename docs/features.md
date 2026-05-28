# Features Reference

Everything the repo provides and every real-world issue it fixes.

---

## Infrastructure & Topology

### Multi-master HA with VIP
- HAProxy + Keepalived on every master node
- Automatic VIP failover when the master holding the VIP dies (Keepalived VRRP)
- `controlPlaneEndpoint = VIP:8443` → HAProxy forwards to `masters:6443`
- **Port split**: HAProxy frontend on 8443, apiserver bindPort on 6443 → no collision when both run on the same master
- HAProxy backend check: `inter 2s rise 1 fall 2` (no slowstart) — detects a backend coming up within ~2 seconds
- HAProxy logs to the systemd journal (`log stdout format raw daemon info`)
- Service `Type=notify` in master-worker mode (`-Ws`)

### Optional worker ingress VIP
- Independent from `master_ha`; configured through `worker_ha`
- HAProxy + Keepalived on every worker node
- VIP floats only across `workers`
- HAProxy listens on `80` and `443`
- Traffic is balanced only to `workers:30080` and `workers:30443`

### Single master
- HA is skipped; `controlPlaneEndpoint` is set to the first master's IP:6443

### Dynamic hostname / topology
- Configurable hostname template: `<short>-<env>[-Cluster<N>]-K8s-Master|Worker-<NN>`
- Any number of masters and workers
- Per-node IP entered through the wizard

---

## Airgap & Offline

### Every artifact downloaded ahead of time
| Type | Location | Tool |
|---|---|---|
| OS packages (DEB) | `artifacts/packages/*.deb` | `apt-get --download-only --reinstall` |
| Pre-built binaries (kubeadm/let/ctl, containerd, runc, crictl, helm, k9s) | `artifacts/bin/` | curl from GitHub releases |
| HAProxy source → compiled binary tar | `artifacts/bin/haproxy-3.2.0.tar.gz` | curl source + compile |
| Container images | `artifacts/images/*.tar` | `docker pull + save` or `ctr images pull + export` |
| Manifests (Calico, metrics-server) | `artifacts/manifests/` | curl |

### Selective download
```bash
./scripts/download-artifacts.sh haproxy    # only build HAProxy
./scripts/download-artifacts.sh deb images # DEBs + images only
```

### Container image loading
- `load-images.sh` runs on every node, importing into the containerd `k8s.io` namespace
- Verifies tar integrity before importing
- Retries without `--digests` for older images
- Fails fast if any image fails to load

---

## Security (CIS-aligned)

Full mapping: [`cis-compliance.md`](./cis-compliance.md)

### Implemented
- **Anonymous auth disabled** (CIS 1.2.1) — two-phase: init with `true` so `kubeadm join` works, then post-hardening flips it to `false` and converts the apiserver probes to `tcpSocket`
- **API audit logging** (CIS 1.2.18-22, 3.2.1) — production-tuned policy, logs go to `<DATA_PARTITION_ROOT>/log/kubernetes/audit/` with 90-day retention, 20 backups, 100 MB per file
- **Kubelet serving cert rotation** (CIS 4.2.12) — `serverTLSBootstrap=true` + `featureGates.RotateKubeletServerCertificate=true` + auto-approval of pending CSRs
- **RBAC** — kubeadm default setup
- **System user hardening** — HAProxy runs as the `haproxy` user/group (not root) with `/usr/sbin/nologin`

### Roadmap
- Encryption at rest (etcd Secrets)
- Pod Security Admission `restricted` profile
- Default deny-all NetworkPolicy per namespace
- `tlsCipherSuites` for kubelet

---

## Container Runtime

- **containerd** v2.3.1, installed from binary tarball into `/usr/local/bin/`
- **SystemdCgroup** = true
- **Root directory** configurable via `containerd_config.root_dir` (default `/var/lib/containerd`, override `/u01/app/lib/containerd`)
- **runc** v1.4.0
- **crictl** v1.36.0

---

## CNI: Calico

- Manifest mode (NOT operator)
- Auto-patched to use **VXLAN** instead of BGP/IPIP:
  - `kubectl set env daemonset/calico-node` sets `CALICO_NETWORKING_BACKEND=vxlan`, `CALICO_IPV4POOL_VXLAN=Always`, `CALICO_IPV4POOL_IPIP=Never`
  - `kubectl patch daemonset` rewrites liveness/readiness probes (drops the BIRD dependency)
  - `kubectl patch ippool` sets `ipipMode=Never, vxlanMode=Always`
- `IP_AUTODETECTION_METHOD` configurable via `calico_ip_autodetection_method` (default `first-found`, prefer `interface=eth0` or `cidr=10.0.6.0/24`)
- Waits for the DaemonSet rollout with a 180s timeout

---

## Addons

### metrics-server v0.8.1
- 2 replicas (configurable via `metrics_server.replicas`)
- Resource requests/limits configurable:
  - Default requests: 100m CPU / 200Mi memory
  - Default limits: 500m CPU / 500Mi memory
- `--kubelet-insecure-tls` (added via `lineinfile`, idempotent) — required while kubelet still uses the self-signed default cert

### k9s
- Binary installed at `/usr/local/bin/k9s` on master nodes
- Configured for the app user (kubeconfig + k9s config)

---

## OS Preparation (common role)

- Swap off (immediate + permanent in `/etc/fstab`)
- Kernel modules: `overlay`, `br_netfilter`
- Sysctl: `net.bridge.bridge-nf-call-iptables=1`, `bridge-nf-call-ip6tables=1`, `ip_forward=1`
- Hostname from inventory
- `/etc/hosts` populated with every cluster node (Ansible-managed block)
- **App user**: creates `app_user` (default `app`). If `app` already exists and `app_user != 'app'`, renames `app` → `app_user` (atomic shell script — idempotent, never creates duplicates)

---

## Kubelet

- Binary from the airgap bundle + DEB systemd service from the package
- Overrides `/usr/bin/kubelet` with the airgap version
- Drop-in `/etc/systemd/system/kubelet.service.d/10-kubeadm.conf` written by Ansible (since kubeadm is installed as a binary, not a DEB, the drop-in normally shipped by the kubeadm DEB is missing)
- KubeletConfiguration in kubeadm-init:
  - `cgroupDriver: systemd`
  - `podLogsDir` configurable (default empty, override `/u01/app/log/containerd`)
  - `volumeStatsAggPeriod: 0s`
  - `containerLogMaxSize: 50Mi`, `containerLogMaxFiles: 90`
  - `imageGCHighThresholdPercent: 65`, `imageGCLowThresholdPercent: 60`
  - `serverTLSBootstrap: true`
  - `featureGates: RotateKubeletServerCertificate: true`

---

## kubeadm

- kubeadm/kubelet/kubectl installed as raw **binaries** from the airgap bundle (NOT DEB) — easier to pin versions
- `kubernetes-cni` from the offline DEB
- Idempotency: if `/etc/kubernetes/admin.conf` exists but `/livez` does not respond, the play automatically runs `kubeadm reset --force` and re-inits
- Pre-init `kubeadm reset --force` clears any stale port/state
- Cluster-info discovery: uses `--discovery-token-ca-cert-hash` (anonymous cluster-info read). After the cluster is up, hardening flips anonymous-auth to false.

### admin-local.conf (bypasses the VIP)
- Each master renders `/etc/kubernetes/admin-local.conf` pointing the server URL at its own IP:6443 instead of the VIP:8443
- Used by admin commands during bootstrap (kubeadm token, kubectl label, upload-certs) to avoid the VIP routing flakiness that occurs immediately after init

### Apiserver static-pod probes
- kubeadm default: `httpGet /livez` over HTTPS — anonymous
- With `--anonymous-auth=false`, the probe returns 401 and kubelet kills the apiserver in a loop
- **Fix**: hardening role converts `httpGet` → `tcpSocket` via a Python regex (matches both numeric ports like `6443` and named ports like `probe-port`)

---

## Node role labels

- Master: `node-role.kubernetes.io/control-plane=`, `node-role.kubernetes.io/master=`
- Worker: `node-role.kubernetes.io/worker=`
- Kubernetes always lowercases node names, so Ansible uses `inventory_hostname | lower`

---

## Teardown

`playbooks/teardown.yml` — removes everything site.yml installs:
1. `kubeadm reset --force` + iptables flush + CNI interface deletion
2. Stops/removes HAProxy (binary + systemd unit + user/group + dirs)
3. Stops/purges keepalived and its deps (apt purge)
4. Removes k9s
5. Removes kubelet/kubeadm/kubectl binaries, kubernetes-cni DEB, and the kubeadm drop-in
6. Removes `/etc/kubernetes`, `/var/lib/kubelet`, `/var/lib/etcd`, CNI dirs, audit logs
7. Removes the containerd binary + systemd unit + config + data dir + offline images
8. OS cleanup: sysctl, kernel modules, `/etc/hosts` block
9. Removes the app user (opt-in: `-e remove_app_user=true`)

```bash
ansible-playbook playbooks/teardown.yml
ansible-playbook playbooks/teardown.yml -e remove_app_user=true
```

---

## Configurable data partition

Every filesystem-heavy path can be relocated onto a custom partition (e.g. `/u01/app`):

| Path | Default | Override (DATA_PARTITION_ROOT=/u01/app) |
|---|---|---|
| containerd root | `/var/lib/containerd` | `/u01/app/lib/containerd` |
| Offline images | `/var/lib/k8s-offline-images` | `/u01/app/lib/k8s-offline-images` |
| Kubelet pod logs | (kubelet default) | `/u01/app/log/containerd` |
| Audit logs | `/var/log/kubernetes/audit` | `/u01/app/log/kubernetes/audit` |
| Backup scripts | `/opt/k8s-backup/scripts` | `/u01/app/scripts` |
| Backup output | `/var/backups/k8s` | `/u01/app/backup` |

Set via the `scripts/bootstrap.sh` wizard → "Data partition root".

---

## Backup (backup role)

The `backup` role (play 6 of `site.yml`, tag `backup`) installs two scripts and schedules them via a root cron at **23:55** daily.

| What | Script | Where it runs | Output |
|---|---|---|---|
| etcd snapshot of the local member | `backup-etcd.sh` | every master | `<dest_root>/etcd/etcd-snapshot-<TS>.db` |
| `/etc/kubernetes` + kubelet/kubeadm config archive | `backup-k8s-config.sh` | every node | `<dest_root>/kubernetes/kubernetes-backup-<TS>.zip` |

- **etcdctl** is bundled offline by `download-artifacts.sh` (the `binaries` step, version matched to the cluster's etcd image) and copied to `/usr/local/bin/etcdctl` on masters. The role fails fast on a master if the binary is missing from `artifacts/bin/`.
- Running the snapshot on **every** master means 3 copies land on 3 separate nodes — satisfying the "≥3 backups across ≥2 storage" compliance item.
- Both jobs default to **90-day** retention and log to `<dest_root>/logs/`.
- Logs are appended per job: `etcd-backup.log` and `k8s-config-backup.log`.

Configured via `group_vars/all.yml` (generated by the wizard from `DATA_PARTITION_ROOT`):

```yaml
backup:
  enabled: true
  scripts_dir: "/u01/app/scripts"
  dest_root: "/u01/app/backup"
  retention_days: 90
  schedule:
    minute: 55
    hour: 23
```

Re-run just this play with `ansible-playbook playbooks/site.yml --tags backup`. Set `backup.enabled: false` to skip it entirely.

**Restoring** from these backups: [`docs/restore-guide.md`](restore-guide.md).

---

## Host firewall (iptables role)

The `iptables` role (play 7 of `site.yml`, tag `firewall`) is prompted by the
wizard (default **on**). It installs a single custom chain `K8S-FW`, jumped at
the top of `INPUT`, that **protects the sensitive host ports** while leaving
everything else untouched. It never flushes the `filter` table or modifies
`nat`/`mangle`/`FORWARD`, so Calico and kube-proxy are unaffected; the `INPUT`
default policy stays `ACCEPT`.

**The chain `RETURN`s (trusts) traffic from:**
- loopback, `ESTABLISHED,RELATED`, ICMP
- every cluster node IP (from inventory) — covers etcd, kubelet, Calico VXLAN/BGP, kube-proxy, VRRP
- the pod CIDR and service CIDR
- any extra `firewall.admin_cidrs`

**Then it `DROP`s these ports for everyone else:**

| Node | Dropped from outside the cluster | Always open |
|---|---|---|
| master | `6443` (API), `2379-2380` (etcd), `10257` (c-m), `10259` (sched), `10250` (kubelet) | `22` (SSH), `8443` (HAProxy → API), NodePort, VRRP |
| worker | `10250` (kubelet), `10256` (kube-proxy) | `22` (SSH), optional worker VIP `80/443`, NodePort, VRRP |

So external administration must go through HAProxy `8443` (the API is not
reachable on `6443` from outside the cluster). If `worker_ha.enabled=true`,
workers may also receive ingress traffic on `80/443`. SSH stays open from
anywhere. Rules persist across reboot via `iptables-persistent`
(`/etc/iptables/rules.v4`), bundled offline by `download-artifacts.sh`.

```yaml
firewall:
  enabled: true
  nodeport_open: true       # allow 30000-32767 from anywhere
  admin_cidrs: []           # extra trusted sources for 6443/10250
```

```yaml
worker_ha:
  enabled: false
  vip_address: ""
  vip_interface: ""
  http_port: 80
  https_port: 443
  backend_http_port: 30080
  backend_https_port: 30443
```

Re-run just this play with `ansible-playbook playbooks/site.yml --tags firewall`.
Set `firewall.enabled: false` (or answer "no" in the wizard) to skip it — e.g.
when a cloud Security Group already enforces this.

> The chain ends in `RETURN` (selective protection). Changing that final rule to
> `DROP` in `roles/iptables/templates/apply-firewall.sh.j2` would upgrade it to a
> full default-deny INPUT allowlist.

---

## Idempotency

Every playbook + script is safe to re-run:
- `scripts/bootstrap.sh` snapshots prior files before overwrite
- `download-artifacts.sh` skips files already present (HAProxy tarball is idempotent too)
- App-user rename: shell logic verifies state before acting
- kubeadm init: probes apiserver `/livez`; if unreachable, resets and re-inits
- kubeadm join: checks for `admin.conf` / `kubelet.conf`, skips if already joined
- HAProxy install: uses `apt-get install` from a local cache instead of raw `dpkg -i` — apt resolves deps automatically
- Hardening role: `replace` module is naturally idempotent (no match → no change)
- CSR approval: filters on condition `<none>` (pending only)

---

## Operational notes

### group_vars location
**Must live under `inventories/group_vars/`**. Ansible does not auto-load `group_vars/` from the project root when the inventory lives under a subfolder. This bug previously caused every variable to silently fall back to role defaults.

### Ubuntu 24.04+ only
The repo was refactored to support Ubuntu 24.04 and newer exclusively. No more RPM/yum/dnf code. `download-artifacts.sh` exits early if the host OS is anything else.

### HAProxy source build
HAProxy does not publish prebuilt binaries — the script downloads source and compiles it. Build dependencies are auto-installed (`build-essential`, `pkg-config`, `libssl-dev`, `libpcre2-dev`, `zlib1g-dev`, `libsystemd-dev`).

### CSR auto-approval
`serverTLSBootstrap=true` makes each kubelet emit a Pending serving-cert CSR; the hardening role auto-approves them. This is acceptable for a trusted airgap environment. For more sensitive deployments, run a dedicated CSR approver controller instead.
