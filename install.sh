#!/bin/bash

# Missing pacman entries and blackarch's repo

# LVM (Unencrypted)

# Virtualbox REQUIRED configuration (else it won't boot)
# Turn EFI ON (Might take a minute to boot, don't worry)

# Set default keyboard languange
loadkeys br-abnt2

# Enable automatic clock time and timezone
timedatectl set-ntp true
timedatectl set-timezone Brazil/East

# Setup disk partitions
parted -s -a optimal /dev/sda \
  mklabel gpt \
  mkpart primary fat32 0 512MiB \
  mkpart primary ext4 512MiB 100% \
  set 1 esp on

# Setup LVM
pvcreate /dev/sda2
vgcreate vg0 /dev/sda2
lvcreate -L 2G vg0 -n swap
lvcreate -l 100%FREE vg0 -n root

mkfs.ext4 /dev/vg0/root
mount /dev/vg0/root /mnt

mkfs.fat -F32 /dev/sda1
mkdir /mnt/boot
mount /dev/sda1 /mnt/boot

mkswap /dev/vg0/swap
swapon /dev/vg0/swap

# Install base packages
pacstrap /mnt base

# Generate fstab entries
genfstab -U /mnt > /mnt/etc/fstab

# Setup chroot clock time and timezone
arch-chroot /mnt ln -sf /usr/share/zoneinfo/Brazil/East /etc/localtime
arch-chroot /mnt hwclock --systohc

# Setup chroot locale
echo "en_US.UTF-8" > /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf

# Setup chroot keymap
echo "KEYMAP=br-abnt2" > /mnt/etc/vconsole.conf

# Setup chroot hostname
echo "warding" > /mnt/etc/hostname

# Setup chroot hosts
echo "127.0.0.1 localhost
::1 localhost
127.0.1.1 warding.localdomain warding" > /mnt/etc/hosts

# Setup chroot root password
arch-chroot /mnt echo -e "warding\nwarding" | passwd

# Setup chroot mkninitcpio
sed -i '/^HOOK/s/filesystems/lvm2 filesystems/' /mnt/etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -p linux

# Setup chroot bootloader
arch-chroot /mnt bootctl install
echo "title Warding Linux
linux /vmlinuz-linux
initrd /initramfs-linux.img
options root=/dev/vg0/root rw" > /mnt/boot/loader/entries/warding.conf

# Setup Xorg
arch-chroot /mnt pacman -Syy xorg-server
arch-chroot /mnt pacman -Syy xf86-video-intel

# Setup KDE
arch-chroot /mnt pacman -Syy plasma

# Setup SDDM
arch-chroot /mnt pacman -Syy sddm
arch-chroot /mnt systemctl enable sddm

mkdir /mnt/etc/sddm.conf.d
echo "[Theme]
Current=breeze" > /mnt/etc/sddm.conf.d/theme.conf
echo "[Autologin]
User=root" > /mnt/etc/sddm.conf.d/login.conf

# Setup blackarch repo
curl https://blackarch.org/strap.sh -o /mnt/tmp/strap.sh
chmod +x /mnt/tmp/strap.sh
arch-chroot /mnt /tmp/strap.sh

# Finish installation
umount -R /mnt
reboot
