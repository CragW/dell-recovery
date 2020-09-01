 #!/bin/sh -ex
#
#       <partitioner_zfs.sh>
#
#       Creates a simple partition layout
#
#       Copyright 2020 Dell Inc.
#           Crag Wang <crag.wang@dell.com>
#
set -eux

#  Args:
#	 $1: /dev/nvme0n1
DISK=$1
PARTITION_NUM_ESP='1'
PARTITION_NUM_RECOVERY='2'
PARTITION_NUM_BOOT='3'
PARTITION_NUM_ROOTFS='4'

# run time dependencies
REQUIRED_PKGS='zfsutils-linux'

# mount point for customer os partition
TARGET="/target"

# prefix 'p' for partition indexing
PREFIX_PARTBASE=""

# Check and set the requirements to run this test. If any of the
# requirement is missing the programs exit with error
#
# Args:
#   $@: List of required packages
#
# Returns
#   Exit program is a requirement is not met
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

# EFI partition is found on the specific disk?
#
# Returns:
#	(boolean) true | false
esp_exists() {
	parttype="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
	sfdisk -d "${DISK}" | grep -q "type=${parttype}"
}

# Create partitions
#
# ---------------------------------------------
# num | format | zfs pool | size | description
# ---------------------------------------------
#  1  | fat16  |          | 128M | EFI System
#  2  | fat32  |          |      | Recovery
#  3  |  zfs   |  bpool   |  1G  | Boot
#  4  |  zfs   |  rpool   | rest | OS rootfs
#
# Args:
#	$1: /dev/nvme0n1
#
# Returns:
#	n/a
format_disk() {
	if ! esp_exists "${DISK}"; then
		sgdisk --new=${PARTITION_NUM_ESP}:0:+128M --typecode=${PARTITION_NUM_ESP}:ef00 --change-name=${PARTITION_NUM_ESP}:ESP ${DISK}
	fi

	sgdisk --new=${PARTITION_NUM_BOOT}:0:+1G --change-name=${PARTITION_NUM_BOOT}:/boot ${DISK}
	sgdisk --new=${PARTITION_NUM_ROOTFS}:0:0 --change-name=${PARTITION_NUM_ROOTFS}:rootfs ${DISK}

	wipefs -a ${DISK}${PREFIX_PARTBASE}${PARTITION_NUM_ROOTFS} || true

	# Force a re-read of the partition table
	echo "I: Re-reading partition table"
	partx --add "${DISK}" 2>/dev/null || true
}

prepare_target(){
	mkdir -p ${TARGET}

	if ! grep -qE "\s${TARGET}\s" /proc/mounts; then
		echo "E: ${TARGET} is not mounted. Exiting!"
		return 0
	fi

	# umount /target
	# It may fail to umount because the swap is being created by partman and not finished when we reach this point.
	# Give it some time and retry with a sleep between tries.
	iter=0
	maxiter=10

	for mountpoint in "${TARGET}/boot/efi" "${TARGET}"; do
		if [ ! -d "${mountpoint}" ]; then
			continue
		fi

		echo "I: umounting ${mountpoint}"
		while :; do
			# Do not make it quiet. We want to know why it failed.
			if ! sudo umount "${mountpoint}"; then
				iter=$(( iter + 1 ))
				echo "W: Try ${iter}. Failed to umount ${mountpoint}."
				if [ ${iter} -eq ${maxiter} ]; then
					echo "E: Failed to umount ${mountpoint}. Exiting!"
					exit 1
				fi
				sleep 3
			else
				break
			fi
		done
	done

	mount ${DISK}${PREFIX_PARTBASE}${PARTITION_NUM_ROOTFS} ${TARGET}
}

init_zfs(){
	echo "I: Initializing ZFS"

	# Prepare 6 digits UUID for dataset use
	UUID_ORIG=$(head -100 /dev/urandom | tr -dc 'a-z0-9' |head -c6)

	# Let udev finish its job before proceeding with zpool creation
	udevadm settle

	# Use stable uuid for partition when available as device name can change
	bpooluuid=$(blkid -s PARTUUID -o value ${DISK}${PREFIX_PARTBASE}${PARTITION_NUM_BOOT})
	partbpool=''
	[ -n "$bpooluuid" -a -e "/dev/disk/by-partuuid/$bpooluuid" ] && partbpool=/dev/disk/by-partuuid/$bpooluuid

	rpooluuid=$(blkid -s PARTUUID -o value ${DISK}${PREFIX_PARTBASE}${PARTITION_NUM_ROOTFS})
	partrpool=''
	[ -n "$rpooluuid" -a -e "/dev/disk/by-partuuid/$rpooluuid" ] && partrpool=/dev/disk/by-partuuid/$rpooluuid

	# rpool
	zpool create -f \
		-o ashift=12 \
		-o autotrim=on \
		-O compression=lz4 \
		-O acltype=posixacl \
		-O xattr=sa \
		-O relatime=on \
		-O normalization=formD \
		-O mountpoint=/ \
		-O canmount=off \
		-O dnodesize=auto \
		-O sync=disabled \
		-O mountpoint=/ -R "${TARGET}" rpool "${partrpool}"

	# bpool
	# The version of bpool is set to the default version to prevent users from upgrading
	# Then only features supported by grub are enabled.
	zpool create -f \
		-o ashift=12 \
		-o autotrim=on \
		-d \
		-o feature@async_destroy=enabled \
		-o feature@bookmarks=enabled \
		-o feature@embedded_data=enabled \
		-o feature@empty_bpobj=enabled \
		-o feature@enabled_txg=enabled \
		-o feature@extensible_dataset=enabled \
		-o feature@filesystem_limits=enabled \
		-o feature@hole_birth=enabled \
		-o feature@large_blocks=enabled \
		-o feature@lz4_compress=enabled \
		-o feature@spacemap_histogram=enabled \
		-O compression=lz4 \
		-O acltype=posixacl \
		-O xattr=sa \
		-O relatime=on \
		-O normalization=formD \
		-O canmount=off \
		-O devices=off \
		-O mountpoint=/boot -R "${TARGET}" bpool "${partbpool}"

	# Root and boot dataset
	zfs create rpool/ROOT -o canmount=off -o mountpoint=none
	zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}" -o mountpoint=/
	zfs create bpool/BOOT -o canmount=off -o mountpoint=none
	zfs create "bpool/BOOT/ubuntu_${UUID_ORIG}" -o mountpoint=/boot

	# System dataset
	zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var" -o canmount=off
	zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/lib"
	zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/lib/AccountsService"
	zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/lib/apt"
	zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/lib/dpkg"
	zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/lib/NetworkManager"

	# Desktop specific system dataset
	zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/srv"
	zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/usr" -o canmount=off
	zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/usr/local"
	zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/games"
	zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/log"
	zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/mail"
	zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/snap"
	zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/spool"
	zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/www"

	# USERDATA datasets
	# Dataset associated to the user are created by the installer.
	zfs create rpool/USERDATA -o canmount=off -o mountpoint=/

	# Set zsys properties
	zfs set com.ubuntu.zsys:bootfs='yes' "rpool/ROOT/ubuntu_${UUID_ORIG}"
	zfs set com.ubuntu.zsys:last-used=$(date +%s) "rpool/ROOT/ubuntu_${UUID_ORIG}"
	zfs set com.ubuntu.zsys:bootfs='no' "rpool/ROOT/ubuntu_${UUID_ORIG}/srv"
	zfs set com.ubuntu.zsys:bootfs='no' "rpool/ROOT/ubuntu_${UUID_ORIG}/usr"
	zfs set com.ubuntu.zsys:bootfs='no' "rpool/ROOT/ubuntu_${UUID_ORIG}/var"
}

# Prepare grub directory
init_system_partitions(){
	# ESP
	mkdir -p "${TARGET}/boot/efi"
	mount -t vfat "${DISK}${PREFIX_PARTBASE}${PARTITION_NUM_ESP}" "${TARGET}/boot/efi"
	mkdir -p "${TARGET}/boot/efi/grub"

	echo "I: Mount grub directory"
	# Finalize grub directory
	mkdir -p "${TARGET}/boot/grub"
	mount -o bind "${TARGET}/boot/efi/grub" "${TARGET}/boot/grub"
}

fixup_prefix_partbase(){
	case "${DISK}" in
		/dev/sd*|/dev/hd*|/dev/vd*)
			PREFIX_PARTBASE=""
			;;
		*)
			PREFIX_PARTBASE="p"
	esac
}

create_target_fstab(){
	# $TARGET/etc has been destroyed by the creation of the zfs partitition
	# Recreate it
	mkdir -p "${TARGET}/etc"
	espuuid=$(blkid -s UUID -o value "${DISK}${PREFIX_PARTBASE}${PARTITION_NUM_ESP}")
	echo "UUID=${espuuid}\t/boot/efi\tvfat\tumask=0022,fmask=0022,dmask=0022\t0\t1" >> "${TARGET}/etc/fstab"

	# Bind mount grub from ESP to the expected location
	echo "/boot/efi/grub\t/boot/grub\tnone\tdefaults,bind\t0\t0" >> "${TARGET}/etc/fstab"

	# Make /boot/{grub,efi} world readable
	sed -i 's#\(.*boot/efi.*\)umask=0077\(.*\)#\1umask=0022,fmask=0022,dmask=0022\2#' "${TARGET}/etc/fstab"
}

# -- main() --
echo "I: Running $(basename "$0")"
check_prerequisites "${REQUIRED_PKGS}"

# determine prefix for each partition upon disk type
fixup_prefix_partbase

# Display partition layout at present
echo "I: Partition table before init of ZFS"
partx --show ${DISK} || true

# Stop ZFS service
echo "I: Stop ZFS backend processes"
systemctl stop zfs.target
systemctl stop zfs-zed.service
systemctl stop zfs-mount.service

# ZFS disk partitioning
echo "I: Create ZFS partitions"
format_disk

# display the updated partition layout
echo "I: Partition table after init of ZFS"
partx --show ${DISK}

# prepare target
prepare_target

# setup zpools, datasets
init_zfs

# assure all mountpoints are mounted
zfs mount -a

# create grub directory
init_system_partitions

# Generate fstab
create_target_fstab

# install zfs tools
echo "I: Marking ZFS utilities to be kept in the target system"
apt-install zfsutils-linux 2>/dev/null
apt-install zfs-initramfs 2>/dev/null
apt-install zsys 2>/dev/null

# Activate zfs generator.
# After enabling the generator we should run zfs set canmount=on DATASET
# in the chroot for one dataset of each pool to refresh the zfs cache.
echo "I: Activating zfs generator"
mkdir -p "${TARGET}/etc/zfs/zed.d"
ln -s /usr/lib/zfs-linux/zed.d/history_event-zfs-list-cacher.sh "${TARGET}/etc/zfs/zed.d"

# Create zpool cache
zpool set cachefile= bpool
zpool set cachefile= rpool
cp /etc/zfs/zpool.cache "${TARGET}/etc/zfs/"
mkdir -p "${TARGET}/etc/zfs/zfs-list.cache"
touch "${TARGET}/etc/zfs/zfs-list.cache/bpool"
touch "${TARGET}/etc/zfs/zfs-list.cache/rpool"

zfs set canmount=noauto bpool/BOOT/ubuntu_${UUID_ORIG}
zfs set canmount=noauto rpool/ROOT/ubuntu_${UUID_ORIG}

