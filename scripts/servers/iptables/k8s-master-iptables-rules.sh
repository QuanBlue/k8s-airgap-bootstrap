#!/usr/bin/env bash
set -euo pipefail

CHAIN_IN="K8S-MASTER-IN"
CHAIN_OUT="K8S-MASTER-OUT"

# The bootstrap-managed value block below is synchronized by
# `./scripts/bootstrap.sh`. Keep firewall rule logic below this block in this
# file; that logic is the source of truth and bootstrap must not overwrite it.
# BEGIN BOOTSTRAP VALUES
NODE_CIDR="10.0.6.0/24"
POD_CIDR="10.244.0.0/16"
SVC_CIDR="10.96.0.0/12"
MASTER_VIP="10.0.6.99"
WORKER_VIP="10.0.6.23"
PROMETHEUS_SCRAPER_IPS=("10.129.0.158" "10.129.0.159" "10.129.0.160" "10.129.0.163" "10.129.0.164" "10.129.0.165")
TELEPORT_PROXY_IPS=("10.129.0.232")
NTP_SERVER_IPS=()
SOC_NSM_IPS=()
SOC_FORWARDER_IPS=()
# END BOOTSTRAP VALUES

require_cidr() {
  local name="$1"
  local value="$2"

  if [[ -z "$value" ]]; then
    echo "ERROR: $name is empty. Run ./scripts/bootstrap.sh or update the bootstrap-managed value block before applying firewall rules." >&2
    exit 2
  fi
}

require_cidr NODE_CIDR "$NODE_CIDR"
require_cidr POD_CIDR "$POD_CIDR"
require_cidr SVC_CIDR "$SVC_CIDR"

ensure_chain() {
  iptables -N "$1" 2>/dev/null || true
  iptables -F "$1"
}

ensure_jump_first() {
  local base="$1"
  local chain="$2"
  iptables -D "$base" -j "$chain" 2>/dev/null || true
  iptables -I "$base" 1 -j "$chain"
}

ensure_chain "$CHAIN_IN"
ensure_chain "$CHAIN_OUT"

# Insert our custom chains at the top so master-specific rules are evaluated
# before the rest of the host firewall stack. The scripts intentionally manage
# only INPUT/OUTPUT and leave FORWARD, nat, mangle, and cali-* chains to
# Kubernetes, kube-proxy, and Calico.
ensure_jump_first INPUT "$CHAIN_IN"
ensure_jump_first OUTPUT "$CHAIN_OUT"

# ===================================================
# ================== INPUT RULES ====================
# ===================================================

# Allow basic host-local and stateful traffic first.
iptables -A "$CHAIN_IN" -m comment --comment "master-in: allow loopback" -i lo -j RETURN
iptables -A "$CHAIN_IN" -m comment --comment "master-in: allow established" -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
iptables -A "$CHAIN_IN" -m comment --comment "master-in: allow icmp" -p icmp -j RETURN

# Calico / CNI transport between nodes. These rules are scoped to NODE_CIDR so
# the host deny-all model does not expose overlay/control ports to outside
# networks:
# - UDP 4789   VXLAN
# - TCP 179    BGP
# - TCP 5473   Typha
# - UDP 51820  WireGuard IPv4
# - UDP 51821  WireGuard IPv6
iptables -A "$CHAIN_IN" -m comment --comment "master-in: allow calico vxlan from nodes" -s "$NODE_CIDR" -p udp --dport 4789 -j RETURN
iptables -A "$CHAIN_IN" -m comment --comment "master-in: allow calico bgp from nodes" -s "$NODE_CIDR" -p tcp --dport 179 -j RETURN
iptables -A "$CHAIN_IN" -m comment --comment "master-in: allow calico typha from nodes" -s "$NODE_CIDR" -p tcp --dport 5473 -j RETURN
iptables -A "$CHAIN_IN" -m comment --comment "master-in: allow wireguard from nodes" -s "$NODE_CIDR" -p udp -m multiport --dports 51820,51821 -j RETURN

# Trust east-west traffic from the Kubernetes node, pod, and service networks.
# This keeps control-plane, etcd, and CNI traffic working inside the cluster.
iptables -A "$CHAIN_IN" -m comment --comment "master-in: allow node cidr" -s "$NODE_CIDR" -j RETURN
iptables -A "$CHAIN_IN" -m comment --comment "master-in: allow pod cidr" -s "$POD_CIDR" -j RETURN
iptables -A "$CHAIN_IN" -m comment --comment "master-in: allow service cidr" -s "$SVC_CIDR" -j RETURN

# Keepalived VRRP multicast between masters for VIP failover.
iptables -A "$CHAIN_IN" -m comment --comment "master-in: allow keepalived vrrp from nodes" -s "$NODE_CIDR" -d 224.0.0.18/32 -p vrrp -j RETURN

# IGMP is needed by multicast-based keepalived VRRP group membership.
iptables -A "$CHAIN_IN" -m comment --comment "master-in: allow igmp multicast from nodes" -s "$NODE_CIDR" -d 224.0.0.0/4 -p igmp -j RETURN

# SSH administration stays reachable from outside.
iptables -A "$CHAIN_IN" -m comment --comment "master-in: allow ssh" -p tcp --dport 22 -j RETURN

# Clients must reach the API through HAProxy on the master VIP:8443.
iptables -A "$CHAIN_IN" -m comment --comment "master-in: allow haproxy api vip" -p tcp --dport 8443 -j RETURN

for ip in "${PROMETHEUS_SCRAPER_IPS[@]}"; do
  # Prometheus / observability scrapers:
  # - 9000:9300 exporter and service metrics range used by this environment
  iptables -A "$CHAIN_IN" -m comment --comment "master-in: allow prometheus scrape" -s "${ip}/32" -p tcp -m multiport --dports 9000:9300 -j RETURN
done

# ===================================================
# ================== INPUT DROP =====================
# ===================================================
# Block direct access to control-plane and etcd ports from outside trusted
# cluster ranges:
# - 6443  kube-apiserver
# - 2379  etcd client
# - 2380  etcd peer
# - 10257 kube-controller-manager metrics/health
# - 10259 kube-scheduler metrics/health
# - 10250 kubelet exec/logs/health
iptables -A "$CHAIN_IN" -m comment --comment "master-in: drop control-plane direct access" -p tcp -m multiport --dports 6443,2379,2380,10257,10259,10250 -j DROP

# Drop all remaining inbound traffic that did not match the explicit allowlist.
iptables -A "$CHAIN_IN" -m comment --comment "master-in: log default drop" -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "Dropped input by firewall: " --log-level 7
iptables -A "$CHAIN_IN" -m comment --comment "master-in: default drop" -j DROP

# \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# ///////////////////////////////////////////////////////////////////////////
# \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

# ===================================================
# ================== OUTPUT RULES ===================
# ===================================================
# Allow host-local and established outbound traffic first.
iptables -A "$CHAIN_OUT" -m comment --comment "master-out: allow loopback" -o lo -j RETURN
iptables -A "$CHAIN_OUT" -m comment --comment "master-out: allow established" -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
iptables -A "$CHAIN_OUT" -m comment --comment "master-out: allow icmp" -p icmp -j RETURN

# Allow outbound traffic to node, pod, and service CIDRs for kube-apiserver,
# etcd, kubelet, CNI, and other internal cluster communication.
iptables -A "$CHAIN_OUT" -m comment --comment "master-out: allow node cidr" -d "$NODE_CIDR" -j RETURN
iptables -A "$CHAIN_OUT" -m comment --comment "master-out: allow pod cidr" -d "$POD_CIDR" -j RETURN
iptables -A "$CHAIN_OUT" -m comment --comment "master-out: allow service cidr" -d "$SVC_CIDR" -j RETURN

if [[ -n "$MASTER_VIP" ]]; then
  # Masters call the Kubernetes API via HAProxy on the VIP rather than
  # connecting directly to :6443 on another control-plane node.
  iptables -A "$CHAIN_OUT" -m comment --comment "master-out: allow api via master vip" -d "$MASTER_VIP" -p tcp --dport 8443 -j RETURN
fi

if [[ -n "$WORKER_VIP" ]]; then
  # Allow cluster administrators and host-level checks on masters to reach the
  # worker ingress VIP even when it is outside the node CIDR.
  iptables -A "$CHAIN_OUT" -m comment --comment "master-out: allow worker vip ingress" -d "$WORKER_VIP" -p tcp -m multiport --dports 80,443,9090 -j RETURN
fi

for ip in "${TELEPORT_PROXY_IPS[@]}"; do
  # Teleport outbound agent traffic to external Proxy/Auth endpoints:
  # - 443   web/proxy endpoint
  # - 3080  Teleport proxy web/listener default
  # - 3024  reverse tunnel / trusted cluster tunnel
  iptables -A "$CHAIN_OUT" -m comment --comment "master-out: allow teleport proxy" -d "${ip}/32" -p tcp -m multiport --dports 443,3080,3024 -j RETURN
done

for ip in "${SOC_NSM_IPS[@]}"; do
  # vTAP / NSM traffic:
  # - TCP 443,444     NSM management / sensor delivery
  # - TCP/UDP 44789   NSM sensor / vTAP data path
  iptables -A "$CHAIN_OUT" -m comment --comment "master-out: allow soc nsm tcp" -d "${ip}/32" -p tcp -m multiport --dports 443,444,44789 -j RETURN
  iptables -A "$CHAIN_OUT" -m comment --comment "master-out: allow soc nsm udp" -d "${ip}/32" -p udp --dport 44789 -j RETURN
done

for ip in "${SOC_FORWARDER_IPS[@]}"; do
  # SOC forwarder traffic:
  # - 8443,4443,8888,5672       EDR agent -> forwarder
  # - 4444,5044,5673,8445,8885  CyM / log shipper -> forwarder
  # - 514,6514                  Syslog / SIEM integration
  iptables -A "$CHAIN_OUT" -m comment --comment "master-out: allow soc fwd tcp" -d "${ip}/32" -p tcp -m multiport --dports 8443,4443,8888,5672,4444,5044,5673,8445,8885,514,6514 -j RETURN
  iptables -A "$CHAIN_OUT" -m comment --comment "master-out: allow soc fwd udp" -d "${ip}/32" -p udp -m multiport --dports 514,6514 -j RETURN
done

# Allow DNS and NTP for name resolution and clock sync. If NTP_SERVER_IPS is
# rendered, NTP is restricted to those servers; otherwise the previous generic
# NTP fallback is preserved for compatibility.
iptables -A "$CHAIN_OUT" -m comment --comment "master-out: allow dns udp" -p udp --dport 53 -j RETURN
iptables -A "$CHAIN_OUT" -m comment --comment "master-out: allow dns tcp" -p tcp --dport 53 -j RETURN

if [[ "${#NTP_SERVER_IPS[@]}" -gt 0 ]]; then
  for ip in "${NTP_SERVER_IPS[@]}"; do
    iptables -A "$CHAIN_OUT" -m comment --comment "master-out: allow ntp server" -d "${ip}/32" -p udp --dport 123 -j RETURN
  done
else
  iptables -A "$CHAIN_OUT" -m comment --comment "master-out: allow ntp udp" -p udp --dport 123 -j RETURN
fi

# Keepalived multicast egress for VIP advertisements.
iptables -A "$CHAIN_OUT" -m comment --comment "master-out: allow keepalived vrrp multicast" -d 224.0.0.18/32 -p vrrp -j RETURN
iptables -A "$CHAIN_OUT" -m comment --comment "master-out: allow igmp multicast" -d 224.0.0.0/4 -p igmp -j RETURN

# ===================================================
# ================== OUTPUT DROP ====================
# ===================================================
# Deny all other master egress not explicitly allowed above.
iptables -A "$CHAIN_OUT" -m comment --comment "master-out: log default drop" -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "Dropped output by firewall: " --log-level 7
iptables -A "$CHAIN_OUT" -m comment --comment "master-out: default drop" -j DROP

echo "Master iptables rules applied."
