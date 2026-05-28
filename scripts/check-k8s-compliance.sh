#!/usr/bin/env bash
#
# check-compliance.sh — Kiểm tra Bộ chỉ tiêu kỹ thuật Nền tảng Kubernetes
# (219/QĐ-CNVTQĐ — "PL12 Mẫu biểu CTKT Kubernetes Platform").
#
# Mỗi tiêu chí trong checklist ánh xạ 1:1 với một dòng kết quả ở đây:
#   ✔ Đạt        tự động xác minh được qua kubectl/jq hoặc Ansible
#   ✘ Không đạt  tự động xác minh và KHÔNG thoả mãn  (tiêu chí (M) làm script exit != 0)
#   ⚠ Cảnh báo   khuyến nghị / phụ thuộc ngữ cảnh, cần soát lại
#   👤 Thủ công  phải do người (đội ATTT, soát tài liệu, Cloud Dashboard, fio…) đánh giá
#   ➖ N/A        không áp dụng cho cụm hiện tại
#
# Các mục kiểm ở mức node tự động qua kubelet /stats/summary và /configz; với mục
# cần SSH thật (df mở rộng, swap fallback…) sẽ qua Ansible nếu có inventory, nếu
# không để 👤 Thủ công.
#
# ─── Tính tái sử dụng ───────────────────────────────────────────────────────────
# Script hoạt động độc lập với mọi cụm Kubernetes (kubeadm, k3s, RKE/RKE2, EKS,
# GKE, AKS, OpenShift…). Tự nhận diện cụm không phải static-pod kubeadm (apiserver
# chạy như binary/process) và dùng heuristic riêng (HTTP probe, configz, kubelet
# stats…) để xác minh các chỉ tiêu vốn cần đọc cmdline apiserver.
#
# Cách dùng:
#   # Standalone (chỉ cần kubectl + jq):
#   KUBECONFIG=~/.kube/config ./check-k8s-compliance.sh
#
#   # Với inventory Ansible riêng (bật node-level checks qua SSH):
#   INVENTORY=~/inv/prod.ini ./check-k8s-compliance.sh
#   # hoặc:  ./check-k8s-compliance.sh --inventory ~/inv/prod.ini
#
#   # Trong repo Ansible này: tự dò inventories/inventory.ini (hoặc sample.ini).
#
# Yêu cầu: bash, kubectl, jq.  curl (cho V.3 HTTP probe).  ansible (cho node-level).

set -uo pipefail   # cố ý KHÔNG dùng -e: nhiều check chạy lệnh được phép "fail"

# ─── Colors ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# Không cd — giữ nguyên CWD của user. SCRIPT_DIR chỉ dùng để dò file cùng repo.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# ─── CLI ──────────────────────────────────────────────────────────────────────
# INVENTORY env var (nếu set) làm mặc định cho --inventory.
# KUBECONFIG env var được kubectl tự xử lý.
KUBECONFIG_ARG=(); INVENTORY="${INVENTORY:-}"
usage() {
    echo -e "${BOLD}usage:${NC} ${CYAN}check-k8s-compliance.sh${NC} [${GREEN}--kubeconfig${NC} PATH] [${GREEN}--inventory${NC} PATH] [${GREEN}--no-color${NC}]"
    echo
    echo "Kiểm tra cụm Kubernetes theo Bộ chỉ tiêu kỹ thuật 219/QĐ-CNVTQĐ."
    echo "Chạy được trên kubeadm, k3s, RKE/RKE2, EKS, GKE, AKS, OpenShift…"
    echo
    echo -e "${BOLD}options:${NC}"
    echo -e "  ${GREEN}--kubeconfig${NC} PATH   kubeconfig truy cập API Server (mặc định: \$KUBECONFIG)"
    echo -e "  ${GREEN}--inventory${NC}  PATH   Ansible inventory cho mục mức node (swap, df, SELinux)"
    echo -e "  ${GREEN}--no-color${NC}          tắt màu"
    echo -e "  ${GREEN}-h${NC}, ${GREEN}--help${NC}          hiện trợ giúp"
    echo
    echo -e "${BOLD}env vars:${NC}"
    echo -e "  ${GREEN}KUBECONFIG${NC}           kubectl đọc trực tiếp (chuẩn)"
    echo -e "  ${GREEN}INVENTORY${NC}            mặc định cho --inventory khi không truyền cờ"
    echo
    echo -e "${BOLD}exit code:${NC} != 0 nếu có tiêu chí bắt buộc (M) ✘ Không đạt."
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --kubeconfig) KUBECONFIG_ARG=(--kubeconfig "$2"); shift 2 ;;
        --inventory)  INVENTORY="$2"; shift 2 ;;
        --no-color)   GREEN=''; BLUE=''; YELLOW=''; RED=''; CYAN=''; BOLD=''; DIM=''; NC=''; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

k() { kubectl "${KUBECONFIG_ARG[@]}" "$@"; }

# ─── Result framework ───────────────────────────────────────────────────────────
PASS_N=0; FAIL_N=0; WARN_N=0; MANUAL_N=0; NA_N=0; MAND_FAIL_N=0; LAST_RESULT=""
result() {  # result <id> <M|O|-> <PASS|FAIL|WARN|MANUAL|NA> <title>
    echo   # dòng trống ngăn cách giữa các mục cho dễ nhìn
    local id="$1" req="$2" status="$3" title="$4" icon color
    case "$status" in
        PASS)   icon="✔";  color="$GREEN";  ((PASS_N++)) ;;
        FAIL)   icon="✘";  color="$RED";    ((FAIL_N++)); [[ "$req" == M ]] && ((MAND_FAIL_N++)) ;;
        WARN)   icon="⚠";  color="$YELLOW"; ((WARN_N++)) ;;
        MANUAL) icon="👤"; color="$CYAN";   ((MANUAL_N++)) ;;
        NA)     icon="➖"; color="$DIM";    ((NA_N++)) ;;
    esac
    printf "  ${color}%s${NC}  ${BOLD}%-6s${NC}${DIM}[%s]${NC} %s\n" "$icon" "$id" "$req" "$title"
    LAST_RESULT="$status"
}
note() { echo -e "         ${DIM}$1${NC}"; }
# Gợi ý khắc phục (HD cấu hình) — in mỗi dòng truyền vào.
fix() { echo -e "         ${YELLOW}↳ Khắc phục:${NC}"; local l; for l in "$@"; do echo -e "           ${DIM}$l${NC}"; done; }
# Chỉ in gợi ý khắc phục khi mục vừa rồi FAIL/WARN.
fix_if_bad() { [[ "$LAST_RESULT" == FAIL || "$LAST_RESULT" == WARN ]] && fix "$@"; }
section() {
    local bar; bar=$(printf '/%.0s' $(seq 70))
    echo
    echo -e "${BOLD}${CYAN}${bar}${NC}"
    echo -e "${BOLD}${CYAN}//${NC}  ${BOLD}$1${NC}"
    echo -e "${BOLD}${CYAN}${bar}${NC}"
}
# In toàn bộ danh sách vi phạm: dòng đếm in đậm, từng mục tô màu.
list_detail() {  # list_detail <label> <item-color> <list>
    local label="$1" color="$2" list="$3"
    echo -e "         ${color}${BOLD}$(wc -l <<<"$list") ${label}${NC}"
    while IFS= read -r l; do echo -e "           ${color}• ${l}${NC}"; done <<<"$list"
}
# In danh sách vi phạm (mỗi dòng 1 mục) -> PASS nếu rỗng, ngược lại FAIL (đỏ).
verdict_list() {  # verdict_list "<list>" <id> <req> <title> <okmsg>
    local list="$1" id="$2" req="$3" title="$4" okmsg="$5"
    if [[ -z "$list" ]]; then
        result "$id" "$req" PASS "$title"; [[ -n "$okmsg" ]] && note "$okmsg"
    else
        result "$id" "$req" FAIL "$title"
        list_detail "mục vi phạm:" "$RED" "$list"
    fi
}
# Tương tự nhưng vi phạm -> WARN (khuyến nghị, không fail build).
warn_list() {
    local list="$1" id="$2" req="$3" title="$4" okmsg="$5"
    if [[ -z "$list" ]]; then
        result "$id" "$req" PASS "$title"; [[ -n "$okmsg" ]] && note "$okmsg"
    else
        result "$id" "$req" WARN "$title"
        list_detail "mục nên rà soát:" "$YELLOW" "$list"
    fi
}

# So sánh phiên bản: ver_ge A B  -> A >= B ?
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

# ─── Banner & preflight ─────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}☸  Kiểm tra Chỉ tiêu kỹ thuật Kubernetes${NC}  ${DIM}(219/QĐ-CNVTQĐ)${NC}       ${BOLD}${CYAN}║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"

command -v jq >/dev/null || { echo -e "${RED}✘ thiếu 'jq' — bắt buộc.${NC}"; exit 1; }

KUBE_OK=0
if command -v kubectl >/dev/null && k version --request-timeout=10s >/dev/null 2>&1; then
    KUBE_OK=1
else
    echo -e "${YELLOW}⚠  Không kết nối được API Server qua kubectl — các mục kiểm qua API sẽ là N/A.${NC}"
    echo -e "${DIM}   (đặt \$KUBECONFIG hoặc dùng --kubeconfig)${NC}"
fi

# Tự động dò inventory ở nhiều vị trí phổ biến (CWD + thư mục script + repo Ansible).
if [[ -z "$INVENTORY" ]]; then
    for cand in \
        "./inventory.ini" \
        "./inventories/inventory.ini" \
        "./inventories/sample.ini" \
        "$SCRIPT_DIR/../inventories/inventory.ini" \
        "$SCRIPT_DIR/../inventories/sample.ini" \
        "$SCRIPT_DIR/inventories/inventory.ini" \
        "$SCRIPT_DIR/inventory.ini"; do
        if [[ -f "$cand" ]]; then
            INVENTORY="$cand"
            echo -e "${DIM}ℹ  Tự động dùng inventory: $cand  (truyền --inventory hoặc set \$INVENTORY để chọn khác).${NC}"
            break
        fi
    done
fi

NODE_MODE="manual"
if [[ -n "$INVENTORY" ]]; then
    if command -v ansible >/dev/null && \
       ANSIBLE_HOST_KEY_CHECKING=False ansible all -i "$INVENTORY" -m ping >/dev/null 2>&1; then
        NODE_MODE="ansible"
        echo -e "${GREEN}✔  Ansible kết nối được tới các node — bật tự động kiểm mức node.${NC}"
    else
        echo -e "${YELLOW}⚠  Không ping được node qua Ansible ($INVENTORY) — các mục mức node để 👤 Thủ công.${NC}"
        echo -e "${DIM}   Thử: ansible all -i $INVENTORY -m ping${NC}"
    fi
fi

# Chạy 1 lệnh shell trên TẤT CẢ node; trả về rc!=0 nếu bất kỳ host nào vi phạm.
node_assert() {  # node_assert <id> <req> <title> '<remote test, exit !=0 = vi phạm>' <ghi chú lệnh>
    local id="$1" req="$2" title="$3" cmd="$4" hint="$5"
    if [[ "$NODE_MODE" != ansible ]]; then
        result "$id" "$req" MANUAL "$title"; note "Lệnh kiểm: $hint"; return
    fi
    if ANSIBLE_HOST_KEY_CHECKING=False ansible all -i "$INVENTORY" -m shell -a "$cmd" >/dev/null 2>&1; then
        result "$id" "$req" PASS "$title"
    else
        result "$id" "$req" FAIL "$title"; note "Có node không thoả mãn. Lệnh kiểm: $hint"
    fi
}

# Bỏ qua các namespace hệ thống/hạ tầng khi soát workload ứng dụng.
SYS_NS_RE='^(kube-system|kube-public|kube-node-lease|kube-flannel|calico-system|calico-apiserver|tigera-operator|metallb-system|ingress-nginx|local-path-storage|monitoring|logging|cattle-system|kubernetes-dashboard)$'

# ─── Cache các lời gọi API ──────────────────────────────────────────────────────
PODS_JSON='{"items":[]}'; NODES_JSON='{"items":[]}'; KSYS_JSON='{"items":[]}'
DEPLOY_JSON='{"items":[]}'; STS_JSON='{"items":[]}'; APISERVER_CMD=""; CM_CMD=""
if [[ $KUBE_OK -eq 1 ]]; then
    PODS_JSON=$(k get pods -A -o json 2>/dev/null || echo '{"items":[]}')
    NODES_JSON=$(k get nodes -o json 2>/dev/null || echo '{"items":[]}')
    KSYS_JSON=$(k -n kube-system get pods -o json 2>/dev/null || echo '{"items":[]}')
    DEPLOY_JSON=$(k get deploy -A -o json 2>/dev/null || echo '{"items":[]}')
    STS_JSON=$(k get statefulset -A -o json 2>/dev/null || echo '{"items":[]}')
    APISERVER_CMD=$(jq -r '[.items[]|select(.metadata.labels.component=="kube-apiserver")|(.spec.containers[0].command + (.spec.containers[0].args // []))]|flatten|join(" ")' <<<"$KSYS_JSON")
    CM_CMD=$(jq -r '[.items[]|select(.metadata.labels.component=="kube-controller-manager")|(.spec.containers[0].command + (.spec.containers[0].args // []))]|flatten|join(" ")' <<<"$KSYS_JSON")
fi
apiflag() { grep -q -- "$1" <<<"$APISERVER_CMD"; }

# Đếm node / phiên bản (dùng nhiều lần)
NODE_COUNT=$(jq '.items|length' <<<"$NODES_JSON")
MASTER_COUNT=$(jq '[.items[]|select(.metadata.labels|has("node-role.kubernetes.io/control-plane") or has("node-role.kubernetes.io/master"))]|length' <<<"$NODES_JSON")
WORKER_COUNT=$(( NODE_COUNT - MASTER_COUNT )); ((WORKER_COUNT < 0)) && WORKER_COUNT=0
MIN_KVER=$(jq -r '[.items[].status.nodeInfo.kubeletVersion]|map(sub("^v";""))|sort_by(split(".")|map(tonumber? // 0))|.[0] // "0"' <<<"$NODES_JSON")
KVER_SET=$(jq -r '[.items[].status.nodeInfo.kubeletVersion]|unique|join(", ")' <<<"$NODES_JSON")

# Bộ lọc jq dùng lại: trả về danh sách container ứng dụng (bỏ ns hệ thống & pod của Job).
APP_CONTAINERS='.items[]
  | select(.metadata.namespace | test($sys) | not)
  | select(((.metadata.ownerReferences // []) | map(.kind) | any(. == "Job")) | not)
  | .metadata.namespace as $ns | .metadata.name as $pod
  | .spec.containers[] | . as $c'

# ════════════════════════════════════════════════════════════════════════════════
section "I.1 — Chỉ tiêu chức năng · Tính phù hợp chức năng"

# I.1 Chức năng dự phòng network (O) — multiple network cho pod (Multus)
if [[ $KUBE_OK -eq 1 ]]; then
    if k get crd networkattachmentdefinitions.k8s.cni.cncf.io >/dev/null 2>&1; then
        n=$(k get net-attach-def -A --no-headers 2>/dev/null | wc -l)
        if (( n >= 1 )); then result "I.1" O PASS "Dự phòng network cho pod (multiple network)"
        else result "I.1" O WARN "Dự phòng network cho pod"; note "Có Multus nhưng chưa có NetworkAttachmentDefinition."; fi
    else
        result "I.1" O NA "Dự phòng network cho pod (multiple network)"; note "Chưa cài Multus — tuỳ chọn, chỉ cần khi muốn ≥2 network/pod."
    fi
else result "I.1" O NA "Dự phòng network cho pod"; fi

# I.1.1 Network Policy / security / QoS của CNI (M) — nhận diện CNI đang chạy
if [[ $KUBE_OK -eq 1 ]]; then
    has_cni() { jq -r --arg p "$1" '[.items[]|select(.metadata.name|test($p;"i"))]|length' <<<"$PODS_JSON"; }
    cni=""; cni_cap=""
    if   (( $(has_cni 'calico-node') > 0 ));        then cni="Calico";      cni_cap=yes
    elif (( $(has_cni 'cilium') > 0 ));             then cni="Cilium";      cni_cap=yes
    elif (( $(has_cni 'antrea') > 0 ));             then cni="Antrea";      cni_cap=yes
    elif (( $(has_cni 'kube-router') > 0 ));        then cni="kube-router"; cni_cap=yes
    elif (( $(has_cni 'weave-net') > 0 ));          then cni="Weave Net";   cni_cap=yes
    elif (( $(has_cni 'kube-ovn|ovn-kubernetes') > 0 )); then cni="OVN-Kubernetes"; cni_cap=yes
    elif (( $(has_cni 'kube-flannel|flannel') > 0 )); then cni="Flannel";   cni_cap=no
    fi
    if [[ "$cni_cap" == yes ]]; then
        result "I.1.1" M PASS "CNI hỗ trợ Network Policy / security / QoS"; note "Phát hiện CNI: $cni (enforce NetworkPolicy)."
    elif [[ "$cni_cap" == no ]]; then
        result "I.1.1" M WARN "CNI hỗ trợ Network Policy / security / QoS"; note "Phát hiện $cni — không tự enforce NetworkPolicy."
        fix_if_bad "Dùng CNI enforce được policy (Calico/Cilium…) hoặc bổ sung Canal (Flannel+Calico)."
    else
        result "I.1.1" M MANUAL "CNI hỗ trợ Network Policy / security / QoS (ACL, isolation)"
        note "Không nhận diện được CNI từ pod kube-system — đối chiếu tài liệu CNI đang dùng."
    fi
else result "I.1.1" M NA "CNI Network Policy"; fi

# DNS cho services (M)
if [[ $KUBE_OK -eq 1 ]]; then
    dns=$(jq -r '[.items[]|select(.metadata.name|test("coredns|kube-dns"))|select(.status.phase=="Running")]|length' <<<"$KSYS_JSON")
    if (( dns >= 1 )); then result "I.DNS" M PASS "DNS cho services (CoreDNS/kube-dns đang chạy)"; note "$dns pod DNS Running trong kube-system."
    else result "I.DNS" M FAIL "DNS cho services"; note "Không thấy pod CoreDNS/kube-dns Running."; fi
else result "I.DNS" M NA "DNS cho services"; fi

# NodeLocal DNS Cache (M, chỉ bắt buộc khi > 100 node)
if [[ $KUBE_OK -eq 1 ]]; then
    if (( NODE_COUNT > 100 )); then
        nl=$(jq -r '[.items[]|select(.metadata.name|test("nodelocaldns|nodecachedns"))]|length' <<<"$KSYS_JSON")
        if (( nl >= 1 )); then result "I.DNSc" M PASS "NodeLocal DNS Cache (cụm > 100 node)"
        else result "I.DNSc" M FAIL "NodeLocal DNS Cache"; note "Cụm $NODE_COUNT node nhưng không có nodelocaldns."; fi
    else result "I.DNSc" M PASS "NodeLocal DNS Cache (không bắt buộc cho cụm ≤ 100 node)"; note "Cụm $NODE_COUNT node — chỉ tiêu chỉ áp dụng khi > 100 node."; fi
else result "I.DNSc" M NA "NodeLocal DNS Cache"; fi

# Định nghĩa Network Policy cho service/namespace (M)
if [[ $KUBE_OK -eq 1 ]]; then
    np=$(k get netpol -A --no-headers 2>/dev/null | wc -l)
    if (( np >= 1 )); then result "I.NP" M PASS "Đã định nghĩa NetworkPolicy cho service/namespace"; note "$np NetworkPolicy."
    else result "I.NP" M FAIL "Định nghĩa NetworkPolicy cho service/namespace"; note "Không có NetworkPolicy nào (kubectl get netpol -A)."; fi
    fix_if_bad "Mỗi namespace nên có policy mặc định deny-all rồi mở allow theo nhu cầu:" \
        "kind: NetworkPolicy / spec: { podSelector: {}, policyTypes: [Ingress, Egress] }"
else result "I.NP" M NA "Định nghĩa NetworkPolicy"; fi

# I.1.6 Readiness Probe (M)
if [[ $KUBE_OK -eq 1 ]]; then
    bad=$(jq -r --arg sys "$SYS_NS_RE" "[$APP_CONTAINERS|select((\$c.readinessProbe // null)==null)|\"\(\$ns)/\(\$pod):\(\$c.name)\"]|unique|.[]" <<<"$PODS_JSON")
    verdict_list "$bad" "I.1.6" M "Readiness Probe trên mọi container ứng dụng" "Tất cả container ứng dụng có readinessProbe."
    fix_if_bad "Thêm readinessProbe vào container (vd):" \
        "readinessProbe: { httpGet: { path: /healthz, port: 8080 }, initialDelaySeconds: 5, periodSeconds: 10 }"
else result "I.1.6" M NA "Readiness Probe"; fi

# I.1.7 Liveness Probe (M)
if [[ $KUBE_OK -eq 1 ]]; then
    bad=$(jq -r --arg sys "$SYS_NS_RE" "[$APP_CONTAINERS|select((\$c.livenessProbe // null)==null)|\"\(\$ns)/\(\$pod):\(\$c.name)\"]|unique|.[]" <<<"$PODS_JSON")
    verdict_list "$bad" "I.1.7" M "Liveness Probe trên mọi container ứng dụng" "Tất cả container ứng dụng có livenessProbe."
    fix_if_bad "Thêm livenessProbe vào container (vd):" \
        "livenessProbe: { tcpSocket: { port: 8080 }, initialDelaySeconds: 15, periodSeconds: 20 }"
else result "I.1.7" M NA "Liveness Probe"; fi

# I.1.8 Liveness Probe không trùng endpoint với Readiness Probe (M)
if [[ $KUBE_OK -eq 1 ]]; then
    bad=$(jq -r --arg sys "$SYS_NS_RE" "
      [$APP_CONTAINERS
       | select((\$c.livenessProbe!=null) and (\$c.readinessProbe!=null))
       | select(
           (\$c.livenessProbe.httpGet!=null and \$c.readinessProbe.httpGet!=null
              and \$c.livenessProbe.httpGet.path==\$c.readinessProbe.httpGet.path
              and \$c.livenessProbe.httpGet.port==\$c.readinessProbe.httpGet.port)
           or
           (\$c.livenessProbe.tcpSocket!=null and \$c.readinessProbe.tcpSocket!=null
              and \$c.livenessProbe.tcpSocket.port==\$c.readinessProbe.tcpSocket.port))
       | \"\(\$ns)/\(\$pod):\(\$c.name)\"]|unique|.[]" <<<"$PODS_JSON")
    verdict_list "$bad" "I.1.8" M "Liveness Probe KHÔNG trùng endpoint với Readiness Probe" "Không có container nào trùng endpoint 2 probe."
else result "I.1.8" M NA "Liveness ≠ Readiness endpoint"; fi

# I.1.9 Readiness Probe độc lập (M) — không tự xác minh được tính phụ thuộc
result "I.1.9" M MANUAL "Readiness Probe độc lập (không phụ thuộc DB/migration/external API)"
note "kubectl get pod -A -o=custom-columns=READINESS:.spec.containers[*].readinessProbe.*.path ... — rà soát endpoint."

# I.1.10 Startup Probe cho app khởi động lâu (O)
if [[ $KUBE_OK -eq 1 ]]; then
    sp=$(jq -r --arg sys "$SYS_NS_RE" "[$APP_CONTAINERS|select(\$c.startupProbe!=null)|1]|length" <<<"$PODS_JSON")
    result "I.1.10" O MANUAL "Startup Probe cho app khởi động lâu"; note "$sp container ứng dụng đang có startupProbe — xác nhận đủ cho các app khởi động chậm."
else result "I.1.10" O NA "Startup Probe"; fi

# I.1.11 Dải IP/pod CIDR phù hợp số lượng POD (khuyến nghị prefix /16)
if [[ $KUBE_OK -eq 1 ]]; then
    cidr=""; svc_cidr=""
    # Nguồn 1: cmdline kube-controller-manager (static pod kubeadm)
    if [[ -n "$CM_CMD" ]]; then
        cidr=$(grep -oE -- '--cluster-cidr=[^ ]+' <<<"$CM_CMD" | head -1 | cut -d= -f2)
        svc_cidr=$(grep -oE -- '--service-cluster-ip-range=[^ ]+' <<<"$CM_CMD" | head -1 | cut -d= -f2)
    fi
    # Nguồn 2: ConfigMap kubeadm-config (ClusterConfiguration)
    if [[ -z "$cidr" || -z "$svc_cidr" ]]; then
        kac=$(k -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null)
        if [[ -n "$kac" ]]; then
            [[ -z "$cidr"     ]] && cidr=$(grep -E 'podSubnet:'     <<<"$kac" | head -1 | awk '{print $2}')
            [[ -z "$svc_cidr" ]] && svc_cidr=$(grep -E 'serviceSubnet:' <<<"$kac" | head -1 | awk '{print $2}')
        fi
    fi
    # Nguồn 3: node.spec.podCIDR (chỉ ra được pod CIDR)
    [[ -z "$cidr" ]] && cidr=$(jq -r '[.items[].spec.podCIDR // empty]|.[0] // empty' <<<"$NODES_JSON")
    if [[ -n "$cidr" ]]; then
        prefix=${cidr##*/}
        label="pod=$cidr"; [[ -n "$svc_cidr" ]] && label="$label, service=$svc_cidr"
        if [[ -n "$prefix" && "$prefix" -le 16 ]]; then result "I.1.11" O PASS "Dải IP pod đủ rộng ($label)"
        else result "I.1.11" O WARN "Dải IP pod ($label)"; note "Khuyến nghị prefix ≤ /16 nếu nhiều POD (vd 10.233.0.0/16)."; fi
    else result "I.1.11" O MANUAL "Dải IP pod"; note "kubectl cluster-info dump | grep -m1 cluster-cidr"; fi
else result "I.1.11" O NA "Dải IP pod"; fi

# ════════════════════════════════════════════════════════════════════════════════
section "I.2 — Chỉ tiêu chức năng · Tính bảo mật"

result "I.2.1" O MANUAL "Kiểm soát truy cập vào nền tảng (access list: iptables/firewall/SG)"
note "Soát iptables trên node / security group trên Cloud Dashboard."

# I.2.2 RBAC/ABAC (M)
if [[ $KUBE_OK -eq 1 ]]; then
    if grep -qE -- '--authorization-mode=[^ ]*RBAC' <<<"$APISERVER_CMD"; then
        result "I.2.2" M PASS "Xác thực/ủy quyền (RBAC bật trên kube-apiserver)"
    elif [[ -z "$APISERVER_CMD" ]]; then result "I.2.2" M MANUAL "Xác thực/ủy quyền (RBAC/ABAC)"; note "Không đọc được cmdline apiserver (cụm không phải static-pod?)."
    else result "I.2.2" M FAIL "Xác thực/ủy quyền (RBAC/ABAC)"; note "--authorization-mode không chứa RBAC."; fi
else result "I.2.2" M NA "RBAC/ABAC"; fi

# I.2.3 Quản lý policy trong cluster (M)
if [[ $KUBE_OK -eq 1 ]]; then
    [[ "${np:-0}" -ge 1 ]] && result "I.2.3" M PASS "Tích hợp quản lý policy (NetworkPolicy/Calico)" \
        || { result "I.2.3" M FAIL "Quản lý policy trong cluster"; note "Chưa thấy NetworkPolicy / giải pháp policy."; }
else result "I.2.3" M NA "Quản lý policy"; fi

# I.2.4 Audit Log (M)
if [[ $KUBE_OK -eq 1 ]]; then
    if apiflag '--audit-policy-file'; then result "I.2.4" M PASS "Audit Log đã bật (--audit-policy-file)"
    elif [[ -z "$APISERVER_CMD" ]]; then result "I.2.4" M MANUAL "Audit Log"; note "Không đọc được cmdline apiserver."
    else result "I.2.4" M FAIL "Audit Log"; note "kube-apiserver thiếu --audit-policy-file."; fi
    fix_if_bad "B1: Tạo policy audit (apply audit-policy.yaml)." \
        "B2: Thêm vào /etc/kubernetes/manifests/kube-apiserver.yaml:" \
        "    - --audit-policy-file=/etc/kubernetes/audit/policy.yaml" \
        "    - --audit-log-path=/var/log/kubernetes/audit/audit.log" \
        "    - --audit-log-maxsize=100  --audit-log-maxbackup=20  --audit-log-maxage=90"
else result "I.2.4" M NA "Audit Log"; fi

# I.2.5 Không cho pod chạy bằng root (Pod Security) (M)
if [[ $KUBE_OK -eq 1 ]]; then
    psa=$(k get ns -o jsonpath='{range .items[*]}{.metadata.labels.pod-security\.kubernetes\.io/enforce}{"\n"}{end}' 2>/dev/null | grep -cE 'restricted|baseline')
    if apiflag 'PodSecurity' || (( psa >= 1 )); then result "I.2.5" M PASS "Pod Security (admission/PSA chặn pod chạy root)"; note "$psa namespace có nhãn pod-security enforce."
    else result "I.2.5" M WARN "Pod Security (không cho pod chạy root)"; note "Chưa thấy PodSecurity admission hay nhãn pod-security.kubernetes.io/enforce."; fi
    fix_if_bad "Gắn nhãn enforce cho namespace ứng dụng:" \
        "kubectl label ns <ns> pod-security.kubernetes.io/enforce=restricted" \
        "và thêm 'securityContext: { runAsNonRoot: true }' vào pod/container."
else result "I.2.5" M NA "Pod Security"; fi

result "I.2.6" O MANUAL "Firewall mềm / Security Group cho worker là VM trên Cloud"
note "Kiểm Security Group trên Cloud Dashboard."

# I.2.7 swap (M) — suy luận từ kubelet failSwapOn (kubelet refuses to start nếu node còn swap)
swap_done=0
if [[ $KUBE_OK -eq 1 ]]; then
    node1=${node1:-$(jq -r '.items[0].metadata.name // empty' <<<"$NODES_JSON")}
    cfg=${cfg:-$(k get --raw "/api/v1/nodes/$node1/proxy/configz" 2>/dev/null)}
    fso=$(jq -r '.kubeletconfig.failSwapOn // empty' <<<"$cfg" 2>/dev/null)
    if [[ "$fso" == "true" ]]; then
        result "I.2.7" M PASS "Disable swap (kubelet failSwapOn=true)"
        note "Kubelet sẽ refuse to start nếu node còn swap → cluster đang chạy nghĩa là swap đã off."
        swap_done=1
    elif [[ "$fso" == "false" ]]; then
        result "I.2.7" M WARN "Disable swap (kubelet failSwapOn=false)"
        note "Kubelet đang cho phép swap (NodeSwap). Cần xác nhận thủ công swap đã off trên node."
        fix_if_bad "swapoff -a  &&  sed -i '/swap/s/^/#/' /etc/fstab  &&  sysctl -w vm.swappiness=0"
        swap_done=1
    fi
fi
(( ! swap_done )) && node_assert "I.2.7" M "Disable swap / swappiness=0" \
    'test "$(swapon --noheadings 2>/dev/null | wc -l)" -eq 0 && test "$(cat /proc/sys/vm/swappiness)" -eq 0' \
    "swapon --show; cat /proc/sys/vm/swappiness; df -Th | grep swap"

# I.2.8 SELinux (M) — Ubuntu/Debian không có SELinux mặc định → PASS; HĐH *EL/Fedora cần kiểm thật
sel_done=0
if [[ $KUBE_OK -eq 1 ]]; then
    osi=$(jq -r '[.items[].status.nodeInfo.osImage]|unique|join(" | ")' <<<"$NODES_JSON")
    if [[ -n "$osi" ]] && ! grep -qiE 'centos|red hat|rhel|fedora|rocky|alma|oracle' <<<"$osi"; then
        result "I.2.8" M PASS "SELinux không áp dụng (HĐH không có SELinux mặc định)"
        note "$osi — chỉ tiêu chỉ áp dụng với HĐH có SELinux."
        sel_done=1
    fi
fi
(( ! sel_done )) && node_assert "I.2.8" M "SELinux disabled (nếu HĐH có SELinux)" \
    '! command -v getenforce >/dev/null 2>&1 || [ "$(getenforce)" != "Enforcing" ]' \
    "sestatus / getenforce"

result "I.2.WAF" M MANUAL "API public ra ngoài được bảo vệ bởi WAF"
note "Đội ATTT đánh giá theo kiến trúc."
result "I.2.GW" M MANUAL "API Gateway tách 2 đường Public / Private"
note "Đội ATTT đánh giá theo kiến trúc."

# ════════════════════════════════════════════════════════════════════════════════
section "II.1 — Chỉ tiêu phi chức năng · Kiến trúc & công nghệ"

# II.1.1 Cấu hình tối thiểu node: 4 vCPU / 8GB RAM / 100GB (M)
if [[ $KUBE_OK -eq 1 ]]; then
    bad=$(jq -r '.items[] | .metadata.name as $n
        | (.status.capacity.cpu|tonumber) as $cpu
        | ((.status.capacity.memory|sub("Ki$";"")|tonumber)/1024/1024) as $gib
        | select($cpu < 4 or $gib < 7.5)
        | "\($n): \($cpu) vCPU, \($gib*100|floor/100) GiB"' <<<"$NODES_JSON")
    verdict_list "$bad" "II.1.1" M "Cấu hình tối thiểu node ≥ 4 vCPU / 8GB RAM (đĩa kiểm thủ công)" "CPU & RAM mọi node đạt tối thiểu (đĩa 100GB: kiểm df thủ công)."
else result "II.1.1" M NA "Cấu hình tối thiểu node"; fi

result "II.1.2" M MANUAL "etcd: 99th percentile fsync < 10ms"
note "fio benchmark volume data etcd (https://etcd.io/docs/v3.3/op-guide/hardware/)."

# II.1.3 Phân vùng image container runtime ≥ 100GB (M) — đọc imageFs.capacityBytes từ kubelet /stats/summary
if [[ $KUBE_OK -eq 1 ]]; then
    bad=""; api_ok=1
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        sum=$(k get --raw "/api/v1/nodes/$n/proxy/stats/summary" 2>/dev/null)
        cap=$(jq -r '.node.runtime.imageFs.capacityBytes // empty' <<<"$sum" 2>/dev/null)
        if [[ -z "$cap" ]]; then api_ok=0; break; fi
        # Ngưỡng 100 GB (decimal) = 100 * 10^9 bytes
        if (( cap < 100000000000 )); then
            gib=$(awk "BEGIN{printf \"%.1f\", $cap/1024/1024/1024}")
            bad+="$n: ${gib} GiB"$'\n'
        fi
    done < <(jq -r '.items[].metadata.name' <<<"$NODES_JSON")
    if (( api_ok )); then
        if [[ -z "$bad" ]]; then result "II.1.3" M PASS "Phân vùng image container runtime ≥ 100GB trên mọi node"
        else result "II.1.3" M FAIL "Phân vùng image container runtime ≥ 100GB"; list_detail "node dưới 100GB:" "$RED" "${bad%$'\n'}"; fi
    else
        result "II.1.3" M MANUAL "Phân vùng lưu image container runtime ≥ 100GB"
        note "Không đọc được /api/v1/nodes/<n>/proxy/stats/summary — df -Th trên containerd root (mặc định /var/lib/containerd; k3s: /var/lib/rancher/k3s/agent/containerd)."
    fi
else result "II.1.3" M NA "Phân vùng image container runtime"; fi

result "II.1.4" M MANUAL "Vượt checklist hạ tầng đang hiệu lực"
note "Chạy công cụ checklist hạ tầng hiện hành."

# II.1.5 Version K8s đồng bộ (M)
if [[ $KUBE_OK -eq 1 ]]; then
    nv=$(jq -r '[.items[].status.nodeInfo.kubeletVersion]|unique|length' <<<"$NODES_JSON")
    if (( nv <= 1 )); then result "II.1.5" M PASS "Mọi node cùng version Kubernetes ($KVER_SET)"
    else result "II.1.5" M FAIL "Version Kubernetes đồng bộ"; note "Nhiều version: $KVER_SET"; fi
else result "II.1.5" M NA "Version K8s đồng bộ"; fi

# II.1.6 Version K8s >= v1.23.2 (M)
if [[ $KUBE_OK -eq 1 ]]; then
    if ver_ge "$MIN_KVER" "1.23.2"; then result "II.1.6" M PASS "Version Kubernetes ≥ v1.23.2 (thấp nhất: v$MIN_KVER)"
    else result "II.1.6" M FAIL "Version Kubernetes ≥ v1.23.2"; note "Node thấp nhất: v$MIN_KVER"; fi
else result "II.1.6" M NA "Version K8s ≥ 1.23.2"; fi

# II.1.7 Phiên bản HĐH (M)
if [[ $KUBE_OK -eq 1 ]]; then
    osimg=$(jq -r '[.items[].status.nodeInfo.osImage]|unique|join(" | ")' <<<"$NODES_JSON")
    if grep -qiE 'ubuntu|debian|centos|red hat|rhel|fedora|rocky|alma' <<<"$osimg"; then
        result "II.1.7" M PASS "HĐH node thuộc nhóm hỗ trợ"; note "$osimg"
    else result "II.1.7" M WARN "Phiên bản HĐH node"; note "$osimg — đối chiếu danh mục chuẩn tham chiếu."; fi
else result "II.1.7" M MANUAL "Phiên bản HĐH node"; note "cat /etc/os-release"; fi

# II.1.8 Hiệu năng Calico BGP Route Reflector (M, chỉ khi > 100 worker)
if [[ $KUBE_OK -eq 1 ]]; then
    if (( WORKER_COUNT > 100 )); then
        rr=$(k get nodes -o jsonpath='{.items[*].metadata.annotations}' 2>/dev/null | grep -c 'routeReflectorClusterID')
        if (( rr > 0 )); then result "II.1.8" M PASS "Calico BGP Route Reflector (cụm > 100 worker)"
        else result "II.1.8" M FAIL "Calico BGP Route Reflector"; note "$WORKER_COUNT worker nhưng không node nào làm RR."; fi
    else result "II.1.8" M PASS "Calico BGP Route Reflector (không bắt buộc cho cụm ≤ 100 worker)"; note "$WORKER_COUNT worker — chỉ tiêu chỉ áp dụng khi > 100 worker."; fi
else result "II.1.8" M NA "Calico BGP RR"; fi

# II.1.9 Container Runtime = containerd >= 1.6, không Docker (M)
if [[ $KUBE_OK -eq 1 ]]; then
    bad=$(jq -r '.items[]|.metadata.name as $n|.status.nodeInfo.containerRuntimeVersion as $r
        | select(($r|test("containerd")|not) or (($r|capture("containerd://(?<v>[0-9.]+)").v // "0")|split(".")|map(tonumber)|.[0]*100+.[1] < 106))
        | "\($n): \($r)"' <<<"$NODES_JSON")
    verdict_list "$bad" "II.1.9" M "Container Runtime = containerd ≥ 1.6 (không Docker)" "Mọi node dùng containerd ≥ 1.6."
else result "II.1.9" M NA "Container Runtime"; fi

result "II.1.10" O MANUAL "Sử dụng API Gateway để quản lý API"
# II.1.11 Ingress xử lý HTTP/HTTPS (O)
if [[ $KUBE_OK -eq 1 ]]; then
    ing=$(k get ingress -A --no-headers 2>/dev/null | wc -l)
    ingc=$(jq -r '[.items[]|select(.metadata.name|test("ingress"))]|length' <<<"$PODS_JSON")
    if (( ing >= 1 || ingc >= 1 )); then result "II.1.11" O PASS "Ingress xử lý HTTP/HTTPS"; note "$ing Ingress, $ingc pod ingress-controller."
    else result "II.1.11" O WARN "Ingress xử lý HTTP/HTTPS"; note "Chưa thấy Ingress / ingress-controller."; fi
else result "II.1.11" O NA "Ingress"; fi
result "II.1.12" O MANUAL "Tách cụm API Gateway khỏi cụm chức năng"
result "II.1.13" O MANUAL "Tách cụm Application khỏi cụm SPI"

# ════════════════════════════════════════════════════════════════════════════════
section "II.2 — Chỉ tiêu phi chức năng · Tính tin cậy"

# II.2.1.1 Tối thiểu 3 etcd / 3 master / 3 worker (M)
if [[ $KUBE_OK -eq 1 ]]; then
    etcd=$(jq -r '[.items[]|select(.metadata.labels.component=="etcd")]|length' <<<"$KSYS_JSON")
    msg="master=$MASTER_COUNT, worker=$WORKER_COUNT, etcd=$etcd"
    if (( MASTER_COUNT >= 3 && WORKER_COUNT >= 3 && etcd >= 3 )); then result "II.2.1.1" M PASS "HA: ≥3 master/worker/etcd ($msg)"
    else result "II.2.1.1" M WARN "HA: tối thiểu 3 master/3 worker/3 etcd"; note "$msg (cụm test/single có thể không đạt)."; fi
    # II.2.1.2 etcd quorum: số etcd phải lẻ
    if (( etcd > 0 )); then
        if (( etcd % 2 == 1 )); then result "II.2.1.2" M PASS "etcd quorum: số node etcd lẻ ($etcd)"
        else result "II.2.1.2" M FAIL "etcd quorum (số node etcd phải lẻ)"; note "Đang có $etcd node etcd → nguy cơ split-brain."; fi
    else result "II.2.1.2" M MANUAL "etcd quorum"; note "Không thấy static pod etcd (etcd external?) — etcdctl member list."; fi
else result "II.2.1.1" M NA "HA node count"; result "II.2.1.2" M NA "etcd quorum"; fi

result "II.2.1.3" M MANUAL "Lưu trữ master/etcd nằm trên ≥ 3 cụm storage khác nhau"
result "II.2.1.4" M MANUAL "Lưu trữ worker nằm trên ≥ 2 cụm storage khác nhau"

# II.2.1.5 LB cho K8s Master API Server (M)
if [[ $KUBE_OK -eq 1 ]]; then
    if (( MASTER_COUNT >= 2 )); then result "II.2.1.5" M MANUAL "Load Balancer phân tải K8s Master API Server"; note "kubectl cluster-info — xác nhận endpoint trỏ về VIP/LB (HAProxy+keepalived)."
    else result "II.2.1.5" M NA "LB Master API Server"; note "Chỉ 1 master — không áp dụng phân tải."; fi
else result "II.2.1.5" M NA "LB Master API"; fi

# II.2.2.1 Deployment/StatefulSet >= 2 replica (M)
if [[ $KUBE_OK -eq 1 ]]; then
    bad=$( { jq -r --arg sys "$SYS_NS_RE" '.items[]|select(.metadata.namespace|test($sys)|not)|select((.spec.replicas // 1) < 2)|"deploy \(.metadata.namespace)/\(.metadata.name) (replicas=\(.spec.replicas // 1))"' <<<"$DEPLOY_JSON";
           jq -r --arg sys "$SYS_NS_RE" '.items[]|select(.metadata.namespace|test($sys)|not)|select((.spec.replicas // 1) < 2)|"sts \(.metadata.namespace)/\(.metadata.name) (replicas=\(.spec.replicas // 1))"' <<<"$STS_JSON"; } )
    verdict_list "$bad" "II.2.2.1" M "Deployment/StatefulSet ứng dụng có ≥ 2 pod dự phòng" "Mọi Deployment/StatefulSet ứng dụng có ≥ 2 replica."
    fix_if_bad "kubectl scale deploy/<name> -n <ns> --replicas=2 (hoặc set spec.replicas ≥ 2)."
else result "II.2.2.1" M NA "Pod dự phòng ≥ 2"; fi

# II.2.2.2 Pod không dồn vào 1 node (anti-affinity / topology spread) (M)
if [[ $KUBE_OK -eq 1 ]]; then
    bad=$(jq -r --arg sys "$SYS_NS_RE" '.items[]|select(.metadata.namespace|test($sys)|not)|select((.spec.replicas // 1) >= 2)
        | select(((.spec.template.spec.affinity.podAntiAffinity // null)==null) and ((.spec.template.spec.topologySpreadConstraints // null)==null))
        | "\(.metadata.namespace)/\(.metadata.name)"' <<<"$DEPLOY_JSON")
    warn_list "$bad" "II.2.2.2" M "Pod ứng dụng phân tán (anti-affinity / topologySpread)" "Các Deployment đa replica đều có anti-affinity/topologySpread."
else result "II.2.2.2" M NA "Pod anti-affinity"; fi

# II.2.2.3 Không chạy bare pod (M)
if [[ $KUBE_OK -eq 1 ]]; then
    bad=$(jq -r --arg sys "$SYS_NS_RE" '.items[]|select(.metadata.namespace|test($sys)|not)|select((.metadata.ownerReferences // []|length)==0)|"\(.metadata.namespace)/\(.metadata.name)"' <<<"$PODS_JSON")
    verdict_list "$bad" "II.2.2.3" M "Mọi pod có đối tượng quản lý (không bare pod)" "Không có bare pod (mọi pod có ownerReferences)."
else result "II.2.2.3" M NA "Bare pod"; fi

# II.2.2.4 Phân vùng node không đầy > 80% (M) — đọc node.fs & node.runtime.imageFs từ /stats/summary
if [[ $KUBE_OK -eq 1 ]]; then
    bad=""; api_ok=1
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        sum=$(k get --raw "/api/v1/nodes/$n/proxy/stats/summary" 2>/dev/null)
        for fp in node.fs node.runtime.imageFs; do
            used=$(jq -r ".${fp}.usedBytes // empty"     <<<"$sum" 2>/dev/null)
            cap=$( jq -r ".${fp}.capacityBytes // empty" <<<"$sum" 2>/dev/null)
            if [[ -z "$used" || -z "$cap" || "$cap" == "0" ]]; then api_ok=0; break 2; fi
            pct=$(( used * 100 / cap ))
            (( pct > 80 )) && bad+="$n ($fp): ${pct}% used"$'\n'
        done
    done < <(jq -r '.items[].metadata.name' <<<"$NODES_JSON")
    if (( api_ok )); then
        if [[ -z "$bad" ]]; then result "II.2.2.4" M PASS "Phân vùng node (nodeFs + imageFs) không đầy > 80%"
        else result "II.2.2.4" M FAIL "Có phân vùng > 80% (theo kubelet stats)"; list_detail "phân vùng vượt 80%:" "$RED" "${bad%$'\n'}"; fi
    else
        node_assert "II.2.2.4" M "Không phân vùng nào đầy > 80%" \
            'df -P | awk "NR>1{gsub(/%/,\"\",\$5); if(\$5+0>80) bad=1} END{exit bad+0}"' \
            "df -h (theo dõi 3 tháng, không phân vùng > 80%)"
    fi
else result "II.2.2.4" M NA "Phân vùng node"; fi

result "II.2.3.1" M MANUAL "etcd backup hằng ngày, ≥ 3 bản, trên ≥ 2 storage khác nhau"
note "Kiểm etcdctl snapshot / volume snapshot."
result "II.2.3.2" M MANUAL "Sao lưu file quan trọng của cluster (ca, key, cert) ở nơi an toàn"

# ════════════════════════════════════════════════════════════════════════════════
section "III — Chỉ tiêu phi chức năng · Tính khả dụng (vận hành)"

result "III.1.1" M MANUAL "Có script khôi phục cluster từ backup (rõ input/output)"
result "III.1.2" M MANUAL "Giám sát & cảnh báo certificate expiration (Prometheus rule)"

# III.1.3 Log rotation container runtime (M) — đọc kubelet configz
if [[ $KUBE_OK -eq 1 ]]; then
    node1=$(jq -r '.items[0].metadata.name // empty' <<<"$NODES_JSON")
    cfg=$(k get --raw "/api/v1/nodes/$node1/proxy/configz" 2>/dev/null)
    maxf=$(jq -r '.kubeletconfig.containerLogMaxFiles // 0' <<<"$cfg" 2>/dev/null)
    maxs=$(jq -r '.kubeletconfig.containerLogMaxSize // "?"' <<<"$cfg" 2>/dev/null)
    if [[ -n "$cfg" && "${maxf:-0}" =~ ^[0-9]+$ && "$maxf" -gt 1 ]]; then
        result "III.1.3" M PASS "Log rotation container runtime (maxFiles=$maxf, maxSize=$maxs)"
    elif [[ -z "$cfg" ]]; then result "III.1.3" M MANUAL "Log rotation container runtime"; note "Không đọc được configz; kiểm containerLogMaxSize/Files."
    else result "III.1.3" M WARN "Log rotation container runtime"; note "containerLogMaxFiles=$maxf — nên > 1."; fi
else result "III.1.3" M NA "Log rotation"; fi

# III.1.4 Phân vùng OS (/) không đầy > 80% (M) — đọc node.fs.usedBytes/capacityBytes từ /stats/summary
if [[ $KUBE_OK -eq 1 ]]; then
    bad=""; api_ok=1
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        sum=$(k get --raw "/api/v1/nodes/$n/proxy/stats/summary" 2>/dev/null)
        used=$(jq -r '.node.fs.usedBytes // empty'     <<<"$sum" 2>/dev/null)
        cap=$( jq -r '.node.fs.capacityBytes // empty' <<<"$sum" 2>/dev/null)
        if [[ -z "$used" || -z "$cap" || "$cap" == "0" ]]; then api_ok=0; break; fi
        pct=$(( used * 100 / cap ))
        (( pct > 80 )) && bad+="$n: ${pct}% used"$'\n'
    done < <(jq -r '.items[].metadata.name' <<<"$NODES_JSON")
    if (( api_ok )); then
        if [[ -z "$bad" ]]; then result "III.1.4" M PASS "Phân vùng OS (nodeFs) không đầy > 80% trên mọi node"
        else result "III.1.4" M FAIL "Phân vùng OS đầy > 80%"; list_detail "node vượt 80%:" "$RED" "${bad%$'\n'}"; fi
    else
        node_assert "III.1.4" M "Phân vùng OS (/) không đầy > 80%" \
            'test "$(df -P / | awk "NR==2{gsub(/%/,\"\",\$5); print \$5}")" -le 80' \
            "df -h / ; xác nhận log ứng dụng không ghi vào phân vùng OS"
    fi
else result "III.1.4" M NA "Phân vùng OS"; fi

result "III.1.5" M MANUAL "Script join/detach master/worker (rõ input/output)"

# ════════════════════════════════════════════════════════════════════════════════
section "IV — Chỉ tiêu phi chức năng · Khả năng bảo trì (log & giám sát)"

if [[ $KUBE_OK -eq 1 ]]; then
    has_pod() { jq -r --arg p "$1" '[.items[]|select(.metadata.name|test($p;"i"))]|length' <<<"$PODS_JSON"; }
    prom=$(has_pod 'prometheus'); graf=$(has_pod 'grafana')
    logc=$(has_pod 'fluent|filebeat|logstash|vector|fluentbit'); logs=$(has_pod 'elasticsearch|opensearch|loki')

    if (( logs >= 1 || logc >= 1 )); then result "IV.1.1" M PASS "Thu thập log nền tảng/ứng dụng lên dashboard"; note "log-collector=$logc, log-store=$logs"
    else result "IV.1.1" M MANUAL "Lưu đầy đủ log nền tảng/ứng dụng (visualized dashboard)"; fi

    if (( logc >= 1 && logs >= 1 )); then result "IV.1.2" M PASS "Bộ công cụ log tập trung (collect + store)"; note "collector=$logc, store=$logs"
    else result "IV.1.2" M MANUAL "Công cụ thu thập/lưu trữ/tra cứu log tập trung (EFK/ELK…)"; fi

    if (( prom >= 1 )); then result "IV.1.3" M PASS "Giám sát metrics nền tảng (Prometheus đang chạy)"; note "$prom pod prometheus."
    else result "IV.1.3" M MANUAL "Giám sát metrics nền tảng (Prometheus)"; fi

    sm=$(k get servicemonitors -A --no-headers 2>/dev/null | wc -l)
    if (( prom >= 1 )); then result "IV.1.4" M MANUAL "Giám sát metrics ứng dụng"; note "$sm ServiceMonitor — xác nhận đủ metric ứng dụng."
    else result "IV.1.4" M MANUAL "Giám sát metrics ứng dụng"; fi

    if (( graf >= 1 )); then result "IV.1.5" M PASS "Grafana Dashboard giám sát"; note "$graf pod grafana — xác nhận đủ màn hình."
    else result "IV.1.5" M MANUAL "Grafana Dashboard cho K8S & ứng dụng"; fi

    # IV.1.6 Prometheus lưu metrics ở remote/persistent storage
    pvc=$(k get sts -A -o json 2>/dev/null | jq -r '[.items[]|select(.metadata.name|test("prometheus";"i"))|select((.spec.volumeClaimTemplates // []|length)>0)]|length')
    if (( prom >= 1 )); then
        [[ "${pvc:-0}" -ge 1 ]] && { result "IV.1.6" M PASS "Prometheus dùng persistent volume (remote storage)"; } \
            || { result "IV.1.6" M WARN "Prometheus lưu metrics ở remote storage"; note "Không thấy volumeClaimTemplates cho Prometheus."; }
    else result "IV.1.6" M MANUAL "Prometheus remote storage"; fi
else
    for id in IV.1.1 IV.1.2 IV.1.3 IV.1.4 IV.1.5 IV.1.6; do result "$id" M NA "Log/giám sát"; done
fi

# IV.2.1 Kubelet dynamic config (M) — đã bị gỡ từ K8s 1.24 nên K8s ≥ 1.24 coi như đạt
if [[ $KUBE_OK -eq 1 ]] && ver_ge "$MIN_KVER" "1.24.0"; then
    result "IV.2.1" M PASS "Kubelet dynamic configuration (không áp dụng từ K8s ≥ 1.24)"
    note "Tính năng bị gỡ từ K8s 1.24 (cụm v$MIN_KVER) — chỉ tiêu không còn áp dụng."
else
    result "IV.2.1" M MANUAL "Kubelet dynamic configuration"; note "Kiểm KUBELET_EXTRA_ARGS=--dynamic-config-dir trong /etc/default/kubelet (Debian/Ubuntu) hoặc /etc/sysconfig/kubelet (RHEL/CentOS)."
fi

# IV.2.2 Ngưỡng garbage collection image (M)
if [[ $KUBE_OK -eq 1 ]]; then
    node1=${node1:-$(jq -r '.items[0].metadata.name // empty' <<<"$NODES_JSON")}
    cfg=${cfg:-$(k get --raw "/api/v1/nodes/$node1/proxy/configz" 2>/dev/null)}
    hi=$(jq -r '.kubeletconfig.imageGCHighThresholdPercent // empty' <<<"$cfg" 2>/dev/null)
    lo=$(jq -r '.kubeletconfig.imageGCLowThresholdPercent // empty' <<<"$cfg" 2>/dev/null)
    if [[ -n "$hi" && -n "$lo" ]]; then
        if (( hi <= 65 && lo <= 60 )); then result "IV.2.2" M PASS "Ngưỡng image GC (high=$hi, low=$lo)"
        else result "IV.2.2" M WARN "Ngưỡng image GC (high=$hi, low=$lo)"; note "Chỉ tiêu: high ≤ 65, low ≤ 60."; fi
    else result "IV.2.2" M MANUAL "Ngưỡng garbage collection image"; note "Đọc imageGC*ThresholdPercent từ kubelet configz."; fi
else result "IV.2.2" M NA "Image GC"; fi

# IV.2.3 Giới hạn tài nguyên cho pod/namespace (M)
if [[ $KUBE_OK -eq 1 ]]; then
    bad=$(jq -r --arg sys "$SYS_NS_RE" "[$APP_CONTAINERS|select(((\$c.resources.limits.cpu // null)==null) or ((\$c.resources.limits.memory // null)==null))|\"\(\$ns)/\(\$pod):\(\$c.name)\"]|unique|.[]" <<<"$PODS_JSON")
    verdict_list "$bad" "IV.2.3" M "Giới hạn tài nguyên (CPU+memory limits) cho container ứng dụng" "Mọi container ứng dụng có limits CPU & memory."
    fix_if_bad "Khai báo trong container:" \
        "resources: { requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: 500m, memory: 512Mi} }" \
        "hoặc đặt LimitRange/ResourceQuota cho namespace."
else result "IV.2.3" M NA "Resource limits"; fi

result "IV.2.4" M MANUAL "Giới hạn memory (Xmx/Xms) cho ứng dụng JAVA"
note "kubectl get deploy <app> -o yaml — kiểm JAVA_OPTS."

# ════════════════════════════════════════════════════════════════════════════════
section "V — Chỉ tiêu phi chức năng · Tính bảo mật"

result "V.1" M MANUAL "Không truy cập trực tiếp worker từ ngoài (chỉ rule nội bộ/giám sát/ATTT)"
note "Soát iptables/security group rule allow vào worker."
result "V.2" M MANUAL "Cấu hình nhạy cảm lưu ở Secret / Vault bên thứ 3"

# V.3 Disable Anonymous Access (M)
if [[ $KUBE_OK -eq 1 ]]; then
    if apiflag '--anonymous-auth=false'; then
        result "V.3" M PASS "Anonymous access đã tắt (--anonymous-auth=false)"
    elif [[ -z "$APISERVER_CMD" ]] && command -v curl >/dev/null; then
        # k3s/k0s/RKE2 — apiserver không phải static pod, đo trực tiếp qua HTTP probe không token.
        server=$(k config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
        code=$(curl -ksS --max-time 5 -o /dev/null -w '%{http_code}' "$server/api/v1/namespaces" 2>/dev/null)
        case "$code" in
            401) result "V.3" M PASS "Anonymous access đã tắt (probe $server → HTTP 401)" ;;
            403) result "V.3" M WARN "Anonymous access vẫn bật (probe → HTTP 403: authn ok, RBAC chặn)"; note "Tắt --anonymous-auth=false để từ chối ngay ở authn." ;;
            200) result "V.3" M FAIL "Anonymous truy cập được API (probe → HTTP 200)"; note "Anonymous list được namespaces — cấu hình hở!" ;;
            *)   result "V.3" M MANUAL "Disable Anonymous Access"; note "Probe trả HTTP $code — kiểm tay: ps -ef | egrep -- --anonymous-auth=false" ;;
        esac
    elif [[ -z "$APISERVER_CMD" ]]; then
        result "V.3" M MANUAL "Disable Anonymous Access"; note "Không có curl/server URL — ps -ef | egrep -- --anonymous-auth=false"
    else
        result "V.3" M FAIL "Disable Anonymous Access"; note "kube-apiserver thiếu --anonymous-auth=false."
    fi
    fix_if_bad "Thêm vào kube-apiserver.yaml:  - --anonymous-auth=false" \
        "Lưu ý: chuyển các probe httpGet của apiserver sang tcpSocket để tránh 401."
else result "V.3" M NA "Anonymous access"; fi

# V.4 Enable Admission Controller (M)
if [[ $KUBE_OK -eq 1 ]]; then
    if apiflag '--enable-admission-plugins'; then
        plugins=$(grep -oE -- '--enable-admission-plugins=[^ ]+' <<<"$APISERVER_CMD" | cut -d= -f2)
        result "V.4" M PASS "Admission Controller đã bật"; note "plugins: $plugins"
    elif [[ -z "$APISERVER_CMD" ]] && ver_ge "$MIN_KVER" "1.23.0"; then
        # k3s/k0s/RKE2 — không đọc được cmdline. K8s ≥ 1.23 luôn bật default admission plugins.
        mw=$(k get mutatingwebhookconfigurations --no-headers 2>/dev/null | wc -l)
        vw=$(k get validatingwebhookconfigurations --no-headers 2>/dev/null | wc -l)
        result "V.4" M PASS "Admission Controller đã bật (default plugins của K8s ≥ 1.23)"
        note "Mặc định bật: NodeRestriction, PodSecurity, ResourceQuota, LimitRanger, ServiceAccount, MutatingAdmissionWebhook, ValidatingAdmissionWebhook | webhook đang đăng ký: mutating=$mw, validating=$vw."
    elif [[ -z "$APISERVER_CMD" ]]; then
        result "V.4" M MANUAL "Enable Admission Controller"; note "Không đọc được cmdline apiserver — ps -ef | egrep enable-admission-plugins"
    else
        result "V.4" M WARN "Enable Admission Controller"; note "Không thấy --enable-admission-plugins (đang dùng plugin mặc định)."
    fi
    fix_if_bad "Thêm vào kube-apiserver.yaml, vd:" \
        "  - --enable-admission-plugins=NodeRestriction,PodSecurity,ResourceQuota,LimitRanger"
else result "V.4" M NA "Admission Controller"; fi

# V.5 Security Context trong Pod/Container (M)
if [[ $KUBE_OK -eq 1 ]]; then
    bad=$(jq -r --arg sys "$SYS_NS_RE" '.items[]|select(.metadata.namespace|test($sys)|not)
        | select(((.spec.template.spec.securityContext // {})|length==0) and ([.spec.template.spec.containers[].securityContext // {}]|map(length)|add==0))
        | "\(.metadata.namespace)/\(.metadata.name)"' <<<"$DEPLOY_JSON")
    warn_list "$bad" "V.5" M "Security Context đặt trong Pod/Container ứng dụng" "Mọi Deployment ứng dụng có securityContext."
    fix_if_bad "Thêm vào spec.template.spec (hoặc từng container):" \
        "securityContext: { runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, runAsNonRoot: true }"
else result "V.5" M NA "Security Context"; fi

result "V.6" O MANUAL "Quét lỗ hổng Container Image (tích hợp CI/CD: Clair/Falco…)"
result "V.7" O MANUAL "Access Control cho Image Registry (cluster Read-Only, CI Push)"

# V.8 Immutable Container File System (M)
if [[ $KUBE_OK -eq 1 ]]; then
    bad=$(jq -r --arg sys "$SYS_NS_RE" "[$APP_CONTAINERS|select((\$c.securityContext.readOnlyRootFilesystem // false)!=true)|\"\(\$ns)/\(\$pod):\(\$c.name)\"]|unique|.[]" <<<"$PODS_JSON")
    warn_list "$bad" "V.8" M "Immutable Container File System (readOnlyRootFilesystem)" "Mọi container ứng dụng đặt readOnlyRootFilesystem=true."
    fix_if_bad "Trong container: securityContext: { readOnlyRootFilesystem: true }" \
        "Nếu cần ghi, mount thêm emptyDir vào đường dẫn tạm (vd /tmp)."
else result "V.8" M NA "Immutable FS"; fi

# V.9 CVE-2021-25741 (subpath) (M) — version-based
if [[ $KUBE_OK -eq 1 ]]; then
    # Bản vá có ở: 1.19.15+, 1.20.11+, 1.21.5+, 1.22.2+, và mọi 1.23+
    vuln=0
    if   ! ver_ge "$MIN_KVER" "1.20.0"; then ver_ge "$MIN_KVER" "1.19.15" || vuln=1
    elif ! ver_ge "$MIN_KVER" "1.21.0"; then ver_ge "$MIN_KVER" "1.20.11" || vuln=1
    elif ! ver_ge "$MIN_KVER" "1.22.0"; then ver_ge "$MIN_KVER" "1.21.5"  || vuln=1
    elif ! ver_ge "$MIN_KVER" "1.23.0"; then ver_ge "$MIN_KVER" "1.22.2"  || vuln=1
    fi
    if (( vuln == 0 )); then result "V.9" M PASS "CVE-2021-25741 đã vá (K8s v$MIN_KVER)"
    else result "V.9" M FAIL "CVE-2021-25741 (subpath volume mount)"; note "K8s v$MIN_KVER nằm trong dải bị ảnh hưởng — tắt subpath hoặc nâng cấp."; fi
else result "V.9" M NA "CVE-2021-25741"; fi

# ════════════════════════════════════════════════════════════════════════════════
section "VI — Chỉ tiêu phi chức năng · Yêu cầu khác (cấu hình ứng dụng)"

result "VI.1" M MANUAL "Cấu hình ứng dụng quản lý ngoài application code (12-factor)"

# VI.2 Cấu hình ứng dụng lưu ở ConfigMap (M)
if [[ $KUBE_OK -eq 1 ]]; then
    cm=$(k get cm -A --no-headers 2>/dev/null | grep -vE 'kube-|kube-root-ca|istio' | wc -l)
    if (( cm >= 1 )); then result "VI.2" M PASS "Cấu hình ứng dụng dùng ConfigMap"; note "$cm ConfigMap (ngoài hệ thống)."
    else result "VI.2" M MANUAL "Cấu hình ứng dụng lưu ở ConfigMap"; note "Chưa thấy ConfigMap ứng dụng."; fi
else result "VI.2" M NA "ConfigMap"; fi

# VI.3 Stateful app dùng Persistent Volume / CSI (M)
if [[ $KUBE_OK -eq 1 ]]; then
    bad=$(jq -r --arg sys "$SYS_NS_RE" '.items[]|select(.metadata.namespace|test($sys)|not)
        | select((.spec.volumeClaimTemplates // []|length)==0)
        | "\(.metadata.namespace)/\(.metadata.name)"' <<<"$STS_JSON")
    warn_list "$bad" "VI.3" M "StatefulSet ứng dụng lưu dữ liệu trên PersistentVolume" "Mọi StatefulSet ứng dụng có volumeClaimTemplates."
    fix_if_bad "Khai báo volumeClaimTemplates dùng StorageClass CSI (NFS/Cinder…), không dùng hostPath/emptyDir."
else result "VI.3" M NA "Stateful PV"; fi

# VI.4 HPA tự động co giãn (O)
if [[ $KUBE_OK -eq 1 ]]; then
    hpa=$(k get hpa -A --no-headers 2>/dev/null | wc -l)
    if (( hpa >= 1 )); then result "VI.4" O PASS "Horizontal Pod Autoscaler đã cấu hình"; note "$hpa HPA."
    else result "VI.4" O WARN "HPA tự động co giãn tài nguyên"; note "Chưa có HPA (kubectl get hpa -A)."; fi
else result "VI.4" O NA "HPA"; fi

# ════════════════════════════════════════════════════════════════════════════════
section "VII — Chỉ tiêu cam kết, dịch vụ · Tài liệu"
result "VII.1.1" M MANUAL "Tài liệu thiết kế & triển khai thực tế"
result "VII.1.2" M MANUAL "Tài liệu hướng dẫn sử dụng script VHKT (rõ input/output)"

# ════════════════════════════════════════════════════════════════════════════════
# ─── Khung tổng kết ─────────────────────────────────────────────────────────────
BW=66   # số ký tự ═ giữa hai góc khung
hr() { printf "${BLUE}${BOLD}%s" "$1"; printf '═%.0s' $(seq "$BW"); printf "%s${NC}\n" "$2"; }
# Độ rộng hiển thị: ký tự NFC = 1 cột, bù +1 cho emoji rộng 2 cột (📊).
dispw() { local e; e=$(grep -oE '📊' <<<"$1" | wc -l); echo $(( ${#1} + e )); }
# Một dòng nội dung canh trong khung:  brow <plain> <rendered-có-màu>
brow() {
    local plain="$1" rendered="$2" w pad
    w=$(dispw "$plain"); pad=$(( BW - 2 - w )); (( pad < 0 )) && pad=0
    printf "${BLUE}${BOLD}║${NC} %b%*s ${BLUE}${BOLD}║${NC}\n" "$rendered" "$pad" ""
}

TOTAL_N=$(( PASS_N + FAIL_N + WARN_N + MANUAL_N + NA_N ))
echo
hr "╔" "╗"
brow "📊  TỔNG KẾT KIỂM TRA CHỈ TIÊU" "${BOLD}📊  TỔNG KẾT KIỂM TRA CHỈ TIÊU ${NC}"
hr "╠" "╣"
brow \
    "$(printf 'Đạt: %-4d   Không đạt: %-4d   Cảnh báo: %-4d' "$PASS_N" "$FAIL_N" "$WARN_N")" \
    "$(printf "${GREEN}Đạt: %-4d${NC}   ${RED}Không đạt: %-4d${NC}   ${YELLOW}Cảnh báo: %-4d${NC}" "$PASS_N" "$FAIL_N" "$WARN_N")"
brow \
    "$(printf 'Thủ công: %-4d   N/A: %-4d   Tổng: %-4d' "$MANUAL_N" "$NA_N" "$TOTAL_N")" \
    "$(printf "${CYAN}Thủ công: %-4d${NC}   ${DIM}N/A: %-4d${NC}   ${BOLD}Tổng: %-4d${NC}" "$MANUAL_N" "$NA_N" "$TOTAL_N")"
hr "╠" "╣"
if (( MAND_FAIL_N > 0 )); then
    brow "KHÔNG ĐẠT   $MAND_FAIL_N tiêu chí bắt buộc (M) cần khắc phục." \
         "${RED}${BOLD}KHÔNG ĐẠT${NC}   $MAND_FAIL_N tiêu chí bắt buộc (M) cần khắc phục."
    hr "╚" "╝"
    echo; exit 1
else
    brow "ĐẠT   Không có tiêu chí bắt buộc (M) nào chưa đạt." \
         "${GREEN}${BOLD}ĐẠT${NC}   Không có tiêu chí bắt buộc (M) nào chưa đạt."
    if (( MANUAL_N > 0 || WARN_N > 0 )); then
        brow "Còn $MANUAL_N mục cần đánh giá thủ công, $WARN_N cảnh báo nên rà soát." \
             "${DIM}Còn $MANUAL_N mục cần đánh giá thủ công, $WARN_N cảnh báo nên rà soát.${NC}"
    fi
    hr "╚" "╝"
    echo; exit 0
fi
