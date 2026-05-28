# Script Reference

Every script in the repo, what it does, arguments, and when to run it.

Everything lives under `scripts/`. User-facing entry points sit at `scripts/`; internal helpers called by automation live in `scripts/helpers/`.

```
scripts/
├── bootstrap.sh                  # interactive wizard (also `--rollback`)
├── download-artifacts.sh         # offline artifact pull/build
└── helpers/
    ├── generate-inventory.sh     # invoked by bootstrap.sh
    └── load-images.sh            # invoked by the containerd role
```

| Script | Purpose | Run on | Idempotent |
|---|---|---|---|
| `scripts/bootstrap.sh` | Interactive wizard — generates inventory + group_vars | Control node | ✅ (snapshots prior files) |
| `scripts/bootstrap.sh --rollback` | Restores the latest bootstrap snapshot | Control node | ✅ |
| `scripts/download-artifacts.sh` | Pulls every offline artifact (DEB, image, source, manifest) | Build machine (with internet) | ✅ (skips already-present files) |
| `scripts/helpers/generate-inventory.sh` | Generates `inventories/inventory.ini` from CLI args | Control node (auto) | ✅ |
| `scripts/helpers/load-images.sh` | Imports container image tarballs into containerd | Each cluster node (auto) | ✅ |

---

## `scripts/bootstrap.sh`

Interactive wizard. Generates `inventories/inventory.ini` and `inventories/group_vars/{all,masters,workers}.yml` from the answers you provide.

### Usage

```bash
./bootstrap.sh
```

The wizard walks through the following sections (every prompt has a sensible default — press Enter to accept):

| Section | Prompt | Default | Notes |
|---|---|---|---|
| Cluster Identity | Cluster name | `k8s-cluster` | Logical cluster name |
| | App user | `app` | Linux user created on every node. If different from `app`, Ansible auto-renames the existing `app` user |
| | Short name | derived | Hostname prefix, e.g. `DMS4` → `DMS4-Prod-K8s-Master-01` |
| | Environment | `Prod` | Env segment of the hostname |
| | Cluster number | (empty) | Optional. `1` → `DMS4-Prod-K8s-Cluster1-Master-01` |
| Node Topology | Master nodes | `3` | Number of masters |
| | Worker nodes | `6` | Number of workers |
| | Master/Worker IPs | `10.0.6.1X` / `10.0.6.2X` | Prompts for each IP individually |
| SSH Access | SSH user | `root` | Ansible user |
| | SSH private key | (empty) | Optional — leave empty if you use an SSH agent |
| HA | Enable VIP | `yes` | Only asked if there is more than one master |
| | VIP address | `10.0.6.100` | |
| | VIP interface | `eth0` | |
| Network | K8s version | `1.36.0` | |
| | Pod CIDR | `10.244.0.0/16` | Must not overlap the LAN range |
| | Service CIDR | `10.96.0.0/12` | |
| | Calico IP autodetection | `first-found` | Prefer `interface=eth0` or `cidr=10.0.6.0/24` |
| | Data partition root | (empty) | e.g. `/u01/app` — containerd, pod logs, audit logs, offline images, and backups all move under this root |
| | Configure host firewall (iptables)? | `yes` | Installs the `iptables` role (protects control-plane/etcd/kubelet ports; API via HAProxy `8443`). Answer `no` to skip |

### Output

- `inventories/inventory.ini` — Ansible inventory with hostnames + IPs
- `inventories/group_vars/all.yml` — all config (master_ha, worker_ha, calico, audit, kubelet, …)
- `inventories/group_vars/masters.yml` — `node_role: master`
- `inventories/group_vars/workers.yml` — `node_role: worker`
- `.bootstrap-backups/<timestamp>/` — snapshot of the previous files before overwrite

### Important

- **`group_vars/` MUST live under `inventories/`**. Ansible only loads `group_vars/` directories adjacent to either the inventory or the playbook.
- If variables are silently ignored, check the location first.
- Re-running `bootstrap.sh` is safe — each run snapshots the previous files into `.bootstrap-backups/<timestamp>/`.

---

## `scripts/bootstrap.sh --rollback`

Rolls back the config to the snapshot made by the most recent `bootstrap.sh` wizard run. Reads the newest backup under `.bootstrap-backups/`.

### Usage

```bash
./scripts/bootstrap.sh --rollback
```

Restores every file listed in the backup manifest:
- `inventories/inventory.ini`
- `inventories/group_vars/all.yml`
- `inventories/group_vars/masters.yml`
- `inventories/group_vars/workers.yml`

### When to use

- After a bad wizard answer set, to revert without re-typing everything.
- When trying multiple configurations and you want to return to the previous one.

---

## `scripts/helpers/generate-inventory.sh`

Generates `inventories/inventory.ini`. Called internally by `bootstrap.sh` but can also be invoked directly.

### Arguments

```
--environment-name <Prod|Stag|Dev>           # Required
--hostname-cluster-number <N>                # Optional, adds "Cluster<N>" to hostnames
--master-count <N>                           # Required
--master-ips "ip1,ip2,..."                   # Comma-separated
--worker-count <N>                           # Required
--worker-ips "ip1,ip2,..."                   # Comma-separated
--project-name <name>                        # Default: k8s-cluster
--project-short-name <prefix>                # Default: derived from project-name
--ansible-user <user>                        # Default: root
--ansible-ssh-private-key-file <path>        # Optional
```

### Example

```bash
./scripts/helpers/generate-inventory.sh \
    --environment-name Prod \
    --hostname-cluster-number 1 \
    --master-count 3 \
    --master-ips "10.0.6.11,10.0.6.12,10.0.6.13" \
    --worker-count 6 \
    --worker-ips "10.0.6.21,10.0.6.22,10.0.6.23,10.0.6.24,10.0.6.25,10.0.6.26" \
    --project-name "dms4-cluster" \
    --project-short-name "DMS4" \
    --ansible-user root
```

---

## `scripts/download-artifacts.sh`

Downloads or builds every offline artifact. Must run on a machine with internet access and the correct OS (Ubuntu 24.04+).

### Usage

```bash
# Download everything
./scripts/download-artifacts.sh

# Run a single step (or several)
./scripts/download-artifacts.sh haproxy
./scripts/download-artifacts.sh haproxy deb

# Help
./scripts/download-artifacts.sh --help
```

### Steps (each can run independently)

| Step | Description | Output | Time |
|---|---|---|---|
| `binaries` | Downloads containerd, runc, crictl, helm, k9s, kubeadm/kubelet/kubectl, and `etcdctl` (version matched to the cluster's etcd image) | `artifacts/bin/` | ~3 min |
| `haproxy` | Downloads HAProxy 3.2.0 source → compiles (full features: OpenSSL, PCRE2, zlib, systemd) → packages as a binary tarball | `artifacts/bin/haproxy-<ver>.tar.gz` | ~5 min |
| `deb` | Downloads offline DEB packages (kubeadm, kubelet, kubectl, keepalived, iptables-persistent, ipset, socat, conntrack, ipvsadm + transitive deps) | `artifacts/packages/*.deb` | ~2 min |
| `manifests` | Downloads Calico + metrics-server YAML | `artifacts/manifests/` | <1 min |
| `images` | Pulls every Kubernetes / Calico / metrics-server image and saves as tar | `artifacts/images/*.tar` | ~5-10 min |
| `manifest` | Writes a version + file-list summary | `artifacts/manifests/installers-manifest.txt` | <1s |

### Environment variables (version override)

```bash
K8S_VERSION=1.36.0           # Kubernetes
CALICO_VERSION=v3.32.0       # Calico CNI
CONTAINERD_VERSION=2.3.1     # containerd
RUNC_VERSION=1.4.0           # runc
CRICTL_VERSION=v1.36.0       # crictl
HELM_VERSION=3.20.1          # helm
K9S_VERSION=v0.50.18         # k9s
HAPROXY_VERSION=3.2.0        # HAProxy source
METRICS_SERVER_VERSION=v0.8.1 # metrics-server
ETCD_VERSION=                # etcdctl release; empty = auto-derive from kubeadm's etcd image
IMAGE_PLATFORM=linux/amd64   # container image platform
```

> `ETCD_VERSION` is left empty by default — the `binaries` step runs `kubeadm config images list` and derives the matching etcd release (e.g. image `3.6.6-0` → `v3.6.6`). Set it explicitly (e.g. `ETCD_VERSION=v3.6.6`) only if that derivation fails (no network to query, custom registry, etc.).

Override example:
```bash
K8S_VERSION=1.35.0 HAPROXY_VERSION=3.2.5 ./scripts/download-artifacts.sh
```

### Build dependencies (only needed for the `haproxy` step)

The script auto-installs them via `apt-get` (with `sudo` if not root) when any are missing:

```bash
apt-get install -y build-essential pkg-config libssl-dev libpcre2-dev zlib1g-dev libsystemd-dev
```

If a third-party PPA is broken (e.g. `tsuru`), the script prints a WARN and proceeds to install from the Ubuntu official repos.

### Verify

```bash
# Combined manifest
cat artifacts/manifests/installers-manifest.txt

# Inspect each kind
ls artifacts/packages/ | head
ls artifacts/images/ | head
ls artifacts/bin/
```

### Pre-flight checks

The script bails out early if:
- The OS is not Ubuntu 24.04+
- `apt-get` is missing
- For the `haproxy` step: `gcc`, `make`, `pkg-config`, or any required dev lib is missing

---

## `scripts/helpers/load-images.sh`

Loads every container image tar into the containerd `k8s.io` namespace. **Not invoked directly** — the `containerd` role copies it to each node and runs it.

### Usage (manual, if needed)

```bash
ctr namespace ls   # verify k8s.io namespace exists
./scripts/helpers/load-images.sh /var/lib/k8s-offline-images
# Or the data-partition path:
./scripts/helpers/load-images.sh /u01/app/lib/k8s-offline-images
```

### Behavior

- Every `*.tar` in the directory is imported via `ctr -n k8s.io images import`.
- Tar integrity is verified beforehand (`tar -tf`).
- Corrupt tars are skipped with a warning.
- Exits with code 1 if any image fails (full summary printed at the end).
- Imports first with `--digests`, then retries without (for older images that don't carry them).

### Environment variables

```bash
IMAGE_PLATFORM=linux/amd64   # default
```

---

## `scripts/backup-etcd.sh`

Takes an etcd snapshot of the **local** member and rotates old snapshots. The `backup` role copies it to every master (alongside `etcdctl` in `/usr/local/bin`) and schedules it via cron at 23:55. Run on a control-plane node — needs read access to `/etc/kubernetes/pki/etcd`.

### Usage

```bash
# Standalone (auto-detects the local endpoint + certs)
/u01/app/scripts/backup-etcd.sh

# Override destination / retention / endpoint
BACKUP_DST=/mnt/snap RETENTION_DAYS=30 /u01/app/scripts/backup-etcd.sh
```

### Behavior

- Auto-detects the local client endpoint from `--advertise-client-urls` in `/etc/kubernetes/manifests/etcd.yaml` (falls back to `https://127.0.0.1:2379`). `snapshot save` only accepts **one** endpoint, so each master backs up its own member.
- Saves `etcd-snapshot-<YYYYmmdd-HHMMSS>.db`, then verifies it with `etcdctl snapshot status`.
- Deletes snapshots older than `RETENTION_DAYS` (default 90).

### Environment variables

```bash
ETCD_ENDPOINT=               # default: local member from etcd.yaml
ETCD_CACERT=/etc/kubernetes/pki/etcd/ca.crt
ETCD_CERT=/etc/kubernetes/pki/etcd/server.crt
ETCD_KEY=/etc/kubernetes/pki/etcd/server.key
BACKUP_DST=/u01/app/backup/etcd
RETENTION_DAYS=90
```

### Exit codes

- `2` — missing `etcdctl` or unreadable certs (pre-flight)
- `1` — snapshot save or integrity check failed

---

## `scripts/backup-k8s-config.sh`

Archives the node's Kubernetes config into a single zip and rotates old archives. The `backup` role copies it to **every** node (master + worker) and schedules it via cron at 23:55.

### Usage

```bash
/u01/app/scripts/backup-k8s-config.sh
BACKUP_DST=/mnt/cfg RETENTION_DAYS=30 /u01/app/scripts/backup-k8s-config.sh
```

### Behavior

- Stages `/etc/kubernetes`, kubelet config (`/var/lib/kubelet/config.yaml`, `/etc/default/kubelet`, `/etc/sysconfig/kubelet`, systemd drop-in), and kubeadm config (file, or dumped from the `kubeadm-config` ConfigMap via `kubectl` on masters).
- Zips into `kubernetes-backup-<YYYYmmdd-HHMMSS>.zip` — extracts to a folder of the same name (staged in a `mktemp` dir, auto-cleaned on exit).
- Deletes archives older than `RETENTION_DAYS` (default 90).
- Requires `zip`. On a worker with no kubeadm config, that section is simply skipped.

### Environment variables

```bash
BACKUP_DST=/u01/app/backup/kubernetes
RETENTION_DAYS=90
```

### Exit codes

- `2` — `zip` not installed
- `1` — archive creation failed

---

## Typical workflow

```bash
# Step 1: On the build machine (internet, Ubuntu 24.04+)
./scripts/download-artifacts.sh

# Step 2: Copy artifacts/ + the repo to the control node inside the airgap
rsync -av k8s-airgap-bootstrap/ user@control-node:/path/to/

# Step 3: On the control node, generate inventory + config
cd /path/to/k8s-airgap-bootstrap
./scripts/bootstrap.sh

# Step 4: Deploy
ansible-playbook playbooks/site.yml
```
