export LUKS_PASSPHRASE=the
export ROOT_PASSWORD=game
export SSH_KEY="ssh-rsa ..."
# be careful with nvme "pX" partitions naming; remove "p" below if non-nvme
export ROOT_DEVICE="/dev/nvme0n1"
export HOSTNAME="bloup1"
export INTERFACE_MAC="00:11:22:33:aa:bb"
export DEB_RELEASE=bookworm

timedatectl set-ntp true

parted -s -a optimal ${ROOT_DEVICE} \
	mklabel gpt \
	mkpart "EFI" fat32 1MiB 501MiB \
	set 1 esp on \
	mkpart "luks" 501MiB 100%
mkfs.fat -F32 ${ROOT_DEVICE}p1

modprobe dm-crypt
cryptsetup -q luksFormat ${ROOT_DEVICE}p2 <<< "${LUKS_PASSPHRASE}"
cryptsetup -q open --type luks ${ROOT_DEVICE}p2 cryptdisk <<< "${LUKS_PASSPHRASE}"
mkfs.ext4 /dev/mapper/cryptdisk

mount /dev/mapper/cryptdisk /mnt
mkdir /mnt/boot
mount ${ROOT_DEVICE}p1 /mnt/boot

pacman -Sy debootstrap

# pacstrap /mnt base linux-lts linux-firmware vim mkinitcpio-netconf mkinitcpio-utils mkinitcpio-dropbear openssh
debootstrap --variant=minbase "${DEB_RELEASE}" /mnt/

genfstab -U -p /mnt > /mnt/etc/fstab

arch-chroot /mnt

export PATH=$PATH:/usr/sbin
echo "${HOSTNAME}" > /etc/hostname
echo "127.0.0.1    localhost ${HOSTNAME}" > /etc/hosts

cat > /etc/apt/sources.list << EOT
deb https://deb.debian.org/debian/ ${DEB_RELEASE} main contrib non-free
deb-src https://deb.debian.org/debian/ ${DEB_RELEASE} main contrib non-free

deb https://security.debian.org/debian-security ${DEB_RELEASE}-security main contrib non-free
deb-src https://security.debian.org/debian-security ${DEB_RELEASE}-security main contrib non-free

deb https://deb.debian.org/debian/ ${DEB_RELEASE}-updates main contrib non-free
deb-src https://deb.debian.org/debian/ ${DEB_RELEASE}-updates main contrib non-free
EOT

apt update
apt install tmux htop less vim zsh git wget curl sudo systemd rsyslog logrotate ca-certificates \
  iputils-ping netbase net-tools netplan.io iproute2 ethtool lsb-release apt-utils gnupg2 \
  apt-transport-https nftables locales ssh dropbear-initramfs linux-image-amd64

ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen

ssh-keygen -A -m PEM
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config
echo "${SSH_KEY}" > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys

cp /root/.ssh/authorized_keys /etc/dropbear/initramfs/authorized_keys
echo 'DROPBEAR_OPTIONS="-I 60 -j -k -p 22 -s -c cryptroot-unlock"' >> /etc/dropbear/initramfs/dropbear.conf
update-initramfs -u

CRYPTDISK_UUID=$(blkid ${ROOT_DEVICE}p2 -s UUID -o value)
echo "ip=:::::eno1:dhcp cryptdevice=UUID=${CRYPTDISK_UUID}:cryptdisk root=/dev/mapper/cryptdisk quiet rw" > /etc/kernel/cmdline
apt install systemd-boot
echo "timeout 3" >> /boot/loader/loader.conf

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