#!/bin/bash

#
# UEFI/LVM (Unencrypted)
# Author: p7r0bl4s7
#

function setup_mirrors() {
  pacman -Sy reflector --noconfirm
  reflector --latest 25 --sort rate --save /etc/pacman.d/mirrorlist
}

function set_timezone() {
  # Enable automatic clock time and timezone
  timedatectl set-ntp true
  timedatectl set-timezone Brazil/East
}

function setup_drives() {
  # Setup disk partitions
  parted -s -a optimal /dev/sda \
    mklabel gpt \
    mkpart primary fat32 0% 512MiB \
    set 1 esp on \
    mkpart primary ext4 512MiB 100% \
    set 2 lvm on

  # Setup LVM
  pvcreate /dev/sda2
  vgcreate vg0 /dev/sda2
  lvcreate -L 4G vg0 -n swap
  lvcreate -l 100%FREE vg0 -n root

  mkfs.ext4 /dev/vg0/root
  mount /dev/vg0/root /mnt

  mkfs.fat -F32 /dev/sda1
  mkdir /mnt/boot
  mount /dev/sda1 /mnt/boot

  # Swap
  mkswap /dev/vg0/swap
  swapon /dev/vg0/swap
}

function install_base() {
  # Update keyring
  pacman -S archlinux-keyring --noconfirm

  # Install base packages
  pacstrap /mnt base base-devel

  # Generate fstab entries
  genfstab -U /mnt > /mnt/etc/fstab
}

function setup_chroot() {
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

  # Install linux kernel
  arch-chroot /mnt pacman -Sy archlinux-keyring linux lvm2 mkinitcpio --noconfirm

  # Setup chroot mkninitcpio
  sed -i '/^HOOK/s/filesystems/lvm2 filesystems/' /mnt/etc/mkinitcpio.conf
  arch-chroot /mnt mkinitcpio -p linux

  # Install microcode
  arch-chroot /mnt pacman -S intel-ucode --noconfirm

  # Setup chroot bootloader
  arch-chroot /mnt bootctl install
  echo "title Warding Linux
  linux /vmlinuz-linux
  initrd /intel-ucode.img
  initrd /initramfs-linux.img
  options root=/dev/vg0/root rw" > /mnt/boot/loader/entries/warding.conf
}

function install_default_packages() {
  # Install packages
  arch-chroot /mnt pacman -S make nano fuse wget automake cmake gcc autoconf openbsd-netcat dhcpcd samba openssh openvpn unzip vim xorg-server xf86-video-intel plasma konsole dolphin kmix sddm wget git kvantum-qt5 zsh --noconfirm

  # Update sddm conf
  mkdir /mnt/etc/sddm.conf.d
  echo "[Theme]
  Current=breeze" > /mnt/etc/sddm.conf.d/theme.conf
  echo "[Autologin]
  User=root" > /mnt/etc/sddm.conf.d/login.conf

  # Enable services
  arch-chroot /mnt systemctl enable dhcpcd
  arch-chroot /mnt systemctl enable sddm

  # Setup blackarch repo
  arch-chroot /mnt wget -qO- https://blackarch.org/strap.sh | sh

  # Setup zsh
  arch-chroot /mnt wget -qO- https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh | sh
}

function install_eye_candy() {
  # Install theme and icon set
  arch-chroot /mnt wget -qO- https://raw.githubusercontent.com/PapirusDevelopmentTeam/arc-kde/master/install.sh | sh
  arch-chroot /mnt wget -qO- https://git.io/papirus-icon-theme-install | sh
}

function install_tools() {
  # Install basic tools
  arch-chroot /mnt pacman -S nmap impacket go ruby php firefox atom hashcat john jre-openjdk proxychains-ng exploitdb httpie metasploit bind-tools radare2 sqlmap wpscan xclip  --noconfirm
  # Setup wordlists
  arch-chroot /mnt mkdir -p /usr/share/wordlists
  arch-chroot /mnt wget -q https://github.com/danielmiessler/SecLists/raw/master/Passwords/Leaked-Databases/rockyou.txt.tar.gz -O /usr/share/wordlists/rockyou.txt.tar.gz
  arch-chroot /mnt wget -q https://github.com/danielmiessler/SecLists/raw/master/Discovery/Web-Content/common.txt -O /usr/share/wordlists/common.txt
}

function finish() {
  # Finish installation
  umount -R /mnt
  reboot
}

# Script chain
setup_mirrors
set_timezone
setup_drives
install_base
setup_chroot
install_default_packages

# Argument parsing
while getopts "et" opt; do
  case "$opt" in
  e)
    install_eye_candy
    ;;
  t)
    install_tools
    ;;
  esac
done

shift $((OPTIND-1))

finish
