#!/bin/bash

# LVM (Unencrypted)
# Turn EFI ON (Might take a minute to boot, don't worry)

# Set default keyboard languange
loadkeys us

# Enable automatic clock time and timezone
timedatectl set-ntp true
timedatectl set-timezone Brazil/East

# Setup disk partitions
parted -s -a optimal /dev/sda \
  mklabel gpt \
  mkpart primary fat32 0 512MiB \
  mkpart primary ext4 512MiB 100% \
  set 1 esp on \
  set 2 lvm on

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
echo "KEYMAP=us" > /mnt/etc/vconsole.conf

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

# Setup networking
arch-chroot /mnt pacman -Sy dhcpcd --noconfirm
arch-chroot /mnt systemctl enable dhcpcd

# Setup Xorg
arch-chroot /mnt pacman -Sy xorg-server xf86-video-intel --noconfirm

# Setup KDE
arch-chroot /mnt pacman -Sy plasma konsole dolphin --noconfirm

# Setup SDDM
arch-chroot /mnt pacman -Sy sddm --noconfirm
arch-chroot /mnt systemctl enable sddm

mkdir /mnt/etc/sddm.conf.d
echo "[Theme]
Current=breeze" > /mnt/etc/sddm.conf.d/theme.conf
echo "[Autologin]
User=root" > /mnt/etc/sddm.conf.d/login.conf

# Setup blackarch repo
arch-chroot /mnt wget -qO- https://blackarch.org/strap.sh | sh

# Install customizations
arch-chroot /mnt pacman -Sy kvantum-qt5 --noconfirm
arch-chroot /mnt wget -qO- https://raw.githubusercontent.com/PapirusDevelopmentTeam/arc-kde/master/install.sh | sh
arch-chroot /mnt wget -qO- https://git.io/papirus-icon-theme-install | sh

# Install basic tools
arch-chroot /mnt pacman -S openbsd-netcat nmap nano go ruby wget openvpn firefox atom hashcat john git jre-openjdk-headless php unzip openssh burpsuite metasploit gunzip wfuzz gobuster impacket enum4linux nikto exploitdb sqlmap binwalk bettercap responder nishang powersploit samba proxychains-ng --noconfirm

# Setup bash aliases
echo "alias l='ls'
alias ll='ls -la'
alias lls='ls -lsah'
alias server='python3 -m http.server'" > /mnt/root/.bash_aliases

# Setup post-install notes
echo "Don't forget to configure your packages, stuff won't work properly until you do so." > /mnt/root/Desktop/todo.txt

# Finish installation
umount -R /mnt
reboot
