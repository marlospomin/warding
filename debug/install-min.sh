#!/bin/bash

# Minimal debug version

# LVM (Unencrypted)
# Turn EFI ON (Might take a minute to boot, don't worry)

# Set default keyboard languange
loadkeys br-abnt2

# Enable automatic clock time and timezone
timedatectl set-ntp true
timedatectl set-timezone Brazil/East

# Setup disk partitions (Interactive)
cfdisk /dev/sda

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
pacstrap /mnt base base-devel

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

# Install more dependencies
arch-chroot /mnt pacman -Sy linux lvm2 mkinitcpio --noconfirm

# Setup chroot mkninitcpio
sed -i '/^HOOK/s/filesystems/lvm2 filesystems/' /mnt/etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -p linux

# Install microcode
arch-chroot /mnt pacman -Sy archlinux-keyring --noconfirm
arch-chroot /mnt pacman -Sy intel-ucode --noconfirm

# Setup chroot bootloader
arch-chroot /mnt bootctl install
echo "title Warding Linux
linux /vmlinuz-linux
initrd /intel-ucode.img
initrd /initramfs-linux.img
options root=/dev/vg0/root rw" > /mnt/boot/loader/entries/warding.conf

# Finish installation
umount -R /mnt
reboot
