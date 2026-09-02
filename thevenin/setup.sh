#!/bin/bash
set -e
set -o pipefail

DEVICE=/dev/disk/by-id/scsi-0DO_Volume_thevenin-data
DATA_DIR=/mnt/thevenin_data
REPO_DIR="$HOME/git/thevenin-nginx"
DOMAIN=new.xin-xin.me
RENEWAL_CONF="$DATA_DIR/certbot/conf/renewal/$DOMAIN.conf"

echo "=== Waiting for the thevenin-data volume ==="
echo "Attach the 'thevenin-data' block volume to this droplet in the"
echo "DigitalOcean control panel (Volumes -> thevenin-data -> Attach)."
read -r -p "Press enter once you have attached it: "

for _ in $(seq 30); do
  [ -e "$DEVICE" ] && break
  sleep 2
done

if [ ! -e "$DEVICE" ]; then
  echo "$DEVICE never appeared. Check that the volume is named thevenin-data" >&2
  echo "and is attached to this droplet, then re-run this script." >&2
  exit 1
fi

# A volume created without a filesystem would mount as an empty overlay and
# silently hide the data directory, so refuse rather than guess.
if ! sudo blkid "$DEVICE" >/dev/null 2>&1; then
  echo "$DEVICE has no filesystem. Format it first:" >&2
  echo "  sudo mkfs.ext4 -F $DEVICE" >&2
  exit 1
fi

echo "=== Mounting $DATA_DIR ==="
sudo mkdir -p "$DATA_DIR"
mountpoint -q "$DATA_DIR" || sudo mount -o discard,defaults,noatime "$DEVICE" "$DATA_DIR"
grep -q "$DATA_DIR" /etc/fstab \
  || echo "$DEVICE $DATA_DIR ext4 defaults,nofail,discard 0 0" | sudo tee -a /etc/fstab

echo "=== Creating data directories ==="
sudo mkdir -p "$DATA_DIR/certbot/conf" "$DATA_DIR/certbot/www" \
  "$DATA_DIR/text-edit-data" "$DATA_DIR/mysql/data"
# text-edit serves as an unknown uid inside its container and needs to write
# uploads here; the mysql image chowns its own datadir on first init.
sudo chmod 0777 "$DATA_DIR/text-edit-data"

echo "=== Cloning thevenin-nginx into $REPO_DIR ==="
mkdir -p "$HOME/git"
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" pull --ff-only
else
  git clone https://github.com/xinxinw1/thevenin-nginx.git "$REPO_DIR"
fi

cd "$REPO_DIR"

if [ ! -f .env.secrets ]; then
  echo "=== Generating .env.secrets ==="
  MYSQL_ROOT_PASSWORD="$(openssl rand -base64 24)"
  printf 'MYSQL_ROOT_PASSWORD=%s\n' "$MYSQL_ROOT_PASSWORD" > .env.secrets
  chmod 600 .env.secrets
  echo "Generated a mysql root password. Save it somewhere safe now:"
  echo "  $MYSQL_ROOT_PASSWORD"
  echo "(It only takes effect on a fresh mysql data directory. An existing"
  echo "volume keeps whatever password it already has.)"
  read -r -p "Press enter once you have saved it: "
fi

# nginx refuses to load conf-secure/ if any of the certificate, the key, the
# ssl options file or the dhparams file is missing, so seed all four before
# starting the stack. Without this webserver-secure restart-loops until the
# real certificate is issued.
echo "=== Seeding TLS material ==="
# The stack always keeps its real certificates in $DATA_DIR/certbot/conf, which
# is what certbot reads and writes. Until a real certificate exists, point only
# nginx at a throwaway placeholder tree in the repo checkout via CERT_DIR, so
# nothing is ever written into certbot's own live/ directory. That is what used
# to produce -0001 lineages and force root-owned permission checks.
#
# options-ssl-nginx.conf and ssl-dhparams.pem ship in the repo rather than being
# fetched from certbot's GitHub: the upstream paths moved once already and
# silently 404'd, which is not a good dependency for a fresh droplet.
# sudo: certbot creates renewal/ mode 0700 root-owned, so a plain [ -f ] here
# fails with EACCES and cannot tell "no lineage" from "cannot look".
if sudo test -f "$RENEWAL_CONF"; then HAVE_LINEAGE=yes; else HAVE_LINEAGE=no; fi

# conf-secure/ includes these two from /etc/letsencrypt/ whichever directory
# CERT_DIR points at, and certbot never writes them under certonly --webroot --
# so the real tree needs them even when the placeholder is what nginx mounts.
sudo cp "$REPO_DIR/data/certbot/conf/options-ssl-nginx.conf" \
        "$REPO_DIR/data/certbot/conf/ssl-dhparams.pem" "$DATA_DIR/certbot/conf/"

if [ "$HAVE_LINEAGE" = yes ]; then
  CERT_DIR="$DATA_DIR/certbot/conf"
else
  echo "=== Seeding a placeholder certificate ==="
  echo "No certbot lineage for $DOMAIN yet; nginx will serve a self-signed cert."
  CERT_DIR="$REPO_DIR/placeholder-certs"
  mkdir -p "$CERT_DIR/live/$DOMAIN"
  if [ ! -f "$CERT_DIR/live/$DOMAIN/fullchain.pem" ]; then
    openssl req -x509 -nodes -newkey rsa:4096 -days 365 \
      -keyout "$CERT_DIR/live/$DOMAIN/privkey.pem" \
      -out "$CERT_DIR/live/$DOMAIN/fullchain.pem" \
      -subj "/CN=$DOMAIN"
  fi
  cp "$REPO_DIR/data/certbot/conf/options-ssl-nginx.conf" \
     "$REPO_DIR/data/certbot/conf/ssl-dhparams.pem" "$CERT_DIR/"
fi
export CERT_DIR

echo "=== Starting the stack ==="
docker compose pull
docker compose up -d --remove-orphans

if [ "$HAVE_LINEAGE" = yes ]; then
  echo "=== Certificate for $DOMAIN already managed by certbot ==="
  echo "Leaving the existing lineage alone. If it is broken, remove it with:"
  echo "  cd $REPO_DIR && docker compose run --rm certbot delete --cert-name $DOMAIN"
else
  echo "=== Issuing certificate for $DOMAIN ==="
  echo "$DOMAIN must already resolve to this droplet's IP, or issuance will fail"
  echo "and count against the Let's Encrypt rate limit."
  read -r -p "Is DNS pointed here? [y/N] " reply
  if [ "$reply" = y ] || [ "$reply" = Y ]; then
    # --cert-name pins the lineage name instead of letting certbot derive it
    # from renewal/, where an existing conf would push it to <domain>-0001.
    docker compose run --rm certbot certonly --webroot \
      --webroot-path /var/www/certbot/ --cert-name "$DOMAIN" -d "$DOMAIN"
    # up -d, not restart: CERT_DIR now names a different directory, and restart
    # reuses the existing container with its original mounts.
    CERT_DIR="$DATA_DIR/certbot/conf" docker compose up -d
  else
    echo "Skipped. The stack is serving the self-signed placeholder on :443."
    echo "Re-run this script once DNS is pointed here."
  fi
fi

echo "=== Setup complete ==="
