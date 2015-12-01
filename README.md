# UBUNTU for Embedded Systems

Tool to create Ubuntu images for embedded systems (mainly arm boards like the Beaglebone or the Raspberry Pi 2).

**Crash course**

To create an Ubuntu image for the Beaglebone Black:

sudo ./make_img.sh -b beaglebone -d 14.04

To create an Ubuntu image for the RaspberryPi2:

sudo ./make_img.sh -b raspi2 -d 15.10

Serial console: 115200 8N1 - no hardware and software flow control 

Default user / password: ubuntu / ubuntu

See 'boards.db' for an up to date list of supported boards.

Prebuilt images are available at:

http://people.canonical.com/~ppisati/ubuntu_embedded/

Additional options are available through the help section (./make_img.sh -h):

```
[flag@southcross ubuntu-embedded]$ ./make_img.sh -h
usage: make_img.sh -b $BOARD -d $DISTRO [options...]

Available values for:
$BOARD:  beaglexm panda beaglebone mirabox cubox arndale5250 raspi2
$DISTRO: 14.04 15.04 15.10

Other options:
-f  <device>  device installation target
-k            don't cleanup after exit
-t            use deboostrap to populate the rootfs

Misc "catch-all" option:
-o <opt=value[,opt=value, ...]> where:

stack:			release used for the enablement stack (kernel, bootloader and flask-kernel)
size:			size of the image file (e.g. 2G, default: 1G)
user:			credentials of the user created on the target image
passwd:			same as above, but for the password here
pkgs:			install additional pkgs (pkgs="pkg1 pkg2 pkg3...")
rootfs:			rootfs tar.gz archive (e.g. ubuntu core), can be local or remote (http/ftp)
script:			initramfs script to be installed
```
