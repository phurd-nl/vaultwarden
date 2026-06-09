#!/usr/bin/env bash
# Set up a LUKS-encrypted DATA disk that auto-unlocks once the (already
# LUKS-encrypted) OS/root disk is unlocked at boot (NIST MP / SC-28).
#
# Mechanism: a random keyfile is stored on the encrypted root filesystem and
# registered as a second LUKS key slot on the data disk. systemd's cryptsetup
# generator orders the data-disk unlock AFTER root is mounted (RequiresMountsFor
# on the keyfile path), so entering the root passphrase once cascades to unlock
# the data disk. The data disk also keeps its own passphrase as a recovery key.
#
# The data disk is mounted at the rootless service user's podman storage dir so
# Postgres, the /data volume, attachments, and Caddy all live on the encrypted
# disk.
#
# DESTRUCTIVE: luksFormat wipes the target disk. Runs interactively and refuses
# to touch the root disk, a mounted disk, or a disk that already has a LUKS
# header (unless you wipe it yourself first).
set -euo pipefail

# ---- defaults -------------------------------------------------------------
DEVICE=""
SVC_USER=""
MOUNT_POINT=""
MAPPER_NAME="data_crypt"
KEYFILE="/etc/luks/data.key"
FSTYPE="xfs"
DISCARD=0
ASSUME_YES=0

usage() {
	cat <<EOF
Usage: sudo $0 --device <disk> --user <service-user> [options]

Required:
  --device PATH     Whole data disk to encrypt, e.g. /dev/vdb or /dev/sdb
  --user NAME       Rootless service user whose container storage holds the data

Options:
  --mount PATH      Mount point (default: /home/<user>/.local/share/containers)
  --name NAME       LUKS mapper name        (default: $MAPPER_NAME)
  --keyfile PATH    Keyfile on encrypted root (default: $KEYFILE)
  --fstype TYPE     xfs|ext4                (default: $FSTYPE)
  --discard         Enable TRIM/allow-discards on the LUKS mapping (SSD perf;
                    slightly leaks block-usage. Off by default.)
  --assume-yes      Skip the typed confirmation (passphrase prompts still apply)
  -h, --help        This help

Example:
  sudo $0 --device /dev/vdb --user vaultwarden
EOF
}

# ---- arg parsing ----------------------------------------------------------
while [[ $# -gt 0 ]]; do
	case "$1" in
		--device)   DEVICE="$2"; shift 2 ;;
		--user)     SVC_USER="$2"; shift 2 ;;
		--mount)    MOUNT_POINT="$2"; shift 2 ;;
		--name)     MAPPER_NAME="$2"; shift 2 ;;
		--keyfile)  KEYFILE="$2"; shift 2 ;;
		--fstype)   FSTYPE="$2"; shift 2 ;;
		--discard)  DISCARD=1; shift ;;
		--assume-yes) ASSUME_YES=1; shift ;;
		-h|--help)  usage; exit 0 ;;
		*) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
	esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

# ---- preflight checks -----------------------------------------------------
[[ $EUID -eq 0 ]] || die "must run as root (use sudo)."
[[ -n "$DEVICE" ]] || { usage; die "--device is required."; }
[[ -n "$SVC_USER" ]] || { usage; die "--user is required."; }
id "$SVC_USER" >/dev/null 2>&1 || die "service user '$SVC_USER' does not exist."
[[ "$FSTYPE" == "xfs" || "$FSTYPE" == "ext4" ]] || die "--fstype must be xfs or ext4."

for tool in cryptsetup blkid lsblk findmnt "mkfs.$FSTYPE"; do
	command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

[[ -b "$DEVICE" ]] || die "$DEVICE is not a block device."

# Refuse if the target is the disk backing root '/'.
ROOT_SRC="$(findmnt -no SOURCE / )"
ROOT_BASE="$(lsblk -nso NAME "$ROOT_SRC" 2>/dev/null | tail -1)"
TGT_BASE="$(lsblk -ndo NAME "$DEVICE")"
[[ -n "$ROOT_BASE" && "$ROOT_BASE" == "$TGT_BASE" ]] && \
	die "$DEVICE is the disk backing root (/). Refusing to wipe the OS disk."

# Refuse if the device or any of its partitions is mounted.
mounts="$(lsblk -nro MOUNTPOINT "$DEVICE" | grep -v '^$' || true)"
[[ -z "$mounts" ]] || die "$DEVICE has mounted filesystems:
$mounts
Unmount them first if you really intend to wipe this disk."

# Refuse if it already carries a LUKS header (prevents clobbering encrypted data).
if cryptsetup isLuks "$DEVICE" 2>/dev/null; then
	die "$DEVICE already has a LUKS header. If you intend to reuse it, wipe it
first (e.g. 'cryptsetup erase $DEVICE' and 'wipefs -a $DEVICE'), then re-run."
fi

# Resolve defaults that depend on the user.
SVC_HOME="$(getent passwd "$SVC_USER" | cut -d: -f6)"
[[ -n "$SVC_HOME" ]] || die "could not resolve home dir for '$SVC_USER'."
[[ -z "$MOUNT_POINT" ]] && MOUNT_POINT="$SVC_HOME/.local/share/containers"

CRYPT_OPTS="luks"
[[ "$DISCARD" -eq 1 ]] && CRYPT_OPTS="luks,discard"
OPEN_OPTS=()
[[ "$DISCARD" -eq 1 ]] && OPEN_OPTS=(--allow-discards)

SIZE="$(lsblk -ndo SIZE "$DEVICE")"

# ---- confirm --------------------------------------------------------------
cat <<EOF

About to set up an encrypted data disk:

  Disk to WIPE + encrypt : $DEVICE  ($SIZE)
  LUKS mapper name       : $MAPPER_NAME
  Keyfile (on root FS)   : $KEYFILE
  Filesystem             : $FSTYPE
  Mount point            : $MOUNT_POINT  (owner: $SVC_USER)
  TRIM/discard           : $([[ $DISCARD -eq 1 ]] && echo enabled || echo disabled)

ALL DATA ON $DEVICE WILL BE DESTROYED.
You will be prompted to set a LUKS passphrase (your recovery key — store it in
your password manager).

EOF

if [[ "$ASSUME_YES" -ne 1 ]]; then
	read -r -p "Type the device path to confirm ($DEVICE): " confirm
	[[ "$confirm" == "$DEVICE" ]] || die "confirmation did not match. Aborting."
fi

# Close the mapper on any failure after we open it.
cleanup() {
	local rc=$?
	if [[ $rc -ne 0 ]] && cryptsetup status "$MAPPER_NAME" >/dev/null 2>&1; then
		echo "Cleaning up: closing $MAPPER_NAME after failure." >&2
		cryptsetup close "$MAPPER_NAME" || true
	fi
}
trap cleanup EXIT

# ---- 1. keyfile on the encrypted root -------------------------------------
KEYDIR="$(dirname "$KEYFILE")"
install -d -m 0700 "$KEYDIR"
if [[ -f "$KEYFILE" ]]; then
	echo "[keep] reusing existing keyfile $KEYFILE"
else
	dd if=/dev/urandom of="$KEYFILE" bs=4096 count=1 status=none
	echo "[ok]   generated keyfile $KEYFILE"
fi
chmod 0400 "$KEYFILE"
chown root:root "$KEYFILE"

# ---- 2. LUKS format (interactive passphrase) ------------------------------
echo "==> Formatting $DEVICE as LUKS2 (set your recovery passphrase) ..."
cryptsetup luksFormat --type luks2 "$DEVICE"

# ---- 3. add the keyfile as a second key slot ------------------------------
echo "==> Adding the keyfile as a second key slot (enter the passphrase you just set) ..."
cryptsetup luksAddKey "$DEVICE" "$KEYFILE"

# ---- 4. crypttab entry for auto-unlock ------------------------------------
DATA_UUID="$(cryptsetup luksUUID "$DEVICE")"
CRYPTTAB_LINE="$MAPPER_NAME UUID=$DATA_UUID $KEYFILE $CRYPT_OPTS"
touch /etc/crypttab
if grep -qE "^[[:space:]]*$MAPPER_NAME[[:space:]]" /etc/crypttab; then
	echo "[warn] /etc/crypttab already has an entry for '$MAPPER_NAME'; leaving it as-is:"
	grep -E "^[[:space:]]*$MAPPER_NAME[[:space:]]" /etc/crypttab
else
	printf '%s\n' "$CRYPTTAB_LINE" >> /etc/crypttab
	echo "[ok]   added /etc/crypttab: $CRYPTTAB_LINE"
fi

# ---- 5. open + make filesystem --------------------------------------------
if ! cryptsetup status "$MAPPER_NAME" >/dev/null 2>&1; then
	cryptsetup open "${OPEN_OPTS[@]}" --key-file "$KEYFILE" "$DEVICE" "$MAPPER_NAME"
fi
echo "==> Creating $FSTYPE filesystem on /dev/mapper/$MAPPER_NAME ..."
"mkfs.$FSTYPE" "/dev/mapper/$MAPPER_NAME"

# ---- 6. mount point + fstab + mount ---------------------------------------
mkdir -p "$MOUNT_POINT"
# Warn if the mount point already has data that would be hidden by the mount.
if [[ -n "$(ls -A "$MOUNT_POINT" 2>/dev/null)" ]]; then
	echo "[warn] $MOUNT_POINT is not empty; its current contents will be hidden"
	echo "       by the mount. Move existing data onto the disk after mounting if needed."
fi
FSTAB_LINE="/dev/mapper/$MAPPER_NAME $MOUNT_POINT $FSTYPE defaults,nofail 0 2"
touch /etc/fstab
if grep -qE "^[^#]*[[:space:]]$MOUNT_POINT[[:space:]]" /etc/fstab; then
	echo "[warn] /etc/fstab already mounts something at $MOUNT_POINT; leaving it as-is."
else
	printf '%s\n' "$FSTAB_LINE" >> /etc/fstab
	echo "[ok]   added /etc/fstab: $FSTAB_LINE"
fi

systemctl daemon-reload
mount "$MOUNT_POINT"
chown -R "$SVC_USER:$SVC_USER" "$MOUNT_POINT"

# ---- done -----------------------------------------------------------------
trap - EXIT
cat <<EOF

--------------------------------------------------------------------------
Done. Encrypted data disk is set up and mounted.

  $DEVICE  ->  LUKS ($MAPPER_NAME)  ->  $FSTYPE  ->  $MOUNT_POINT  (owner $SVC_USER)

Verify the auto-unlock cascade survives a reboot:

  sudo reboot
  # enter the ROOT disk passphrase once at boot, then after login:
  findmnt $MOUNT_POINT
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE

Keep the LUKS recovery passphrase you set (for $DEVICE) in your password
manager. The keyfile $KEYFILE is protected by the root-disk encryption.
--------------------------------------------------------------------------
EOF
