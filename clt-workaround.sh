# This machine's Command Line Tools install has a stale duplicate modulemap
# (usr/include/swift/module.modulemap, 2023 copy) that clashes with
# bridging.modulemap and breaks ALL Swift compilation with
# "redefinition of module 'SwiftBridging'". We mask the stale file with a
# VFS overlay instead of modifying system files.
# Permanent fix: reinstall the Command Line Tools (needs admin):
#   sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install
set -euo pipefail
_OVERLAY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.build"
mkdir -p "$_OVERLAY_DIR"
touch "$_OVERLAY_DIR/empty.modulemap"
cat > "$_OVERLAY_DIR/clt-overlay.yaml" <<EOF
{
  "version": 0,
  "roots": [
    {
      "name": "/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap",
      "type": "file",
      "external-contents": "$_OVERLAY_DIR/empty.modulemap"
    }
  ]
}
EOF
SWIFT_EXTRA_FLAGS=(-vfsoverlay "$_OVERLAY_DIR/clt-overlay.yaml")
