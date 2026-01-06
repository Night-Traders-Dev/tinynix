#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

KERNEL_VERSION="6.18"
KERNEL_DIR="linux"
BUILD_DIR="$(pwd)/build"

echo -e "${GREEN}=== ARM64 Linux Kernel + Buildroot Rootfs Builder for QEMU ===${NC}"
echo -e "${BLUE}Configuration: Using CUSTOM kernel, Buildroot for rootfs only${NC}"
echo ""

# Check dependencies
echo -e "${YELLOW}Checking dependencies...${NC}"
for cmd in wget tar make gcc flex bison bc git rsync e2fsck tune2fs; do
	if ! command -v $cmd &> /dev/null; then
		echo -e "${RED}ERROR: $cmd is not installed${NC}"
		exit 1
	fi
done

# ============================================================================
# PART 1: Build Custom Kernel (6.18 tinyconfig + VIRTIO)
# ============================================================================

echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}PART 1: Building Custom Kernel${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"

if [ ! -d "$KERNEL_DIR" ]; then
	echo -e "${YELLOW}Cloning Linux kernel ${KERNEL_VERSION}...${NC}"
	git clone --depth=1 --branch=v${KERNEL_VERSION} git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
else
	echo -e "${YELLOW}Kernel source already exists${NC}"
fi

cd "$KERNEL_DIR"

echo -e "${YELLOW}Configuring kernel (tinyconfig + VIRTIO support)...${NC}"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- tinyconfig

# Core features
./scripts/config --enable CONFIG_64BIT
./scripts/config --enable CONFIG_ARM64
./scripts/config --enable CONFIG_SMP
./scripts/config --set-val CONFIG_NR_CPUS 4

# Console
./scripts/config --enable CONFIG_TTY
./scripts/config --enable CONFIG_SERIAL_AMBA_PL011
./scripts/config --enable CONFIG_SERIAL_AMBA_PL011_CONSOLE
./scripts/config --enable CONFIG_HW_CONSOLE
./scripts/config --enable CONFIG_VT
./scripts/config --enable CONFIG_VT_CONSOLE
./scripts/config --enable CONFIG_UNIX98_PTYS

# VIRTIO (critical for rootfs)
./scripts/config --enable CONFIG_VIRTIO
./scripts/config --enable CONFIG_VIRTIO_MMIO
./scripts/config --enable CONFIG_VIRTIO_BLK
./scripts/config --enable CONFIG_VIRTIO_BLK_SCSI
./scripts/config --enable CONFIG_VIRTIO_NET
./scripts/config --enable CONFIG_VIRTIO_CONSOLE
./scripts/config --enable CONFIG_VIRTIO_ANCHOR
./scripts/config --enable CONFIG_VIRTIO_QUEUE_RESET

# Block devices
./scripts/config --enable CONFIG_BLK_DEV
./scripts/config --enable CONFIG_BLOCK
./scripts/config --enable CONFIG_HAVE_EFFICIENT_UNALIGNED_ACCESS
./scripts/config --enable CONFIG_BLK_DEV_INITRD
./scripts/config --enable CONFIG_BLK_DEV_RAM

# Filesystems
./scripts/config --enable CONFIG_EXT4_FS
./scripts/config --enable CONFIG_EXT4_USE_FOR_EXT2
./scripts/config --enable CONFIG_EXT3_FS
./scripts/config --enable CONFIG_EXT2_FS
./scripts/config --enable CONFIG_TMPFS
./scripts/config --enable CONFIG_DEVTMPFS
./scripts/config --enable CONFIG_DEVTMPFS_MOUNT

# Kernel features
./scripts/config --enable CONFIG_PROC_FS
./scripts/config --enable CONFIG_SYSFS
./scripts/config --enable CONFIG_MMU
./scripts/config --enable CONFIG_PRINTK
./scripts/config --enable CONFIG_EARLY_PRINTK

# Network
./scripts/config --enable CONFIG_NET
./scripts/config --enable CONFIG_INET
./scripts/config --enable CONFIG_PACKET
./scripts/config --enable CONFIG_UNIX

# Devices
./scripts/config --enable CONFIG_PCI
./scripts/config --enable CONFIG_PCI_HOST_GENERIC
./scripts/config --enable CONFIG_RTC_CLASS
./scripts/config --enable CONFIG_RTC_DRV_PL031
./scripts/config --enable CONFIG_GPIOLIB
./scripts/config --enable CONFIG_GENERIC_IRQ_INJECTION
./scripts/config --enable CONFIG_IRQCHIP

# Execution
./scripts/config --enable CONFIG_BINFMT_ELF
./scripts/config --enable CONFIG_BINFMT_SCRIPT

# System
./scripts/config --enable CONFIG_PM
./scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE
./scripts/config --enable CONFIG_FB
./scripts/config --enable CONFIG_INPUT
./scripts/config --enable CONFIG_INPUT_KEYBOARD
./scripts/config --enable CONFIG_INPUT_MOUSE
./scripts/config --enable CONFIG_HAVE_SMP

echo -e "${YELLOW}Validating kernel configuration...${NC}"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

echo -e "${YELLOW}Building kernel...${NC}"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)"

mkdir -p "$BUILD_DIR"
if [ -f "arch/arm64/boot/Image" ]; then
	cp arch/arm64/boot/Image "$BUILD_DIR/"
	KERNEL_SIZE=$(ls -lh "$BUILD_DIR/Image" | awk '{print $5}')
	echo -e "${GREEN}✓ Kernel built: $KERNEL_SIZE${NC}"
else
	echo -e "${RED}ERROR: Kernel image not found!${NC}"
	exit 1
fi

cd ..

# ============================================================================
# PART 2: Build Rootfs with Buildroot (NO KERNEL)
# ============================================================================

echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}PART 2: Building Rootfs with Buildroot (Custom Kernel Only)${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"

if [ ! -d "buildroot" ]; then
	echo -e "${YELLOW}Cloning Buildroot...${NC}"
	git clone --depth=1 https://git.buildroot.net/buildroot
else
	echo -e "${YELLOW}Buildroot already exists${NC}"
fi

cd buildroot

echo -e "${YELLOW}Loading tinynix custom configuration (4GB ext4, no kernel)...${NC}"

# Copy the persistent defconfig into Buildroot
cp ../tinynix_defconfig .

# Load it
make BR2_DEFCONFIG=tinynix_defconfig defconfig

echo -e "${YELLOW}Verifying configuration...${NC}"
grep -E "^BR2_TARGET_ROOTFS_EXT2_SIZE=" .config || echo "⚠ Warning: Size not found in config"
grep -E "^BR2_TARGET_ROOTFS_EXT2_MKFS_OPTIONS=" .config || echo "⚠ Warning: MKFS options not found"
grep -E "^# BR2_LINUX_KERNEL is not set" .config || echo "⚠ Warning: Kernel not disabled"

# ============================================================================
# Custom os-release and Network Configuration
# ============================================================================

echo -e "${YELLOW}Configuring custom os-release and networking...${NC}"

# Create rootfs overlay directory structure
mkdir -p board/kraken/rootfs-overlay/etc
mkdir -p board/kraken/rootfs-overlay/etc/systemd/network

# Copy custom os-release
cp ../os-release board/kraken/rootfs-overlay/etc/

# Configure DHCP for eth0 (QEMU virtio-net)
cat > board/kraken/rootfs-overlay/etc/systemd/network/20-eth0-dhcp.network <<'NETWORK_EOF'
[Match]
Name=eth0

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCPv4]
RouteMetric=100

[IPv6AcceptRA]
RouteMetric=256
NETWORK_EOF

# Enable systemd-networkd
cat > board/kraken/rootfs-overlay/etc/systemd/network/99-default.link <<'LINK_EOF'
[Match]
OriginalName=eth0

[Link]
NamePolicy=keep
LINK_EOF

# Set rootfs overlay path in Buildroot config
echo "" >> .config
echo "# Custom rootfs overlay for os-release and network config" >> .config
echo "BR2_ROOTFS_OVERLAY=\"board/kraken/rootfs-overlay\"" >> .config

echo ""
echo -e "${YELLOW}Building Buildroot (rootfs only, ~20-40 minutes on first run)...${NC}"
echo -e "${BLUE}This may take a while. Packages are being compiled...${NC}"
make -j"$(nproc)"

# Verify output
echo -e "${YELLOW}Verifying rootfs image...${NC}"

if [ ! -d "output/images" ]; then
	echo -e "${RED}ERROR: output/images directory not found!${NC}"
	exit 1
fi

if [ -f "output/images/rootfs.ext4" ]; then
	ROOTFS_SIZE=$(ls -lh output/images/rootfs.ext4 | awk '{print $5}')
	echo -e "${GREEN}✓ Rootfs built: $ROOTFS_SIZE${NC}"
	cp output/images/rootfs.ext4 "$BUILD_DIR/rootfs.ext4"
elif [ -f "output/images/rootfs.ext2" ]; then
	ROOTFS_SIZE=$(ls -lh output/images/rootfs.ext2 | awk '{print $5}')
	echo -e "${GREEN}✓ Rootfs built (ext2): $ROOTFS_SIZE${NC}"
	cp output/images/rootfs.ext2 "$BUILD_DIR/rootfs.ext4"
else
	echo -e "${RED}ERROR: Rootfs image not found in output/images/!${NC}"
	ls -lah output/images/
	exit 1
fi

echo -e "${YELLOW}Verifying rootfs integrity...${NC}"
e2fsck -n "$BUILD_DIR/rootfs.ext4" || true

cd ..

# ============================================================================
# PART 3: Launch QEMU
# ============================================================================

echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}PART 3: Launching QEMU${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"

KERNEL="build/Image"
ROOTFS="build/rootfs.ext4"

if [ ! -f "$KERNEL" ] || [ ! -f "$ROOTFS" ]; then
	echo -e "${RED}ERROR: Missing files!${NC}"
	echo -e "${YELLOW}Kernel: $KERNEL ($([ -f "$KERNEL" ] && echo 'OK' || echo 'MISSING'))${NC}"
	echo -e "${YELLOW}Rootfs: $ROOTFS ($([ -f "$ROOTFS" ] && echo 'OK' || echo 'MISSING'))${NC}"
	exit 1
fi

KERNEL_SIZE=$(ls -lh "$KERNEL" | awk '{print $5}')
ROOTFS_SIZE=$(ls -lh "$ROOTFS" | awk '{print $5}')

echo ""
echo -e "${GREEN}Build Complete!${NC}"
echo ""
echo -e "${YELLOW}System Configuration:${NC}"
echo "  Kernel:        $KERNEL_SIZE (custom 6.18 with VIRTIO)"
echo "  Rootfs:        $ROOTFS_SIZE (Buildroot with tools)"
echo "  Architecture:  ARM64 (Cortex-A53)"
echo "  CPU Cores:     2 active (4 max)"
echo "  RAM:           1 GB"
echo "  Networking:    Enabled (DHCP on eth0)"
echo "  Init System:   systemd"
echo ""
echo -e "${YELLOW}Boot Instructions:${NC}"
echo "  Login:         root (no password)"
echo "  Exit QEMU:     Ctrl+A then X"
echo ""
echo -e "${YELLOW}Network Usage (inside QEMU):${NC}"
echo "  # ip addr              - Show IP addresses (auto-configured via DHCP)"
echo "  # ping 8.8.8.8         - Test internet connectivity"
echo "  # nslookup google.com  - Test DNS resolution"
echo "  # wget https://example.com/file - Download files from internet"
echo ""
echo -e "${YELLOW}Check System Info:${NC}"
echo "  # cat /etc/os-release  - View custom os-release"
echo "  # neofetch             - Display system information"
echo ""

qemu-system-aarch64 \
	-M virt \
	-cpu cortex-a53 \
	-nographic \
	-smp 2 \
	-m 1024M \
	-kernel "$KERNEL" \
	-append "root=/dev/vda rw rootwait rootfstype=ext4 console=ttyAMA0" \
	-drive file="$ROOTFS",if=none,format=raw,id=hd0 \
	-device virtio-blk-device,drive=hd0 \
	-netdev user,id=net0,net=192.168.100.0/24,dhcpstart=192.168.100.15 \
	-device virtio-net-device,netdev=net0
