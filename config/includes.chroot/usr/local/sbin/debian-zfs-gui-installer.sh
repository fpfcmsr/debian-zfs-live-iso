#!/usr/bin/env bash
# debian-zfs-gui-installer.sh
# A semi-graphical Debian installer that sets up:
# - ZFS-on-root on top of LUKS (mirror across two disks)
# - /boot as RAID1 ext4, ESP on each disk
# - Secure Boot: sign ZFS kernel modules with a MOK (password "debian-zfs") and schedule MOK enrollment
# - TPM auto-unlock for LUKS (PCR 7 and 14) when a TPM is present
# - Installs firmware, ZFS, virtualization (qemu/kvm), cockpit, and podman in the target system
#
# Tested on Debian 12 live ISO; network required.
set -euo pipefail

log() { echo -e "[*] $*"; }
fail() { echo -e "[!] $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }

confirm() {
  if command -v zenity >/dev/null 2>&1; then
    zenity --question --title="Confirm" --text="$1" || exit 1
  else
    read -rp "$1 [y/N]: " yn; [[ "${yn,,}" == y* ]] || exit 1
  fi
}

[[ $EUID -eq 0 ]] || fail "Please run as root."
for c in parted mdadm cryptsetup debootstrap lsblk awk sed cut grep tr uname; do need_cmd "$c"; done
command -v zenity >/dev/null 2>&1 || { apt-get update -y && apt-get install -y zenity; }

# --- Collect credentials ---
USERNAME="$(zenity --entry --title="User" --text="Enter the non-root admin username:" --entry-text="admin" || true)"
[[ -n "${USERNAME:-}" ]] || fail "Username is required."

USERPASS="$(zenity --password --title="User Password" --text="Enter password for user '$USERNAME':" || true)"
[[ -n "${USERPASS:-}" ]] || fail "User password is required."
USERPASS2="$(zenity --password --title="User Password" --text="Confirm password for user '$USERNAME':" || true)"
[[ "$USERPASS" == "$USERPASS2" ]] || fail "User passwords do not match."

LUKSPASS="$(zenity --password --title="Disk Encryption" --text="Enter LUKS passphrase (used if TPM unlock fails):" || true)"
[[ -n "${LUKSPASS:-}" ]] || fail "LUKS passphrase is required."
LUKSPASS2="$(zenity --password --title="Disk Encryption" --text="Confirm LUKS passphrase:" || true)"
[[ "$LUKSPASS" == "$LUKSPASS2" ]] || fail "LUKS passphrases do not match."

# --- Select two disks ---
DISK_LIST=$(lsblk -d -e7 -o NAME,SIZE,MODEL,TYPE | awk '$4=="disk"{printf "/dev/%s  (%s)  %s\n",$1,$2,$3}')
[[ -n "$DISK_LIST" ]] || fail "No installable disks found."

SELECTION=$(zenity --list --width=800 --height=420 \
  --title="Select TWO install disks" \
  --text="Choose exactly two disks for the mirrored install (ALL DATA WILL BE ERASED):" \
  --column="Disk" --column="Details" \
  $(echo "$DISK_LIST" | while read -r line; do d=$(echo "$line" | awk '{print $1}'); echo "$d" "$line"; done) \
  --multiple --separator=" " ) || exit 1
read -r DISK1 DISK2 <<<"$(echo "$SELECTION" | tr '|' ' ' | awk '{print $1,$2}')"
[[ -n "${DISK1:-}" && -n "${DISK2:-}" ]] || fail "You must select exactly two disks."
[[ "$DISK1" != "$DISK2" ]] || fail "The two disks must be different."
confirm "Erase EVERYTHING on $DISK1 and $DISK2 and install Debian with ZFS mirror on LUKS?"

log "Using disks: $DISK1 and $DISK2"

# --- Partitioning ---
part_disk() {
  local D="$1"
  log "Partitioning $D ..."
  wipefs -a "$D" || true
  sgdisk --zap-all "$D" || true
  parted -s "$D" mklabel gpt
  parted -s "$D" mkpart ESP fat32 1MiB 513MiB
  parted -s "$D" set 1 esp on
  parted -s "$D" mkpart BOOT ext4 513MiB 1537MiB
  parted -s "$D" mkpart LUKS 1537MiB 100%
  partprobe "$D"
}
part_disk "$DISK1"
part_disk "$DISK2"

partname() { local D="$1" N="$2"; if [[ "$D" == *"nvme"* || "$D" == *"mmcblk"* ]]; then echo "${D}p${N}"; else echo "${D}${N}"; fi; }
ESP1=$(partname "$DISK1" 1); BOOT1=$(partname "$DISK1" 2); LUKS1=$(partname "$DISK1" 3)
ESP2=$(partname "$DISK2" 1); BOOT2=$(partname "$DISK2" 2); LUKS2=$(partname "$DISK2" 3)

mkfs.vfat -F32 "$ESP1"
mkfs.vfat -F32 "$ESP2"

mdadm --zero-superblock --force "$BOOT1" "$BOOT2" || true
mdadm --create /dev/md/boot --level=1 --raid-devices=2 "$BOOT1" "$BOOT2"
mkfs.ext4 -L boot /dev/md/boot

# --- LUKS + ZFS ---
echo -n "$LUKSPASS" | cryptsetup luksFormat "$LUKS1" -q --type luks2 --pbkdf argon2id --iter-time 2000 --hash sha512 --cipher aes-xts-plain64 --key-size 512 --use-urandom --batch-mode --label luks1
echo -n "$LUKSPASS" | cryptsetup luksFormat "$LUKS2" -q --type luks2 --pbkdf argon2id --iter-time 2000 --hash sha512 --cipher aes-xts-plain64 --key-size 512 --use-urandom --batch-mode --label luks2
echo -n "$LUKSPASS" | cryptsetup open "$LUKS1" crypt1
echo -n "$LUKSPASS" | cryptsetup open "$LUKS2" crypt2

# ZFS tooling in live env
if ! modprobe zfs 2>/dev/null; then
  apt-get update -y
  apt-get install -y zfsutils-linux zfs-dkms linux-headers-amd64
  modprobe zfs
fi

zpool create -f -o ashift=12 \
  -O atime=off -O compression=zstd -O xattr=sa -O acltype=posixacl \
  -O normalization=formD -O dnodesize=auto -O relatime=on \
  -O mountpoint=none rpool mirror /dev/mapper/crypt1 /dev/mapper/crypt2

zfs create -o mountpoint=none rpool/ROOT
zfs create -o mountpoint=/ -o canmount=noauto rpool/ROOT/debian
zfs mount rpool/ROOT/debian

zfs create -o mountpoint=/home rpool/home
zfs create -o mountpoint=/var rpool/var
zfs create -o mountpoint=/var/log rpool/var/log
zfs create -o mountpoint=/var/tmp -o sync=disabled rpool/var/tmp
zfs create -o mountpoint=/srv rpool/srv

mkdir -p /mnt/target
mount -t zfs rpool/ROOT/debian /mnt/target
mkdir -p /mnt/target/boot /mnt/target/boot/efi
mount /dev/md/boot /mnt/target/boot
mount "$ESP1" /mnt/target/boot/efi

# --- Bootstrap Debian ---
DEB_RELEASE="${DEB_RELEASE:-bookworm}"
apt-get update -y
apt-get install -y debootstrap
debootstrap --arch amd64 "$DEB_RELEASE" /mnt/target http://deb.debian.org/debian

cat >/mnt/target/etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

HOSTNAME="debian-zfs"
echo "$HOSTNAME" >/mnt/target/etc/hostname

UUID_LUKS1=$(blkid -s UUID -o value "$LUKS1")
UUID_LUKS2=$(blkid -s UUID -o value "$LUKS2")
cat >/mnt/target/etc/crypttab <<EOF
crypt1 UUID=$UUID_LUKS1 none luks,discard
crypt2 UUID=$UUID_LUKS2 none luks,discard
EOF

UUID_BOOT=$(blkid -s UUID -o value /dev/md/boot)
UUID_ESP1=$(blkid -s UUID -o value "$ESP1")
cat >/mnt/target/etc/fstab <<EOF
UUID=$UUID_BOOT /boot ext4 defaults 0 2
UUID=$UUID_ESP1 /boot/efi vfat umask=0077 0 1
EOF

mkdir -p /mnt/target/etc/zfs
zpool set cachefile=/etc/zfs/zpool.cache rpool
zfs set mountpoint=/ rpool/ROOT/debian

# --- Chroot phase ---
cat >/mnt/target/root/inside-chroot.sh <<"CHROOT"
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
log() { echo "[chroot] $*"; }

apt-get update -y
apt-get install -y locales
sed -i 's/^# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

apt-get install -y linux-image-amd64 grub-efi-amd64 shim-signed efibootmgr \
  zfsutils-linux zfs-initramfs dkms sbsigntool mokutil \
  mdadm cryptsetup-initramfs \
  tpm2-tools tpm2-tss clevis clevis-luks clevis-initramfs \
  sudo curl wget vim git net-tools

# Firmware and microcode
if grep -qi "GenuineIntel" /proc/cpuinfo; then MICROP="intel-microcode"; else MICROP="amd64-microcode"; fi
apt-get install -y firmware-linux firmware-misc-nonfree ${MICROP}

# Virtualization + containers + cockpit (in target system)
apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst bridge-utils \
  podman cockpit cockpit-podman cockpit-machines

systemctl enable zfs-mount zfs-import-cache zfs-zed || true
systemctl enable cockpit.socket || true

USERNAME_FILE="/root/installer-username"
USERPASS_FILE="/root/installer-userpass"
if [[ -f "$USERNAME_FILE" && -f "$USERPASS_FILE" ]]; then
  USERNAME="$(cat "$USERNAME_FILE")"
  USERPASS="$(cat "$USERPASS_FILE")"
  log "Creating user $USERNAME ..."
  adduser --disabled-password --gecos "" "$USERNAME"
  echo "${USERNAME}:${USERPASS}" | chpasswd
  usermod -aG sudo,libvirt,libvirt-qemu,kvm "${USERNAME}"
  passwd -l root
fi

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck
update-initramfs -u
update-grub

# Secure Boot: sign ZFS modules; set up DKMS auto-signing
MOKDIR=/root/mok
mkdir -p "$MOKDIR"
openssl req -new -x509 -newkey rsa:2048 -days 36500 \
  -keyout "$MOKDIR/MOK-ZFS.key" -out "$MOKDIR/MOK-ZFS.crt" \
  -subj "/CN=Debian ZFS MOK/" -sha256 -passout pass:debian-zfs
openssl x509 -in "$MOKDIR/MOK-ZFS.crt" -outform DER -out "$MOKDIR/MOK-ZFS.der"
echo "debian-zfs" > "$MOKDIR/mok-pass.txt"
mokutil --import "$MOKDIR/MOK-ZFS.der" < "$MOKDIR/mok-pass.txt" || true

install -Dm0755 /dev/stdin /usr/local/sbin/dkms-sign-zfs.sh <<'EOS'
#!/bin/bash
set -euo pipefail
MOD="$1"
KEY="/root/mok/MOK-ZFS.key"
CRT="/root/mok/MOK-ZFS.crt"
export KBUILD_SIGN_PIN="debian-zfs"
/usr/bin/kmodsign sha512 "$KEY" "$CRT" "$MOD"
EOS
echo 'sign_tool=/usr/local/sbin/dkms-sign-zfs.sh' >/etc/dkms/framework.conf

KREL="$(uname -r)"
find "/lib/modules/${KREL}" -type f -name 'zfs*.ko' -print0 | while IFS= read -r -d '' mod; do
  export KBUILD_SIGN_PIN="debian-zfs"
  /usr/bin/kmodsign sha512 /root/mok/MOK-ZFS.key /root/mok/MOK-ZFS.crt "$mod" || true
done

# TPM auto-unlock with PCR 7 and 14
if [[ -e /dev/tpmrm0 || -e /dev/tpm0 ]]; then
  log "TPM detected; binding LUKS volumes with clevis TPM2 (PCR 7,14)."
  for dev in $(blkid -t TYPE="crypto_LUKS" -o device); do
    echo '{"pcr_bank":"sha256","pcr_ids":"7,14"}' | clevis luks bind -f -d "$dev" tpm2 -
  done
  update-initramfs -u
else
  log "No TPM found; skipping clevis binding."
fi

# SSH hardening
if [ -f /etc/ssh/sshd_config ]; then
  sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config || true
fi

CHROOT

chmod +x /mnt/target/root/inside-chroot.sh
echo -n "$USERNAME" >/mnt/target/root/installer-username
echo -n "$USERPASS" >/mnt/target/root/installer-userpass

for d in /dev /dev/pts /proc /sys /run; do mount --bind "$d" "/mnt/target$d"; done
chroot /mnt/target /root/inside-chroot.sh
for d in /run /sys /proc /dev/pts /dev; do umount -lf "/mnt/target$d" || true; done
rm -f /mnt/target/root/installer-username /mnt/target/root/installer-userpass

mkdir -p /mnt/target/boot/efi2
mount "$ESP2" /mnt/target/boot/efi2
rsync -a /mnt/target/boot/efi/EFI/ /mnt/target/boot/efi2/EFI/
umount /mnt/target/boot/efi2
rmdir /mnt/target/boot/efi2 || true

mdadm --detail --scan >> /mnt/target/etc/mdadm/mdadm.conf || true

zpool set cachefile=/etc/zfs/zpool.cache rpool
zpool export rpool || true
sync

log "Installation completed."
log "On first reboot with Secure Boot enabled, enroll the MOK using password: debian-zfs"
confirm "Reboot now into the installed system?"
reboot
