#!/usr/bin/env bash
set -e

IMAGES_DIR=$1

if [ -z "$IMAGES_DIR" ]; then
    echo "Usage: $0 <path-to-images-directory>"
    exit 1
fi

if [ ! -d "$IMAGES_DIR" ]; then
    echo "Directory $IMAGES_DIR does not exist."
    exit 1
fi

echo "Loading container images from $IMAGES_DIR into containerd (k8s.io namespace)..."

for tar_file in "$IMAGES_DIR"/*.tar; do
    if [ -f "$tar_file" ]; then
        echo "Loading $tar_file..."
        ctr -n k8s.io image import "$tar_file"
    fi
done

echo "Finished loading images."
