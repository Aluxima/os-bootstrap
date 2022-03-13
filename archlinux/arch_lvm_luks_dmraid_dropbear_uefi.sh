# NAME            MAJ:MIN RM   SIZE RO TYPE  MOUNTPOINTS
# sda               8:0    0   3.6T  0 disk
# ├─sda1            8:1    0   511M  0 part
# │ └─md0           9:0    0 510.9M  0 raid1
# │   └─md0p1     259:0    0   509M  0 part  /boot
# └─sda2            8:2    0   3.6T  0 part
#   └─md1           9:1    0   3.6T  0 raid1
#     └─vg        253:0    0   3.6T  0 crypt
#       ├─vg-swap 253:1    0    16G  0 lvm   [SWAP]
#       ├─vg-root 253:2    0   100G  0 lvm   /
#       └─vg-data 253:3    0   3.5T  0 lvm   /data
# sdb               8:16   0   3.6T  0 disk
# ├─sdb1            8:17   0   511M  0 part
# │ └─md0           9:0    0 510.9M  0 raid1
# │   └─md0p1     259:0    0   509M  0 part  /boot
# └─sdb2            8:18   0   3.6T  0 part
#   └─md1           9:1    0   3.6T  0 raid1
#     └─vg        253:0    0   3.6T  0 crypt
#       ├─vg-swap 253:1    0    16G  0 lvm   [SWAP]
#       ├─vg-root 253:2    0   100G  0 lvm   /
#       └─vg-data 253:3    0   3.5T  0 lvm   /data

export LUKS_PASSPHRASE=p@ssphr@se
export ROOT_PASSWORD=password
export SSH_KEY="ssh-rsa ..."
export ROOT_DEVICES=(/dev/sda /dev/sdb)

for dev in ${ROOT_DEVICES[@]}; do
	parted -s -a optimal ${dev} \
		mklabel gpt \
		mkpart "efi" 1MiB 512MiB \
		set 1 raid on \
		mkpart "luks" 512MiB 98% \
		set 2 raid on
done

modprobe raid1 && modprobe dm-mod
yes | mdadm --create /dev/md0 --level=1 --raid-devices=2 --metadata=1.0 ${ROOT_DEVICES[@]/%/1}
yes | mdadm --create /dev/md1 --level=1 --raid-devices=2 ${ROOT_DEVICES[@]/%/2}

parted -s -a optimal /dev/md0 \
	mklabel gpt \
	mkpart "efi" 0% 100% \
	set 1 esp on

modprobe dm-crypt
cryptsetup -q luksFormat /dev/md1 <<< "${LUKS_PASSPHRASE}"
cryptsetup -q open --type luks /dev/md1 cryptdisk <<< "${LUKS_PASSPHRASE}"

pvcreate -y /dev/mapper/cryptdisk
vgcreate -y vg /dev/mapper/cryptdisk
lvcreate -y -L16G vg -n swap
lvcreate -y -L100G vg -n root
lvcreate -y -l 100%FREE vg -n data

mkfs.fat -F32 /dev/md0p1
mkswap /dev/mapper/vg-swap
mkfs.ext4 /dev/mapper/vg-root
mkfs.ext4 /dev/mapper/vg-data

mount /dev/mapper/vg-root /mnt
mkdir /mnt/boot /mnt/data
mount /dev/md0p1 /mnt/boot
mount /dev/mapper/vg-data /mnt/data
swapon /dev/mapper/vg-swap

pacstrap /mnt base linux-lts linux-firmware lvm2 mdadm vim mkinitcpio-netconf mkinitcpio-utils mkinitcpio-dropbear openssh sudo python3
genfstab -U -p /mnt > /mnt/etc/fstab
mdadm --examine --scan > /mnt/etc/mdadm.conf

arch-chroot /mnt

chpasswd <<< "root:${ROOT_PASSWORD}"
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

sed -i 's/^MODULES=.*/MODULES=(raid1 dm-mod ext4)/g' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect keyboard modconf block mdadm_udev netconf dropbear encryptssh lvm2 filesystems fsck)/g' /etc/mkinitcpio.conf
mkinitcpio -P

bootctl --path=/boot/ install

CRYPTDISK_UUID=$(blkid /dev/md1 -s UUID -o value)
cat <<EOF >/boot/loader/entries/arch.conf
title Arch Linux
linux /vmlinuz-linux-lts
initrd /initramfs-linux-lts.img
options ip=:::::eth0:dhcp cryptdevice=UUID=${CRYPTDISK_UUID}:vg root=/dev/mapper/vg-root quiet rw
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

cat <<EOF >/etc/resolv.conf
# Resolver configuration file.
# See resolv.conf(5) for details.

nameserver 1.1.1.1
nameserver 9.9.9.9
nameserver 8.8.8.8
EOF

exit
umount -R /mnt
sync
reboot