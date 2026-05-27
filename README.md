<h1 align="center">
  <img src="./assets/favicon.png" alt="icon" width="200"></img>
  <br>
  <b>ansible-airgap-k8s</b>
</h1>

<p align="center">Production-grade Ansible automation for fully air-gapped Kubernetes clusters with multi-master HA, CIS-aligned hardening, and an interactive bootstrap wizard.</p>

<!-- Badges -->
<p align="center">
  <a href="https://github.com/QuanBlue/k8s-airgap-bootstrap/graphs/contributors">
    <img src="https://img.shields.io/github/contributors/QuanBlue/k8s-airgap-bootstrap" alt="contributors" />
  </a>
  <a href="">
    <img src="https://img.shields.io/github/last-commit/QuanBlue/k8s-airgap-bootstrap" alt="last update" />
  </a>
  <a href="https://github.com/QuanBlue/k8s-airgap-bootstrap/network/members">
    <img src="https://img.shields.io/github/forks/QuanBlue/k8s-airgap-bootstrap" alt="forks" />
  </a>
  <a href="https://github.com/QuanBlue/k8s-airgap-bootstrap/stargazers">
    <img src="https://img.shields.io/github/stars/QuanBlue/k8s-airgap-bootstrap" alt="stars" />
  </a>
  <a href="https://github.com/QuanBlue/k8s-airgap-bootstrap/issues/">
    <img src="https://img.shields.io/github/issues/QuanBlue/k8s-airgap-bootstrap" alt="open issues" />
  </a>
  <a href="https://github.com/QuanBlue/k8s-airgap-bootstrap/blob/master/LICENSE">
    <img src="https://img.shields.io/github/license/QuanBlue/k8s-airgap-bootstrap.svg" alt="license" />
  </a>
</p>

<p align="center">
  <b>
      <a href="#demo">Demo</a> •
      <a href="./docs/">Documentation</a> •
      <a href="https://github.com/QuanBlue/k8s-airgap-bootstrap/issues/">Report Bug</a> •
      <a href="https://github.com/QuanBlue/k8s-airgap-bootstrap/issues/">Request Feature</a>
  </b>
</p>

<br/>

<div align="center">
  <div>
    <img src="./assets/bootstrap-demo.gif" height="350" alt="bootstrap wizard demo"/>
    <div>
      <i>Interactive bootstrap wizard</i>
    </div>
  </div>
  <br/>
  <div >
    <img src="./assets/cluster-demo.png" height="450" alt="cluster up demo"/>
    <div>
      <i>HA cluster ready with kube-apiserver hardened</i>
    </div>
  </div>
</div>

<details open>
<summary><b>📖 Table of Contents</b></summary>

- [Demo](#film_projector-demo)
- [Key features](#star-key-features)
- [Architecture](#building_construction-architecture)
- [Getting start](#toolbox-getting-start)
  - [Prerequisites](#pushpin-prerequisites)
  - [Environment Variables](#key-environment-variables)
  - [Run locally](#hammer_and_wrench-run-locally)
    - [Manually](#manually)
    - [Selective steps](#selective-steps)
- [Scripts](#scroll-scripts)
- [CIS Hardening](#lock-cis-hardening)
- [Roadmap](#world_map-roadmap)
- [Contributors](#busts_in_silhouette-contributors)
- [Credits](#sparkles-credits)
- [License](#scroll-license)
- [Related Projects](#link-related-projects)
</details>

# :film_projector: Demo

See it in action:

- **Bootstrap wizard**: `./scripts/bootstrap.sh` — interactive node topology, VIP, audit, data-partition config.
- **Full deploy**: `ansible-playbook playbooks/site.yml` — `prepare → ha → kubernetes → addons → hardening` in one command.
- **Tag-driven re-runs**: `--tags addons` or `--tags hardening` to re-apply just one slice without re-running the whole pipeline.

# :star: Key features

- **Fully air-gapped** — DEB packages, container images, kubelet/kubeadm/kubectl binaries, and a from-source HAProxy build are all bundled offline.
- **Multi-master HA** — HAProxy (compiled from source v3.2.0) + Keepalived VIP, with a port-split design (VIP:8443 → masters:6443) so HAProxy and the apiserver coexist on the same master nodes.
- **CIS-aligned hardening** — anonymous-auth disabled (1.2.1), TLS 1.2+ with a strong cipher list (1.2.14/1.2.15), full API audit logging (1.2.18-22, 3.2.1), kubelet serving cert rotation with auto-CSR-approval (4.2.12). Full mapping: [`docs/cis-compliance.md`](docs/cis-compliance.md).
- **Modern stack** — containerd v2.3.1 runtime, Calico CNI in VXLAN mode, metrics-server v0.8.1 with 2 replicas + resource limits.
- **Configurable data partition** — every filesystem-heavy path (containerd root, kubelet pod logs, audit logs, offline images) follows one wizard prompt.
- **Idempotent** — playbooks detect stale state and self-heal (auto-reset+init on a dead apiserver, rename-or-skip for app user, replace-without-duplicates for hardening patches).
- **Interactive wizard** — `bootstrap.sh` walks through cluster identity, topology, IPs, VIP, network CIDRs, Calico autodetection, and data partition root — every prompt has a sensible default.
- **Dynamic topology** — any master/worker count, IPs prompted per node, hostnames templated as `<Short>-<Env>[-Cluster<N>]-K8s-Master|Worker-NN`.
- **Cluster operations UX** — `k9s` installed on every master for both `root` and the application user.
- **Full teardown** — `playbooks/teardown.yml` reverses everything `site.yml` installed.

# :building_construction: Architecture

```
            ┌──────────────────────────────────────────┐
 Clients →  │       VIP:8443 (Keepalived MASTER)       │
            │              │                           │
            │              ▼  HAProxy on each master   │
            │   ┌─────────────────────────────────┐    │
            │   │  master-01  │ master-02  │ ...  │    │
            │   │  apiserver  │ apiserver  │      │    │
            │   │   :6443     │   :6443    │      │    │
            │   └─────────────────────────────────┘    │
            │              │                           │
            │              ▼                           │
            │           etcd cluster                   │
            └──────────────────────────────────────────┘
```

Details: [`docs/ha-architecture.md`](docs/ha-architecture.md).

# :toolbox: Getting start

## :pushpin: Prerequisites

- **Ubuntu 24.04 LTS or newer** on the build host, control node, and every target node — RPM/yum is not supported.
- Ansible on the control node.
- SSH key-based access from the control node to every master / worker.
- Internet access on the build host (one-time, only to populate `artifacts/`).
- For the HAProxy source step: `build-essential`, `pkg-config`, `libssl-dev`, `libpcre2-dev`, `zlib1g-dev`, `libsystemd-dev` (the script auto-installs them on first run).

## :key: Environment Variables

Override the versions used by `./scripts/download-artifacts.sh`:

```sh
K8S_VERSION=1.36.0            # Kubernetes
CALICO_VERSION=v3.32.0        # Calico CNI
CONTAINERD_VERSION=2.3.1      # containerd
RUNC_VERSION=1.4.0            # runc
CRICTL_VERSION=v1.36.0        # crictl
HELM_VERSION=3.20.1           # helm
K9S_VERSION=v0.50.18          # k9s
HAPROXY_VERSION=3.2.0         # HAProxy source
METRICS_SERVER_VERSION=v0.8.1 # metrics-server
IMAGE_PLATFORM=linux/amd64    # container image platform
```

Example:

```sh
K8S_VERSION=1.35.0 HAPROXY_VERSION=3.2.5 ./scripts/download-artifacts.sh
```

Cluster-level settings live under `inventories/group_vars/all.yml` (generated by the wizard). See [`docs/features.md`](docs/features.md) for the full list.

> **Note**: `group_vars/` must live under `inventories/` — Ansible only loads `group_vars/` adjacent to either the inventory or the playbook.

## :hammer_and_wrench: Run locally

### Manually

```bash
# Clone the repo (on the build host with internet)
git clone https://github.com/QuanBlue/k8s-airgap-bootstrap.git
cd k8s-airgap-bootstrap

# 1. Pull / build every offline artifact
./scripts/download-artifacts.sh

# 2. Move repo + artifacts/ to the airgap control node
tar -czvf k8s-airgap-bundle.tar.gz k8s-airgap-bootstrap/
# … copy via USB / private network …
tar -xzvf k8s-airgap-bundle.tar.gz && cd k8s-airgap-bootstrap

# 3. Generate inventory + group_vars
./scripts/bootstrap.sh

# 4. Deploy
ansible-playbook playbooks/site.yml
```

### Selective steps

Run just the parts you need:

```sh
# Only build the HAProxy binary tarball
./scripts/download-artifacts.sh haproxy

# Only re-deploy addons (Calico, metrics-server)
ansible-playbook playbooks/site.yml --tags addons

# Only re-apply CIS hardening (anonymous-auth, probes, kubelet CSRs)
ansible-playbook playbooks/site.yml --tags hardening

# Roll back the latest bootstrap (config only — cluster untouched)
./scripts/bootstrap.sh --rollback

# Tear the cluster down completely
ansible-playbook playbooks/teardown.yml
ansible-playbook playbooks/teardown.yml -e remove_app_user=true   # also removes the app user
```

# :scroll: Scripts

Full reference (args, env vars, output paths, idempotency notes): [`docs/scripts.md`](docs/scripts.md).

```
scripts/
├── bootstrap.sh                  # interactive wizard (also `--rollback` to undo latest run)
├── download-artifacts.sh         # offline artifact pull/build
└── helpers/
    ├── generate-inventory.sh     # invoked by bootstrap.sh
    └── load-images.sh            # invoked by the containerd role
```

| Script | Purpose |
|---|---|
| `./scripts/bootstrap.sh` | Interactive wizard — generates inventory + group_vars |
| `./scripts/bootstrap.sh --rollback` | Rolls bootstrap back to the latest snapshot |
| `./scripts/download-artifacts.sh` | Downloads every offline artifact (DEBs, binaries, HAProxy source build, images) |
| `./scripts/helpers/generate-inventory.sh` | Generates `inventories/inventory.ini` from CLI args (called by `bootstrap.sh`) |
| `./scripts/helpers/load-images.sh` | Imports container image tarballs into containerd (run by Ansible) |

# :lock: CIS Hardening

The repo automatically applies a curated subset of the [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes) as the last play of `site.yml`. Highlights:

| CIS | Control | Where it's set |
|---|---|---|
| 1.2.1 | `--anonymous-auth=false` (+ tcpSocket probes) | post-init `kubernetes-hardening` role |
| 1.2.14 | `--tls-min-version=VersionTLS12` | `apiServer.extraArgs` in kubeadm-init |
| 1.2.15 | `--tls-cipher-suites` strong-only | `apiServer.extraArgs` in kubeadm-init |
| 1.2.18-22 | API audit log path / max-age / max-backup / max-size | `apiServer.extraArgs` |
| 3.2.1 | Audit policy file | `roles/kubernetes/files/audit-policy.yaml` |
| 4.2.11 | `--rotate-kubelet-server-certificate=true` | KubeletConfiguration featureGates |
| 4.2.12 | `serverTLSBootstrap=true` + auto-approve kubelet-serving CSRs | KubeletConfiguration + hardening role |

Full mapping (including ⚠️ partial / ❌ todo items): [`docs/cis-compliance.md`](docs/cis-compliance.md).

# :world_map: Roadmap

- [x] Air-gapped artifact pipeline (DEB + binaries + HAProxy source build + images)
- [x] Multi-master HA with HAProxy + Keepalived
- [x] Interactive bootstrap wizard
- [x] Configurable data partition
- [x] Idempotent install / re-run / teardown
- [x] CIS hardening
  - [x] `--anonymous-auth=false`
  - [x] TLS minimum version + cipher suite restriction
  - [x] API audit logging
  - [x] Kubelet serving cert rotation
- [x] Addons
  - [x] Calico (VXLAN)
  - [x] metrics-server (2 replicas + limits)
  - [x] k9s
- [ ] Encryption at rest for etcd Secrets (CIS 1.2.25)
- [ ] Pod Security Admission `restricted` profile (CIS 5.2.x)
- [ ] Default deny-all NetworkPolicy per namespace (CIS 5.3.2)
- [ ] `tlsCipherSuites` restriction for kubelet (CIS 4.2.13)
- [ ] Optional ingress-nginx + MetalLB roles (skeletons exist)

# :busts_in_silhouette: Contributors

<a href="https://github.com/QuanBlue/k8s-airgap-bootstrap/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=QuanBlue/k8s-airgap-bootstrap" />
</a>

Contributions are always welcome!

# :sparkles: Credits

Open source components this project relies on:

- [Kubernetes](https://kubernetes.io/) / [kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/) — cluster bootstrap
- [containerd](https://containerd.io/) — container runtime
- [Calico](https://www.tigera.io/project-calico/) — CNI
- [HAProxy](https://www.haproxy.org/) — L4 load balancer
- [Keepalived](https://www.keepalived.org/) — VIP failover (VRRP)
- [Ansible](https://www.ansible.com/) — automation
- [metrics-server](https://github.com/kubernetes-sigs/metrics-server) — cluster metrics
- [k9s](https://k9scli.io/) — terminal UI for clusters
- [Helm](https://helm.sh/) / [crictl](https://github.com/kubernetes-sigs/cri-tools)

Security benchmark:

- [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)

Emoji and badges from:

- [github@thebespokepixel](https://github.com/thebespokepixel/badges) - Badges
- [github@WebpageFX](https://github.com/WebpageFX/emoji-cheat-sheet.com) - Emoji

# :scroll: License

Distributed under the MIT License. See <a href="./LICENSE">`LICENSE`</a> for more information.

# :link: Related Projects

- <u>[**QuanBlue**](https://github.com/QuanBlue/QuanBlue)</u>: My bio
- <u>[**Portfolio**](https://github.com/QuanBlue/Portfolio)</u>: My first portfolio website, using MERN stack. [Visit here](https://quanblue.netlify.app/)
- <u>[**Readme-template**](https://github.com/QuanBlue/Portfolio)</u>: A template for creating README.md

---

> Bento [@quanblue](https://bento.me/quanblue) &nbsp;&middot;&nbsp;
> GitHub [@QuanBlue](https://github.com/QuanBlue) &nbsp;&middot;&nbsp; Gmail quannguyenthanh558@gmail.com
