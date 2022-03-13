# Arch LVM/LUKS/dmraid + dropbear on BIOS/GPT

This short guide shows how to install Arch linux on raid1, encrypted storage with remote unlocking using dmraid, LUKS, LVM and Dropbear with grub bios bootloader on GPT.

The resulting partitions should look something like the following:

```
NAME            MAJ:MIN RM   SIZE RO TYPE  MOUNTPOINT
sda               8:0    0   2.7T  0 disk  
├─sda1            8:1    0     1M  0 part  
├─sda2            8:2    0   512M  0 part  
│ └─md0           9:0    0 511.9M  0 raid1 /boot
└─sda3            8:3    0   2.7T  0 part  
  └─md1           9:1    0   2.7T  0 raid1 
    └─vg        253:0    0   2.7T  0 crypt 
      ├─vg-swap 253:1    0    32G  0 lvm   [SWAP]
      ├─vg-root 253:2    0   100G  0 lvm   /
      └─vg-data 253:3    0   2.6T  0 lvm   /data
sdb               8:16   0   2.7T  0 disk  
├─sdb1            8:17   0     1M  0 part  
├─sdb2            8:18   0   512M  0 part  
│ └─md0           9:0    0 511.9M  0 raid1 /boot
└─sdb3            8:19   0   2.7T  0 part  
  └─md1           9:1    0   2.7T  0 raid1 
    └─vg        253:0    0   2.7T  0 crypt 
      ├─vg-swap 253:1    0    32G  0 lvm   [SWAP]
      ├─vg-root 253:2    0   100G  0 lvm   /
      └─vg-data 253:3    0   2.6T  0 lvm   /data 
```

### partitions

In order to install a BIOS bootloader on GPT, the trick is to create a special 1MiB partition - see [details](https://wiki.archlinux.org/index.php/GRUB#GUID_Partition_Table_(GPT)_specific_instructions).

```
cgdisk /dev/sda
# blank: 1M type ef02
# boot: 512M type fd00
# main: type fd00

# Replicate partition table on the other disk
sgdisk -R=/dev/sdb /dev/sda

# Generate new GUID for the second disk
sgdisk -G /dev/sdb
```

### raid1

```
modprobe raid1 && modprobe dm-mod

# Create /boot raid1 with metadata at the end
mdadm --create /dev/md0 --level=1 --raid-devices=2 --metadata=0.90 /dev/sd{a,b}2

# Create cryptdisk raid1
mdadm --create /dev/md1 --level=1 --raid-devices=2 /dev/sd{a,b}3

# Wait for resync to complete
watch -n1 cat /proc/mdstat
```

### luks

```
modprobe dm-crypt
cryptsetup --verify-passphrase luksFormat /dev/md1
cryptsetup open --type=luks /dev/md1 cryptdisk
```

### lvm

```
pvcreate /dev/mapper/cryptdisk
vgcreate vg /dev/mapper/cryptdisk
lvcreate -L32G vg -n swap
lvcreate -L100G vg -n root
lvcreate -l 100%FREE vg -n data
```

### mkfs

```
mkfs.ext4 /dev/md0
mkswap /dev/mapper/vg-swap
mkfs.ext4 /dev/mapper/vg-root
mkfs.ext4 /dev/mapper/vg-data
```

### mount

```
mount /dev/mapper/vg-root /mnt
mkdir /mnt/boot /mnt/data
mount /dev/mapper/vg-data /mnt/data
mount /dev/md0 /mnt/boot
swapon /dev/mapper/vg-swap
```

### install

```
pacstrap /mnt base linux linux-firmware lvm2 mdadm vim grub-bios mkinitcpio-netconf mkinitcpio-utils mkinitcpio-dropbear openssh
genfstab -p /mnt >> /mnt/etc/fstab
mdadm --examine --scan > /mnt/etc/mdadm.conf
```

### configure

```
arch-chroot /mnt
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc
sed -i '/#en_US\.UTF-8 UTF-8/s/^#//g' /etc/locale.gen
locale-gen
locale > /etc/locale.conf
passwd
```

### ssh

```
# Generate some ssh host keys for dropbear to copy from
ssh-keygen -A -m PEM

# Enable root ssh authentication
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config

# Enable sshd service
ln -sf /usr/lib/systemd/system/sshd.service /etc/systemd/system/multi-user.target.wants/sshd.service

# Trust your public ssh key
mkdir /root/.ssh && chmod 700 /root/.ssh
echo "ssh-rsa ..." > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
```

### dropbear

Dropbear is a tiny ssh server that will run in initramfs to remotely unlock your encrypted volume - see [details](https://wiki.archlinux.org/index.php/Dm-crypt/Specialties#Remote_unlocking_(hooks:_netconf,_dropbear,_tinyssh,_ppp)).

```
# Trust your public ssh key in initramfs dropbear
cp /root/.ssh/authorized_keys /etc/dropbear/root_key
```

### mkinitcpio

Add modules and hooks needed to use network, setup raid, run dropbear, open your encrypted volume and setup LVM.

In `/etc/mkinitcpio.conf`:
```
MODULES=(raid1 dm-mod ext4)
HOOKS=(base udev autodetect keyboard modconf block mdadm_udev netconf dropbear encryptssh lvm2 filesystems fsck)
```

```
mkinitcpio -P
```

### bootloader

Dropbear needs a network interface configured.  
Here I am using DHCP on interface `eth0`. For static config, set the appropriate `ip=` kernel command parameter.  

We also need to tell where our encrypted partition and root volume are.


In `/etc/default/grub`:
```
GRUB_CMDLINE_LINUX="ip=:::::eth0:dhcp cryptdevice=/dev/md1:vg root=/dev/mapper/vg-root"
GRUB_DISABLE_LINUX_UUID=true
```
**NOTE**: the `ip=` parameter uses predictable interface name. Here I use `eth0` which is named `eno1` in the system.


```
# Install grub on the 1MiB space we prepared in first step
grub-install --recheck --target=i386-pc /dev/sda
grub-install --recheck --target=i386-pc /dev/sdb

grub-mkconfig -o /boot/grub/grub.cfg
```

### minimal network configuration

Enable systemd-networkd service and configure a minimal network interface.

```
ln -sf /usr/lib/systemd/system/systemd-networkd.service /etc/systemd/system/dbus-org.freedesktop.network1.service
ln -sf /usr/lib/systemd/system/systemd-networkd.service /etc/systemd/system/multi-user.target.wants/systemd-networkd.service
ln -sf /usr/lib/systemd/system/systemd-networkd.socket /etc/systemd/system/sockets.target.wants/systemd-networkd.socket
ln -sf /usr/lib/systemd/system/systemd-networkd-wait-online.service /etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service
```

`/etc/systemd/network/20-wired.network`:
```
[Match]
Name=eno1

[Network]
DHCP=yes
```

## reboot
```
exit
umount -R /mnt
swapoff /dev/mapper/vg-swap
sync
reboot
```

Now, cross your fingers and wait for the server to reboot then ssh with the root user to unlock the encrypted partition via dropbear:
```
$ ssh root@your.server
Enter passphrase for /dev/md1: 
Shared connection to your.server closed.
```

Ssh again to the system
```
$ ssh root@your.server
[root@archlinux ~]#
```

## Done !

Continue with your usual system configuration.