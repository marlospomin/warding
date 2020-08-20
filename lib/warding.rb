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
      locales_list = %w[en-US es-ES pt-BR ru-RU fr-FR it-IT de-DE ja-JP ko-KR zh-CN]
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

        key(:extra_settings).multi_select("Select extra options:", %w[desktop-environment hacking-tools crons])
      end

      parsed_input
    end

    def install(data)
      if @@prompt.yes?("Confirm settings and continue?")

        @@prompt.say("Installing, please wait...")

        def setup_mirrors
          `reflector --latest 25 --sort rate --save /etc/pacman.d/mirrorlist`
        end

        setup_mirrors if data[:update_mirrors]

        def setup_timezone(timezone = false)
          `timedatectl set-ntp true`
          if timezone
            `timedatectl set-timezone #{timezone}`
          else
            `timedatectl set-timezone "$(curl -s https://ipapi.co/timezone)"`
          end
        end

        data[:update_timezone] ? setup_timezone(data[:update_timezone]) : setup_timezone

        def setup_partitions(boot_size)
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
          `pvcreate /dev/sda2`
          `vgcreate vg0 /dev/sda2`
          `lvcreate -L #{swap_size}Mib vg0 -n swap`
          if scheme == "/boot, /root and /home"
            `lvcreate -L #{home_size}Mib vg0 -n home`
          end
          `lvcreate -l 100%FREE vg0 -n root`

          `mkfs.ext4 /dev/vg0/root`
          `mount /dev/vg0/root /mnt`

          if scheme == "/boot, /root and /home"
            `mkfs.ext4 /dev/vg0/home`
            `mount /dev/vg0/home /mnt/home`
          end

          `mkfs.fat -F32 /dev/sda1`
          `mkdir /mnt/boot`
          `mount /dev/sda1 /mnt/boot`

          `mkswap /dev/vg0/swap`
          `swapon /dev/vg0/swap`
        end

        if data[:system_settings][:partition] == "/boot, /root and /home"
          setup_lvm(data[:system_settings][:partition], data[:system_settings][:swap_size], data[:system_settings[:home_size]])
        else
          setup_lvm(data[:system_settings][:partition], data[:system_settings][:swap_size])
        end

        # setup encryption

        def setup_packages
          `pacman -Syy`
          `pacstrap /mnt base base-devel linux linux-firmware lvm2 mkinitcpio reflector man-db nano vi fuse wget openbsd-netcat dhcpcd samba openssh openvpn unzip vim git zsh`
          `genfstab -U /mnt >> /mnt/etc/fstab`
        end

        setup_packages

        def setup_chroot(lang, keymap, password)
          `arch-chroot /mnt ln -sf /usr/share/zoneinfo/"$(curl -s https://ipapi.co/timezone)" /etc/localtime`
          `arch-chroot /mnt hwclock --systohc`

          `echo "#{lang}.UTF-8" > /mnt/etc/locale.gen`
          `arch-chroot /mnt locale-gen`
          `echo "LANG=#{lang}.UTF-8" > /mnt/etc/locale.conf`
          `echo "KEYMAP=#{keymap}" > /mnt/etc/vconsole.conf`
          `echo "warding" > /mnt/etc/hostname`
          `echo "127.0.0.1 localhost\n::1 localhost\n127.0.1.1 warding.localdomain warding" > /mnt/etc/hosts`

          `echo -e "#{password}\n#{password}" | arch-chroot /mnt passwd`

          `sed -i "/^HOOK/s/filesystems/lvm2 filesystems/" /mnt/etc/mkinitcpio.conf`
          `arch-chroot /mnt mkinitcpio -p linux 2>/dev/null`
          `arch-chroot /mnt pacman -S intel-ucode --noconfirm`
        end

        setup_chroot(data[:system_language], data[:keyboard_keymap], data[:root_password])

        def setup_bootloader(loader)
          if loader == "systemd-boot"
            `arch-chroot /mnt bootctl install 2>/dev/null`
            `echo "title Warding Linux
            linux /vmlinuz-linux
            initrd /intel-ucode.img
            initrd /initramfs-linux.img
            options root=/dev/vg0/root rw" > /mnt/boot/loader/entries/warding.conf`
          else
            # TODO: grub
          end
        end

        setup_bootloader(data[:system_settings][:bootloader])

        def setup_usability
          `arch-chroot /mnt systemctl enable dhcpcd`
          `arch-chroot /mnt wget -qO- https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh | sh`

          # `arch-chroot /mnt wget -qO- https://blackarch.org/strap.sh | sh`
          `wget -q https://www.blackarch.org/keyring/blackarch-keyring.pkg.tar.xz{,.sig}`
          `gpg --keyserver hkp://pgp.mit.edu --recv-keys 4345771566D76038C7FEB43863EC0ADBEA87E4E3 > /dev/null 2>&1`
          `gpg --keyserver-options no-auto-key-retrieve --with-fingerprint blackarch-keyring.pkg.tar.xz.sig > /dev/null 2>&1`
          `rm blackarch-keyring.pkg.tar.xz.sig`
          `pacman-key --init`
          `pacman --config /dev/null --noconfirm -U blackarch-keyring.pkg.tar.xz`
          `pacman-key --populate`
          `pacman -Syy`
        end

        setup_usability

        def setup_visuals
          `arch-chroot /mnt pacman -S xorg-server xf86-video-intel plasma konsole dolphin kmix sddm kvantum-qt5`
          `mkdir -p /mnt/etc/sddm.conf.d`
          `echo "[Theme]\nCurrent=breeze" > /mnt/etc/sddm.conf.d/theme.conf`
          `echo "[Autologin]\nUser=root" > /mnt/etc/sddm.conf.d/login.conf`
          `arch-chroot /mnt systemctl enable sddm`
          `arch-chroot /mnt wget -qO- https://raw.githubusercontent.com/PapirusDevelopmentTeam/arc-kde/master/install.sh | sh`
          `arch-chroot /mnt wget -qO- https://git.io/papirus-icon-theme-install | sh`
        end

        setup_visuals if data[:extra_settings].include?("desktop-emvironment")

        def setup_tools
          `arch-chroot /mnt pacman -S nmap impacket go ruby php firefox atom hashcat john jre-openjdk proxychains-ng exploitdb httpie metasploit bind-tools radare2 sqlmap wpscan xclip --noconfirm`
          `arch-chroot /mnt mkdir -p /usr/share/wordlists`
          `arch-chroot /mnt wget -q https://github.com/danielmiessler/SecLists/raw/master/Passwords/Leaked-Databases/rockyou.txt.tar.gz -O /usr/share/wordlists/rockyou.txt.tar.gz`
          `arch-chroot /mnt wget -q https://github.com/danielmiessler/SecLists/raw/master/Discovery/Web-Content/common.txt -O /usr/share/wordlists/common.txt`
        end

        setup_tools if data[:extra_settings].include?("hacking-tools")

        def setup_cron
          `arch-chroot /mnt pacman -S cronie --noconfirm`
          `arch-chroot /mnt systemctl enable cronie`
          `echo "#!/bin/bash\nreflector --latest 25 --sort rate --save /etc/pacman.d/mirrorlist" > /mnt/etc/cron.hourly/mirrorlist; chmod +x /mnt/etc/cron.hourly/mirrorlist`
          `echo "#!/bin/bash\npacman -Sy" > /mnt/etc/cron.weekly/pacman-sync; chmod +x /mnt/etc/cron.weekly/pacman-sync`
          `echo "#!/bin/bash\npacman -Syu --noconfirm" > /mnt/etc/cron.monthly/system-upgrade; chmod +x /mnt/etc/cron.monthly/system-upgrade`
        end

        setup_cron if data[:extra_settings].include?("crons")

        def finish
          `umount -R /mnt`
          `reboot`
        end

        finish
      end
    end
  end
end
