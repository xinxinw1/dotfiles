#!/bin/bash
set -e
set -o pipefail

DATA_DIR=/mnt/thevenin_data
REPO_DIR="$HOME/git/thevenin-nginx"
DOMAIN=new.xin-xin.me
RENEWAL_CONF="$DATA_DIR/certbot/conf/renewal/$DOMAIN.conf"

# Whether there is a human on the other end. thevenin/cloud-init.yaml runs this
# from runcmd at bootstrap, where stdin is not a tty, and the steps below that
# need an answer cannot be guessed on a human's behalf -- answering the DNS
# question wrong burns a Let's Encrypt rate-limit slot. Set
# SETUP_NONINTERACTIVE=1 to take the unattended path from a terminal.
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
  echo "  ~/setup.sh"
  exit 0
}

echo "=== Checking $DATA_DIR ==="
# cloud-init puts the NFS share in /etc/fstab, so nothing here mounts it.
# Touch the path first: that fstab entry uses x-systemd.automount, so the real
# mount only happens on first access -- until then the path is an autofs stub
# that mountpoint(1) reports as mounted either way, which is why the check
# below asks findmnt for the filesystem type instead.
ls "$DATA_DIR" >/dev/null 2>&1 || true

if ! findmnt -t nfs,nfs4 "$DATA_DIR" >/dev/null; then
  echo "$DATA_DIR is not an NFS mount. The share is mounted from the fstab" >&2
  echo "entry written by thevenin/cloud-init.yaml; without it the stack would" >&2
  echo "write certbot, text-edit and mysql data to the droplet's own disk and" >&2
  echo "lose it with the droplet. Check the entry and the share:" >&2
  echo "  grep thevenin_data /etc/fstab" >&2
  echo "  sudo mount -a && findmnt $DATA_DIR" >&2
  exit 1
fi

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
  if [ "$INTERACTIVE" = yes ]; then
    read -r -p "Press enter once you have saved it: "
  else
    # Nothing to decide here, so an unattended run has no reason to stop: the
    # prompt only exists so the password does not scroll past a human. It stays
    # readable in the file either way.
    echo "Unattended run, so nothing to acknowledge. The password stays in"
    echo "  $REPO_DIR/.env.secrets"
  fi
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
fi

echo "=== Setup complete ==="
