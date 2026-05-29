#!/usr/bin/env bash
#===============================================================================
# backup-k8s-config.sh
#
# Backup Kubernetes config trên node (master + worker) thành 1 zip,
# rotate file cũ hơn RETENTION_DAYS.
#
# Override qua env:
#   BACKUP_DST, RETENTION_DAYS
#
# RUN ON K8S MASTER + WORKER NODE
#===============================================================================

set -euo pipefail

BACKUP_DST="${BACKUP_DST:-/u01/app/backup/kubernetes}"
RETENTION_DAYS="${RETENTION_DAYS:-90}"

TS=$(date +'%Y%m%d-%H%M%S')
BACKUP_NAME="kubernetes-backup-$TS"
BACKUP_FILE="$BACKUP_DST/$BACKUP_NAME.zip"

log() { echo "[$(date +'%F %T')] $*"; }
err() { echo "[$(date +'%F %T')] ERROR: $*" >&2; }

command -v zip >/dev/null || { err "zip không tìm thấy trong PATH"; exit 2; }

# tmp dir an toàn + tự dọn. Stage vào subfolder tên $BACKUP_NAME để khi giải nén
# ra đúng thư mục kubernetes-backup-<TS> thay vì tên mktemp ngẫu nhiên.
TMP_BACKUP_DIR=$(mktemp -d -t k8s-backup.XXXXXX)
trap 'rm -rf "$TMP_BACKUP_DIR"' EXIT
STAGE_DIR="$TMP_BACKUP_DIR/$BACKUP_NAME"

mkdir -p "$STAGE_DIR/kubernetes-etc" \
         "$STAGE_DIR/kubelet" \
         "$STAGE_DIR/kubeadm"

mkdir -p "$BACKUP_DST"
log "Backup dir: $BACKUP_DST"

###################################################
# /etc/kubernetes
###################################################
K8S_ETC_SRC="/etc/kubernetes"
if [[ -d "$K8S_ETC_SRC" ]]; then
   cp -rp "$K8S_ETC_SRC"/. "$STAGE_DIR/kubernetes-etc/"
   log "Backup success: $K8S_ETC_SRC"
else
   log "Not found: $K8S_ETC_SRC"
fi

###################################################
# kubelet config files
###################################################
KUBELET_SYSTEMD_DIR="/usr/lib/systemd/system/kubelet.service.d"
KUBELET_FILES=(
   "/var/lib/kubelet/config.yaml"
   "/etc/default/kubelet"
   "/etc/sysconfig/kubelet"
   "/etc/kubernetes/bootstrap-kubelet.conf"
)
for file in "${KUBELET_FILES[@]}"; do
   if [[ -f "$file" ]]; then
      cp -p "$file" "$STAGE_DIR/kubelet/"
      log "Backup success: $(basename "$file")"
   else
      log "Not found: $file"
   fi
done
if [[ -d "$KUBELET_SYSTEMD_DIR" ]]; then
   cp -rp "$KUBELET_SYSTEMD_DIR" "$STAGE_DIR/kubelet/"
   log "Backup success: kubelet systemd drop-in"
fi

###################################################
# kubeadm config
###################################################
KUBEADM_CONFIG_SRC="/etc/kubernetes/kubeadm-config.yaml"
if [[ -f "$KUBEADM_CONFIG_SRC" ]]; then
   cp -p "$KUBEADM_CONFIG_SRC" "$STAGE_DIR/kubeadm/"
   log "Backup success: kubeadm-config.yaml"
elif command -v kubectl >/dev/null \
   && kubectl get cm -n kube-system kubeadm-config -o yaml \
      > "$STAGE_DIR/kubeadm/kubeadm-config.yaml" 2>/dev/null; then
   log "kubeadm config dumped via API"
else
   log "kubeadm config không có (worker node?) — bỏ qua"
   rmdir "$STAGE_DIR/kubeadm" 2>/dev/null || true
fi

###################################################
# Zip
###################################################
log "Compressing backup files into $BACKUP_FILE..."
( cd "$TMP_BACKUP_DIR" && zip -r -q "$BACKUP_FILE" "$BACKUP_NAME" )
if [[ -f "$BACKUP_FILE" ]]; then
   log "Backup archive created: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
else
   err "Failed to create backup archive"
   exit 1
fi

###################################################
# Rotate
###################################################
log "Deleting backups older than $RETENTION_DAYS days..."
find "$BACKUP_DST" -name "kubernetes-backup-*.zip" -type f -mtime "+$RETENTION_DAYS" -print -delete

log "Done."
