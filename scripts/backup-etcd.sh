#!/usr/bin/env bash
#===============================================================================
# backup-etcd.sh
#
# Daily etcd snapshot to BACKUP_DST, rotates files older than RETENTION_DAYS.
# Chụp etcd LOCAL trên chính node đang chạy (snapshot save chỉ nhận 1 endpoint).
# Tự dò endpoint từ /etc/kubernetes/manifests/etcd.yaml; có thể override bằng
# biến môi trường:
#   ETCD_ENDPOINT, ETCD_CACERT, ETCD_CERT, ETCD_KEY, BACKUP_DST, RETENTION_DAYS
#
# Run on a control-plane node (cần đọc được /etc/kubernetes/pki/etcd).
#===============================================================================

set -euo pipefail

ETCD_CACERT="${ETCD_CACERT:-/etc/kubernetes/pki/etcd/ca.crt}"
ETCD_CERT="${ETCD_CERT:-/etc/kubernetes/pki/etcd/server.crt}"
ETCD_KEY="${ETCD_KEY:-/etc/kubernetes/pki/etcd/server.key}"
BACKUP_DST="${BACKUP_DST:-/u01/app/backup/etcd}"
RETENTION_DAYS="${RETENTION_DAYS:-90}"

log() { echo "[$(date +'%F %T')] $*"; }
err() { echo "[$(date +'%F %T')] ERROR: $*" >&2; }

# Dependency check
command -v etcdctl >/dev/null || { err "etcdctl không tìm thấy trong PATH"; exit 2; }
for f in "$ETCD_CACERT" "$ETCD_CERT" "$ETCD_KEY"; do
   [[ -r "$f" ]] || { err "không đọc được cert: $f (cần chạy với quyền root?)"; exit 2; }
done

# Auto-detect endpoint local nếu chưa set. snapshot save chỉ chụp 1 member,
# nên lấy advertise-client-urls của etcd trên chính node này.
ETCD_ENDPOINT="${ETCD_ENDPOINT:-}"
if [[ -z "$ETCD_ENDPOINT" ]]; then
   manifest="/etc/kubernetes/manifests/etcd.yaml"
   if [[ -r "$manifest" ]]; then
      ETCD_ENDPOINT=$(grep -oE -- '--advertise-client-urls=[^ ]+' "$manifest" \
         | head -1 | cut -d= -f2-)
   fi
   if [[ -z "$ETCD_ENDPOINT" ]]; then
      ETCD_ENDPOINT="https://127.0.0.1:2379"
      log "Không dò được endpoint từ $manifest, dùng mặc định: $ETCD_ENDPOINT"
   else
      log "Dò endpoint local: $ETCD_ENDPOINT"
   fi
fi
# Phòng trường hợp có nhiều URL (phân tách bằng dấu phẩy) → chỉ lấy cái đầu.
ETCD_ENDPOINT="${ETCD_ENDPOINT%%,*}"

# Dùng array để tránh bug quote nesting
ETCDCTL_ARGS=(
   --endpoints="$ETCD_ENDPOINT"
   --cacert="$ETCD_CACERT"
   --cert="$ETCD_CERT"
   --key="$ETCD_KEY"
)

TS=$(date +'%Y%m%d-%H%M%S')
mkdir -p "$BACKUP_DST"
BACKUP_FILE="$BACKUP_DST/etcd-snapshot-$TS.db"

log "Starting etcd snapshot to $BACKUP_FILE"
if ! etcdctl "${ETCDCTL_ARGS[@]}" snapshot save "$BACKUP_FILE"; then
   err "snapshot save thất bại"
   rm -f "$BACKUP_FILE"
   exit 1
fi
log "Snapshot saved"

log "Verifying snapshot integrity..."
if ! etcdctl "${ETCDCTL_ARGS[@]}" snapshot status -w table "$BACKUP_FILE"; then
   err "snapshot status check failed"
   rm -f "$BACKUP_FILE"
   exit 1
fi
log "OK"

log "Removing snapshots older than ${RETENTION_DAYS} days"
find "$BACKUP_DST" -name "etcd-snapshot-*.db" -type f -mtime "+$RETENTION_DAYS" -print -delete

log "Rotation complete"
