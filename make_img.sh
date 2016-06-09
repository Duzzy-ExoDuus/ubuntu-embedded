#!/bin/bash
#
#  Copyright (c) 2014 Canonical
#
#  Author: Paolo Pisati <p.pisati@canonical.com>
#
#  This program is free software; you can redistribute it and/or
#  modify it under the terms of the GNU General Public License as
#  published by the Free Software Foundation; either version 2 of the
#  License, or (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307
#  USA
#

# TODO:
#
# - multiple ppa support
# - kernel and bootloader selection support
# - arch support (arm64? amd64? i386?)
# - autoresize at first boot
#
# boards support:
# - vanilla i386? qemu-i386?
# - vexpress support?
# - android device support?
# - chomebook device support?
#
# stuff to check:
# - check vars quoting&style
# - reduce root usage if possible
# - move fs/device creation from top to bottom of script
# - check if we can slim uenv.txt some more
# - kernel installation on old installs? flash-kernel execution looks for
#   /lib/firmware/...

set -e

export LC_ALL=C PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
DB="boards.db"
KERNELCONF="kernel-img.conf"
DEFIMGSIZE="2147483648" # 2GB
BOOTSIZE="32"
USER="ubuntu"
PASSWD="ubuntu"
EMBEDDEDPPA="ppa:p-pisati/embedded"
KEEP=0
DEBOOTSTRAP=0
BASEPKGS="linux-base sudo net-tools vim whois kpartx netcat-openbsd openssh-server avahi-daemon"
SCRIPTDIR="initramfs-scripts"

BOARD=
DISTRO=
BOOTLOADERS=
UBOTPREF=
BOOTDEVICE=
ROOTDEVICE=
BOOTLOADERDEVICE=

rm -f build.log && touch build.log
tail -f build.log &
TAILPID=$!

exec 3>&1 4>&2 >build.log 2>&1

ARRAY=("14.04:trusty" "15.04:vivid" "15.10:wily" "16.04:xenial")

ubuntuversion() {
	local CMD="$1"
	local KEY="$2"
	local RET=""

	for ubuntu in "${ARRAY[@]}" ; do
		REL=${ubuntu%%:*}
		COD=${ubuntu#*:}
		if [ "${CMD}" = "release" ]; then
			[ "${KEY}" = "${COD}" ] && RET="${REL}" && break
		elif [ "${CMD}" = "codename" ]; then
			[ "${KEY}" = "${REL}" ] && RET="${COD}" && break
		elif [ "${CMD}" = "releases" ]; then
			if [ "${RET}" ]; then
				RET="${RET} ${REL}"
			else
				RET="${REL}"
			fi
		fi
	done
	echo "${RET}"
}

ubunturecentversion() {
	local ARCH="$1"
	local DISTRO="$2"

	wget -O- http://cdimage.ubuntu.com/ubuntu-base/releases/$DISTRO/release/MD5SUMS | sed -n "s/^[[:xdigit:]]*[[:space:]]*\*ubuntu-core-\([^-]*\)-core-$ARCH.tar.gz$/\1/p" | sort -V | tail -n 1
}

ugetrel()
{
	echo $(ubuntuversion "release" "$1")
}

ugetcod()
{
	echo $(ubuntuversion "codename" "$1")
}

ugetrels()
{
	echo $(ubuntuversion "releases")
}

get_all_fields() {
	local field="$1"
	local all

	cat "$DB" | {
		while read key value; do
			#echo "a: $all"
			[ "$key" = "${field}:" ] && all="$all $value"
		done
		echo "$all"
	}
}



get_field() {
	local board="$1"
	local field_name="$2"
	local state="block"
	local key
	local value

	cat "$DB" | {
		while read key value; do
			case "$state" in
				"block")
					[ "$key" = "board:" ] && [ "$value" = "$board" ] && state="field"
				;;
				"field")
					case "$key" in
						"${field_name}:")
							echo "$value"
						;;
						"")
							echo ""
							return
						;;
					esac
				;;
			esac
		done
		echo ""
	}
}

mount_dev()
{
	local DEV="$1"
	local DIR="$2"

	#echo "mount x${DEV}x y${DIR}y"
	mount "${DEV}" "${DIR}"
	[ $? -eq 0 ] && echo "${DEV}" >> "${MOUNTFILE}" && return
	exit $?
}


do_chroot()
{
		local ROOT="$1"
		local CMD="$2"
		shift 2

		mount --bind /proc $ROOT/proc
		mount --bind /sys $ROOT/sys
		#echo "cmd: $CMD args: $@"
		chroot $ROOT $CMD "$@"
		umount $ROOT/sys
		umount $ROOT/proc
}

cleanup()
{
	echo "== Cleanup =="
	sync
	[ -n "$TAILPID" ] && kill -9 $TAILPID
	if [ -e "$ROOTFSDIR" ]; then
		umount $ROOTFSDIR/sys >/dev/null 2>&1 || true
		umount $ROOTFSDIR/proc >/dev/null 2>&1 || true
		tac $MOUNTFILE | while read line; do
			umount $line >/dev/null 2>&1 || true
		done
		$KPARTX -d "$DEVICE" >/dev/null 2>&1  || true
		[ $KEEP -eq 0 ] && rmdir "$BOOTDIR" "$ROOTFSDIR" >/dev/null 2>&1 || true
	fi
	if [ $KEEP -eq 0 ]; then
		rm -f $FSTABFILE
		rm -f $MOUNTFILE
	fi
}

mbr_layout_device()
{
	echo "== Layout device =="
	local BOOTPART=
	local ROOTPART=
	local LAYOUT=

	LAYOUT=$(get_field "$BOARD" "layout") || true
	[ -z "$LAYOUT" ] && echo "Error: unknown media layout" && exit 1

	# create a new img file
	rm -f "$DEVICE"
	truncate -s ${IMGSIZE} ${DEVICE} 

	# 1) create partitions
	echo "1) Creating partitions..."
	local PART=0
	for i in $LAYOUT; do
		PART=$((PART+1))
		echo "part: $PART layout: $i";
		local MPOINT=`echo "$i" | cut -f1 -d","`
		local FS=`echo "$i" | cut -f2 -d","`
		local SIZE=`echo "$i" | cut -f3 -d","`
		echo "mpoint: $MPOINT fs: $FS size: $SIZE"
		[ $SIZE = "FILL" ] && SIZE="" || SIZE="+$SIZE"
		[ $MPOINT = "BOOTDIR" ] && BOOTPART=$PART
		[ $MPOINT = "/" ] && ROOTPART=$PART
		echo "mpoint: $MPOINT fs: $FS size: $SIZE"
		/bin/echo -e "n\np\n\n\n${SIZE}\nw" | fdisk "$DEVICE"
		if [ $FS = "vfat" ]; then 
			if [ $PART = "1" ]; then
				/bin/echo -e "t\nc\nw" | fdisk "$DEVICE"
			else
				/bin/echo -e "t\n${PART}\nc\nw" | fdisk "$DEVICE"
			fi
		fi
		[ $MPOINT = "BOOTDIR" ] && /bin/echo -e "a\n${PART}\nw\n" | fdisk "$DEVICE"
	done
	echo "ROOTPART: $ROOTPART BOOTPART: ${BOOTPART:-null}"

	# 2) make filesystems & assemble fstab
	$KPARTX -asv "$DEVICE"
	LOOP=$(losetup -a | grep $DEVICE | cut -f1 -d: | cut -f3 -d/)
	PHYSDEVICE="/dev/mapper/${LOOP}p"
	BOOTLOADERDEVICE="/dev/${LOOP}"
	echo "2) Making filesystems..."
	PART=0
	for i in $LAYOUT; do
		PART=$((PART+1))
		echo "part: $PART layout: $i";
		local MPOINT=`echo "$i" | cut -f1 -d","`
		local FS=`echo "$i" | cut -f2 -d","`
		local SIZE=`echo "$i" | cut -f3 -d","`
		echo "mpoint: $MPOINT fs: $FS size: $SIZE"
		[ $MPOINT = "SKIP" ] && continue
		mkfs.${FS} ${PHYSDEVICE}${PART}
		if [ $MPOINT != "SKIP" -a $MPOINT != "BOOTDIR" ]; then
			MNTOPTS="defaults"
			FSCK="0"
			UUID=`blkid ${PHYSDEVICE}${PART} -s UUID -o value`
			[ $MPOINT = "/" ] && MNTOPS="errors=remount-ro" && FSCK="1"
			[ $MPOINT = "/boot" ] && FSCK="2"
			echo "UUID=$UUID	$MPOINT	$FS	$MNTOPTS	0	$FSCK" >> $FSTABFILE
		fi
	done

	# 3) final assignment
	[ ${BOOTPART} ] && BOOTDEVICE="${PHYSDEVICE}${BOOTPART}"
	ROOTDEVICE="${PHYSDEVICE}${ROOTPART}"
	echo "ROOTDEVICE: $ROOTDEVICE BOOTDEVICE: ${BOOTDEVICE:-null}"
}

gpt_layout_device() {
	# create a new img file
	rm -f "$DEVICE"
	truncate -s $IMGSIZE "$DEVICE"

	# 1) create partitions
	echo "1) Creating partitions..."
	local PART=1
	while read mpoint fs size name type; do
		[[ $mpoint =~ ^#.* ]] && continue
		echo "mpoint: $mpoint fs: $fs size: $size name: $name type: $type"
		[ $size = "FILL" ] && size="" || size="+$size"
		[ $mpoint = "/" ] && ROOTPART=$PART
		sgdisk -a 1 -n 0:0:$size "$DEVICE"
		[ $name -a $name != "NULL" ] && sgdisk -c $PART:$name "$DEVICE"
		[ $fs = "fat" -a $type = "NULL" ] && type="0700" # GPT's fat partition
		[ $fs = "msdos" -a $type = "NULL" ] && type="0700"
		[ $fs = "vfat" -a $type = "NULL" ] && type="0700"
		[ $type -a $type != "NULL" ] && sgdisk -t $PART:$type "$DEVICE"
		PART=$((PART+1))
	done < "boards/$BOARD/parts.txt"

	# 2) make filesystems & assemble fstab
	$KPARTX -asv "$DEVICE"
	LOOP=$(losetup -a | grep $DEVICE | cut -f1 -d: | cut -f3 -d/)
	PHYSDEVICE="/dev/mapper/${LOOP}p"
	echo "2) Making filesystems..."
	PART=0
	while read mpoint fs size name type; do
		[[ $mpoint =~ ^#.* ]] && continue
		echo "mpoint: $mpoint fs: $fs size: $size name: $name type: $type"
		PART=$((PART+1))
		[ $fs = "NULL" ] && continue
		mkfs.${fs} ${PHYSDEVICE}${PART}
		if [ $mpoint != "NULL" ]; then
			mntopts="defaults"
			fsck="0"
			uuid=`blkid ${PHYSDEVICE}${PART} -s UUID -o value`
			[ $mpoint = "/" ] && mntopts="errors=remount-ro" && fsck="1"
			[ $mpoint = "/boot" ] && fsck="2"
			echo "UUID=$uuid $mpoint $fs $mntopts 0 $fsck" >> $FSTABFILE
		fi
	done < "boards/$BOARD/parts.txt"

	# 3) final assignment
	ROOTDEVICE="$PHYSDEVICE$ROOTPART"
	echo "ROOTDEVICE: $ROOTDEVICE"
}


vanilla_bootchain()
{
	# 1) if there's a $BOOTDEVICE defined, mount it
	# 	a) if there's a uEnv.txt in /boot, move it to $BOOTDIR

	if [ "${BOOTDEVICE}" ]; then
		mount_dev "${BOOTDEVICE}" "${BOOTDIR}"
		[ -f "${ROOTFSDIR}/boot/uEnv.txt" ] && mv "${ROOTFSDIR}/boot/uEnv.txt" $BOOTDIR
	fi

	# 2) if there's any bootloader defined
	# 	a) if there's a bootdir partition, copy/rename the bootloader to that partition
	# 	b) else, dd the corresponding bootloader file at $b blocks from the beginning of
	#		the device

	# XXX shortcut for: copy all the bootloader files from
	# boards/$BOARD/bootloaders to $BOOTDIR
	if [ "${BOOTLOADERS}" = "ALL" ]; then
		cp -R boards/$BOARD/bootloaders/* $BOOTDIR/
	elif [ "${BOOTLOADERS}" ]; then

		if [ "${UBOOTPREF}" ]; then
			do_chroot $ROOTFSDIR apt-get -y install u-boot
			local PREFIX="$ROOTFSDIR/usr/lib/u-boot/$UBOOTPREF"
		else
			local PREFIX="boards/$BOARD/bootloaders"
		fi
		local DEST=""
		if [ $BOOTDEVICE ] ; then
			DEST="$BOOTDIR"
			DELIMITER='>'
		else
			DEST="$BOOTLOADERDEVICE"
			DELIMITER=':'
		fi
		for i in $BOOTLOADERS; do
			a="$(echo $i | cut -f1 -d$DELIMITER)"
			b="$(echo $i | cut -f2 -d$DELIMITER)"
			if [ "${BOOTDEVICE}" ]; then
				cp $PREFIX/$a $DEST/$b
			else
				dd if=$PREFIX/$a of=${DEST} bs=512 seek=$b
			fi
		done
	fi

	# XXX - mirabox's bad uboot workaround
	# no bootloaders defined, just copy uImage/uInitrd to BOOTDIR
	if [ "${BOOTDEVICE}" -a -z "${BOOTLOADERS}" ]; then
		cp ${ROOTFSDIR}/boot/uImage ${ROOTFSDIR}/boot/uInitrd ${BOOTDIR}
	fi

	# install any initramfs BOOTDIR files
	if [ "$SCRIPTS" -a -d "$SCRIPTDIR/$script/BOOTDIR" ]; then
		for script in $SCRIPTS; do
			cp -vR $SCRIPTDIR/$script/BOOTDIR/* "$BOOTDIR"
		done
	fi
}

fastboot_bootchain()
{
	LOOP=$(losetup -a | grep $DEVICE | cut -f1 -d: | cut -f3 -d/)
	PHYSDEVICE="/dev/mapper/${LOOP}p"
	PREFIX="boards/$BOARD/bootloaders/"
	while read part binary offset; do
		[[ $part =~ ^#.* ]] && continue
		echo "part: $part binary: $binary off: $offset"
		dd if=${PREFIX}${binary} of=${PHYSDEVICE}${part} seek=$offset
	done < "boards/$BOARD/bootchain.txt"
}

BOARDS="$(get_all_fields "board")"

usage()
{
cat << EOF
usage: $(basename $0) -b \$BOARD -d \$DISTRO [options...]

Available values for:
\$BOARD: $BOARDS
\$DISTRO: 14.04 15.04 15.10 16.04

Other options:
-k            don't cleanup after exit
-t            use deboostrap to populate the rootfs

Misc "catch-all" option:
-o <opt=value[,opt=value, ...]> where:

size:			size of the image file (e.g. 2G, default: 1G)
user:			credentials of the user created on the target image
passwd:			same as above, but for the password here
pkgs:			install additional pkgs (pkgs="pkg1 pkg2 pkg3...")
rootfs:			rootfs tar.gz archive (e.g. ubuntu core), can be local or remote (http/ftp)
script:			initramfs script to be installed
EOF
	exit 1
}

# setup_env_generic
# -prepare all env variables
# -check requisites
# -print summary of env

while [ $# -gt 0 ]; do
	case "$1" in
		-b)
			[ -n "$2" ] && BOARD=$2 && shift || usage
			;;
		-d)
			[ -n "$2" ] && DISTRO=$2 && shift || usage
			[ -z $(ugetcod "$DISTRO") ] && echo "Error: $DISTRO is not a valid input" && exit 1
			;;
		-k)
			KEEP=1
			;;
		-t)
			DEBOOTSTRAP=1
			;;
		-o)
			[ "$2" ] || usage
			OIFS=$IFS
			IFS=','
			for ARG in $2; do
				[ -z "${ARG}" ] && echo "Error: syntax error in $ARG" && usage
				cmd=${ARG%%=*}
				arg=${ARG#*=}
				# code below always expect an agument, so enforce it
				[ -z "$arg" -o "$cmd" = "$arg" ] && echo "Error: syntax error for opt: $ARG" && usage
				#echo "cmd: $cmd arg: ${arg:-null}"
				case "$cmd" in
					"pkgs") MPKGS="$arg" ;;
					"passwd") PASSWD="$arg" ;;
					"rootfs") UROOTFS="$arg" ;;
					"script") MSCRIPT="$arg" ;;
					"size")
						USRIMGSIZE=`numfmt --from=iec --invalid=ignore $arg`
						! [[ $USRIMGSIZE =~ ^[0-9]+$ ]] && echo "Error: invalid input \"$arg\"" && exit 1
						;;
					"user") USER="$arg" ;;
					*)
						echo "Error: $ARG unknown option" && exit 1
						;;
				esac
			done
			IFS=$OIFS
			shift
			;;
		*|h)
			usage
			;;
	esac
	shift	
done

# mandatory checks
[ -z "$BOARD" -o -z "$DISTRO" ] && usage
# XXX check if $BOARD is known
ARCH=$(get_field "$BOARD" "arch") || true
case "$ARCH" in
	arm64)
		ARCHIVE="http://ports.ubuntu.com"
		QEMU=$(which qemu-aarch64-static) || true
		;;
	armhf)
		ARCHIVE="http://ports.ubuntu.com"
		QEMU=$(which qemu-arm-static) || true
		;;
	i386)
		ARCHIVE="http://archive.ubuntu.com/ubuntu"
		QEMU=$(which qemu-i386-static) || true
		;;
	*)
		echo "Error: Unsupported architecture: $ARCH"
		exit 1
esac
MACHINE=$(get_field "$BOARD" "machine") || true
[ -z "$MACHINE" ] && echo "Error: unknown machine string" && exit 1
PTABLE=$(get_field "$BOARD" "ptable") || true
[ -z "$PTABLE" ] && echo "Error: unknown partition table" && exit 1
BOOTLOADER=$(get_field "$BOARD" "bootloader") || true
[ -z "$BOOTLOADER" ] && echo "Error: unknown bootloader chain" && exit 1
[ -z $QEMU ] && echo "Error: install the qemu-user-static package" && exit 1
KPARTX=$(which kpartx) || true
[ -z $KPARTX ] && echo "Error: install the kpartx package" && exit 1
MKPASSWD=$(which mkpasswd) || true
[ -z $MKPASSWD ] && echo "Error: install the whois package" && exit 1
[ -z `which debootstrap` ] && echo "Error: install the debootstrap package" && exit 1
SGDISK=$(which sgdisk) || true
[ -z $SGDISK ] && echo "Error: install the gdisk package" && exit 1
[ $(id -u) -ne 0 ] && echo "Error: run me with sudo!" && exit 1

# optional parameters
SERIAL=$(get_field "$BOARD" "serial") || true
UENV=$(get_field "$BOARD" "uenv") || true
UBOOTPREF=$(get_field "$BOARD" "uboot-prefix") || true
BOOTLOADERS=$(get_field "$BOARD" "bootloaders") || true
PPA=$(get_field "$BOARD" "ppa") || true
KERNEL=$(get_field "$BOARD" "kernel") || true
BPKGS=$(get_field "$BOARD" "packages") || true
BSCRIPT=$(get_field "$BOARD" "script") || true
REPOSITORIES=$(get_field "$BOARD" "repositories") || true

# sanitize input params
IMGSIZE=${USRIMGSIZE:-$(echo $DEFIMGSIZE)}
[ "${IMGSIZE}" -lt "${DEFIMGSIZE}" ] && echo "Error: size can't be smaller than `numfmt --from=auto --to=iec ${DEFIMGSIZE}`" && exit 1
[ "$BPKGS" -o "$MPKGS" ] && PACKAGES="${BPKGS} ${MPKGS}"
[ "$BSCRIPT" -o "$MSCRIPT" ] && SCRIPTS="${BSCRIPT} ${MSCRIPT}"
if [ "$SCRIPTS" ]; then
	for script in $SCRIPTS; do
		[ ! -d $SCRIPTDIR/$script ] && echo "Error: $script is not a valid initramfs-script" && exit 1
	done
fi

# final environment setup
trap cleanup 0 1 2 3 9 15
if [ $DEBOOTSTRAP -eq 1 ]; then
	COMPLETEVER=$DISTRO
else
	COMPLETEVER=$(ubunturecentversion $ARCH $DISTRO)
fi
KERNEL=${KERNEL:-linux-image-generic}
DEVICE="ubuntu-embedded-$COMPLETEVER-$BOARD.img"
ROOTFS="${UROOTFS:-http://cdimage.ubuntu.com/ubuntu-core/releases/$DISTRO/release/ubuntu-core-$COMPLETEVER-core-$ARCH.tar.gz}"
ROOTFSDIR=$(mktemp -d build/embedded-rootfs.XXXXXX)
BOOTDIR=$(mktemp -d build/embedded-boot.XXXXXX)
FSTABFILE=$(mktemp build/embedded-fstab.XXXXXX)
MOUNTFILE=$(mktemp build/embedded-mount.XXXXXX)

echo "Summary: "
echo $BOARD
echo $DISTRO
echo $BOOTDIR
echo $ROOTFSDIR
echo $FSTABFILE
echo $MOUNTFILE
echo $UBOOTPREF
echo $BOOTLOADERS
echo $DEVICE
echo $ROOTFS
echo $PTABLE
echo $IMGSIZE
echo $USER
echo $PASSWD
echo $KERNEL
echo $PACKAGES
echo $SCRIPTS
echo $DEBOOTSTRAP
echo "------------"

# end of setup_env_generic()

# prepare_media_generic()
# prepare the target device/loop-file:
# - create the partitions
# - mkfs
# - create the fstab file
# - properly assign ROOTDEVICE and (optionally) BOOTDEVICE
${PTABLE}_layout_device

# end of prepare_media_generic()

# init_system_generic()
# - mount ROOTDEVICE to ROOTFSDIR
# - download ubuntu core/rootfs
# - install rootfs
echo "== Init System =="
mount_dev "${ROOTDEVICE}" "${ROOTFSDIR}"
if [ "$DEBOOTSTRAP" -eq 0 ]; then
	if [ "${ROOTFS%%:*}" = "http" -o "${ROOTFS%%:*}" = "ftp" ]; then
		 wget --verbose -O- "${ROOTFS}" | tar zxf - -C "${ROOTFSDIR}"
	else
		tar zxf "${ROOTFS}" -C "${ROOTFSDIR}"
	fi
else
	CODENAME=$(ugetcod "$DISTRO")
	debootstrap --arch="$ARCH" --variant=minbase --foreign "$CODENAME" "$ROOTFSDIR" "$ARCHIVE"
fi
cp "$QEMU" "$ROOTFSDIR/usr/bin"
# finish off deboostrap config
[ "$DEBOOTSTRAP" -eq 1 ] && chroot "$ROOTFSDIR" ./debootstrap/debootstrap --second-stage "$CODENAME" .
cp /etc/resolv.conf $ROOTFSDIR/etc
# prevent demon from starting inside the chroot
cp skel/policy-rc.d $ROOTFSDIR/usr/sbin/
chmod +x $ROOTFSDIR/usr/sbin/policy-rc.d
do_chroot $ROOTFSDIR apt-get update
do_chroot $ROOTFSDIR apt-get install -y ifupdown udev

# end of init_system_generic()

# setup_system_generic()
# - parse fstab and mount it accordingly
# - bare minimal system setup
echo "== Setup System =="
# 1) parse fstab and mount it inside $ROOTFSDIR
while read line; do
	MPOINT=`echo $line | cut -f2 -d " "`
	[ $MPOINT = "/" ] && continue
	UUID=`echo $line | cut -f1 -d " " | cut -f 2 -d =`
	DEV=`blkid -U $UUID`
	# if the mountpoint is a not an existing canonical directory, create it
	[ ! -d "${ROOTFSDIR}/${MPOINT}" ] && mkdir -p "${ROOTFSDIR}/${MPOINT}"
	mount_dev "${DEV}" "${ROOTFSDIR}/${MPOINT}"
done < $FSTABFILE

cp skel/hosts $ROOTFSDIR/etc
cp $FSTABFILE $ROOTFSDIR/etc/fstab
[ -n $SERIAL ] && sed "s/ttyX/$SERIAL/g" skel/serial.conf > $ROOTFSDIR/etc/init/${SERIAL}.conf
do_chroot $ROOTFSDIR useradd $USER -m -p `mkpasswd $PASSWD` -s /bin/bash
do_chroot $ROOTFSDIR adduser $USER adm
do_chroot $ROOTFSDIR adduser $USER sudo
cp skel/interfaces $ROOTFSDIR/etc/network/
# avoid dynamic naming of the NIC
do_chroot $ROOTFSDIR touch /etc/udev/rules.d/80-net-setup-link.rules
echo "$BOARD" > $ROOTFSDIR/etc/hostname
cp skel/$KERNELCONF $ROOTFSDIR/etc

# install per board custom rootfs files if present
[ -d "boards/$BOARD/rootfs" ] && cp -rv boards/$BOARD/rootfs/* "$ROOTFSDIR"

# end of setup_system_generic()

# install_pkgs_generic()
# - install & setup pkgs (e.g. kernel)
# - apply all custom patches
# - run flash-kernel as last step
echo "== Install pkgs =="
# install the corresponding src repositories
awk '$1 ~ /^deb$/{sub(/deb/, "&-src");print}' $ROOTFSDIR/etc/apt/sources.list >> $ROOTFSDIR/etc/apt/sources.list
do_chroot $ROOTFSDIR apt-get update
# the embedded PPA is mandatory
do_chroot $ROOTFSDIR apt-get install -y software-properties-common
do_chroot $ROOTFSDIR add-apt-repository -y ${EMBEDDEDPPA}
# pin the embedded ppa
cp skel/embedded-ppa $ROOTFSDIR/etc/apt/preferences.d/
# add optional repostitories
for REPO in ${REPOSITORIES}; do
	do_chroot $ROOTFSDIR add-apt-repository -y ${REPO}
done
do_chroot $ROOTFSDIR apt-get update
# if specified, add a 3rd party PPA
if [ "${PPA}" ]; then
	do_chroot $ROOTFSDIR add-apt-repository -y ${PPA}
	do_chroot $ROOTFSDIR apt-get update
fi
# don't run flash-kernel during kernel installation
export FLASH_KERNEL_SKIP=1
do_chroot $ROOTFSDIR apt-get -y install ${KERNEL} ${BASEPKGS}
unset FLASH_KERNEL_SKIP

# flash-kernel-specific-bits - XXX shouldn't we do a better check?
if [ $ARCH = "armhf" -o $ARCH = "arm64" ]; then
	do_chroot $ROOTFSDIR apt-get -y install u-boot-tools flash-kernel
	do_chroot $ROOTFSDIR flash-kernel --machine "$MACHINE" --nobootdevice
	[ "${UENV}" ] && cp skel/"uEnv.${UENV}" $ROOTFSDIR/boot/uEnv.txt
fi

# install additional pkgs if specified
[ -n "$PACKAGES" ] && do_chroot "$ROOTFSDIR" apt-get install -y $PACKAGES

# install any initramfs script
if [ "$SCRIPTS" ]; then
	for script in $SCRIPTS; do
		cp -vR $SCRIPTDIR/$script/hooks $ROOTFSDIR/etc/initramfs-tools
		cp -vR $SCRIPTDIR/$script/scripts $ROOTFSDIR/etc/initramfs-tools
	done
	KVER=`do_chroot "$ROOTFSDIR" linux-version list | linux-version sort | tail -1`
	FLASH_KERNEL_SKIP=1 do_chroot "$ROOTFSDIR" update-initramfs -u -k $KVER
fi

# end of install_pkgs_generic()

# install_bootloader()
# - copy bootscript
# - install bootloaders
echo "== Install Bootloader =="
# XXX so far, this part is relevant only in case we use uboot
${BOOTLOADER}_bootchain

rm $ROOTFSDIR/usr/sbin/policy-rc.d
do_chroot $ROOTFSDIR apt-get clean
[ -e "boards/$BOARD/first_boot.txt" ] && echo -e "\n\n\n\n" && cat "boards/$BOARD/first_boot.txt"
