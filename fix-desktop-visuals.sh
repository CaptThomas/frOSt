#!/bin/bash
set -e
BUILD_DIR="/root/frost-build"
ROOTFS="${BUILD_DIR}/rootfs"
KVER=$(ls ${ROOTFS}/lib/modules/ | sort -V | tail -1)

log() { echo "[frost-desktop-fix] $1"; }

# ============================================================
# STEP 1: Install picom compositor + visual packages
# ============================================================
log "=== STEP 1: Installing picom and visual packages ==="
chroot "${ROOTFS}" apt-get update 2>&1 | tail -1
chroot "${ROOTFS}" apt-get install -y picom papirus-icon-theme fonts-noto-color-emoji 2>&1 | tail -5
log "Picom and visual packages installed"

# ============================================================
# STEP 2: Generate a proper frOSt wallpaper (1920x1080)
# ============================================================
log "=== STEP 2: Generating custom frOSt wallpaper ==="
# Create a Python script to generate a cool wallpaper
cat > /tmp/gen-wallpaper.py << 'PYWALL'
#!/usr/bin/env python3
"""Generate a dark cyberpunk/frost themed wallpaper"""
import struct
import zlib
import math
import random

WIDTH, HEIGHT = 1920, 1080
random.seed(42)  # Deterministic

def make_png(pixels, w, h):
    """Create PNG from raw pixel data"""
    def chunk(ctype, data):
        c = ctype + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)

    raw = b''
    for y in range(h):
        raw += b'\x00'  # filter none
        for x in range(w):
            idx = (y * w + x) * 3
            raw += bytes(pixels[idx:idx+3])

    compressed = zlib.compress(raw, 9)

    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', compressed)
    png += chunk(b'IEND', b'')
    return png

pixels = [0] * (WIDTH * HEIGHT * 3)

# Dark gradient background with subtle noise
for y in range(HEIGHT):
    for x in range(WIDTH):
        # Center radial gradient
        cx, cy = WIDTH/2, HEIGHT/2
        dx, dy = (x - cx) / cx, (y - cy) / cy
        dist = math.sqrt(dx*dx + dy*dy)

        # Base dark blue gradient
        t = min(1.0, dist)
        r = int(10 * (1 - t * 0.6))
        g = int(22 * (1 - t * 0.5))
        b = int(40 * (1 - t * 0.3))

        # Subtle noise
        noise = random.randint(-3, 3)
        r = max(0, min(255, r + noise))
        g = max(0, min(255, g + noise))
        b = max(0, min(255, b + noise))

        idx = (y * WIDTH + x) * 3
        pixels[idx] = r
        pixels[idx+1] = g
        pixels[idx+2] = b

# Draw aurora/frost streaks (cyan/teal lines with glow)
for i in range(8):
    # Organic curve using sinusoids
    amp = random.uniform(50, 200)
    freq = random.uniform(0.003, 0.008)
    phase = random.uniform(0, 2 * math.pi)
    y_base = random.randint(200, 800)
    alpha = random.uniform(0.15, 0.5)
    hue_shift = random.uniform(-0.1, 0.1)

    for x in range(WIDTH):
        y_center = int(y_base + amp * math.sin(freq * x + phase) +
                       amp * 0.3 * math.sin(freq * 2.7 * x + phase * 1.5))

        # Glow around the streak
        for dy in range(-40, 41):
            y = y_center + dy
            if 0 <= y < HEIGHT:
                falloff = math.exp(-abs(dy) * abs(dy) / (150.0 + 80 * abs(math.sin(x * 0.01))))
                intensity = falloff * alpha

                idx = (y * WIDTH + x) * 3
                # Cyan/teal color with variation
                cr = int(0 + 30 * hue_shift)
                cg = int(180 + 75 * hue_shift)
                cb = int(255 - 20 * abs(hue_shift))

                pixels[idx] = min(255, int(pixels[idx] + cr * intensity))
                pixels[idx+1] = min(255, int(pixels[idx+1] + cg * intensity))
                pixels[idx+2] = min(255, int(pixels[idx+2] + cb * intensity))

# Draw subtle grid lines (cyberpunk feel)
for x in range(0, WIDTH, 120):
    for y in range(HEIGHT):
        falloff = 0.03
        idx = (y * WIDTH + x) * 3
        pixels[idx] = min(255, pixels[idx] + int(20 * falloff))
        pixels[idx+1] = min(255, pixels[idx+1] + int(60 * falloff))
        pixels[idx+2] = min(255, pixels[idx+2] + int(80 * falloff))

for y in range(0, HEIGHT, 120):
    for x in range(WIDTH):
        falloff = 0.03
        idx = (y * WIDTH + x) * 3
        pixels[idx] = min(255, pixels[idx] + int(20 * falloff))
        pixels[idx+1] = min(255, pixels[idx+1] + int(60 * falloff))
        pixels[idx+2] = min(255, pixels[idx+2] + int(80 * falloff))

# Draw particles (scattered bright dots)
for _ in range(300):
    px = random.randint(0, WIDTH - 1)
    py = random.randint(0, HEIGHT - 1)
    brightness = random.uniform(0.3, 1.0)
    size = random.randint(1, 3)
    for ddx in range(-size, size + 1):
        for ddy in range(-size, size + 1):
            nx, ny = px + ddx, py + ddy
            if 0 <= nx < WIDTH and 0 <= ny < HEIGHT:
                d = math.sqrt(ddx*ddx + ddy*ddy) / size
                if d <= 1.0:
                    f = (1 - d) * brightness
                    idx = (ny * WIDTH + nx) * 3
                    pixels[idx] = min(255, int(pixels[idx] + 100 * f))
                    pixels[idx+1] = min(255, int(pixels[idx+1] + 220 * f))
                    pixels[idx+2] = min(255, int(pixels[idx+2] + 255 * f))

# Add "frOSt" text (large, bottom-right corner, subtle)
# Using a simple pixel font approach - draw it subtly
# We'll skip text rendering and just do a logo glow in bottom-right

# Bottom-right corner glow
for y in range(HEIGHT - 200, HEIGHT):
    for x in range(WIDTH - 300, WIDTH):
        dx = (x - (WIDTH - 150)) / 150.0
        dy = (y - (HEIGHT - 100)) / 100.0
        dist = math.sqrt(dx*dx + dy*dy)
        if dist < 1.0:
            f = (1 - dist) * 0.08
            idx = (y * WIDTH + x) * 3
            pixels[idx] = min(255, int(pixels[idx] + 0 * f))
            pixels[idx+1] = min(255, int(pixels[idx+1] + 212 * f))
            pixels[idx+2] = min(255, int(pixels[idx+2] + 255 * f))

png_data = make_png(pixels, WIDTH, HEIGHT)
with open('/tmp/frost-wallpaper.png', 'wb') as f:
    f.write(png_data)
print(f"Wallpaper generated: {len(png_data)} bytes")
PYWALL

python3 /tmp/gen-wallpaper.py
cp /tmp/frost-wallpaper.png "${ROOTFS}/usr/share/backgrounds/frost/wallpaper.png"
log "Wallpaper generated and installed"

# ============================================================
# STEP 3: Fix xfdesktop config - add eDP-1 monitor config
# ============================================================
log "=== STEP 3: Fixing xfdesktop monitor config ==="
# XFCE uses "monitoreDP-1" (monitor prefix + output name) for properties
# We need to add eDP-1 alongside the virtual monitor entries
cat > "${ROOTFS}/home/frost/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" << 'DESKXML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitoreDP-1" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/frost/wallpaper.png"/>
        </property>
        <property name="workspace1" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/frost/wallpaper.png"/>
        </property>
        <property name="workspace2" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/frost/wallpaper.png"/>
        </property>
        <property name="workspace3" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/frost/wallpaper.png"/>
        </property>
      </property>
      <property name="monitorVirtual-0" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/frost/wallpaper.png"/>
        </property>
      </property>
      <property name="monitorHDMI-1" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/frost/wallpaper.png"/>
        </property>
      </property>
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/frost/wallpaper.png"/>
        </property>
      </property>
    </property>
  </property>
  <property name="desktop-icons" type="empty">
    <property name="style" type="int" value="2"/>
    <property name="file-icons" type="empty">
      <property name="show-home" type="bool" value="true"/>
      <property name="show-filesystem" type="bool" value="true"/>
      <property name="show-removable" type="bool" value="true"/>
      <property name="show-trash" type="bool" value="true"/>
    </property>
    <property name="icon-size" type="uint" value="36"/>
    <property name="font-size" type="double" value="10"/>
    <property name="use-custom-font-size" type="bool" value="true"/>
  </property>
</channel>
DESKXML
# Also update the system-wide version
cp "${ROOTFS}/home/frost/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" \
   "${ROOTFS}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
chown 1000:1000 "${ROOTFS}/home/frost/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
log "Desktop config fixed with proper eDP-1 monitor name"

# ============================================================
# STEP 4: Configure picom compositor
# ============================================================
log "=== STEP 4: Configuring picom compositor ==="
mkdir -p "${ROOTFS}/home/frost/.config/picom"
cat > "${ROOTFS}/home/frost/.config/picom/picom.conf" << 'PICOMCFG'
# frOSt Picom Compositor Configuration
# Shadows, transparency, blur, and animations

# Backend
backend = "glx";
vsync = true;
glx-no-stencil = true;
glx-copy-from-front = false;

# Shadows
shadow = true;
shadow-radius = 12;
shadow-offset-x = -7;
shadow-offset-y = -7;
shadow-opacity = 0.6;
shadow-color = "#000000";
shadow-exclude = [
    "name = 'Notification'",
    "class_g = 'Conky'",
    "class_g ?= 'Notify'",
    "class_g = 'Cairo-clock'",
    "_GTK_FRAME_EXTENTS@:c",
    "class_g = 'xfce4-panel'",
    "class_g = 'xfce4-notifyd'"
];

# Fading
fading = true;
fade-in-step = 0.04;
fade-out-step = 0.04;
fade-delta = 4;
fade-exclude = [];

# Opacity
inactive-opacity = 0.92;
active-opacity = 1.0;
frame-opacity = 0.9;
inactive-opacity-override = false;
focus-exclude = [
    "class_g = 'Cairo-clock'",
    "class_g = 'xfce4-panel'",
    "class_g = 'Conky'"
];
opacity-rule = [
    "95:class_g = 'xfce4-terminal'",
    "90:class_g = 'Thunar'",
    "100:class_g = 'firefox'",
    "100:class_g = 'Chromium-browser'",
    "85:class_g = 'Conky'"
];

# Corner rounding
corner-radius = 8;
rounded-corners-exclude = [
    "class_g = 'xfce4-panel'",
    "window_type = 'dock'",
    "window_type = 'desktop'"
];

# General
detect-rounded-corners = true;
detect-client-opacity = true;
detect-transient = true;
detect-client-leader = true;
use-damage = true;
log-level = "warn";

# Window type settings
wintypes:
{
    tooltip = { fade = true; shadow = true; opacity = 0.85; focus = true; full-shadow = false; };
    dock = { shadow = false; clip-shadow-above = true; };
    dnd = { shadow = false; };
    popup_menu = { opacity = 0.95; shadow = true; };
    dropdown_menu = { opacity = 0.95; shadow = true; };
};
PICOMCFG
chown -R 1000:1000 "${ROOTFS}/home/frost/.config/picom"

# Add picom to autostart
cat > "${ROOTFS}/etc/xdg/autostart/picom.desktop" << 'PICOMSTART'
[Desktop Entry]
Type=Application
Name=Picom Compositor
Comment=Picom compositor for visual effects
Exec=picom --config /home/frost/.config/picom/picom.conf -b
Terminal=false
Hidden=false
X-GNOME-Autostart-enabled=true
X-XFCE-Autostart-Override=true
PICOMSTART
log "Picom compositor configured and added to autostart"

# ============================================================
# STEP 5: Fix conky to work properly with xfdesktop
# ============================================================
log "=== STEP 5: Fixing conky configuration ==="
# Change own_window_type from 'desktop' to 'override' to avoid conflicts with xfdesktop
# Also update network interface from eth0 to wlo1
cat > "${ROOTFS}/etc/frost/conky.conf" << 'CONKYCFG'
-- frOSt System Monitor - Conky Configuration
-- Dark semi-transparent overlay with cyan/red frost theme

conky.config = {
    alignment = 'top_right',
    background = true,
    border_width = 0,
    cpu_avg_samples = 2,
    net_avg_samples = 2,
    double_buffer = true,
    font = 'Hack:size=9',
    gap_x = 20,
    gap_y = 50,
    minimum_width = 260,
    maximum_width = 260,
    no_buffers = true,
    own_window = true,
    own_window_type = 'override',
    own_window_transparent = false,
    own_window_argb_visual = true,
    own_window_argb_value = 160,
    own_window_colour = '0a1628',
    own_window_hints = 'undecorated,below,sticky,skip_taskbar,skip_pager',
    draw_shades = false,
    draw_outline = false,
    draw_borders = false,
    draw_graph_borders = true,
    use_xft = true,
    xftalpha = 0.9,
    update_interval = 2.0,
    uppercase = false,
    override_utf8_locale = true,
    default_color = 'e0f0ff',
    color0 = '00d4ff',    -- cyan (headers)
    color1 = 'e0f0ff',    -- white (text)
    color2 = '6b8299',    -- dim (labels)
    color3 = 'ff2d2d',    -- red (accents)
    color4 = '00ff88',    -- green (good)
    color5 = '0090c1',    -- blue (bars)
    color6 = '1a3050',    -- border
};

conky.text = [[
${color3}${font Hack:bold:size=14}frOSt${font Hack:size=9} OS${font}${color6}${hr 1}${color}
${color2}Host:${color1}    ${nodename}
${color2}Kernel:${color1}  ${kernel}
${color2}Uptime:${color1}  ${uptime_short}

${color0}${font Hack:bold:size=10}CPU${font}${color6}${hr 1}${color}
${color2}Usage:${color1}  ${cpu cpu0}%${goto 160}${color5}${cpubar cpu0 8,100}${color}
${color2}Core 1:${color1} ${cpu cpu1}%${goto 160}${color5}${cpubar cpu1 8,100}${color}
${color2}Core 2:${color1} ${cpu cpu2}%${goto 160}${color5}${cpubar cpu2 8,100}${color}
${color2}Core 3:${color1} ${cpu cpu3}%${goto 160}${color5}${cpubar cpu3 8,100}${color}
${color2}Core 4:${color1} ${cpu cpu4}%${goto 160}${color5}${cpubar cpu4 8,100}${color}
${color2}Freq:${color1}   ${freq_g}GHz
${color5}${cpugraph 30,260 0090c1 00d4ff -l}${color}

${color0}${font Hack:bold:size=10}MEMORY${font}${color6}${hr 1}${color}
${color2}RAM:${color1}  ${mem}/${memmax}  ${memperc}%
${color5}${membar 8,260}${color}

${color0}${font Hack:bold:size=10}STORAGE${font}${color6}${hr 1}${color}
${color2}Root:${color1}    ${fs_used /}/${fs_size /}  ${fs_used_perc /}%
${color5}${fs_bar 8,260 /}${color}
${if_mounted /frost/persist}${color2}Persist:${color1} ${fs_used /frost/persist}/${fs_size /frost/persist}  ${fs_used_perc /frost/persist}%
${color5}${fs_bar 8,260 /frost/persist}${color}${endif}

${color0}${font Hack:bold:size=10}NETWORK${font}${color6}${hr 1}${color}
${if_up wlo1}${color2}WiFi:${color4} Connected${color}
${color2}IP:${color1}     ${addr wlo1}
${color2}ESSID:${color1}  ${wireless_essid wlo1}
${color2}Signal:${color1} ${wireless_link_qual_perc wlo1}%${goto 160}${color5}${wireless_link_bar 8,100 wlo1}${color}
${color3}Down:${color4} ${downspeed wlo1}${goto 160}${color3}Up:${color4} ${upspeed wlo1}${color}
${color5}${downspeedgraph wlo1 20,125 0090c1 00d4ff -l} ${upspeedgraph wlo1 20,125 0090c1 ff2d2d -l}${color}${else}${if_up eno2}${color2}Ethernet:${color4} Connected${color}
${color2}IP:${color1}   ${addr eno2}
${color3}Down:${color4} ${downspeed eno2}${goto 160}${color3}Up:${color4} ${upspeed eno2}${color}${else}${color3}No network${color}${endif}${endif}

${color0}${font Hack:bold:size=10}PROCESSES${font}${color6}${hr 1}${color}
${color2}Total:${color1} ${processes}  ${color2}Running:${color1} ${running_processes}
${color2}Name${goto 140}PID${goto 195}CPU%${goto 240}MEM%${color}
${color6}${hr 1}${color}
${color1}${top name 1}${goto 130}${top pid 1}${goto 190}${top cpu 1}${goto 235}${top mem 1}
${color1}${top name 2}${goto 130}${top pid 2}${goto 190}${top cpu 2}${goto 235}${top mem 2}
${color1}${top name 3}${goto 130}${top pid 3}${goto 190}${top cpu 3}${goto 235}${top mem 3}
${color2}${top name 4}${goto 130}${top pid 4}${goto 190}${top cpu 4}${goto 235}${top mem 4}
${color2}${top name 5}${goto 130}${top pid 5}${goto 190}${top cpu 5}${goto 235}${top mem 5}
]];
CONKYCFG
log "Conky config updated (own_window_type=override, wlo1 network)"

# ============================================================
# STEP 6: Update icon theme to Papirus Dark
# ============================================================
log "=== STEP 6: Configuring Papirus Dark icon theme ==="
# Update xsettings for both user and system
for f in "${ROOTFS}/home/frost/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml" \
         "${ROOTFS}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"; do
    if [ -f "$f" ]; then
        sed -i 's/value="Adwaita"/value="Papirus-Dark"/g' "$f"
    fi
done
log "Icon theme set to Papirus-Dark"

# ============================================================
# STEP 7: Configure xfce4-terminal with transparency
# ============================================================
log "=== STEP 7: Configuring terminal transparency ==="
mkdir -p "${ROOTFS}/home/frost/.config/xfce4/terminal"
cat > "${ROOTFS}/home/frost/.config/xfce4/terminal/terminalrc" << 'TERMRC'
[Configuration]
BackgroundMode=TERMINAL_BACKGROUND_TRANSPARENT
BackgroundDarkness=0.85
FontName=Hack 11
MiscAlwaysShowTabs=FALSE
MiscBell=FALSE
MiscBellUrgent=FALSE
MiscBordersDefault=TRUE
MiscCursorBlinks=TRUE
MiscCursorShape=TERMINAL_CURSOR_SHAPE_BLOCK
MiscDefaultGeometry=100x30
MiscInheritGeometry=FALSE
MiscMenubarDefault=TRUE
MiscMouseAutohide=FALSE
MiscMouseWheelZoom=TRUE
ScrollingUnlimited=TRUE
MiscSlimTabs=TRUE
MiscNewTabAdjacent=TRUE
MiscSearchDialogOpacity=100
MiscShowRelaunchDialog=TRUE
MiscRewrapOnResize=TRUE
MiscUseShiftArrowsToScroll=FALSE
MiscTabCloseButtons=TRUE
MiscTabCloseMiddleClick=TRUE
MiscTabPosition=GTK_POS_TOP
MiscHighlightUrls=TRUE
MiscMiddleClickOpensUri=FALSE
MiscCopyOnSelect=FALSE
MiscShowUnsafePasteDialog=TRUE
MiscRightClickAction=TERMINAL_RIGHT_CLICK_ACTION_CONTEXT_MENU
ColorForeground=#e0f0ff
ColorBackground=#0a1628
ColorCursor=#00d4ff
ColorCursorUseDefault=FALSE
ColorPalette=#0a1628;#ff2d2d;#00ff88;#ffb800;#0090c1;#d946ef;#00d4ff;#e0f0ff;#1a3050;#ff6b6b;#33ffaa;#ffd000;#48cae4;#e879f9;#4de8ff;#ffffff
ColorBold=#00d4ff
ColorBoldUseDefault=FALSE
ColorSelection=#1a3050
ColorSelectionUseDefault=FALSE
TabActivityColor=#ff2d2d
TERMRC
chown -R 1000:1000 "${ROOTFS}/home/frost/.config/xfce4/terminal"
log "Terminal configured with transparency and frost colors"

# ============================================================
# STEP 8: Create gtk-3.0/gtk.css for custom styling
# ============================================================
log "=== STEP 8: Creating custom GTK CSS ==="
mkdir -p "${ROOTFS}/home/frost/.config/gtk-3.0"
cat > "${ROOTFS}/home/frost/.config/gtk-3.0/gtk.css" << 'GTKCSS'
/* frOSt Custom GTK3 CSS Overrides */

/* Overall window transparency support */
window {
    background-color: alpha(@theme_bg_color, 0.95);
}

/* Panel styling */
.xfce4-panel {
    background-color: rgba(10, 22, 40, 0.92);
    border-bottom: 1px solid rgba(0, 212, 255, 0.3);
}

/* Tooltip styling */
tooltip {
    background-color: rgba(10, 22, 40, 0.95);
    border: 1px solid rgba(0, 212, 255, 0.4);
    border-radius: 6px;
    color: #e0f0ff;
}

/* Selection color */
*:selected {
    background-color: rgba(0, 144, 193, 0.7);
    color: #ffffff;
}

/* Scrollbar styling */
scrollbar {
    background-color: transparent;
}

scrollbar slider {
    background-color: rgba(0, 212, 255, 0.3);
    border-radius: 4px;
    min-width: 6px;
    min-height: 6px;
}

scrollbar slider:hover {
    background-color: rgba(0, 212, 255, 0.5);
}

/* Button hover effect */
button:hover {
    background-image: linear-gradient(rgba(0, 212, 255, 0.1), rgba(0, 212, 255, 0.05));
}
GTKCSS
chown -R 1000:1000 "${ROOTFS}/home/frost/.config/gtk-3.0"
log "Custom GTK CSS created"

# ============================================================
# STEP 9: Configure xfwm4 for better visual effects
# ============================================================
log "=== STEP 9: Disabling xfwm4 compositor (picom replaces it) ==="
# Disable xfwm4's built-in compositor since picom takes over
for f in "${ROOTFS}/home/frost/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml" \
         "${ROOTFS}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"; do
    if [ -f "$f" ]; then
        sed -i 's/name="use_compositing" type="bool" value="true"/name="use_compositing" type="bool" value="false"/' "$f"
    fi
done
log "xfwm4 compositing disabled (picom handles it now)"

# ============================================================
# STEP 10: Panel styling - transparent dock-style bottom panel
# ============================================================
log "=== STEP 10: Updating panel to bottom dock-style ==="
cat > "${ROOTFS}/home/frost/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml" << 'PANELXML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="dark-mode" type="bool" value="true"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=8;x=960;y=1066"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="icon-size" type="uint" value="24"/>
      <property name="size" type="uint" value="36"/>
      <property name="background-style" type="uint" value="1"/>
      <property name="background-rgba" type="array">
        <value type="double" value="0.039216"/>
        <value type="double" value="0.086275"/>
        <value type="double" value="0.156863"/>
        <value type="double" value="0.88"/>
      </property>
      <property name="enter-opacity" type="uint" value="100"/>
      <property name="leave-opacity" type="uint" value="85"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
        <value type="int" value="3"/>
        <value type="int" value="4"/>
        <value type="int" value="5"/>
        <value type="int" value="6"/>
        <value type="int" value="7"/>
        <value type="int" value="8"/>
        <value type="int" value="9"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="whiskermenu">
      <property name="button-icon" type="string" value="frost-logo"/>
      <property name="button-title" type="string" value="frOSt"/>
      <property name="show-button-title" type="bool" value="true"/>
    </property>
    <property name="plugin-2" type="string" value="separator">
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-3" type="string" value="tasklist">
      <property name="show-handle" type="bool" value="false"/>
      <property name="flat-buttons" type="bool" value="true"/>
      <property name="show-labels" type="bool" value="true"/>
      <property name="grouping" type="uint" value="1"/>
    </property>
    <property name="plugin-4" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-5" type="string" value="pager">
      <property name="rows" type="uint" value="1"/>
      <property name="miniature-view" type="bool" value="true"/>
    </property>
    <property name="plugin-6" type="string" value="separator">
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-7" type="string" value="systray">
      <property name="icon-size" type="int" value="20"/>
      <property name="square-icons" type="bool" value="true"/>
    </property>
    <property name="plugin-8" type="string" value="power-manager-plugin"/>
    <property name="plugin-9" type="string" value="clock">
      <property name="digital-format" type="string" value="%H:%M  |  %a %d %b"/>
      <property name="mode" type="uint" value="2"/>
    </property>
  </property>
</channel>
PANELXML
cp "${ROOTFS}/home/frost/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml" \
   "${ROOTFS}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
chown 1000:1000 "${ROOTFS}/home/frost/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
log "Panel moved to bottom with dock-style transparency"

# ============================================================
# STEP 11: Create missing lightdm data directory
# ============================================================
log "=== STEP 11: Creating missing LightDM directories ==="
mkdir -p "${ROOTFS}/var/lib/lightdm/data"
chown 110:118 "${ROOTFS}/var/lib/lightdm/data" 2>/dev/null || chown lightdm:lightdm "${ROOTFS}/var/lib/lightdm/data" 2>/dev/null || true
log "LightDM data directory created"

# ============================================================
# STEP 12: Ensure all frost user files have correct ownership
# ============================================================
log "=== STEP 12: Fixing file ownership ==="
chown -R 1000:1000 "${ROOTFS}/home/frost"
log "File ownership fixed"

# ============================================================
# STEP 13: Remove verbose boot debug flags
# ============================================================
log "=== STEP 13: Removing debug boot flags ==="
# Remount EFI to update GRUB config
IMAGE_FILE="${BUILD_DIR}/frost.img"
loop_dev=$(losetup --show -fP "${IMAGE_FILE}")
sleep 1
partprobe "${loop_dev}" 2>/dev/null || true
sleep 1
mkdir -p /tmp/efi-grub
mount "${loop_dev}p1" /tmp/efi-grub

# Update GRUB to remove debug flags and add quiet splash
GRUB_CFG="/tmp/efi-grub/boot/grub/grub.cfg"
if [ -f "$GRUB_CFG" ]; then
    # Replace debug loglevel=7 with quiet splash
    sed -i 's/debug loglevel=7/quiet splash/g' "$GRUB_CFG"
    log "GRUB updated: removed debug flags, added quiet splash"
fi

sync
umount /tmp/efi-grub
rmdir /tmp/efi-grub
losetup -d "${loop_dev}"

# ============================================================
# STEP 14: Rebuild squashfs and update image
# ============================================================
log "=== STEP 14: Rebuilding squashfs ==="
mksquashfs "${ROOTFS}" "${BUILD_DIR}/rootfs.squashfs" \
    -comp xz -b 262144 -Xbcj x86 -noappend 2>&1 | tail -3
log "Squashfs size: $(du -h ${BUILD_DIR}/rootfs.squashfs | cut -f1)"

# ============================================================
# STEP 15: Update initramfs with firmware
# ============================================================
log "=== STEP 15: Updating initramfs firmware ==="
INITRAMFS_DIR="${BUILD_DIR}/initramfs"
mkdir -p "${INITRAMFS_DIR}/lib/firmware"
for prefix in QuZ-a0-hr-b0 QuZ-a0-jf-b0 Qu-b0-hr-b0 Qu-b0-jf-b0 Qu-c0-hr-b0 Qu-c0-jf-b0 so-a0-hr-b0 so-a0-gf-a0 so-a0-jf-b0 cc-a0; do
    for f in ${ROOTFS}/lib/firmware/iwlwifi-${prefix}*.ucode; do
        [ -f "$f" ] && cp "$f" "${INITRAMFS_DIR}/lib/firmware/"
    done
done
for f in ${ROOTFS}/lib/firmware/iwlwifi-*.pnvm; do
    [ -f "$f" ] && cp "$f" "${INITRAMFS_DIR}/lib/firmware/"
done
mkdir -p "${INITRAMFS_DIR}/lib/firmware/i915"
for f in ${ROOTFS}/lib/firmware/i915/tgl_*.bin ${ROOTFS}/lib/firmware/i915/icl_*.bin; do
    [ -f "$f" ] && cp "$f" "${INITRAMFS_DIR}/lib/firmware/i915/"
done

# WiFi modules
IWL_SRC="${ROOTFS}/lib/modules/${KVER}/kernel/drivers/net/wireless/intel/iwlwifi"
IWL_DST="${INITRAMFS_DIR}/lib/modules/${KVER}/kernel/drivers/net/wireless/intel/iwlwifi"
mkdir -p "${IWL_DST}"
cp -r "${IWL_SRC}"/* "${IWL_DST}/"
for mod_path in \
    "kernel/net/wireless/cfg80211.ko.xz" \
    "kernel/net/rfkill/rfkill.ko.xz" \
    "kernel/net/mac80211/mac80211.ko.xz" \
    "kernel/lib/crypto/libarc4.ko.xz"; do
    src="${ROOTFS}/lib/modules/${KVER}/${mod_path}"
    if [ -f "$src" ]; then
        dst="${INITRAMFS_DIR}/lib/modules/${KVER}/${mod_path}"
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
    fi
done
depmod -b "${INITRAMFS_DIR}" "${KVER}" 2>/dev/null || true

cd "${INITRAMFS_DIR}"
find . | cpio -o -H newc 2>/dev/null | gzip -9 > "${BUILD_DIR}/initramfs.cpio.gz"
log "Initramfs size: $(du -h ${BUILD_DIR}/initramfs.cpio.gz | cut -f1)"

# ============================================================
# STEP 16: Update disk image partitions
# ============================================================
log "=== STEP 16: Updating disk image ==="
loop_dev=$(losetup --show -fP "${IMAGE_FILE}")
sleep 1
partprobe "${loop_dev}" 2>/dev/null || true
sleep 1

mkdir -p /tmp/efi-update /tmp/root-update
mount "${loop_dev}p1" /tmp/efi-update
mount "${loop_dev}p2" /tmp/root-update

cp "${BUILD_DIR}/rootfs.squashfs" /tmp/root-update/rootfs.squashfs
cp "${BUILD_DIR}/initramfs.cpio.gz" /tmp/efi-update/boot/initramfs.img

log "Rootfs partition usage:"
df -h /tmp/root-update | tail -1
log "EFI partition usage:"
df -h /tmp/efi-update | tail -1

sync
umount /tmp/root-update
umount /tmp/efi-update
rmdir /tmp/root-update /tmp/efi-update
losetup -d "${loop_dev}"

log "============================================"
log "=== DESKTOP FIX + VISUALS COMPLETE =="
log "============================================"
log "Fixes applied:"
log "  1. picom compositor installed (shadows, fading, rounded corners, transparency)"
log "  2. Custom wallpaper generated (dark cyberpunk/frost theme)"
log "  3. xfdesktop config fixed (eDP-1 monitor name)"
log "  4. Conky fixed (own_window_type=override, wlo1 network)"
log "  5. Papirus-Dark icon theme"
log "  6. Terminal transparency with frost colors"
log "  7. Custom GTK CSS overrides"
log "  8. xfwm4 compositor disabled (picom replaces it)"
log "  9. Panel moved to bottom with dock-style"
log "  10. LightDM data directory created"
log "  11. Debug boot flags removed (quiet splash)"
