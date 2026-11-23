#!/bin/zsh
# Builds nxmd, copies it to /Applications and makes it the default app for Markdown files.
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/build.sh

DEST=/Applications/nxmd.app
rm -rf "$DEST"
ditto build/nxmd.app "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"

if command -v duti >/dev/null; then
  duti -s app.nxmd net.daringfireball.markdown all
  echo "nxmd is now the default app for Markdown files."
else
  echo "Installed. To make it the default: brew install duti && ./scripts/install.sh"
  echo "(or Finder: Get Info on any .md file > Open with: nxmd > Change All)"
fi
