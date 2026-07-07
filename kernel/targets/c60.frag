# C60-only kernel options (board delta over kernel/config.base).
# RM67191 DSI panel, EDT-FT5x06 touch, BCM4356 wifi/BT, LP5569 LEDs,
# MIPI-CSI + TC358743 HDMI-in, DigiPyro, C60 audio (ADC3101 + TAS5751).
#
# C60 (Kepler proto1) kernel config fragment — primary (mmc-read+booti)
# build. Root is on /dev/disk/by-partlabel/system_a; no embedded initramfs.
# Apply via: scripts/kconfig/merge_config.sh -m .config c60.config
# Then run:  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
#
# Board-specific enables (Broadcom WiFi/BT combo, TC358743 HDMI-RX bridge,
# RM67191 stock panel, FT5x06 touch, ADC3101 mic ADC, PCIe host) are
# documented inline at their definitions below. Image size is held under
# u-boot's 32 MiB BOOTM_LEN cap via the ARCH_* disables and
# CC_OPTIMIZE_FOR_SIZE.

# --- No embedded initramfs in the primary build ---
# Empty CONFIG_INITRAMFS_SOURCE = no embedded ramdisk. Root comes up via
# the kernel cmdline (root=/dev/disk/by-partlabel/system_a) + ext4 in the
# core kernel.
CONFIG_INITRAMFS_SOURCE=""
# BLK_DEV_INITRD stays on regardless — minimal cost, and it keeps the
# external-ramdisk rescue path available. RD_GZIP is kept so a gzip-
# compressed initrd can be used without overriding this fragment.
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_GZIP=y

# --- Disk-root knobs (needed because root is on system_a, not in initramfs) ---
# Partition table discovery so root=/dev/disk/by-partlabel/system_a resolves.
CONFIG_BLK_DEV=y
CONFIG_PARTITION_ADVANCED=y
CONFIG_EFI_PARTITION=y
# ext4 must be =y — modules are not loaded before root is mounted.
CONFIG_EXT4_FS=y
CONFIG_EXT4_USE_FOR_EXT2=y
# i.MX 8M Mini eMMC controller (SDHCI variant). =y so root mount works
# without loading modules from a /lib that doesn't exist yet.
CONFIG_MMC_SDHCI_ESDHC_IMX=y

# --- Audio: Poly Trio C60 machine driver (poly,c60-audio) ---
# ONE sound card, TWO dai_links, both cpu=SAI1: TAS5751M speaker playback +
# 3x TLV320ADC3101 mic-array capture. The machine driver (c60-audio.c, patch
# 0008) fixes the DAI format to I2S/CBC_CFC in C so the SAI is the sole clock
# provider and the ADCs accept it — audio-graph-card2's mixed clock role does
# not (adc3xxx_set_dai_fmt -EINVAL). SND_IMX_SOC=y forces the SAI + imx PCM
# DMA path built-in so the whole stack lands in the Image (no modules).
CONFIG_SND_IMX_SOC=y
CONFIG_SND_SOC_TLV320ADC3XXX=y
# The machine driver itself; selects SAI + imx-pcm-dma + both codecs.
CONFIG_SND_SOC_C60_AUDIO=y
# RM67191 panel (C60 stock; status="disabled" in DTS until probe verified).
CONFIG_DRM_PANEL_RAYDIUM_RM67191=y

# --- Touch: Focaltech FT5x06-family. DTS keeps it disabled until the
# panel is up; the driver is built in so it is ready when re-enabled. ---
CONFIG_TOUCHSCREEN_EDT_FT5X06=y

# --- I/O subsystems: status LED, light-bar/mute-ring LEDs, mute button,
# I2C GPIO expander, DigiPyro presence sensor ---
# gpio-leds "status" (GPIO3_IO16) + 3x TI LP5569 9-ch controllers driving
# the Trio light-bar/mute-ring (27 channels total, i2c2/i2c3/i2c4 @0x32).
# LEDS_CLASS_MULTICOLOR must be =y (not m): leds-lp55xx-common is built-in
# and references its symbols, so a modular build would fail to link.
CONFIG_LEDS_CLASS=y
CONFIG_LEDS_CLASS_MULTICOLOR=y
CONFIG_LEDS_GPIO=y
CONFIG_LEDS_LP55XX_COMMON=y
CONFIG_LEDS_LP5569=y
# extmic-mute button (gpio-keys, KEY_MICMUTE on GPIO5_IO1)
CONFIG_KEYBOARD_GPIO=y
# TCA6408 8-bit I2C GPIO expander on i2c4 @0x20 (pca953x driver)
CONFIG_GPIO_PCA953X=y
CONFIG_GPIO_PCA953X_IRQ=y
# Excelitas PYD1588 "DigiPyro" presence sensor (custom bit-bang driver)
CONFIG_INPUT_MISC=y
CONFIG_INPUT_DIGIPYRO=y
CONFIG_VIDEO_TC358743=y
# HDMI-RX capture path: TC358743 (I2C, =y above) -> i.MX8MM MIPI-CSIS
# receiver -> CSI bridge -> /dev/video. arm64 defconfig ships both of
# these as =m, but the C60 build only runs `make Image dtbs` (no modules
# are built or installed), so force them built-in or they are absent at
# runtime and the async media graph never completes.
# imx-mipi-csis binds fsl,imx8mm-mipi-csi2; imx7-media-csi binds the
# fsl,imx7-csi fallback of the imx8mm-csi node (IMX7 model is correct for
# 8MM — the 8MQ-only base-address errata path is gated off).
CONFIG_VIDEO_IMX_MIPI_CSIS=y
CONFIG_VIDEO_IMX7_CSI=y

# --- Broadcom WiFi/BT on SDIO ---
# Stock cmdline says androidboot.wifivendor=bcm. SDIO bus on USDHC1 per
# stock DTS. Specific chip ID is TBD — brcmfmac probes by chip ID over
# SDIO at runtime.
CONFIG_MMC=y
CONFIG_MMC_SDHCI=y
CONFIG_MMC_SDHCI_PLTFM=y
CONFIG_CFG80211=y
CONFIG_MAC80211=y
CONFIG_BRCMFMAC=y
CONFIG_BRCMFMAC_SDIO=y
# Bluetooth (BCM combo chip; hci_bcm serdev auto-probe over UART1)
CONFIG_RFKILL=y
CONFIG_BT=y
CONFIG_BT_BREDR=y
CONFIG_BT_HCIUART=y
CONFIG_BT_HCIUART_H4=y
CONFIG_BT_HCIUART_BCM=y
CONFIG_BT_BCM=y
# serdev bus + tty port controller: lets the bluetooth{} DT child bind
# hci_bcm automatically, so hci0 comes up without an explicit btattach.
CONFIG_BT_HCIUART_SERDEV=y
CONFIG_SERIAL_DEV_BUS=y
CONFIG_SERIAL_DEV_CTRL_TTYPORT=y

# --- PCIe Gen1 (stock has brcmfmac on it; left disabled until probed) ---
CONFIG_PCI=y
CONFIG_PCIE_DW_PLAT_HOST=y
# CONFIG_ARCH_ACTIONS is not set
# CONFIG_ARCH_ALPINE is not set
# CONFIG_ARCH_APPLE is not set
# CONFIG_ARCH_BCM is not set
# CONFIG_ARCH_BCM2835 is not set
# CONFIG_ARCH_BCMBCA is not set
# CONFIG_ARCH_BERLIN is not set
# CONFIG_ARCH_BRCMSTB is not set
# CONFIG_ARCH_EXYNOS is not set
# CONFIG_ARCH_HISI is not set
# CONFIG_ARCH_KEEMBAY is not set
# CONFIG_ARCH_LAYERSCAPE is not set
# CONFIG_ARCH_LG1K is not set
# CONFIG_ARCH_MEDIATEK is not set
# CONFIG_ARCH_MESON is not set
# CONFIG_ARCH_NPCM is not set
# CONFIG_ARCH_QCOM is not set
# CONFIG_ARCH_R8A774A1 is not set
# CONFIG_ARCH_R8A774B1 is not set
# CONFIG_ARCH_R8A774C0 is not set
# CONFIG_ARCH_R8A774E1 is not set
# CONFIG_ARCH_R8A77951 is not set
# CONFIG_ARCH_R8A77960 is not set
# CONFIG_ARCH_R8A77961 is not set
# CONFIG_ARCH_R8A77965 is not set
# CONFIG_ARCH_R8A77970 is not set
# CONFIG_ARCH_R8A77980 is not set
# CONFIG_ARCH_R8A77990 is not set
# CONFIG_ARCH_R8A77995 is not set
# CONFIG_ARCH_R8A779A0 is not set
# CONFIG_ARCH_R8A779F0 is not set
# CONFIG_ARCH_R8A779G0 is not set
# CONFIG_ARCH_R9A07G043 is not set
# CONFIG_ARCH_R9A07G044 is not set
# CONFIG_ARCH_R9A07G054 is not set
# CONFIG_ARCH_R9A09G011 is not set
# CONFIG_ARCH_RCAR_GEN3 is not set
# CONFIG_ARCH_REALTEK is not set
# CONFIG_ARCH_RENESAS is not set
# CONFIG_ARCH_ROCKCHIP is not set
# CONFIG_ARCH_RZG2L is not set
# CONFIG_ARCH_S32 is not set
# CONFIG_ARCH_SEATTLE is not set
# CONFIG_ARCH_SPRD is not set
# CONFIG_ARCH_STM32 is not set
# CONFIG_ARCH_SUNXI is not set
# CONFIG_ARCH_SYNQUACER is not set
# CONFIG_ARCH_TEGRA is not set
# CONFIG_ARCH_TEGRA_132_SOC is not set
# CONFIG_ARCH_TEGRA_186_SOC is not set
# CONFIG_ARCH_TEGRA_194_SOC is not set
# CONFIG_ARCH_TEGRA_210_SOC is not set
# CONFIG_ARCH_TEGRA_234_SOC is not set
# CONFIG_ARCH_TESLA_FSD is not set
# CONFIG_ARCH_THUNDER is not set
# CONFIG_ARCH_THUNDER2 is not set
# CONFIG_ARCH_UNIPHIER is not set
# CONFIG_ARCH_VEXPRESS is not set
# CONFIG_ARCH_VISCONTI is not set
# CONFIG_ARCH_XGENE is not set
# CONFIG_ARCH_ZYNQMP is not set

# WiFi: Cypress/Broadcom BCM4356 via PCIe (FullMAC).
CONFIG_BRCMUTIL=y
CONFIG_BRCMFMAC=y
CONFIG_BRCMFMAC_PROTO_BCDC=y
CONFIG_BRCMFMAC_PROTO_MSGBUF=y
CONFIG_BRCMFMAC_PCIE=y

# Embed BCM4356 firmware in the kernel image so brcmfmac PCIe probe at
# t~3s loads firmware synchronously without racing /lib/firmware mount.
# Blobs staged into linux-6.6/firmware/brcm/ by kernel/build.sh from
# firmware-blobs/. Adds ~622 KiB to Image.
CONFIG_EXTRA_FIRMWARE="brcm/brcmfmac4356-pcie.bin brcm/brcmfmac4356-pcie.clm_blob brcm/brcmfmac4356-pcie.txt brcm/BCM4356A2.hcd imx/sdma/sdma-imx7d.bin"
CONFIG_EXTRA_FIRMWARE_DIR="firmware"
