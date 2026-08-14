#!/usr/bin/env bash
# Downloads Playwright's browser binaries into the image. Run as ROOT from the
# Dockerfile; drops to `agent` for the download itself, because
# PLAYWRIGHT_BROWSERS_PATH defaults to ~/.cache/ms-playwright and the binaries
# must be owned by the runtime user. Deliberately avoids sudo, which is not
# guaranteed to be configured for `agent` during a docker build.
#
# Baking the browsers means sandboxes never need cdn.playwright.dev at runtime.
#
# The os-release dance: Playwright 1.58 has no build registered for
# "ubuntu26.04-arm64" and refuses before it even tries —
#     ERROR: Playwright does not support chromium on ubuntu26.04-arm64
# It selects its download by reading /etc/os-release, so we present 24.04 for
# the duration. The Ubuntu 24.04 arm64 binaries run fine on 26.04: glibc is
# backward compatible, and 26.04 ships 2.43 against 24.04's 2.39.
# Delete this file and call `playwright install` directly once Playwright
# registers a resolute build.
set -eux

PLAYWRIGHT_VERSION=1.58.2

cp /etc/os-release /etc/os-release.real
trap 'mv -f /etc/os-release.real /etc/os-release' EXIT
sed -i 's/^VERSION_ID="26.04"/VERSION_ID="24.04"/; s/resolute/noble/g' /etc/os-release

runuser -u agent -- env HOME=/home/agent \
  /usr/local/bin/npx --yes "playwright@${PLAYWRIGHT_VERSION}" install chromium ffmpeg
