#!/bin/sh
# Local entry point for the same complete macOS/Xcode flow used by Actions.
# Outputs: build/ci/ThemeBoard.app and dist/*.deb (App + optional arm64e engine).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -ne 0 ]; then
  printf '%s\n' 'Usage: sh tools/build-app.sh' >&2
  exit 2
fi
if [ "$(uname -s)" != "Darwin" ]; then
  printf '%s\n' 'error: Original Theseus needs Apple Swift, the iPhoneOS SDK, and the Metal toolchain. Linux/iSH cannot build this app. Run sh tools/build-app.sh on macOS with full Xcode, or manually dispatch .github/workflows/build.yml.' >&2
  exit 1
fi
exec /bin/bash "$ROOT/tools/ci-build.sh"
