# TC8-only kernel options (board delta over kernel/config.base).
# Panel-Poly-LCC DSI + Goodix touch + fbcon rotation for the 800x1280 panel;
# OVERLAY_FS for the sealed rootfs (C60 gains this when sealed-root ports).
CONFIG_DRM_PANEL_POLY_LCC=y
CONFIG_TOUCHSCREEN_GOODIX=y
CONFIG_FRAMEBUFFER_CONSOLE_ROTATION=y
CONFIG_OVERLAY_FS=y
