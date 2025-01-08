# /!\ run in bash, not zsh

export LUKS_PASSPHRASE=awefwefwaefwef
export ROOT_PASSWORD=awfweaf
export SSH_KEY="ssh-rsa AAAA"
# be careful with nvme "pX" partitions naming; remove "p" below if non-nvme
export ROOT_DEVICES=(/dev/nvme0n1 /dev/nvme1n1)
export HOSTNAME="mf1"
export INTERFACE_MAC="ac:ab:ac:ab:ac:ab"
export DEB_RELEASE=bookworm

timedatectl set-ntp true

for dev in ${ROOT_DEVICES[@]}; do
  parted -s -a optimal ${dev} \
    mklabel gpt \
    mkpart "efi" fat32 1MiB 512MiB \
    set 1 esp on \
    mkpart "luks" 512MiB 95% \
    set 2 raid on
  mkfs.fat -F32 ${dev}p1
done

modprobe raid1 && modprobe dm-mod
yes | mdadm --create /dev/md0 --level=1 --raid-devices=2 ${ROOT_DEVICES[@]/%/p2}

modprobe dm-crypt
cryptsetup -q luksFormat /dev/md0 <<< "${LUKS_PASSPHRASE}"
cryptsetup -q open --type luks /dev/md0 cryptdisk <<< "${LUKS_PASSPHRASE}"
mkfs.ext4 /dev/mapper/cryptdisk

mount /dev/mapper/cryptdisk /mnt
mkdir -p /mnt/boot/efi
mkdir -p /mnt/boot/efi_bkp
mount ${ROOT_DEVICES[0]}p1 /mnt/boot/efi
mount ${ROOT_DEVICES[1]}p1 /mnt/boot/efi_bkp

pacman -Sy debootstrap

# pacstrap /mnt base linux-lts linux-firmware vim mkinitcpio-netconf mkinitcpio-utils mkinitcpio-dropbear openssh
debootstrap --variant=minbase "${DEB_RELEASE}" /mnt/

genfstab -U -p /mnt > /mnt/etc/fstab

arch-chroot /mnt
export PATH=$PATH:/usr/sbin

echo "${HOSTNAME}" > /etc/hostname
echo "127.0.0.1    localhost ${HOSTNAME}" > /etc/hosts

cat > /etc/apt/sources.list << EOT
deb https://deb.debian.org/debian/ ${DEB_RELEASE} main contrib non-free-firmware
deb-src https://deb.debian.org/debian/ ${DEB_RELEASE} main contrib non-free-firmware

deb https://security.debian.org/debian-security ${DEB_RELEASE}-security main contrib non-free-firmware
deb-src https://security.debian.org/debian-security ${DEB_RELEASE}-security main contrib non-free-firmware

deb https://deb.debian.org/debian/ ${DEB_RELEASE}-updates main contrib non-free-firmware
deb-src https://deb.debian.org/debian/ ${DEB_RELEASE}-updates main contrib non-free-firmware

deb https://deb.debian.org/debian/ ${DEB_RELEASE}-backports main contrib
deb-src https://deb.debian.org/debian/ ${DEB_RELEASE}-backports main contrib
EOT

apt update
apt install -y tmux htop less vim zsh git wget curl sudo systemd rsyslog logrotate ca-certificates \
  iputils-ping netbase net-tools netplan.io iproute2 ethtool lsb-release apt-utils gnupg2 rsync mdadm \
  apt-transport-https nftables locales ssh dropbear-initramfs linux-image-amd64

ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen

ssh-keygen -A -m PEM
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config
echo "${SSH_KEY}" > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys

cp /root/.ssh/authorized_keys /etc/dropbear/initramfs/authorized_keys
echo 'DROPBEAR_OPTIONS="-I 60 -j -k -p 22 -s -c cryptroot-unlock"' >> /etc/dropbear/initramfs/dropbear.conf

CRYPTDISK_UUID=$(blkid /dev/md0 -s UUID -o value)

echo "cryptdisk UUID=${CRYPTDISK_UUID} none luks" >> /etc/crypttab

echo "net.ifnames=0 biosdevname=0 ip=:::::eth0:dhcp cryptdevice=UUID=${CRYPTDISK_UUID}:cryptdisk root=/dev/mapper/cryptdisk quiet rw" > /etc/kernel/cmdline
apt install -y systemd-boot
bootctl install
echo "timeout 3" >> /boot/efi/loader/loader.conf

bootctl install --efi-boot-option-description="Linux Boot Manager (bak)" --esp-path=/boot/efi_bkp

cat > /etc/kernel/install.d/zzz-copy-efi-to-efi-bkp.install << EOT
#!/bin/sh

set -e

if ! mountpoint --quiet --nofollow /boot/efi; then
    echo "/boot/efi is not mounted, skipping the copy to /boot/efi_bkp"
else
    echo "Mounting /boot/efi_bkp"
    mount /boot/efi_bkp || :
    echo "Copying files from /efi to /boot/efi_bkp"
    rsync --times --recursive --delete /boot/efi/ /boot/efi_bkp/
fi
exit 0
EOT

chmod +x /etc/kernel/install.d/zzz-copy-efi-to-efi-bkp.install

update-initramfs -u -k all

cat <<EOT >/etc/netplan/default.yaml
network:
  version: 2
  ethernets:
    net0:
      set-name: net0
      match:
        macaddress: "${INTERFACE_MAC}"
      dhcp4: yes
EOT
chmod 600 /etc/netplan/default.yaml

chpasswd <<< "root:${ROOT_PASSWORD}"

exit

umount -R /mnt
sync
reboot