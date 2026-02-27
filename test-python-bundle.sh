#!/bin/bash
# Test that the Python bundle in the initramfs actually works
set -e
BUILD=/root/frost-pyinit-build
INITRAMFS=$BUILD/initramfs

echo "=== Testing Python bundle in initramfs ==="

# Check if the initramfs was already built
if [ ! -d "$INITRAMFS" ]; then
    echo "ERROR: initramfs dir not found at $INITRAMFS"
    echo "Run rebuild-pyinit.sh first"
    exit 1
fi

echo "Files in Python bundle:"
ls -la $INITRAMFS/usr/lib/frost-python/bin/
echo ""

echo "Python libs:"
ls $INITRAMFS/usr/lib/frost-python/lib/ | head -20
echo ""

echo "Python stdlib modules:"
ls $INITRAMFS/usr/lib/frost-python/lib/python*/ 2>/dev/null | head -20
echo ""

echo "Encodings dir:"
ls $INITRAMFS/usr/lib/frost-python/lib/python*/encodings/ 2>/dev/null | head -10
echo ""

echo "frost_init.py exists:"
ls -la $INITRAMFS/frost_init.py 2>/dev/null || echo "NOT FOUND"
echo ""

echo "frost_init wrapper:"
cat $INITRAMFS/frost_init
echo ""

echo "init shim:"
cat $INITRAMFS/init
echo ""

# Try running Python with the bundle using chroot-like approach
echo "=== Testing Python execution ==="
export PYTHONHOME=$INITRAMFS/usr/lib/frost-python
PYVER=$(ls $INITRAMFS/usr/lib/frost-python/lib/ | grep python | head -1)
export PYTHONPATH=$INITRAMFS/usr/lib/frost-python/lib/$PYVER
export PYTHONDONTWRITEBYTECODE=1
export LD_LIBRARY_PATH=$INITRAMFS/usr/lib/frost-python/lib

echo "PYTHONHOME=$PYTHONHOME"
echo "PYTHONPATH=$PYTHONPATH"
echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
echo ""

echo "Testing 'python3 -c print(hello)'..."
$INITRAMFS/usr/lib/frost-python/bin/python3 -c "print('Hello from frOSt Python init!')" 2>&1 || echo "FAILED"

echo ""
echo "Testing 'import os, sys, json, time'..."
$INITRAMFS/usr/lib/frost-python/bin/python3 -c "
import os, sys, json, time
print(f'Python {sys.version}')
print(f'Modules: os, sys, json, time - OK')
print(f'Platform: {sys.platform}')
" 2>&1 || echo "FAILED"

echo ""
echo "Testing 'import subprocess'..."
$INITRAMFS/usr/lib/frost-python/bin/python3 -c "
import subprocess
print('subprocess module - OK')
" 2>&1 || echo "FAILED"

echo ""
echo "Testing frost_init.py syntax..."
$INITRAMFS/usr/lib/frost-python/bin/python3 -c "
import py_compile
py_compile.compile('$INITRAMFS/frost_init.py', doraise=True)
print('frost_init.py - syntax OK')
" 2>&1 || echo "FAILED"

echo ""
echo "=== Test complete ==="
