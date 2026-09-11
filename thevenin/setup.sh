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

# conf-secure/ includes these two from /etc/letsencrypt/, and certbot never
# writes them under certonly --webroot, so nginx cannot load its config without
# them even once a real certificate exists. They ship in the repo rather than
# being fetched from certbot's GitHub: the upstream paths moved once already and
# silently 404'd, which is not a good dependency for a fresh droplet. Copied
# unconditionally -- nothing on the host owns them.
echo "=== Seeding TLS material ==="
sudo cp "$REPO_DIR/data/certbot/conf/options-ssl-nginx.conf" "$DATA_DIR/certbot/conf/"
sudo cp "$REPO_DIR/data/certbot/conf/ssl-dhparams.pem" "$DATA_DIR/certbot/conf/"

# sudo: certbot creates renewal/ mode 0700 root-owned, so a plain [ -f ] fails
# with EACCES and cannot tell "no lineage" from "cannot look" -- which would
# re-issue against an existing lineage.
if sudo test -f "$RENEWAL_CONF"; then HAVE_LINEAGE=yes; else HAVE_LINEAGE=no; fi

if [ "$HAVE_LINEAGE" = no ]; then
  echo "No certificate for $DOMAIN yet. webserver-secure will restart-loop until"
  echo "one is issued -- conf-secure/ needs fullchain.pem and privkey.pem to load."
  echo "This is expected: :80 stays up to serve the ACME challenge, and the secure"
  echo "container comes up on its own once the certificate lands."
fi

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
    # --cert-name pins the lineage name. certbot otherwise derives it from
    # renewal/<domain>.conf and falls back to <domain>-0001 if one exists.
    docker compose run --rm certbot certonly --webroot \
      --webroot-path /var/www/certbot/ --cert-name "$DOMAIN" -d "$DOMAIN"
    docker compose restart webserver-secure
  else
    echo "Skipped. :443 stays down until a certificate is issued."
    echo "Re-run this script once DNS is pointed here."
  fi
fi

echo "=== Setup complete ==="
