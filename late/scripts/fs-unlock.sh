#!/bin/sh
set -x

# redirect std
exec 8<&1
exec 9<&2
logout=/run/initramfs/fs-unlock.out
logerr=/run/initramfs/fs-unlock.err
exec 1>$logout
exec 2>$logerr

# variables
name=$CRYPTTAB_NAME
tpm_obj=0x81000005
tmpdir=$(mktemp -d)
secret=$(cat /sys/class/dmi/id/product_serial)
if [ -z "$secret" ]; then secret=$(cat /sys/class/dmi/id/product_uuid); fi

# funcs
do_seal(){
  dir4tpm=$(mktemp -d)
  mkdir -p $dir4tpm
  dd if=/dev/urandom bs=1 count=128 of=$dir4tpm/luks-128bytes.keyfile
  printf $secret | openssl dgst -sha256 -binary | cryptsetup luksAddKey /dev/disk/by-partlabel/keystore $dir4tpm/luks-128bytes.keyfile --key-file=-
  tpm2_startauthsession --session $dir4tpm/session.ctx
  tpm2_policypcr -V --session $dir4tpm/session.ctx --pcr-list sha256:7,8,9 --policy $dir4tpm/pcr_sha256_789.policy
  tpm2_flushcontext $dir4tpm/session.ctx
  rm -f $dir4tpm/session.ctx
  tpm2_createprimary -V --hierarchy o --hash-algorithm sha256 --key-algorithm rsa --key-context $dir4tpm/prim.ctx
  tpm2_create -V --parent-context $dir4tpm/prim.ctx --hash-algorithm sha256 --public $dir4tpm/pcr_seal_key.pub --private $dir4tpm/pcr_seal_key.priv --sealing-input $dir4tpm/luks-128bytes.keyfile --policy $dir4tpm/pcr_sha256_789.policy
  tpm2_load -V -C $dir4tpm/prim.ctx -u $dir4tpm/pcr_seal_key.pub -r $dir4tpm/pcr_seal_key.priv -n $dir4tpm/pcr_seal_key.name -c $dir4tpm/pcr_seal_key.ctx
  tpm2_flushcontext --transient
  tpm2_evictcontrol --hierarchy o --object-context $dir4tpm/pcr_seal_key.ctx $tpm_obj
  tpm2_flushcontext --transient
  rm -rf $dir4tpm
}
do_unseal(){
  dir4tpm=$(mktemp -d)
  mkdir -p $dir4tpm
  tpm2_startauthsession -V --policy-session --session $dir4tpm/session.ctx
  tpm2_policypcr -V --session $dir4tpm/session.ctx --pcr-list sha256:7,8,9 --policy $dir4tpm/unsealing.pcr_sha256_789.policy
  tpm2_unseal -V -p session:$dir4tpm/session.ctx -c $tpm_obj | cryptsetup open /dev/disk/by-partlabel/keystore keystore --key-file=-
  rm -rf $dir4tpm
}

# main process
mkdir -p $tmpdir

if [ -n "`grep fs-unlock /proc/cmdline`" ]; then
  if [ -n "`tpm2_getcap handles-persistent | grep $tpm_obj`" ]; then
    do_unseal
  else
    do_seal
  fi
fi
if [ ! -e /dev/mapper/keystore ]; then
  printf $secret | openssl dgst -sha256 -binary | cryptsetup open /dev/disk/by-partlabel/keystore keystore
fi

mount /dev/mapper/keystore $tmpdir
cat $tmpdir/luks-$name.keyfile >&8
umount $tmpdir; rm -rf $tmpdir
cryptsetup close keystore

# redirect std
exec 1<&8
exec 2<&9

