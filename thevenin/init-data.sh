#!/bin/bash
set -e
set -o pipefail

# One-time initialization of the NFS share behind $DATA_DIR: the directories the
# stack writes to, the TLS material nginx needs to load, and the first
# certificate. None of it is per-droplet -- the share outlives any one box, which
# is the whole reason the data is on it -- so this is deliberately not part of
# host bootstrap. cloud-init does not run it and ~/setup.sh does not do it.
#
# It also cannot run unattended: answering the DNS question below wrong burns a
# Let's Encrypt rate-limit slot, and nothing here can guess it on a human's
# behalf. Run it by hand once per share:
#
#   ~/init-data.sh
#
# Re-running it is harmless. It creates what is missing, re-seeds the TLS
# material and leaves an existing certificate lineage alone.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

# Whether there is a human on the other end. Set SETUP_NONINTERACTIVE=1 to take
# the unattended path from a terminal, which stops short of the certificate.
if [ -n "${SETUP_NONINTERACTIVE:-}" ] || [ ! -t 0 ]; then
  INTERACTIVE=no
else
  INTERACTIVE=yes
fi

# Stop short of a prompt nobody can answer. Reading EOF off /dev/null instead
# would abort the script anyway -- `read` returns non-zero at EOF and `set -e`
# takes it from there -- but say nothing about what is missing.
stop_for_human() {
  echo
  echo "=== Stopping: this step needs a human ==="
  printf '%s\n' "$@"
  echo
  echo "Re-run the script from a terminal once that is sorted:"
  echo "  ~/init-data.sh"
  exit 0
}

echo "=== Checking $DATA_DIR ==="
require_data_mount

# The checkout and its .env are ~/setup.sh's half of the job: the TLS material
# seeded below is copied out of the repo, and the certificate is issued by a
# container `docker compose` can only start with those in place.
if [ ! -f "$REPO_DIR/.env" ] || [ ! -f "$REPO_DIR/.env.secrets" ]; then
  echo "$REPO_DIR is not set up yet. cloud-init runs ~/setup.sh at bootstrap to" >&2
  echo "clone thevenin-nginx and write its .env; on a droplet that not having" >&2
  echo "happened is the problem to fix. Otherwise run it first:" >&2
  echo "  ~/setup.sh" >&2
  exit 1
fi

echo "=== Creating data directories ==="
sudo mkdir -p "$DATA_DIR/certbot/conf" "$DATA_DIR/certbot/www" \
  "$DATA_DIR/text-edit-data" "$DATA_DIR/mysql/data"
# text-edit serves as an unknown uid inside its container and needs to write
# uploads here; the mysql image chowns its own datadir on first init.
sudo chmod 0777 "$DATA_DIR/text-edit-data"

# templates-secure/ includes these two from /etc/letsencrypt/, and certbot never
# writes them under certonly --webroot, so nginx cannot load its config without
# them even once a real certificate exists. They ship in the repo rather than
# being fetched from certbot's GitHub: the upstream paths moved once already and
# silently 404'd, which is not a good dependency for a fresh droplet. Copied
# unconditionally -- nothing on the host owns them.
echo "=== Seeding TLS material ==="
sudo cp "$REPO_DIR/data/certbot/conf/options-ssl-nginx.conf" "$SEEDED_SSL_CONF"
sudo cp "$REPO_DIR/data/certbot/conf/ssl-dhparams.pem" "$DATA_DIR/certbot/conf/"

cd "$REPO_DIR"

# sudo: certbot creates renewal/ mode 0700 root-owned, so a plain [ -f ] fails
# with EACCES and cannot tell "no lineage" from "cannot look" -- which would
# re-issue against an existing lineage.
if sudo test -f "$RENEWAL_CONF"; then HAVE_LINEAGE=yes; else HAVE_LINEAGE=no; fi

if [ "$HAVE_LINEAGE" = yes ]; then
  echo "=== Certificate for $DOMAIN already managed by certbot ==="
  echo "Leaving the existing lineage alone. If it is broken, remove it with:"
  echo "  cd $REPO_DIR && docker compose run --rm certbot delete --cert-name $DOMAIN"
  echo
  echo "=== Data directory initialized ==="
  echo "Nothing else to do here. ~/setup.sh runs the stack."
  exit 0
fi

# Issuance is over :80, so webserver-insecure has to be serving the challenge
# webroot before certbot asks for anything. ~/setup.sh stops short of starting
# the stack until the share is initialized, so on a fresh one this is what
# brings it up; on a re-run it is the same idempotent pair of commands.
echo "=== Starting the stack ==="
docker compose pull
docker compose up -d --remove-orphans

echo "=== Issuing certificate for $DOMAIN ==="
echo "No certificate for $DOMAIN yet. webserver-secure will restart-loop until"
echo "one is issued -- templates-secure/ needs fullchain.pem and privkey.pem to load."
echo "This is expected: :80 stays up to serve the ACME challenge, and the secure"
echo "container comes up on its own once the certificate lands."
echo "$DOMAIN must already resolve to this droplet's IP, or issuance will fail"
echo "and count against the Let's Encrypt rate limit."
if [ "$INTERACTIVE" = no ]; then
  stop_for_human \
    "Point $DOMAIN at this droplet's IP before a certificate can be issued." \
    "The stack is up and :80 is already serving the ACME challenge, so" \
    "everything but :443 works in the meantime."
fi
read -r -p "Is DNS pointed here? [y/N] " reply
if [ "$reply" = y ] || [ "$reply" = Y ]; then
  # --cert-name pins the lineage name. certbot otherwise derives it from
  # renewal/<domain>.conf and falls back to <domain>-0001 if one exists.
  docker compose run --rm certbot certonly --webroot \
    --webroot-path /var/www/certbot/ --cert-name "$DOMAIN" -d "$DOMAIN"
  docker compose restart webserver-secure
else
  echo "Skipped. :443 stays down until a certificate is issued."
  echo "Re-run this script once DNS is pointed here."
fi

echo "=== Data directory initialized ==="
