# UBUNTU for Embedded Systems

Tool to create Ubuntu images for embedded systems (mainly arm / arm64 boards
like the Beaglebone, the RaspberryPi 2, the RaspberryPi 3 or the 96Boards
DragonBoard 410c).

**Crash course**

To build a Xenial image for the Beaglebone Black:

sudo ./make_img.sh -b beaglebone

Or a Xenial image for the RaspberryPi 2:

sudo ./make_img.sh -b raspi2

Or the RaspberryPi 3 (**_experimental_**):

sudo ./make_img.sh -b raspi3

To build an arm64 Xenial image for the RaspberryPi3 (**_experimental_**):

sudo ./make_img.sh -b raspi3

Or one for the 96Boards DragonBoard 410c:

sudo ./make_img.sh -b dragon410c

Serial console: 115200 8N1 - no hardware or software flow control 

Default user / password: ubuntu / ubuntu

See 'boards.db' for an up to date list of supported boards.

Prebuilt images are available at:

http://people.canonical.com/~ppisati/ubuntu_embedded/

Additional options are available through the help section (./make_img.sh -h):

```
[flag@southcross ubuntu-embedded]$ ./make_img.sh -h
usage: make_img.sh -b $BOARD -d $DISTRO [options...]

Available values for:
$BOARD:  beaglexm panda beaglebone mirabox cubox raspi2 raspi3 raspi64 dragon410c
$DISTRO: 14.04 15.04 15.10 16.04

Other options:
-k            don't cleanup after exit

Misc "catch-all" option:
-o <opt=value[,opt=value, ...]> where:

size:			size of the image file (e.g. 2G, default: 1G)
user:			credentials of the user created on the target image
passwd:			same as above, but for the password here
pkgs:			install additional pkgs (pkgs="pkg1 pkg2 pkg3...")
script:			initramfs script to be installed
```
