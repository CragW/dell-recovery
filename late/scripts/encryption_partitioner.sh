#!/bin/sh -ex
#
#       <partitioner_zfs.sh>
#
#       Creates a simple partition layout
#
#       Copyright 2021 Dell Inc.
#           Crag Wang <crag.wang@dell.com>
#
set -eux

disk=$1
disk_index_esp=1
disk_index_recovery=2
disk_index_boot=3
disk_index_rootfs=4
disk_index_keystore=5
part_prefix=""

pkg_dependencies='cryptsetup cryptsetup-bin'
target="/target"
target_keystore="/target_keystore"

check_prerequisites() {
    echo "I: Checking system requirements"

    if [ $(id -u) -ne 0 ]; then
        echo "E: Script must be executed as root. Exiting!"
        exit 1
    fi

    for pkg in $@; do
        if ! dpkg-query -W -f'${Status}' "${pkg}"|grep -q "install ok installed" 2>/dev/null; then
            echo "E: $pkg is required and not installed on this system. Exiting!"
            exit 1
        fi
    done
}

do_partition(){
	local part_num=$1
	local part_label=$2
	local part_size=$3
	local part_type=$4
	local part_format=$5
	local disk=$disk
	local part_prefix=${part_prefix}

	printf "do_partition():
			disk=$disk,
			part_num=$part_num,
			part_label=$part_label,
			part_size=$part_size,
			part_type=$part_type,
			part_format=$part_format,
			part_prefix=${part_prefix}
			"
	sgdisk --new=$part_num:0:$part_size \
	       --typecode=$part_num:$part_type \
		   --change-name=$part_num:$part_label \
		   $disk

	partprobe $disk 2>/dev/null || true
	wipefs -a $disk$part_prefix$part_num || true

	case "$part_format" in
		vfat)
			mkfs.vfat -F 32 -n $part_label $disk$part_prefix$part_num
			;;
		ext4)
			mkfs.ext4 -q -L $part_label $disk$part_prefix$part_num
			;;
	esac
}
do_luks(){
	case "$1" in
		rootfs)
			local tmpdir=$(mktemp -d)
			mkdir -p $tmpdir
			mount /dev/mapper/keystore $tmpdir
			#keyfile
			dd if=/dev/urandom bs=1024 count=4 status=none of=$tmpdir/luks-rootfs.keyfile
			chmod u+r,go-rwx $tmpdir/luks-rootfs.keyfile
			#cryptsetup
			cryptsetup luksFormat \
					--key-file=$tmpdir/luks-rootfs.keyfile \
					${disk}${part_prefix}${disk_index_rootfs}
			cryptsetup open \
					--key-file=$tmpdir/luks-rootfs.keyfile \
					${disk}${part_prefix}${disk_index_rootfs} \
					rootfs
			mkfs.ext4 -q -L rootfs /dev/mapper/rootfs
			mkdir -p $target
			mount "/dev/mapper/rootfs" $target
			#crypttab, fstab
			mkdir -p $target/etc
			uuid_rootfs=$(blkid -s UUID -o value -t PARTLABEL=rootfs)
			echo "rootfs UUID=${uuid_rootfs}  none  luks,keyscript=/usr/share/dell/scripts/fs-unlock.sh,initramfs" >> "$target/etc/crypttab"
			echo "/dev/mapper/rootfs  /  ext4  errors=remount-ro  0  1" >> "$target/etc/fstab"
			#cleanup
			umount $tmpdir
			rm -rf $tmpdir
			;;
		keystore)
			#cryptsetup
			local serial_number=$(cat /sys/class/dmi/id/product_serial)
			if [ -z "$serial_number" ]; then
				serial_number="0000000"
			fi

			printf $serial_number | openssl dgst -sha256 -binary | cryptsetup luksFormat \
					--key-file=- \
					${disk}${part_prefix}${disk_index_keystore}
			printf $serial_number | openssl dgst -sha256 -binary | cryptsetup open \
					--key-file=- \
					${disk}${part_prefix}${disk_index_keystore} keystore
			mkfs.ext4 -q -L keystore /dev/mapper/keystore
			;;
		*)
			printf "skipped..\n"
	esac
}
do_disk_layout() {
	if ! sfdisk -d "${disk}" | grep -iq "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"; then
		do_partition "$disk_index_esp" "ESP" "+128M" "ef00" "vfat"
	fi
	if ! [ -e ${disk}${part_prefix}2 ]; then
		do_partition "$disk_index_recovery" "RECOVERY" "+`expr $(blockdev --getsize64 /dev/cdrom) / 1024 / 1024 + 600`M" "8300" "vfat"
	fi
	do_partition "$disk_index_boot" "boot" "+1024M" "8300" "ext4"
	do_partition "$disk_index_rootfs" "rootfs" "-512M" "8300" "ext4"
	do_partition "$disk_index_keystore" "keystore" "0" "8300" "ext4"
	do_luks "keystore"
	do_luks "rootfs"
}

fixup_part_prefix(){
	case "${disk}" in
		/dev/sd*|/dev/hd*|/dev/vd*)
			part_prefix=""
			;;
		*)
			part_prefix="p"
	esac
}

only_esp_recovery_survive(){
	for part in $(lsblk -o name -n -l $disk); do
		local num=${part##*[^0-9]}
		case "$num" in
			$disk_index_esp|$disk_index_recovery|'')
				;;
			*)
				sgdisk -d $num $disk
				;;
		esac
	done
}
# -- main() --
echo "I: Running $(basename "$0")"
check_prerequisites "${pkg_dependencies}"
fixup_part_prefix
only_esp_recovery_survive
do_disk_layout

# prepare boot
mkdir -p "$target/etc"
mkdir -p "$target/boot"
mount $disk$part_prefix$disk_index_boot "$target/boot"
uuid_boot=$(blkid -s UUID -o value "$disk$part_prefix$disk_index_boot")
echo "UUID=${uuid_boot}  /boot  ext4  defaults  0  2" >> "$target/etc/fstab"

# prepare efi
mkdir -p "$target/boot/efi"
mount -t vfat "$disk$part_prefix$disk_index_esp" "$target/boot/efi"
uuid_esp=$(blkid -s UUID -o value "$disk$part_prefix$disk_index_esp")
echo "UUID=${uuid_esp}  /boot/efi  vfat  umask=0022,fmask=0022,dmask=0022  0  1" >> "$target/etc/fstab"
