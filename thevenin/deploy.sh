#!/bin/bash
set -e
set -o pipefail

# Rebuilds and restarts the stack by forwarding to thevenin-nginx's deploy.sh,
# which has to run beside docker-compose.yml -- hence a wrapper at ~/deploy.sh.
GIT_ROOT="$HOME/git"
REPO_DIR="$GIT_ROOT/thevenin-nginx"
SCRIPT="$REPO_DIR/deploy.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "$SCRIPT is missing or not executable." >&2
  echo "~/setup.sh clones thevenin-nginx into $GIT_ROOT -- run it first." >&2
  exit 1
fi

exec "$SCRIPT" "$@"
