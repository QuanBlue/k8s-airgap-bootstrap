#!/usr/bin/env bash
set -euo pipefail

CHAIN_IN="K8S-WORKER-IN"
CHAIN_OUT="K8S-WORKER-OUT"

# The bootstrap-managed value block below is synchronized by
# `./scripts/bootstrap.sh`. Keep firewall rule logic below this block in this
# file; that logic is the source of truth and bootstrap must not overwrite it.
# BEGIN BOOTSTRAP VALUES
NODE_CIDR="10.0.6.0/24"
POD_CIDR="10.244.0.0/16"
SVC_CIDR="10.96.0.0/12"
MASTER_VIP="10.0.6.99"
WORKER_VIP="10.0.6.23"
MONGODB_IPS=()
MARIADB_IPS=()
DORISDB_IPS=()
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

# Insert worker-specific chains at the top so these rules are evaluated before
# the rest of the host firewall stack. The scripts intentionally manage only
# INPUT/OUTPUT and leave FORWARD, nat, mangle, and cali-* chains to Kubernetes,
# kube-proxy, and Calico.
ensure_jump_first INPUT "$CHAIN_IN"
ensure_jump_first OUTPUT "$CHAIN_OUT"

# ===================================================
# ================== INPUT RULES ====================
# ===================================================
# Allow basic host-local and stateful traffic first.
iptables -A "$CHAIN_IN" -m comment --comment "worker-in: allow loopback" -i lo -j RETURN
iptables -A "$CHAIN_IN" -m comment --comment "worker-in: allow established" -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
iptables -A "$CHAIN_IN" -m comment --comment "worker-in: allow icmp" -p icmp -j RETURN

# Calico / CNI transport between nodes. These rules are scoped to NODE_CIDR so
# the host deny-all model does not expose overlay/control ports to outside
# networks:
# - UDP 4789   VXLAN
# - TCP 179    BGP
# - TCP 5473   Typha
# - UDP 51820  WireGuard IPv4
# - UDP 51821  WireGuard IPv6
iptables -A "$CHAIN_IN" -m comment --comment "worker-in: allow calico vxlan from nodes" -s "$NODE_CIDR" -p udp --dport 4789 -j RETURN
iptables -A "$CHAIN_IN" -m comment --comment "worker-in: allow calico bgp from nodes" -s "$NODE_CIDR" -p tcp --dport 179 -j RETURN
iptables -A "$CHAIN_IN" -m comment --comment "worker-in: allow calico typha from nodes" -s "$NODE_CIDR" -p tcp --dport 5473 -j RETURN
iptables -A "$CHAIN_IN" -m comment --comment "worker-in: allow wireguard from nodes" -s "$NODE_CIDR" -p udp -m multiport --dports 51820,51821 -j RETURN

# Trust east-west traffic from the Kubernetes node, pod, and service networks.
iptables -A "$CHAIN_IN" -m comment --comment "worker-in: allow node cidr" -s "$NODE_CIDR" -j RETURN
iptables -A "$CHAIN_IN" -m comment --comment "worker-in: allow pod cidr" -s "$POD_CIDR" -j RETURN
iptables -A "$CHAIN_IN" -m comment --comment "worker-in: allow service cidr" -s "$SVC_CIDR" -j RETURN

# Keepalived VRRP multicast for worker VIP failover, if worker HA is enabled.
iptables -A "$CHAIN_IN" -m comment --comment "worker-in: allow keepalived vrrp from nodes" -s "$NODE_CIDR" -d 224.0.0.18/32 -p vrrp -j RETURN

# IGMP is needed by multicast-based keepalived VRRP group membership.
iptables -A "$CHAIN_IN" -m comment --comment "worker-in: allow igmp multicast from nodes" -s "$NODE_CIDR" -d 224.0.0.0/4 -p igmp -j RETURN

# SSH administration stays reachable from outside.
iptables -A "$CHAIN_IN" -m comment --comment "worker-in: allow ssh" -p tcp --dport 22 -j RETURN

for ip in "${PROMETHEUS_SCRAPER_IPS[@]}"; do
  # Prometheus / observability scrapers:
  # - 9000:9300 exporter and service metrics range used by this environment
  iptables -A "$CHAIN_IN" -m comment --comment "worker-in: allow prometheus scrape" -s "${ip}/32" -p tcp -m multiport --dports 9000:9300 -j RETURN
done

# Monitoring agents and scrapers inside the node network.
iptables -A "$CHAIN_IN" -m comment --comment "worker-in: allow node monitoring" -s "$NODE_CIDR" -p tcp -m multiport --dports 9100,9101,9165 -j RETURN

if [[ -n "$WORKER_VIP" ]]; then
  # Traffic entering the worker VIP:
  # - 80,443  application ingress via HAProxy / NodePort backend
  # - 9090    centralized Prometheus / Grafana style access
  iptables -A "$CHAIN_IN" -m comment --comment "worker-in: allow worker vip ingress" -d "$WORKER_VIP" -p tcp -m multiport --dports 80,443,9090 -j RETURN
fi

# NodePort backends are accepted only from inside the node CIDR.
iptables -A "$CHAIN_IN" -m comment --comment "worker-in: allow nodeport backends" -s "$NODE_CIDR" -p tcp -m multiport --dports 30080,30443,30990 -j RETURN

# ===================================================
# ================== INPUT DROP =====================
# ===================================================
# Block direct access to worker-sensitive ports from outside trusted sources:
# - 10250 kubelet exec/logs/health
# - 10256 kube-proxy health / metrics
iptables -A "$CHAIN_IN" -m comment --comment "worker-in: drop kubelet kube-proxy direct access" -p tcp -m multiport --dports 10250,10256 -j DROP

# Drop all remaining inbound traffic that did not match the explicit allowlist.
iptables -A "$CHAIN_IN" -m comment --comment "worker-in: log default drop" -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "Dropped input by firewall: " --log-level 7
iptables -A "$CHAIN_IN" -m comment --comment "worker-in: default drop" -j DROP

# \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# ///////////////////////////////////////////////////////////////////////////
# \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

# ===================================================
# ================== OUTPUT RULES ===================
# ===================================================
# Allow host-local and established outbound traffic first.
iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow loopback" -o lo -j RETURN
iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow established" -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow icmp" -p icmp -j RETURN

# Allow outbound traffic to node, pod, and service CIDRs for kubelet, CNI,
# service access, and internal cluster east-west communication.
iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow node cidr" -d "$NODE_CIDR" -j RETURN
iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow pod cidr" -d "$POD_CIDR" -j RETURN
iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow service cidr" -d "$SVC_CIDR" -j RETURN

if [[ -n "$MASTER_VIP" ]]; then
  # Workers reach the Kubernetes API through HAProxy on the master VIP.
  iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow api via master vip" -d "$MASTER_VIP" -p tcp --dport 8443 -j RETURN
fi

if [[ -n "$WORKER_VIP" ]]; then
  # Allow host-level validation to reach the worker ingress VIP even when it is
  # outside the node CIDR.
  iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow worker vip ingress" -d "$WORKER_VIP" -p tcp -m multiport --dports 80,443,9090 -j RETURN
fi

for ip in "${TELEPORT_PROXY_IPS[@]}"; do
  # Teleport outbound agent traffic to external Proxy/Auth endpoints:
  # - 443   web/proxy endpoint
  # - 3080  Teleport proxy web/listener default
  # - 3024  reverse tunnel / trusted cluster tunnel
  iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow teleport proxy" -d "${ip}/32" -p tcp -m multiport --dports 443,3080,3024 -j RETURN
done

for ip in "${MONGODB_IPS[@]}"; do
  # MongoDB:
  # - 27017 application traffic
  # - 9216  metrics / monitoring exporter
  iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow mongodb app" -d "${ip}/32" -p tcp --dport 27017 -j RETURN
  iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow mongodb monitor" -d "${ip}/32" -p tcp --dport 9216 -j RETURN
done

for ip in "${MARIADB_IPS[@]}"; do
  # MariaDB / MaxScale / monitoring:
  # - 3306,3307 database connectivity
  # - 9104      metrics exporter
  iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow mariadb app" -d "${ip}/32" -p tcp -m multiport --dports 3306,3307 -j RETURN
  iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow mariadb monitor" -d "${ip}/32" -p tcp --dport 9104 -j RETURN
done

for ip in "${DORISDB_IPS[@]}"; do
  # DorisDB:
  # - 8030,8040,8060,9030 application/data-plane connectivity
  # - 9033,9034           monitoring / internal observability endpoints
  iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow dorisdb app" -d "${ip}/32" -p tcp -m multiport --dports 8030,8040,8060,9030 -j RETURN
  iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow dorisdb monitor" -d "${ip}/32" -p tcp -m multiport --dports 9033,9034 -j RETURN
done

for ip in "${SOC_NSM_IPS[@]}"; do
  # vTAP / NSM traffic:
  # - TCP 443,444     NSM management / sensor delivery
  # - TCP/UDP 44789   NSM sensor / vTAP data path
  iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow soc nsm tcp" -d "${ip}/32" -p tcp -m multiport --dports 443,444,44789 -j RETURN
  iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow soc nsm udp" -d "${ip}/32" -p udp --dport 44789 -j RETURN
done

for ip in "${SOC_FORWARDER_IPS[@]}"; do
  # SOC forwarder traffic:
  # - 8443,4443,8888,5672       EDR agent -> forwarder
  # - 4444,5044,5673,8445,8885  CyM / log shipper -> forwarder
  # - 514,6514                  Syslog / SIEM integration
  iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow soc fwd tcp" -d "${ip}/32" -p tcp -m multiport --dports 8443,4443,8888,5672,4444,5044,5673,8445,8885,514,6514 -j RETURN
  iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow soc fwd udp" -d "${ip}/32" -p udp -m multiport --dports 514,6514 -j RETURN
done

# Allow DNS and NTP for name resolution and clock sync. If NTP_SERVER_IPS is
# rendered, NTP is restricted to those servers; otherwise the previous generic
# NTP fallback is preserved for compatibility.
iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow dns udp" -p udp --dport 53 -j RETURN
iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow dns tcp" -p tcp --dport 53 -j RETURN

if [[ "${#NTP_SERVER_IPS[@]}" -gt 0 ]]; then
  for ip in "${NTP_SERVER_IPS[@]}"; do
    iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow ntp server" -d "${ip}/32" -p udp --dport 123 -j RETURN
  done
else
  iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow ntp udp" -p udp --dport 123 -j RETURN
fi

# Keepalived multicast egress for VIP advertisements.
iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow keepalived vrrp multicast" -d 224.0.0.18/32 -p vrrp -j RETURN
iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: allow igmp multicast" -d 224.0.0.0/4 -p igmp -j RETURN

# ===================================================
# ================== OUTPUT DROP ====================
# ===================================================
# Deny all other worker egress not explicitly allowed above.
iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: log default drop" -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "Dropped output by firewall: " --log-level 7
iptables -A "$CHAIN_OUT" -m comment --comment "worker-out: default drop" -j DROP

echo "Worker iptables rules applied."
