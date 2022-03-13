# NAME          MAJ:MIN RM   SIZE RO TYPE  MOUNTPOINTS
# sda             8:0    0 223.6G  0 disk
# ├─sda1          8:1    0   500M  0 part  /boot
# └─sda2          8:2    0 223.1G  0 part
#   └─cryptdisk 254:0    0 223.1G  0 crypt /

export LUKS_PASSPHRASE=p@ssphr@se
export ROOT_PASSWORD=password
export SSH_KEY="ssh-rsa ..."
export ROOT_DEVICE="/dev/sda"

timedatectl set-ntp true

parted -s -a optimal ${ROOT_DEVICE} \
	mklabel gpt \
	mkpart "EFI" fat32 1MiB 501MiB \
	set 1 esp on \
	mkpart "luks" 501MiB 100%
mkfs.fat -F32 ${ROOT_DEVICE}1

modprobe dm-crypt
cryptsetup -q luksFormat ${ROOT_DEVICE}2 <<< "${LUKS_PASSPHRASE}"
cryptsetup -q open --type luks ${ROOT_DEVICE}2 cryptdisk <<< "${LUKS_PASSPHRASE}"
mkfs.ext4 /dev/mapper/cryptdisk

mount /dev/mapper/cryptdisk /mnt
mkdir /mnt/boot
mount ${ROOT_DEVICE}1 /mnt/boot

pacstrap /mnt base linux-lts linux-firmware vim mkinitcpio-netconf mkinitcpio-utils mkinitcpio-dropbear openssh
genfstab -U -p /mnt > /mnt/etc/fstab
chpasswd -R /mnt <<< "root:${ROOT_PASSWORD}"

arch-chroot /mnt
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc
sed -i '/#en_US\.UTF-8 UTF-8/s/^#//g' /etc/locale.gen
locale-gen
locale > /etc/locale.conf

ssh-keygen -A -m PEM
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config
ln -sf /usr/lib/systemd/system/sshd.service /etc/systemd/system/multi-user.target.wants/sshd.service

mkdir /root/.ssh && chmod 700 /root/.ssh
echo "${SSH_KEY}" > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
cp /root/.ssh/authorized_keys /etc/dropbear/root_key

sed -i 's/^MODULES=.*/MODULES=(dm-mod ext4)/g' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect keyboard modconf block netconf dropbear encryptssh filesystems fsck)/g' /etc/mkinitcpio.conf
mkinitcpio -P

bootctl --path=/boot/ install

CRYPTDISK_UUID=$(blkid ${ROOT_DEVICE}2 -s UUID -o value)
cat <<EOF >/boot/loader/entries/arch.conf
title Arch Linux
linux /vmlinuz-linux-lts
initrd /initramfs-linux-lts.img
options ip=:::::eth0:dhcp cryptdevice=UUID=${CRYPTDISK_UUID}:cryptdisk root=/dev/mapper/cryptdisk quiet rw
EOF

cat <<EOF >/boot/loader/loader.conf
default arch
timeout 3
editor 0
EOF

ln -sf /usr/lib/systemd/system/systemd-networkd.service /etc/systemd/system/dbus-org.freedesktop.network1.service
ln -sf /usr/lib/systemd/system/systemd-networkd.service /etc/systemd/system/multi-user.target.wants/systemd-networkd.service

cat <<EOF >/etc/systemd/network/20-wired.network
[Match]
Name=eno1

[Network]
DHCP=yes
EOF

exit
umount -R /mnt
sync
reboot