#!/bin/bash
set -e

# === 0. Set keyboard layout and mirrors ===
loadkeys colemak
echo "Keyboard layout set to Colemak."

echo "Configuring pacman mirrors for Germany and Switzerland..."
curl -s 'https://archlinux.org/mirrorlist/?country=DE&country=CH&protocol=https&use_mirror_status=on' \
    | sed 's/^#Server/Server/' > /etc/pacman.d/mirrorlist

# === 1. Prompt for variables ===
read -rp "Enter target disk (e.g., /dev/sda): " DISK
read -rp "Enter hostname: " HOSTNAME
read -rp "Enter username: " USERNAME
read -rsp "Enter user password: " PASSWORD
echo
read -rsp "Enter root password: " ROOT_PASSWORD
echo
read -rsp "Enter LUKS encryption passphrase: " BTRFS_PASSPHRASE
echo
EFI_SIZE="512M"

# === 2. Wipe disk ===
echo "Wiping disk..."
sgdisk --zap-all $DISK
wipefs -a $DISK
sgdisk -n1:0:+$EFI_SIZE -t1:EF00 $DISK
sgdisk -n2:0:0 -t2:8300 $DISK

EFI_PART="${DISK}1"
ROOT_PART="${DISK}2"

# === 3. Setup LUKS encryption ===
echo "Setting up LUKS encryption..."
echo -n "$BTRFS_PASSPHRASE" | cryptsetup luksFormat $ROOT_PART -
echo -n "$BTRFS_PASSPHRASE" | cryptsetup open $ROOT_PART cryptroot -

# === 4. Format partitions ===
echo "Formatting partitions..."
mkfs.fat -F32 $EFI_PART
mkfs.btrfs -f /dev/mapper/cryptroot

# === 5. Create Btrfs subvolumes ===
echo "Creating Btrfs subvolumes..."
mount /dev/mapper/cryptroot /mnt
btrfs su cr /mnt/@
btrfs su cr /mnt/@home
btrfs su cr /mnt/@pkg
btrfs su cr /mnt/@log
umount /mnt

# === 6. Mount subvolumes (HDD-friendly) ===
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{boot,home,var/cache/pacman/pkg,var/log}
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@pkg /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@log /dev/mapper/cryptroot /mnt/var/log
mount $EFI_PART /mnt/boot

# === 7. Install base system ===
echo "Installing base system..."
pacstrap /mnt linux-hardened base base-devel linux-firmware git vim sudo networkmanager

# === 8. Generate fstab ===
echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# === 9. Chroot into new system ===
arch-chroot /mnt /bin/bash <<EOF_CHROOT
set -e

# === Hostname & keyboard ===
echo "$HOSTNAME" > /etc/hostname
localectl set-keymap colemak

# === Locale ===
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# === Root password ===
echo "root:$ROOT_PASSWORD" | chpasswd

# === mkinitcpio for encrypted Btrfs ===
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block keyboard keymap encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# === systemd-boot ===
bootctl --path=/boot install
UUID=\$(blkid -s UUID -o value $ROOT_PART)
cat <<EOL > /boot/loader/loader.conf
default arch
timeout 3
EOL

cat <<EOL > /boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux-hardened
initrd  /initramfs-linux-hardened.img
options cryptdevice=UUID=\$UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
EOL

# === Enable NetworkManager ===
systemctl enable NetworkManager

# === Create user ===
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers
EOF_CHROOT

echo "Installation complete! You can now reboot."
