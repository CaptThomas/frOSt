#!/usr/bin/env python3
"""frOSt transparent spinning desktop logo widget.

This runs as a tiny always-on desktop overlay in XFCE and draws a rotating
transparent PNG so the logo feels alive without blocking normal workflow.
"""

import argparse
import math
import os
import signal
import sys
import logging

# Setup logging
log_file = os.path.expanduser("~/.frost-logo.log")
logging.basicConfig(
    level=logging.DEBUG,
    format="[%(asctime)s] %(levelname)s: %(message)s",
    handlers=[
        logging.FileHandler(log_file),
        logging.StreamHandler(sys.stderr),
    ],
)
logger = logging.getLogger(__name__)

logger.info("frost-spinning-logo starting...")

try:
    import gi  # type: ignore[import-not-found]
    logger.debug("gi module imported")
except ImportError as exc:
    logger.error(f"missing python3-gi (Gtk bindings): {exc}")
    print(
        "[frost-logo] missing python3-gi (Gtk bindings). Install python3-gi and gir1.2-gtk-3.0.",
        file=sys.stderr,
    )
    raise SystemExit(1) from exc

gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, GLib, GdkPixbuf, Gtk, cairo  # type: ignore[import-not-found]

logger.debug("gtk bindings imported successfully")


class SpinningLogoWindow(Gtk.Window):
    def __init__(
        self,
        image_path: str,
        size: int,
        fps: int,
        x_offset: int,
        y_offset: int,
        position: str,
        degrees_step: float,
    ) -> None:
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.set_title("frOSt Desktop Logo")
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_app_paintable(True)
        self.set_accept_focus(False)
        self.stick()
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_keep_below(True)
        self.set_type_hint(Gdk.WindowTypeHint.DESKTOP)

        self.connect("destroy", Gtk.main_quit)
        self.connect("draw", self.on_draw)
        self.connect("screen-changed", self.on_screen_changed)

        self.size = max(64, size)
        self.fps = max(10, fps)
        self.x_offset = max(8, x_offset)
        self.y_offset = max(8, y_offset)
        self.position = position
        self.degrees_step = max(0.05, degrees_step)
        self.angle_deg = 0.0

        logger.info(f"Loading logo from: {image_path}")
        
        # Try primary path first, then fallback options
        search_paths = [
            image_path,
            os.path.expanduser("~/.local/share/backgrounds/frost-logo.png"),
            "/tmp/frost-logo.png",
        ]
        
        actual_path = None
        for path in search_paths:
            if os.path.exists(path):
                actual_path = path
                logger.info(f"Found logo at: {actual_path}")
                break
        
        if not actual_path:
            logger.error(f"Logo image not found in any location: {search_paths}")
            raise FileNotFoundError(f"Image not found in any location: {search_paths}")

        try:
            self.source_pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(
                actual_path,
                self.size,
                self.size,
                True,
            )
            logger.info(f"Logo loaded successfully, size: {self.size}x{self.size}")
        except Exception as exc:
            logger.error(f"Failed to load pixbuf: {exc}")
            raise

        self.set_default_size(self.size, self.size)
        self.set_size_request(self.size, self.size)
        self.on_screen_changed(self, None)
        self.position_on_primary_monitor()

        interval_ms = int(1000 / self.fps)
        GLib.timeout_add(interval_ms, self.tick)

    def on_screen_changed(self, widget: Gtk.Widget, old_screen: Gdk.Screen) -> None:
        screen = widget.get_screen()
        visual = screen.get_rgba_visual()
        if visual and screen.is_composited():
            widget.set_visual(visual)

    def position_on_primary_monitor(self) -> None:
        screen = self.get_screen()
        monitor_idx = screen.get_primary_monitor()
        if monitor_idx < 0:
            monitor_idx = 0
        monitor = screen.get_monitor_geometry(monitor_idx)

        if self.position == "center-right":
            x = monitor.x + monitor.width - self.size - self.x_offset
            y = monitor.y + (monitor.height - self.size) // 2
        elif self.position == "center-left":
            x = monitor.x + self.x_offset
            y = monitor.y + (monitor.height - self.size) // 2
        else:
            x = monitor.x + self.x_offset
            y = monitor.y + monitor.height - self.size - self.y_offset
        self.move(x, y)

    def tick(self) -> bool:
        self.angle_deg = (self.angle_deg + self.degrees_step) % 360.0
        self.queue_draw()
        return True

    def on_draw(self, widget: Gtk.Widget, cr: cairo.Context) -> bool:
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0.0, 0.0, 0.0, 0.0)
        cr.paint()
        cr.set_operator(cairo.OPERATOR_OVER)

        center = self.size / 2.0
        angle = math.radians(self.angle_deg)

        cr.save()
        cr.translate(center, center)
        cr.rotate(angle)

        Gdk.cairo_set_source_pixbuf(
            cr,
            self.source_pixbuf,
            -self.source_pixbuf.get_width() / 2.0,
            -self.source_pixbuf.get_height() / 2.0,
        )
        cr.paint_with_alpha(0.34)
        cr.restore()

        return False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run frOSt spinning desktop logo.")
    parser.add_argument(
        "--image",
        default="/usr/share/backgrounds/frost/frost-logo.png",
        help="Path to transparent logo image.",
    )
    parser.add_argument("--size", type=int, default=180, help="Logo size in pixels.")
    parser.add_argument("--fps", type=int, default=40, help="Frame update rate.")
    parser.add_argument("--x-offset", type=int, default=24, help="Distance from left edge.")
    parser.add_argument("--y-offset", type=int, default=48, help="Distance from bottom edge.")
    parser.add_argument(
        "--position",
        choices=["bottom-left", "center-left", "center-right"],
        default="bottom-left",
        help="Logo placement on the primary monitor.",
    )
    parser.add_argument(
        "--degrees-step",
        type=float,
        default=1.2,
        help="Rotation step in degrees per frame.",
    )
    return parser.parse_args()


def main() -> int:
    logger.info("main() starting")
    args = parse_args()
    logger.info(f"Arguments: image={args.image}, size={args.size}, position={args.position}")

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: Gtk.main_quit())

    try:
        logger.info("Creating SpinningLogoWindow...")
        win = SpinningLogoWindow(
            args.image,
            args.size,
            args.fps,
            args.x_offset,
            args.y_offset,
            args.position,
            args.degrees_step,
        )
        logger.info("Window created successfully")
    except Exception as exc:  # Keep failure explicit for desktop debugging.
        logger.exception(f"Failed to start logo: {exc}")
        print(f"[frost-logo] failed to start: {exc}", file=sys.stderr)
        return 1

    logger.info("Showing window and starting main loop")
    win.show_all()
    Gtk.main()
    logger.info("Main loop ended")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
