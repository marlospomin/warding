# frozen_string_literal: true

require 'warding/version'
require 'tty-prompt'

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
      unless `uname -a`.include?('archiso')
        @@prompt.error('Exiting, this is not an Arch Linux distribution!')
        exit!
      end

      unless `[ -d /sys/firmware/efi ] && echo true`.include?('true')
        @@prompt.error('UEFI/EFI must be enabled to install warding')
        exit!
      end
    end

    def gather
      locales_list = %w[en-US es-ES pt-BR ru-RU fr-FR it-IT de-DE ja-JP ko-KR zh-CN]
      keymaps_list = %w[us uk br en fr de zh ru it es]

      parsed_input = @@prompt.collect do
        key(:update_mirrors).yes?('Update mirrorlist?')
        key(:system_language).select('Pick the desired system language:', locales_list)
        key(:keyboard_keymap).select('Pick your keyboard layout:', keymaps_list)

        unless @@prompt.yes?('Set timezone automatically?', default: true)
          key(:update_timezone).ask('Enter timezone:', required: true)
        end

        key(:root_password).mask('Insert new root password:', required: true)

        key(:system_settings) do
          bootloader = key(:bootloader).select('Which bootloader to use?', %w[systemd-boot grub])
          partitions = key(:partitions).select(
            'Select partition scheme to use:', ['/boot and /root', '/boot, /root and /home']
          )

          key(:boot_size).slider('Boot drive partition size (MiB):', min: 512, max: 4096, default: 1024, step: 128)

          if partitions == '/boot, /root and /home'
            key(:home_size).slider('Home partition size (MiB):', min: 2048, max: 8192, default: 4096, step: 256)
          end

          key(:swap_size).slider('Swap partition size (MiB):', min: 1024, max: 8192, default: 2048, step: 256)

          if @@prompt.yes?('Enable encryption?', default: false)
            key(:encryption_settings) do
              key(:encryption_mode).expand('Which cryptic setup to use?') do |q|
                if partitions == '/boot, /root and /home'
                  q.choice key: 'm', name: 'minimal (/home only)' do :minimal end
                  q.choice key: 's', name: 'safe (/home, /var, /tmp and swap)', value: :safe
                end
                q.choice key: 'p', name: 'paranoid (full disk encryption, except /boot)', value: :paranoid
                q.choice key: 'i', name: 'insane (full disk encryption)', value: :insane if bootloader == 'grub'
              end
              key(:encryption_key).mask('Insert the encryption key:', required: true)
            end
          end
        end

        key(:extra_settings).multi_select('Select extra options:', %w[tools themes cron])
      end

      parsed_input
    end

    def install(data)
      if @@prompt.yes?('Confirm settings and continue?')

        # setup mirrorlist

        if data[:update_mirrors]
          `reflector --latest 25 --sort rate --save /etc/pacman.d/mirrorlist`
        end

        # setup timezone

        `timedatectl set-ntp true`

        if data[:update_timezone]
          `timedatectl set-timezone #{data[:update_timezone]}`
        else
          `timedatectl set-timezone "$(curl --fail https://ipapi.co/timezone)"`
        end

        # setup paritions

        `parted -s -a optimal /dev/sda \
          mklabel gpt \
          mkpart primary fat32 0% #{data[:system_settings][:boot_size]}Mib \
          set 1 esp on \
          mkpart primary ext4 #{data[:system_settings][:boot_size]}Mib 100% \
          set 2 lvm on
        `

        `pvcreate /dev/sda2`
        `vgcreate vg0 /dev/sda2`
        `lvcreate -L #{data[:system_settings][:swap_size]}Mib vg0 -n swap`
        `lvcreate -L #{data[:system_settings[:home_size]]}Mib vg0 -n home` if data[:system_settings][:partition] == '/boot, /root and /home'
        `lvcreate -l 100%FREE vg0 -n root`

        `mkfs.ext4 /dev/vg0/root`
        `mount /dev/vg0/root /mnt`

        if data[:system_settings][:partition] == '/boot, /root and /home'
          `mkfs.ext4 /dev/vg0/home`
          `mount /dev/vg0/home /mnt/home`
        end

        `mkfs.fat -F32 /dev/sda1`
        `mkdir /mnt/boot`

        `mkswap /dev/vg0/swap`
        `swapon /dev/vg0/swap`

        # setup encryption

        # TODO: everything

        # setup base packages

        `pacman -Sy`
        `pacstrap /mnt base base-devel`
        `genfstab -U /mnt >> /mnt/etc/fstab`

        # setup chroot

        `arch-chroot /mnt ln -sf /usr/share/zoneinfo/"$(curl --fail https://ipapi.co/timezone)" /etc/localtime`
        `arch-chroot /mnt hwclock --systohc`

        `echo "#{data[:system_language]}.UTF-8" > /mnt/etc/locale.gen`
        `arch-chroot /mnt locale-gen`
        `echo "LANG=#{data[:system_language]}.UTF-8" > /mnt/etc/locale.conf`

        `echo KEYMAP=#{data[:keyboard_keymap]} > /mnt/etc/vconsole.conf`

        `echo "warding" > /mnt/etc/hostname`

        `echo "127.0.0.1 localhost
        ::1 localhost
        127.0.1.1 warding.localdomain warding" > /mnt/etc/hosts`

        `arch-chroot /mnt echo -e "#{data[:root_password]}\n#{data[:root_password]}" | passwd`

        `arch-chroot /mnt pacman -Sy archlinux-keyring linux lvm2 mkinitcpio --noconfirm`

        `sed -i "/^HOOK/s/filesystems/lvm2 filesystems/" /mnt/etc/mkinitcpio.conf`

        `arch-chroot /mnt mkinitcpio -p linux`

        `arch-chroot /mnt pacman -S intel-ucode --noconfirm`

        # bootloader

        if data[:system_settings][:bootloader] == 'systemd-boot'
          `arch-chroot /mnt bootctl install`
          `echo "title Warding Linux
          linux /vmlinuz-linux
          initrd /intel-ucode.img
          initrd /initramfs-linux.img
          options root=/dev/vg0/root rw" > /mnt/boot/loader/entries/warding.conf`
        else
          # TODO: grub
        end

        # setup default packages

        # TODO: include gnome desktop
        `arch-chroot /mnt pacman -S make nano fuse wget automake cmake gcc autoconf openbsd-netcat dhcpcd samba openssh openvpn unzip vim xorg-server xf86-video-intel plasma konsole dolphin kmix sddm wget git kvantum-qt5 zsh --noconfirm`

        `arch-chroot /mnt systemctl enable dhcpcd`
        `arch-chroot /mnt systemctl enable sddm`

        `arch-chroot /mnt wget -qO- https://blackarch.org/strap.sh | sh`

        `arch-chroot /mnt wget -qO- https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh | sh`

        # setup themes

        if data[:extra_settings].include?('themes')
          `arch-chroot /mnt wget -qO- https://raw.githubusercontent.com/PapirusDevelopmentTeam/arc-kde/master/install.sh | sh`
          `arch-chroot /mnt wget -qO- https://git.io/papirus-icon-theme-install | sh`
        end

        # setup extra tools

        if data[:extra_settings].include?('tools')
          `arch-chroot /mnt pacman -S nmap impacket go ruby php firefox atom hashcat john jre-openjdk proxychains-ng exploitdb httpie metasploit bind-tools radare2 sqlmap wpscan xclip --noconfirm`
          `arch-chroot /mnt mkdir -p /usr/share/wordlists`
          `arch-chroot /mnt wget -q https://github.com/danielmiessler/SecLists/raw/master/Passwords/Leaked-Databases/rockyou.txt.tar.gz -O /usr/share/wordlists/rockyou.txt.tar.gz`
          `arch-chroot /mnt wget -q https://github.com/danielmiessler/SecLists/raw/master/Discovery/Web-Content/common.txt -O /usr/share/wordlists/common.txt`
        end

        # setup crons

        # TODO: include crons
      end
    end
  end
end
