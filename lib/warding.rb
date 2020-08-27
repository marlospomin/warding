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
        @@prompt.error("UEFI/EFI must be enabled to install warding")
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

        key(:root_password).mask("Insert new root password:", required: true)

        key(:system_settings) do
          bootloader = key(:bootloader).select("Which bootloader to use?", %w[systemd-boot grub])
          partitions = key(:partitions).select(
            "Select partition scheme to use:", ["/boot and /root", "/boot, /root and /home"]
          )

          key(:boot_size).slider("Boot drive partition size (MiB):", min: 512, max: 4096, default: 1024, step: 128)

          if partitions == "/boot, /root and /home"
            key(:home_size).slider("Home partition size (MiB):", min: 2048, max: 8192, default: 4096, step: 256)
          end

          key(:swap_size).slider("Swap partition size (MiB):", min: 1024, max: 8192, default: 2048, step: 256)

          if @@prompt.yes?("Enable encryption?", default: false)
            key(:encryption_settings) do
              key(:encryption_mode).expand("Which cryptic setup to use?") do |q|
                if partitions == "/boot, /root and /home"
                  q.choice key: "m", name: "minimal (/home only)" do :minimal end
                  q.choice key: "s", name: "safe (/home, /var, /tmp and swap)", value: :safe
                end
                q.choice key: "p", name: "paranoid (full disk encryption, except /boot)", value: :paranoid
                q.choice key: "i", name: "insane (full disk encryption)", value: :insane if bootloader == "grub"
              end
              key(:encryption_key).mask("Insert the encryption key:", required: true)
            end
          end
        end

        key(:desktop_environment).select("Select your desktop environment:", %w[plasma gnome none])
      end

      parsed_input
    end

    def install(data)
      if @@prompt.yes?("Confirm settings and continue?")

        @@prompt.say("Installing, please wait...")

        def setup_mirrors
          # update mirrorlist
          `reflector --latest 25 --sort rate --save /etc/pacman.d/mirrorlist`
        end

        setup_mirrors if data[:update_mirrors]

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

        data[:update_timezone] ? setup_timezone(data[:update_timezone]) : setup_timezone

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

        setup_partitions(data[:system_settings][:boot_size])

        def setup_lvm(scheme, swap_size, home_size = false)
          # create physical volume
          `pvcreate /dev/sda2`
          # create virtual group
          `vgcreate vg0 /dev/sda2`
          # create logical volumes
          `lvcreate -L #{swap_size}Mib vg0 -n swap`
          if scheme == "/boot, /root and /home"
            `lvcreate -L #{home_size}Mib vg0 -n home`
          end
          `lvcreate -l 100%FREE vg0 -n root`
          # make and mount root fs
          `mkfs.ext4 /dev/vg0/root`
          `mount /dev/vg0/root /mnt`
          # make and mount home folder
          if scheme == "/boot, /root and /home"
            `mkfs.ext4 /dev/vg0/home`
            `mount /dev/vg0/home /mnt/home`
          end
          # make and mount boot partition
          `mkfs.fat -F32 /dev/sda1`
          `mkdir /mnt/boot`
          if data[:system_settings][:bootloader] == "systemd-boot"
            `mount /dev/sda1 /mnt/boot`
          else
            `mount /dev/sda1 /mnt/boot/efi`
          end
          # setup swap
          `mkswap /dev/vg0/swap`
          `swapon /dev/vg0/swap`
        end

        if data[:system_settings][:partition] == "/boot, /root and /home"
          setup_lvm(data[:system_settings][:partition], data[:system_settings][:swap_size], data[:system_settings[:home_size]])
        else
          setup_lvm(data[:system_settings][:partition], data[:system_settings][:swap_size])
        end

        def setup_packages
          # update packages list
          `pacman -Syy`
          # install base system
          `pacstrap /mnt base base-devel linux linux-firmware lvm2 mkinitcpio dmidecode reflector networkmanager cronie man-db nano vi fuse wget openbsd-netcat dhcpcd samba openssh openvpn unzip vim git zsh`
          # generate fstab
          `genfstab -U /mnt >> /mnt/etc/fstab`
        end

        setup_packages

        def setup_chroot(lang, keymap, password)
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
          `sed -i "/^HOOK/s/filesystems/lvm2 filesystems/" /mnt/etc/mkinitcpio.conf`
          # recompile initramfs
          `arch-chroot /mnt mkinitcpio -p linux`
          # add intel microcode
          `arch-chroot /mnt pacman -S intel-ucode --noconfirm`
        end

        setup_chroot(data[:system_language], data[:keyboard_keymap], data[:root_password])

        def setup_bootloader(loader)
          # setup systemd-boot
          if loader == "systemd-boot"
            `arch-chroot /mnt bootctl install`
            `echo "title Warding Linux
            linux /vmlinuz-linux
            initrd /intel-ucode.img
            initrd /initramfs-linux.img
            options root=/dev/vg0/root rw" > /mnt/boot/loader/entries/warding.conf`
          else
            # setup grub
            `arch-chroot /mnt pacman -S grub efibootmgr --noconfirm`
            `arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB`
            `arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg`
          end
        end

        setup_bootloader(data[:system_settings][:bootloader])

        def setup_usability
          # enable internet
          `arch-chroot /mnt systemctl enable NetworkManager`
          # add cron jobs
          `echo "#!/bin/bash\nreflector --latest 25 --sort rate --save /etc/pacman.d/mirrorlist" > /mnt/etc/cron.hourly/mirrorlist; chmod +x /mnt/etc/cron.hourly/mirrorlist`
          `echo "#!/bin/bash\npacman -Sy" > /mnt/etc/cron.weekly/pacman-sync; chmod +x /mnt/etc/cron.weekly/pacman-sync`
          `echo "#!/bin/bash\npacman -Syu --noconfirm" > /mnt/etc/cron.monthly/system-upgrade; chmod +x /mnt/etc/cron.monthly/system-upgrade`
          # enable cron jobs
          `arch-chroot /mnt systemctl enable cronie`
          # change default shell
          `arch-chroot /mnt chsh -s $(which zsh)"`
          # setup blackarch's keyring
          `wget -q https://blackarch.org/keyring/blackarch-keyring.pkg.tar.xz{,.sig}`
          `gpg --keyserver hkp://pgp.mit.edu --recv-keys 4345771566D76038C7FEB43863EC0ADBEA87E4E3 > /dev/null 2>&1`
          `gpg --keyserver-options no-auto-key-retrieve --with-fingerprint blackarch-keyring.pkg.tar.xz.sig > /dev/null 2>&1`
          `rm blackarch-keyring.pkg.tar.xz.sig`
          `pacman-key --init`
          `pacman --config /dev/null --noconfirm -U blackarch-keyring.pkg.tar.xz`
          `pacman-key --populate`
          # update package list
          `pacman -Syy`
          # check if on VM
          if `dmidecode -s system-manufacturer`.include?("VMware, Inc.")
            # install and enable VMware utils
            `arch-chroot /mnt pacman -S openvpn-vm-tools --noconfirm`
            `arch-chroot /mnt systemctl enable vmtoolsd`
          end
        end

        setup_usability

        def setup_visuals(theme = "none")
          if theme == "none"
            break
          elsif theme == "kde"
            # install packages
            `arch-chroot /mnt pacman -S xorg-server xf86-video-intel plasma konsole dolphin kmix sddm kvantum-qt5`
            # create conf dir
            `mkdir -p /mnt/etc/sddm.conf.d`
            # fix theme
            `echo "[Theme]\nCurrent=breeze" > /mnt/etc/sddm.conf.d/theme.conf`
            # enable autologin
            `echo "[Autologin]\nUser=root" > /mnt/etc/sddm.conf.d/login.conf`
            # enable sddm
            `arch-chroot /mnt systemctl enable sddm`
          else
            # install packages
            `arch-chroot /mnt pacman -S xf86-video-intel gnome`
            # enable gdm
            `arch-chroot /mnt systemctl enable gdm`
          end
        end

        setup_visuals(data[:desktop_environment])

        def finish
          # end
          `umount -R /mnt`
          `reboot`
        end

        finish
      end
    end
  end
end
