# Sourced by ~/setup.sh and ~/init-data.sh, not run on its own. Holds the three
# things both have to agree on: which box this is, where its data lives, and
# what "the share is really mounted" means.

# Which box this is. thevenin and thevenin-dev share these scripts --
# thevenin-dev/ is a symlink to thevenin/ -- so they have to work out which of
# the two they are on. cloud-init writes /etc/host-type at bootstrap, before
# anything here runs, so there is nothing to pass in and no caller that does.
# SETUP_HOST_TYPE overrides it for a dry run somewhere that is neither box.
HOST_TYPE_FILE="/etc/host-type"

if [ -n "${SETUP_HOST_TYPE:-}" ]; then
  HOST_TYPE="$SETUP_HOST_TYPE"
elif [ -r "$HOST_TYPE_FILE" ]; then
  HOST_TYPE="$(tr -d '[:space:]' < "$HOST_TYPE_FILE")"
fi

if [ -z "$HOST_TYPE" ]; then
  echo "Cannot tell what host this is: $HOST_TYPE_FILE is missing or empty." >&2
  echo "It is written by cloud-init at bootstrap; on a droplet that file not" >&2
  echo "being there is the problem to fix. Set SETUP_HOST_TYPE to override." >&2
  exit 1
fi

# The only thing that differs between the two. Both mount their own NFS share at
# the same path and run the same stack from the same repo; they answer on
# different names.
case "$HOST_TYPE" in
  thevenin)     DOMAIN=new.xin-xin.me ;;
  thevenin-dev) DOMAIN=xin-xin-test.me ;;
  *)
    echo "These scripts run on thevenin and thevenin-dev, not '$HOST_TYPE'." >&2
    exit 1
    ;;
esac

DATA_DIR=/mnt/thevenin_data
REPO_DIR="$HOME/git/thevenin-nginx"
RENEWAL_CONF="$DATA_DIR/certbot/conf/renewal/$DOMAIN.conf"

# Stands in for "init-data.sh has run against this share". Seeding it is the
# last thing init-data.sh does before the certificate, nothing else on either
# box writes it, and webserver-secure cannot load its config without it.
SEEDED_SSL_CONF="$DATA_DIR/certbot/conf/options-ssl-nginx.conf"

require_data_mount() {
  # cloud-init puts the NFS share in /etc/fstab, so nothing here mounts it.
  # Touch the path first: that fstab entry uses x-systemd.automount, so the real
  # mount only happens on first access -- until then the path is an autofs stub
  # that mountpoint(1) reports as mounted either way, which is why the check
  # below asks findmnt for the filesystem type instead.
  ls "$DATA_DIR" >/dev/null 2>&1 || true

  if ! findmnt -t nfs,nfs4 "$DATA_DIR" >/dev/null; then
    echo "$DATA_DIR is not an NFS mount. The share is mounted from the fstab" >&2
    echo "entry written by $HOST_TYPE/cloud-init.yaml; without it the stack would" >&2
    echo "write certbot, text-edit and mysql data to the droplet's own disk and" >&2
    echo "lose it with the droplet. Check the entry and the share:" >&2
    echo "  grep thevenin_data /etc/fstab" >&2
    echo "  sudo mount -a && findmnt $DATA_DIR" >&2
    exit 1
  fi
}
