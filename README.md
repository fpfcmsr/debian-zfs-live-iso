# Debian Live ISO with ZFS-on-LUKS Installer (PCR 7+14, Secure Boot)

This repository contains a **live-build** recipe for a Debian 12 (Bookworm) live ISO that boots to an XFCE desktop and offers a graphical installer to set up **ZFS-on-LUKS** (mirror across two disks), with:

- Root-on-ZFS on top of **LUKS** (two-disk mirror)
- **/boot** on RAID1 (ext4), **ESP** on each disk (UEFI)
- **Secure Boot**: generates & imports a MOK, **signs ZFS modules** with password `debian-zfs`, and configures DKMS auto-signing
- **TPM auto-unlock** via **Clevis** bound to PCR **7 and 14**
- Target system packages: firmware (intel/amd), ZFS + utilities, **qemu/kvm**, **Cockpit**, **Podman**

## Requirements
- A Debian 12/13 (amd64) build host with internet access
- Packages: `live-build` `debootstrap` `xorriso` `cpio` `squashfs-tools` `apt-cacher-ng` (optional)  
  ```bash
  sudo apt-get update
  sudo apt-get install -y live-build debootstrap xorriso cpio squashfs-tools
  ```

## Build the ISO
```bash
git clone <this-folder> debian-zfs-live-iso
cd debian-zfs-live-iso
sudo ./scripts/make-iso.sh
```
The resulting ISO appears under `live-image-amd64.hybrid.iso`.

## What’s inside
- `auto/config` – live-build configuration (Bookworm, amd64, **main contrib non-free non-free-firmware**)
- `config/package-lists/custom.list.chroot` – packages for the live system (ZFS, cryptsetup, clevis, dkms, linux-headers, zenity, XFCE…)
- `config/includes.chroot/usr/local/sbin/debian-zfs-gui-installer.sh` – the installer (GUI prompts via zenity)
- `config/includes.chroot/usr/local/bin/run-installer-gui` – launcher that asks to start and runs the installer as root
- `config/includes.chroot/etc/xdg/autostart/debian-zfs-installer.desktop` – autostarts the launcher when the desktop loads
- `config/includes.chroot/etc/sudoers.d/zz-zfs-installer` – lets sudoers run the installer without a password in the live session
- `config/hooks/live/010-apt-sources.hook.chroot` – ensures **non-free-firmware** is enabled in the live environment

## Using the ISO
1. Boot the ISO (UEFI recommended). The desktop will prompt to start the installer.
2. The installer will:
   - Ask for username/password and **LUKS** passphrase
   - Let you pick **two disks** (all data wiped)
   - Create **ESP + /boot RAID1 + LUKS + ZFS mirror**
   - Bootstrap Debian, install requested packages, **lock root**, set up ZFS services
   - **Create a MOK, sign ZFS modules** (password `debian-zfs`), enroll MOK on next boot
   - Enable **TPM auto-unlock** with Clevis bound to **PCR 7 and 14**
3. Reboot. On first boot with Secure Boot enabled, a **MOK Manager** screen appears; choose **Enroll key**, enter `debian-zfs`.

## Notes
- Based on the OpenZFS **Debian Bookworm Root on ZFS** guidance (archive areas and general flow).  
- Live environment includes `zfs-dkms` and `linux-headers-amd64` so ZFS modules load in RAM.
- If you need a different desktop or additional live packages, add them to `config/package-lists/custom.list.chroot`.

## Change the MOK passphrase (optional)
The passphrase `debian-zfs` is convenient for testing but not ideal for production. To change it, edit the installer at:
`config/includes.chroot/usr/local/sbin/debian-zfs-gui-installer.sh` (search for `debian-zfs`).

## License
Public domain / CC0 for everything in this recipe.
