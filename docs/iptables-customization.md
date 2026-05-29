# iptables Customization Guide

This guide explains how to manage firewall rules when the repo applies the
iptables scripts under `scripts/servers/iptables/` through Ansible.

## Quick model

This repo does **not** treat `/etc/iptables/rules.v4` as the source of truth.
Instead:

1. `scripts/servers/iptables/k8s-master-iptables-rules.sh` and
   `k8s-worker-iptables-rules.sh` are the source of truth for firewall logic
2. `./scripts/bootstrap.sh` updates only the bootstrap-managed value block at
   the top of those scripts
3. Ansible copies the role-specific script onto the node and executes it
4. `netfilter-persistent save` snapshots the live rules into
   `/etc/iptables/rules.v4`

Because of that:

- `rules.v4` always contains many Kubernetes and Calico rules
- you should **not** manually edit `rules.v4` as your normal workflow
- if you add rules directly inside the repo-managed chains on a live node, a
  later Ansible firewall run may overwrite them

## Source of truth

- Firewall rule logic: `scripts/servers/iptables/k8s-master-iptables-rules.sh`
  and `scripts/servers/iptables/k8s-worker-iptables-rules.sh`
- Bootstrap-managed values injected into those scripts: synchronized by
  `./scripts/bootstrap.sh` inside the `# BEGIN BOOTSTRAP VALUES` block
- Cluster configuration values: `inventories/group_vars/all.yml`
- Saved runtime snapshot: `/etc/iptables/rules.v4` is not source of truth

## Managed chains

The repo-managed chains are:

- masters: `K8S-MASTER-IN`, `K8S-MASTER-OUT`
- workers: `K8S-WORKER-IN`, `K8S-WORKER-OUT`

The scripts also insert jumps into `INPUT` and `OUTPUT`, so manual changes in
those managed chains should be treated as temporary unless moved back into the
repo workflow.

Those jumps are inserted at the top of `INPUT` and `OUTPUT`. That means the
repo-managed allowlist and final `DROP` rules are evaluated before later
host-level rules, including any Calico-generated rules in those base chains.
For Calico safety, keep required node-to-node transport rules before the final
drop and scope them to the rendered `NODE_CIDR`.

The scripts intentionally do not flush or edit `FORWARD`, `nat`, `mangle`, or
`cali-*` chains. Kubernetes, kube-proxy, and Calico continue to own those
dataplane rules.

## Rule comments

To make rules easy to identify in `iptables-save`, `iptables -S`, or
`/etc/iptables/rules.v4`, prefer adding a comment to every custom rule:

```bash
iptables -I K8S-MASTER-IN 1 -m comment --comment "manual: allow admin laptop" -s 203.0.113.10/32 -j RETURN
```

Recommended naming:

- `manual:` for ad-hoc rules added on a node
- `temp:` for short-lived test rules
- `ticket-123:` or `change-2026-05-28:` for change-tracking

## Which place should you customize?

Use one of these three approaches depending on the goal.

### 1. Persistent, repo-managed customization

Use this when the rule should live long-term and be reproducible.

Adjust:

- the reusable logic in `scripts/servers/iptables/` when changing firewall behavior
- bootstrap inputs / inventory values when changing CIDRs, VIPs, Prometheus
  IPs, Teleport IPs/ports, NTP IPs, SOC IPs, or DB IPs

Then re-render and apply:

```bash
./scripts/bootstrap.sh
ansible-playbook playbooks/firewall.yml
```

or:

```bash
ansible-playbook playbooks/site.yml --tags firewall
```

This is the safest and most stable method.

Important:

- bootstrap preserves manual logic outside the `# BEGIN BOOTSTRAP VALUES` /
  `# END BOOTSTRAP VALUES` block
- if you want a rule change to persist, edit the script itself rather than the
  live node state
- add persistent allow rules before the managed `default drop`; rules appended
  after that drop will not be reached
- Prometheus is inbound-only by default for scraper IPs to TCP `9000:9300`.
- Teleport is outbound-only by default. Bootstrap manages Teleport Proxy/Auth
  IPs, defaulting to `10.129.0.232`; the source-of-truth scripts keep fixed
  TCP ports `443,3080,3024`.
- NTP can be restricted by bootstrap-managed server IPs; if no NTP IP is
  configured, the scripts preserve the generic UDP `123` fallback.

### 2. Temporary manual testing inside a managed chain

Use this when you want to test a rule quickly before codifying it in the repo.

Example: allow one admin IP:

```bash
iptables -I K8S-MASTER-IN 1 -m comment --comment "manual: allow admin ip" -s 203.0.113.10/32 -j RETURN
```

Example: drop one hostile source:

```bash
iptables -I K8S-MASTER-IN 1 -m comment --comment "manual: drop hostile source" -s 198.51.100.77/32 -j DROP
```

Example: allow a custom TCP port:

```bash
iptables -I K8S-MASTER-IN 1 -m comment --comment "temp: allow tcp 9443" -p tcp --dport 9443 -j RETURN
```

Persist it across reboot:

```bash
netfilter-persistent save
```

Important:

- this survives reboot only because you saved the runtime state
- this may still be removed by the next Ansible firewall apply, because that
  play rebuilds the managed chains

### 3. Manual custom chain outside the managed chains

Use this when you want a manual rule set that is less likely to be replaced by
the repo.

Create your own chain:

```bash
iptables -N MY-FW 2>/dev/null || true
iptables -F MY-FW
iptables -I INPUT 1 -m comment --comment "manual: jump to MY-FW" -j MY-FW
iptables -A MY-FW -m comment --comment "manual: allow admin ip" -s 203.0.113.10/32 -j RETURN
iptables -A MY-FW -m comment --comment "manual: default return" -j RETURN
netfilter-persistent save
```

Why this helps:

- the repo rebuilds only the managed master/worker chains
- your own chain can coexist next to them

But note:

- if Ansible later changes the `INPUT` chain ordering, your custom chain may no
  longer run before the managed chain
- this is still weaker than managing the rule in the repo

## Common operations

### View the live chains

```bash
iptables -S K8S-MASTER-IN
iptables -S K8S-WORKER-IN
iptables -L K8S-MASTER-IN -n --line-numbers
iptables -L K8S-WORKER-IN -n --line-numbers
iptables -L K8S-MASTER-IN -n --line-numbers -v
```

### Insert a rule at the top

```bash
iptables -I K8S-MASTER-IN 1 -m comment --comment "manual: allow admin ip" -s 203.0.113.10/32 -j RETURN
```

### Append a rule at the bottom

```bash
iptables -A K8S-MASTER-IN -m comment --comment "manual: allow admin ip" -s 203.0.113.10/32 -j RETURN
```

### Delete by exact rule

```bash
iptables -D K8S-MASTER-IN -m comment --comment "manual: allow admin ip" -s 203.0.113.10/32 -j RETURN
```

### Delete by line number

```bash
iptables -L K8S-MASTER-IN -n --line-numbers
iptables -D K8S-MASTER-IN 3
```

### Replace a rule

Delete the old one, then add the new one:

```bash
iptables -D K8S-MASTER-IN -m comment --comment "manual: allow admin ip" -s 203.0.113.10/32 -j RETURN
iptables -I K8S-MASTER-IN 1 -m comment --comment "manual: allow new admin ip" -s 203.0.113.11/32 -j RETURN
```

## Save and rollback

### Save current runtime rules

```bash
netfilter-persistent save
```

### Inspect the saved snapshot

```bash
grep -n "K8S-MASTER-IN\\|K8S-WORKER-IN\\|K8S-MASTER-OUT\\|K8S-WORKER-OUT" /etc/iptables/rules.v4
grep -n "manual:" /etc/iptables/rules.v4
```

### Restore from the saved snapshot

```bash
iptables-restore < /etc/iptables/rules.v4
```

### Rebuild the repo-managed chains

If your manual edits become messy, just re-apply the Ansible firewall play:

```bash
ansible-playbook playbooks/firewall.yml
```

This is the cleanest way to get back to the repo-defined state.

## Recommended workflow

For production changes:

1. Test manually in the relevant managed chain
2. Verify traffic works
3. Move the rule into bootstrap inputs or the reusable role-specific script
4. Re-run `./scripts/bootstrap.sh` if generated values changed
5. Re-apply `playbooks/firewall.yml`

## Warnings

- Do not flush the whole `filter`, `nat`, or `mangle` tables on a live cluster
- Do not edit or flush `cali-*` chains unless you are intentionally debugging
  Calico internals
- Do not hand-edit `/etc/iptables/rules.v4` unless you understand that it is
  only a saved snapshot
- Be careful with rule order: the first matching rule wins
- A `DROP` or `REJECT` inserted near the top of a managed input chain can lock
  you out

## Useful commands

```bash
iptables -S
iptables -S K8S-MASTER-IN
iptables -S K8S-WORKER-IN
iptables -L INPUT -n --line-numbers
iptables -L OUTPUT -n --line-numbers
iptables -L K8S-MASTER-IN -n --line-numbers
iptables -L K8S-MASTER-OUT -n --line-numbers
iptables -L K8S-WORKER-IN -n --line-numbers
iptables -L K8S-WORKER-OUT -n --line-numbers
iptables-save | less
systemctl status netfilter-persistent
```
