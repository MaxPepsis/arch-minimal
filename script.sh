#!/usr/bin/env bash
set -e

read -p "Enter hostname: " HOSTNAME
read -p "Enter username: " USERNAME
DISK="/dev/sda"

# Get total size and compute root and home sizes
TOTAL_SIZE_GB=$(lsblk -b -n -o SIZE ${DISK} | awk '{print $1/1024/1024/1024}')
ROOT_SIZE_GB=$(printf "%.1f" $(echo "$TOTAL_SIZE_GB * 0.08" | bc -l))
HOME_SIZE_GB=$(echo "$TOTAL_SIZE_GB - $ROOT_SIZE_GB" | bc -l | awk '{printf("%.0f", $1/100) * 100}')

echo "Suggested layout:"
echo "Root: ${ROOT_SIZE_GB}GiB"
echo "Home: ${HOME_SIZE_GB}GiB (multiple of 100)"
read -p "Accept this layout? (y/n): " ANSWER
if [[ "$ANSWER" != "y" ]]; then
    read -p "Enter root size in GiB: " ROOT_SIZE_GB
    read -p "Enter home size in GiB: " HOME_SIZE_GB
fi

echo "Partitions will be created:
Root: ${ROOT_SIZE_GB}GiB
Home: ${HOME_SIZE_GB}GiB"
read -p "Continue with fdisk partitioning? (y/n): " CONTINUE
if [[ "$CONTINUE" != "y" ]]; then
    echo "Exiting..."
    exit 1
fi

# Wipe disk
hdparm -r0 $DISK || true
wipefs -a $DISK
sgdisk --zap-all $DISK

# Detect EFI or BIOS
if [ -d /sys/firmware/efi ]; then
    IS_UEFI=true
    fdisk $DISK <<EOF
g
n
1

+300M
t
1
n
2

+8G
t
2
19
n
3

+${ROOT_SIZE_GB}G
n
4

+${HOME_SIZE_GB}G
w
EOF
else
    IS_UEFI=false
    fdisk $DISK <<EOF
o
n
1

+8G
t
1
19
n
2

+${ROOT_SIZE_GB}G
n
3

+${HOME_SIZE_GB}G
w
EOF
fi

echo "Partitions created. Proceed with formatting and installation."
