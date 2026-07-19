#!/bin/sh
# Regenerates MobileSeal.xcodeproj from project.yml. Commit the
# regenerated project together with the project.yml change.
set -eu
cd "$(dirname "$0")/.."
xcodegen generate
