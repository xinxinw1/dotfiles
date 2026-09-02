#!/bin/bash
set -e

REPO="xinxinw1/dotfiles"
BRANCH="main"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== Downloading $REPO@$BRANCH ==="
curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" \
  | tar -xz -C "$TMP_DIR" --strip-components=1

echo "=== Installing devbox files into $HOME ==="
cp -a "$TMP_DIR/devbox/." "$HOME/"
find "$HOME" -maxdepth 1 -name '*.sh' -exec chmod 0755 {} +

echo "=== Dotfiles installed ==="
