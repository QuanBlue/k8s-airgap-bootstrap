# Restore Guide

How to restore the cluster from the backups produced by the `backup` role
(see [`docs/features.md`](features.md#backup-backup-role) and
[`docs/scripts.md`](scripts.md)).

Two independent artifacts are produced daily at 23:55:

| Artifact | Produced on | Default location | Contains |
|---|---|---|---|
| `etcd-snapshot-<TS>.db` | every master | `/u01/app/backup/etcd/` | full etcd key-value store (all cluster objects) |
| `kubernetes-backup-<TS>.zip` | every node | `/u01/app/backup/kubernetes/` | `/etc/kubernetes` (certs, manifests, kubeconfigs), kubelet + kubeadm config |

> Paths assume `DATA_PARTITION_ROOT=/u01/app` (i.e. `backup.dest_root: /u01/app/backup`). Adjust if yours differs — check `inventories/group_vars/all.yml`.

**Which one do I need?**

- **Lost / corrupted cluster *data*** (objects deleted, etcd corrupt, bad upgrade) → restore the **etcd snapshot**. This rolls the whole cluster state back to the snapshot time.
- **Lost a master's *files*** (PKI/certs wiped, `/etc/kubernetes` gone, rebuilding a master host) → restore the **k8s config zip**.
- **Total disaster** (rebuild masters from bare OS) → restore the **config zip first** (to get certs/PKI back), **then** the etcd snapshot.

---

## Part 1 — Restore etcd (stacked, 3 masters)

This is a **destructive, cluster-wide** operation: every master is rolled back to the same snapshot. Do it during a maintenance window. Pick **one** snapshot file and copy it to all masters so every member restores from an identical source.

### 1.1 Pre-flight

On each master, gather the per-member values straight from the live etcd static pod (do this **before** stopping anything):

```bash
manifest=/etc/kubernetes/manifests/etcd.yaml
grep -oE -- '--name=[^ ]+'                         "$manifest"   # member name
grep -oE -- '--initial-advertise-peer-urls=[^ ]+'  "$manifest"   # this member's peer URL
grep -oE -- '--initial-cluster=[^ ]+'              "$manifest"   # full member list (same on all)
```

Choose the snapshot to restore (same timestamp on every master):

```bash
SNAP=/u01/app/backup/etcd/etcd-snapshot-20260528-235501.db
etcdctl snapshot status -w table "$SNAP"   # sanity-check it's readable
```

Copy that exact file to the same path on **all three** masters.

### 1.2 Stop the control plane on every master

kubelet runs static pods from `/etc/kubernetes/manifests/`. Moving the manifests out stops kube-apiserver and etcd cleanly. **Run on each master:**

```bash
sudo mkdir -p /etc/kubernetes/manifests.bak
sudo mv /etc/kubernetes/manifests/{kube-apiserver,kube-controller-manager,kube-scheduler,etcd}.yaml \
        /etc/kubernetes/manifests.bak/

# Wait until etcd + apiserver containers are gone
sudo crictl ps | grep -E 'etcd|kube-apiserver' || echo "control plane stopped"
```

Then move the old data directory aside on **each** master:

```bash
sudo mv /var/lib/etcd /var/lib/etcd.old-$(date +%Y%m%d-%H%M%S)
```

### 1.3 Restore the snapshot on each master

Run **on every master**, substituting that master's own `--name` / peer URL (from step 1.1). `--initial-cluster` and `--initial-cluster-token` must be **identical** across all three.

```bash
# --- values for THIS master ---
NAME=<member-name>                              # e.g. DMS4-Prod-K8s-Cluster1-Master-01
PEER=https://<this-master-ip>:2380              # this member's peer URL
CLUSTER='<name1>=https://<ip1>:2380,<name2>=https://<ip2>:2380,<name3>=https://<ip3>:2380'
TOKEN=etcd-restore-20260528                     # any string, SAME on all masters
SNAP=/u01/app/backup/etcd/etcd-snapshot-20260528-235501.db

sudo ETCDCTL_API=3 etcdctl snapshot restore "$SNAP" \
  --name "$NAME" \
  --initial-advertise-peer-urls "$PEER" \
  --initial-cluster "$CLUSTER" \
  --initial-cluster-token "$TOKEN" \
  --data-dir /var/lib/etcd
```

This recreates `/var/lib/etcd` with the snapshot data and the new membership. The default mount in `etcd.yaml` already points at `/var/lib/etcd`, so no manifest edit is needed.

### 1.4 Bring the control plane back

On **each** master, move the manifests back:

```bash
sudo mv /etc/kubernetes/manifests.bak/{etcd,kube-apiserver,kube-controller-manager,kube-scheduler}.yaml \
        /etc/kubernetes/manifests/
```

kubelet restarts the static pods. etcd members discover each other via `--initial-cluster` and form quorum.

### 1.5 Verify

```bash
# etcd health (run on a master)
sudo etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health --cluster

sudo etcdctl ... member list -w table   # expect 3 started members

# cluster
kubectl get nodes
kubectl get pods -A
```

> **Note:** restoring rolls state back to the snapshot. Objects created *after* the snapshot are gone; any node that joined after it may show `NotReady` and need to re-join. Pods are reconciled by their controllers once the API is back.

---

## Part 2 — Restore Kubernetes config (per node)

The zip restores the control-plane files for a single node — certs/PKI, static-pod manifests, kubeconfigs, kubelet/kubeadm config. Use it when a node's `/etc/kubernetes` is lost or you are rebuilding a master host.

### 2.1 Extract

```bash
cd /tmp
unzip /u01/app/backup/kubernetes/kubernetes-backup-20260528-235501.zip
cd kubernetes-backup-20260528-235501
ls -R          # kubernetes-etc/  kubelet/  kubeadm/
```

### 2.2 Restore `/etc/kubernetes`

```bash
# Optional safety copy of whatever is there now
sudo cp -a /etc/kubernetes /etc/kubernetes.bak-$(date +%Y%m%d-%H%M%S) 2>/dev/null || true

# Restore (certs, keys, *.conf, manifests, audit policy …)
sudo cp -rp kubernetes-etc/. /etc/kubernetes/
sudo chown -R root:root /etc/kubernetes
```

### 2.3 Restore kubelet config (if kubelet was reinstalled)

```bash
sudo cp -p kubelet/config.yaml          /var/lib/kubelet/config.yaml
sudo cp -p kubelet/kubelet              /etc/default/kubelet 2>/dev/null || true
sudo cp -rp kubelet/kubelet.service.d   /usr/lib/systemd/system/
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

### 2.4 Restore kubeadm config (optional)

`kubeadm/kubeadm-config.yaml` is the `kubeadm-config` ConfigMap dump. Re-apply only if it was lost (needed for `kubeadm upgrade` / `kubeadm join`):

```bash
kubectl apply -f kubeadm/kubeadm-config.yaml   # when the API is reachable
```

### 2.5 Verify

```bash
sudo systemctl status kubelet
kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes
```

> **Caution:** restore a node's config zip **only onto that same node** (or a replacement taking the same identity). Cross-restoring certs/manifests between different masters will break TLS — the apiserver cert, etcd peer certs and `*.conf` are bound to that node's name/IP.

---

## Disaster recovery order (rebuild masters from scratch)

1. Reinstall the OS + install the binaries/DEBs from the airgap bundle (see [`docs/airgap-guide.md`](airgap-guide.md)). Ensure `etcdctl` is on the masters.
2. **Restore the config zip** on `masters[0]` (Part 2) to recover the PKI/certs.
3. **Restore the etcd snapshot** on `masters[0]` as a single member (`--initial-cluster` listing only itself), then bring its control plane up.
4. Re-join the other masters with `kubeadm join --control-plane` (they get fresh certs from the restored CA) — or restore their config zips and add them as etcd members.
5. Verify with `kubectl get nodes` and `etcdctl member list`.

---

## Quick reference

| Task | Command |
|---|---|
| List snapshots | `ls -lt /u01/app/backup/etcd/` |
| Inspect a snapshot | `etcdctl snapshot status -w table <file>` |
| List config archives | `ls -lt /u01/app/backup/kubernetes/` |
| Peek into an archive | `unzip -l <file>` |
| Backup logs | `/u01/app/backup/logs/{etcd-backup,k8s-config-backup}.log` |
