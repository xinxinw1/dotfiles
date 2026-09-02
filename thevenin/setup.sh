#!/bin/bash
set -e
set -o pipefail

DEVICE=/dev/disk/by-id/scsi-0DO_Volume_thevenin-data
DATA_DIR=/mnt/thevenin_data
REPO_DIR="$HOME/git/thevenin-nginx"
DOMAIN=new.xin-xin.me
LIVE_DIR="$DATA_DIR/certbot/conf/live/$DOMAIN"
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
# These two ship in the repo rather than being fetched from certbot's GitHub:
# the upstream paths moved once already and silently 404'd, which is not a good
# dependency for the one procedure that has to work on a fresh droplet.
# Copied unconditionally: nothing on the host owns them. certbot only writes
# options-ssl-nginx.conf through its nginx installer plugin, and this stack runs
# certonly --webroot with no installer. Overwriting every run also repairs the
# empty files the old curl-into-tee seeding left behind.
sudo cp "$REPO_DIR/data/certbot/conf/options-ssl-nginx.conf" "$DATA_DIR/certbot/conf/"
sudo cp "$REPO_DIR/data/certbot/conf/ssl-dhparams.pem" "$DATA_DIR/certbot/conf/"
# Every test against certbot/conf/ needs sudo. certbot creates renewal/,
# archive/ and live/ mode 0700 owned by root, and live/<domain>/*.pem are
# symlinks into archive/. As xinxin, [ -f ] on those paths fails with EACCES and
# reports "not found" for a certificate that is really there -- which regenerates
# the placeholder and re-arms the sentinel on every run.
if ! sudo test -f "$LIVE_DIR/fullchain.pem"; then
  echo "No certificate yet, generating a self-signed placeholder so nginx starts."
  sudo mkdir -p "$LIVE_DIR"
  sudo openssl req -x509 -nodes -newkey rsa:4096 -days 365 \
    -keyout "$LIVE_DIR/privkey.pem" -out "$LIVE_DIR/fullchain.pem" \
    -subj "/CN=$DOMAIN"
  # Marks this lineage as disposable. Step "Issuing certificate" below keys
  # off this file, not off the directory existing.
  sudo touch "$LIVE_DIR/.self-signed"
fi

echo "=== Starting the stack ==="
docker compose pull
docker compose up -d --remove-orphans

# certbot derives the lineage name from renewal/<domain>.conf, not from
# live/<domain>/: unique_lineage_name() opens that conf O_EXCL and falls back to
# <domain>-0001 when it already exists. Deleting live/ while the renewal conf
# survives is what produces a -0001 lineage -- certbot can no longer load the
# old lineage to match it as a duplicate, but still cannot reuse its name. So
# branch on the renewal conf, and pin the name with --cert-name.
if sudo test -f "$RENEWAL_CONF"; then
  echo "=== Certificate for $DOMAIN already managed by certbot ==="
  echo "Leaving the existing lineage alone. If it is broken, remove it with:"
  echo "  cd $REPO_DIR && docker compose run --rm certbot delete --cert-name $DOMAIN"
elif sudo test -f "$LIVE_DIR/.self-signed"; then
  echo "=== Issuing certificate for $DOMAIN ==="
  echo "$DOMAIN must already resolve to this droplet's IP, or issuance will fail"
  echo "and count against the Let's Encrypt rate limit."
  read -r -p "Is DNS pointed here? [y/N] " reply
  if [ "$reply" = y ] || [ "$reply" = Y ]; then
    # Safe here precisely because no renewal conf exists, so there is no lineage
    # to orphan. Still needed: new_lineage() errors on a non-empty live dir.
    sudo rm -rf "$LIVE_DIR"
    docker compose run --rm certbot certonly --webroot \
      --webroot-path /var/www/certbot/ --cert-name "$DOMAIN" -d "$DOMAIN"
    docker compose restart webserver-secure
  else
    echo "Skipped. The stack is serving the self-signed placeholder on :443."
    echo "Re-run this script once DNS is pointed here."
  fi
fi

echo "=== Setup complete ==="
