#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BACKUP_ROOT="$ROOT_DIR/.bootstrap-backups"

banner() {
    echo
    echo -e "${BOLD}${CYAN}========================================${NC}"
    echo -e "${BOLD}${CYAN}Bootstrap Rollback${NC}"
    echo -e "${BOLD}${CYAN}========================================${NC}"
}

log() {
    echo -e "${BLUE}INFO${NC} $1"
}

success() {
    echo -e "${GREEN}PASS${NC} $1"
}

fail() {
    echo -e "${RED}FAIL${NC} $1"
    exit 1
}

latest_backup_dir() {
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1
}

restore_from_backup() {
    local backup_dir="$1"
    local manifest_file="$backup_dir/manifest.txt"

    [[ -f "$manifest_file" ]] || fail "Backup manifest not found: $manifest_file"

    while IFS='|' read -r relative_path entry_type; do
        [[ -n "$relative_path" ]] || continue

        if [[ "$entry_type" == "file" ]]; then
            mkdir -p "$ROOT_DIR/$(dirname "$relative_path")"
            cp "$backup_dir/$relative_path" "$ROOT_DIR/$relative_path"
            echo -e "${GREEN}RESTORE${NC} $relative_path"
        else
            rm -f "$ROOT_DIR/$relative_path"
            echo -e "${YELLOW}REMOVE${NC}  $relative_path"
        fi
    done < "$manifest_file"
}

banner

if [[ ! -d "$BACKUP_ROOT" ]]; then
    fail "No bootstrap backup directory found. Nothing to rollback."
fi

LATEST_BACKUP=$(latest_backup_dir)
[[ -n "$LATEST_BACKUP" ]] || fail "No bootstrap backup found. Nothing to rollback."

log "Rolling back bootstrap changes from $(basename "$LATEST_BACKUP")"
restore_from_backup "$LATEST_BACKUP"
success "Bootstrap rollback completed. Repository files are back to the state before the latest bootstrap run."
