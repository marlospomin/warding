# frozen_string_literal: true

require "warding/version"
require "tty-prompt"

module Warding
  class Error < StandardError; end

  class Installer
    @@prompt = TTY::Prompt.new

    def banner
      puts <<~'EOF'

         (  (                    (
         )\))(   '    )   (      )\ )   (            (  (
        ((_)()\ )  ( /(   )(    (()/(   )\    (      )\))(
        _(())\_)() )(_)) (()\    ((_)) ((_)   )\ )  ((_))\
        \ \((_)/ /((_)_   ((_)   _| |   (_)  _(_/(   (()(_)
         \ \/\/ / / _` | | '_| / _` |   | | | ' \)) / _` |
          \_/\_/  \__,_| |_|   \__,_|   |_| |_||_|  \__, |
                                                    |___/

      EOF
    end

    def check
      unless `uname -a`.include?("archiso")
        @@prompt.error("Exiting...")
        @@prompt.warn("Warding can only be installed from within the live ISO context!")
        exit!
      end

      unless `[ -d /sys/firmware/efi ] && echo true`.include?("true")
        @@prompt.error("UEFI/EFI must be enabled to install warding.")
        exit!
      end
    end

    def gather
      locales_list = %w[en_US es_ES pt_BR ru_RU fr_FR it_IT de_DE ja_JP ko_KR zh_CN]
      keymaps_list = %w[us uk br en fr de zh ru it es]

      parsed_input = @@prompt.collect do
        key(:update_mirrors).yes?("Update mirrorlist?")
        key(:system_language).select("Pick the desired system language:", locales_list)
        key(:keyboard_keymap).select("Pick your keyboard layout:", keymaps_list)

        unless @@prompt.yes?("Set timezone automatically?", default: true)
          key(:update_timezone).ask("Enter timezone:", required: true)
        end

        key(:root_password).mask("Insert new root password:", default: "warding")

        key(:system_settings) do
          key(:boot_size).slider("Boot drive partition size (MiB):", min: 512, max: 4096, default: 1024, step: 128)
          key(:swap_size).slider("Swap partition size (MiB):", min: 1024, max: 8192, default: 2048, step: 256)

          if key(:encrypted).yes?("Enable encryption?", default: false)
            key(:encryption_settings) do
              key(:encryption_key).mask("Insert the encryption key:", required: true)
            end
          end
        end

        key(:desktop_environment).select("Select your desktop environment:", %w[plasma gnome i3 none])
      end

      parsed_input
    end

    def install(data, encrypted = false)
      if @@prompt.yes?("Confirm settings and continue?")

        @@prompt.say("Installing, please wait...")

        def setup_mirrors
          # update mirrorlist
          `reflector --latest 100 --sort rate --save /etc/pacman.d/mirrorlist`
        end

        def setup_timezone(timezone = false)
          # set clock
          `timedatectl set-ntp true`
          # set timezone
          if timezone
            `timedatectl set-timezone #{timezone}`
          else
            `timedatectl set-timezone "$(curl -s https://ipapi.co/timezone)"`
          end
        end

        def setup_partitions(boot_size)
          # create partitions
          `parted -s -a optimal /dev/sda \
            mklabel gpt \
            mkpart primary fat32 0% #{boot_size}Mib \
            set 1 esp on \
            mkpart primary ext4 #{boot_size}Mib 100% \
            set 2 lvm on
          `
        end

        def setup_lvm(swap_size, key = false)
          # setup encryption
          if key
            # create an encrypted volume
            `echo "#{key}" | cryptsetup -q luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 /dev/sda2`
            # open the volume
            `echo "#{key}" | cryptsetup open /dev/sda2 cryptlvm -`
            # setup lvm
            `pvcreate /dev/mapper/cryptlvm`
            # create virtual group
            `vgcreate vg0 /dev/mapper/cryptlvm`
          else
            # create physical volume
            `pvcreate /dev/sda2`
            # create virtual group
            `vgcreate vg0 /dev/sda2`
          end
          # create logical volumes
          `lvcreate -L #{swap_size}Mib vg0 -n swap`
          `lvcreate -l 100%FREE vg0 -n root`
          # make and mount rootfs
          `mkfs.ext4 -q /dev/vg0/root`
          `mount /dev/vg0/root /mnt`
          # make and mount boot partition
          `mkfs.fat -F32 /dev/sda1`
          `mkdir /mnt/boot`
          `mount /dev/sda1 /mnt/boot`
          # setup swap
          `mkswap /dev/vg0/swap`
          `swapon /dev/vg0/swap`
        end

        def setup_packages
          # update packages list
          `pacman -Syy`
          # install base system
          `pacstrap /mnt base base-devel linux linux-firmware linux-headers lvm2 mkinitcpio dmidecode smbclient reflector networkmanager go cronie man-db nano vi fuse wget openbsd-netcat dhcpcd samba openssh openvpn unzip vim git zsh`
          # generate fstab
          `genfstab -U /mnt >> /mnt/etc/fstab`
        end

        def setup_chroot(lang, keymap, password = "warding", encrypted = false)
          # set timezone
          `arch-chroot /mnt ln -sf /usr/share/zoneinfo/"$(curl -s https://ipapi.co/timezone)" /etc/localtime`
          # update clock
          `arch-chroot /mnt hwclock --systohc`
          # set locale
          `echo "#{lang}.UTF-8 UTF-8" > /mnt/etc/locale.gen`
          `arch-chroot /mnt locale-gen`
          `echo "LANG=#{lang}.UTF-8" > /mnt/etc/locale.conf`
          # set keymap
          `echo "KEYMAP=#{keymap}" > /mnt/etc/vconsole.conf`
          # update hostname
          `echo "warding" > /mnt/etc/hostname`
          # update hosts
          `echo "127.0.0.1 localhost\n::1 localhost\n127.0.1.1 warding.localdomain warding" > /mnt/etc/hosts`
          # update root password
          `echo -e "#{password}\n#{password}" | arch-chroot /mnt passwd`
          # update hooks
          if encrypted
            `sed -i "/^HOOK/s/modconf/keyboard keymap modconf/" /mnt/etc/mkinitcpio.conf`
            `sed -i "/^HOOK/s/filesystems/encrypt lvm2 filesystems/" /mnt/etc/mkinitcpio.conf`
          else
            `sed -i "/^HOOK/s/filesystems/lvm2 filesystems/" /mnt/etc/mkinitcpio.conf`
          end
          # recompile initramfs
          `arch-chroot /mnt mkinitcpio -P`
          # add intel microcode
          `arch-chroot /mnt pacman -S amd-ucode --noconfirm`
        end

        def setup_bootloader(encrypted = false)
          # setup systemd-boot
          `arch-chroot /mnt bootctl install`
          `echo "title Warding Linux
          linux /vmlinuz-linux
          initrd /amd-ucode.img
          initrd /initramfs-linux.img" > /mnt/boot/loader/entries/warding.conf`
          if encrypted
            `echo "options cryptdevice=UUID=$(blkid -s UUID -o value /dev/sda2):cryptlvm:allow-discards root=/dev/vg0/root quiet rw" >> /mnt/boot/loader/entries/warding.conf`
          else
            `echo "options root=/dev/vg0/root rw" >> /mnt/boot/loader/entries/warding.conf`
          end
        end

        def setup_usability
          # enable internet
          `arch-chroot /mnt systemctl -q enable NetworkManager`
          # add cron jobs
          `echo "#!/bin/bash\nreflector --latest 100 --sort rate --save /etc/pacman.d/mirrorlist" > /mnt/etc/cron.weekly/mirrorlist; chmod +x /mnt/etc/cron.weekly/mirrorlist`
          `echo "#!/bin/bash\npacman -Sy" > /mnt/etc/cron.weekly/pacman-sync; chmod +x /mnt/etc/cron.weekly/pacman-sync`
          `echo "#!/bin/bash\npacman -Syu --noconfirm" > /mnt/etc/cron.monthly/system-upgrade; chmod +x /mnt/etc/cron.monthly/system-upgrade`
          # enable cron jobs
          `arch-chroot /mnt systemctl -q enable cronie`
          # change default shell
          `arch-chroot /mnt chsh -s /usr/bin/zsh`
          # setup wordlists
          `arch-chroot /mnt mkdir -p /usr/share/wordlists`
          `arch-chroot /mnt curl -s https://github.com/danielmiessler/SecLists/blob/master/Discovery/Web-Content/raft-large-directories-lowercase.txt -O --output-dir /usr/share/wordlists`
          `arch-chroot /mnt curl -s https://github.com/danielmiessler/SecLists/blob/master/Discovery/Web-Content/common.txt -O --output-dir /usr/share/wordlists`
          `arch-chroot /mnt curl -s https://github.com/danielmiessler/SecLists/raw/master/Passwords/Leaked-Databases/rockyou.txt.tar.gz -O --output-dir /usr/share/wordlists`
          # setup drivers
          `arch-chroot /mnt pacman -S alsa-utils alsa-plugins alsa-lib --noc`
          # update package list
          `arch-chroot /mnt pacman -Syy`
          # user creation --fix
          `arch-chroot /mnt useradd -m -g wheel -s /bin/zsh ward`
          `sed -i '85 s/# %wheel ALL=(ALL) NOPASSWD: ALL/%wheel ALL=(ALL) NOPASSWD: ALL/g' /mnt/etc/sudoers`
          `arch-chroot /mnt sudo -u ward sh -c "cd /home/ward; git clone https://aur.archlinux.org/yay.git; cd yay; makepkg -si --noconfirm"`
          `arch-chroot /mnt sudo -u ward sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended`
          # check if on VM
          if `arch-chroot /mnt dmidecode -s system-manufacturer`.include?("VMware, Inc.")
            # install and enable VMware utils
            `arch-chroot /mnt pacman -S open-vm-tools --noconfirm`
            `arch-chroot /mnt systemctl -q enable vmtoolsd`
          end
        end

        def setup_visuals(theme)
          case theme
          when "plasma"
            # install packages
            `arch-chroot /mnt pacman -S xorg-server plasma-meta gtkmm konsole sddm kvantum-qt5 --noc -q`
            # create conf dir
            `mkdir -p /mnt/etc/sddm.conf.d`
            # fix theme
            `echo "[Theme]\nCurrent=breeze" > /mnt/etc/sddm.conf.d/theme.conf`
            # enable autologin
            `echo "[Autologin]\nUser=ward\nSession=plasma" > /mnt/etc/sddm.conf.d/autologin.conf`
            # enable sddm
            `arch-chroot /mnt systemctl -q enable sddm`
          when "gnome"
            # install packages
            `arch-chroot /mnt pacman -S gtkmm gnome gnome-tweaks --noc`
            # enable autologin
            `echo "[daemon]\nAutomaticLogin=ward\nAutomaticLoginEnable=True" > /mnt/etc/gdm/custom.conf`
            # enable gdm
            `arch-chroot /mnt systemctl -q enable gdm`
          when "i3"
            # install packages
            `arch-chroot /mnt pacman -S lightdm lightdm-gtk-greeter xorg-server xorg-apps xorg-xinit i3-wm --noc`
            # enable lightdm
            `arch-chroot /mnt systemctl -q enable lightdm`
          else
            nil
          end
        end

        def finish
          `umount -R /mnt`
          `reboot`
        end

        setup_mirrors if data[:update_mirrors]
        data[:update_timezone] ? setup_timezone(data[:update_timezone]) : setup_timezone
        setup_partitions(data[:system_settings][:boot_size])
        data[:system_settings][:encrypted] ? setup_lvm(data[:system_settings][:swap_size], data[:system_settings][:encryption_settings][:encryption_key]) : setup_lvm(data[:system_settings][:swap_size])
        setup_packages
        data[:system_settings][:encrypted] ? setup_chroot(data[:system_language], data[:keyboard_keymap], data[:root_password], true) : setup_chroot(data[:system_language], data[:keyboard_keymap], data[:root_password])
        data[:system_settings][:encrypted] ? setup_bootloader(true) : setup_bootloader
        setup_usability
        setup_visuals(data[:desktop_environment])
        finish
      end
    end
  end
end
