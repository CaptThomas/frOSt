#!/bin/bash
# Startup wrapper for frOSt spinning logo with better error handling

LOG_FILE="$HOME/.frost-logo-startup.log"

# Log to file
exec 3>&1 4>&2 >> "$LOG_FILE" 2>&1

echo "[$(date)] Starting frost-spinning-logo wrapper..."

# Wait for compositor and display to be ready
sleep 2

# Check if DISPLAY is set
if [ -z "$DISPLAY" ]; then
    echo "ERROR: DISPLAY not set, cannot start logo"
    exit 1
fi

# Check if logo image exists
LOGO_PATH="/usr/share/backgrounds/frost/frost-logo.png"
if [ ! -f "$LOGO_PATH" ]; then
    echo "WARNING: Logo not found at $LOGO_PATH"
    # Try to find it
    for path in ~/.local/share/backgrounds/frost-logo.png /tmp/frost-logo.png; do
        if [ -f "$path" ]; then
            LOGO_PATH="$path"
            echo "Found logo at: $LOGO_PATH"
            break
        fi
    done
fi

# Run the logo with options
echo "Launching with: /usr/local/bin/frost-spinning-logo --size 190 --fps 24 --x-offset 30 --position center-left --degrees-step 0.35"
exec /usr/local/bin/frost-spinning-logo --size 190 --fps 24 --x-offset 30 --position center-left --degrees-step 0.35

echo "ERROR: Logo launcher exited with code $?"
