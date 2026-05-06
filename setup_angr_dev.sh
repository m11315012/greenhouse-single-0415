#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANGR_DEV_DIR="$SCRIPT_DIR/angr-dev"

echo "[1/3] Cloning angr-dev..."
if [ -d "$ANGR_DEV_DIR" ]; then
    echo "  angr-dev already exists, skipping clone."
else
    git clone https://github.com/angr/angr-dev.git "$ANGR_DEV_DIR"
    echo "  Done."
fi

echo "[2/3] Cloning angr sub-repos..."
cd "$ANGR_DEV_DIR"
./setup.sh -C -D "archinfo pyvex cle claripy ailment angr angr-management archr binaries"
echo "  Done."

echo "[3/3] Patching pyproject.toml files (PEP 639 -> PEP 621)..."
python3 "$SCRIPT_DIR/patch_pyproject.py" "$ANGR_DEV_DIR"
echo "  Done."

echo ""
echo "All done. angr-dev is ready at: $ANGR_DEV_DIR"
