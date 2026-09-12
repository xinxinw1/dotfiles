#!/bin/bash
set -e
set -o pipefail

# Rebuild the stack and restart its nginx containers, so they re-resolve the
# rebuilt main-website and text-edit; left alone they keep dialing those
# containers' old IPs and answer 502. The full why is in the script this hands
# off to, along with the deploy itself.
#
# That script has to run beside docker-compose.yml, so it lives in
# thevenin-nginx. This wrapper is here so a deploy is `~/deploy.sh` on a droplet,
# with no need to remember where the checkout is -- the same reason ~/setup.sh is
# a path and not a set of instructions. thevenin and thevenin-dev share it, as
# thevenin-dev/ is a symlink to thevenin/, and the checkout is at the same path
# on both.
#
# Arguments are passed straight through, for the env file the stack's script
# explains: a droplet has the .env ~/setup.sh generates, so nothing is normally
# needed here, but `~/deploy.sh --env-file ...` works for a throwaway domain.
GIT_ROOT="$HOME/git"
REPO_DIR="$GIT_ROOT/thevenin-nginx"
SCRIPT="$REPO_DIR/deploy.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "$SCRIPT is missing or not executable." >&2
  echo "~/setup.sh clones thevenin-nginx into $GIT_ROOT -- run it first." >&2
  exit 1
fi

# No cd: the target script cds to its own directory, which is what it needs for
# `docker compose` to find the project.
exec "$SCRIPT" "$@"
