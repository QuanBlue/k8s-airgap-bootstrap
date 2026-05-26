#!/usr/bin/env bash
set -uo pipefail

IMAGES_DIR=$1
IMAGE_PLATFORM="${IMAGE_PLATFORM:-linux/amd64}"

if [ -z "$IMAGES_DIR" ]; then
    echo "Usage: $0 <path-to-images-directory>"
    exit 1
fi

if [ ! -d "$IMAGES_DIR" ]; then
    echo "Directory $IMAGES_DIR does not exist."
    exit 1
fi

echo "Loading container images from $IMAGES_DIR into containerd (k8s.io namespace, platform ${IMAGE_PLATFORM})..."

failed_images=()

for tar_file in "$IMAGES_DIR"/*.tar; do
    [ -f "$tar_file" ] || continue

    if ! tar -tf "$tar_file" >/dev/null 2>&1; then
        echo "ERROR: $tar_file is corrupted (invalid tar archive), skipping."
        failed_images+=("$tar_file")
        continue
    fi

    echo "Loading $tar_file..."
    if ctr -n k8s.io images import --local --platform "${IMAGE_PLATFORM}" --digests "$tar_file" 2>/dev/null; then
        continue
    fi

    echo "Retrying import without --digests for $tar_file..."
    if ! ctr -n k8s.io images import --local --platform "${IMAGE_PLATFORM}" "$tar_file"; then
        echo "ERROR: Failed to import $tar_file"
        failed_images+=("$tar_file")
    fi
done

if [ ${#failed_images[@]} -gt 0 ]; then
    echo ""
    echo "FAILED to load the following images:"
    for f in "${failed_images[@]}"; do
        echo "  - $f"
    done
    echo "Re-download these tar files and retry."
    exit 1
fi

echo "Finished loading images."
