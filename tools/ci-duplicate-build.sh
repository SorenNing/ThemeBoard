#!/bin/bash
set -euo pipefail
# Each engine is compiled and signed for its actual target, never relabelled.
TB_PACKAGE_ARCH=iphoneos-arm64 TB_ENGINE_ARCH=arm64 bash tools/ci-duplicate-variant.sh
TB_PACKAGE_ARCH=iphoneos-arm64e TB_ENGINE_ARCH=arm64e bash tools/ci-duplicate-variant.sh
