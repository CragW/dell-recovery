#!/bin/sh
name=$CRYPTTAB_NAME
serial_number=$(cat /sys/class/dmi/id/product_serial)
if [ -z "$serial_number" ]; then
    serial_number="0000000"
fi

tmpdir=$(mktemp -d)
printf $serial_number | openssl dgst -sha256 -binary | cryptsetup open /dev/disk/by-partlabel/keystore keystore
mkdir -p $tmpdir
mount /dev/mapper/keystore $tmpdir
cat $tmpdir/luks-$name.keyfile
umount $tmpdir
rm -rf $tmpdir
cryptsetup close keystore
