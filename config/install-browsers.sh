#!/usr/bin/env bash
# Artifacts-stage download of Playwright's browser binaries. Runs ONCE in the
# Dockerfile's shared `artifacts` stage as root, into /opt/ms-playwright; every
# agent image copies that dir via COPY --link and symlinks the default lookup
# path (~/.cache/ms-playwright) at it — see devstack-install.sh. The agent user
# only ever reads/executes the binaries, so a root-owned a+rX copy is fine.
#
# Baking the browsers means sandboxes never need cdn.playwright.dev at runtime.
#
# The os-release dance: Playwright 1.58 has no build registered for
# "ubuntu26.04-arm64" and refuses before it even tries —
#     ERROR: Playwright does not support chromium on ubuntu26.04-arm64
# It selects its download by reading /etc/os-release, so we present 24.04 for
# the duration. The Ubuntu 24.04 arm64 binaries run fine on 26.04: glibc is
# backward compatible, and 26.04 ships 2.43 against 24.04's 2.39.
# Drop the os-release edit and call `playwright install` directly once
# Playwright registers a resolute build.
set -eux

PLAYWRIGHT_VERSION=1.58.2

export PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
# npx spawns `node`; only /opt/node exists at this point in the artifacts stage.
export PATH=/opt/node/bin:$PATH

cp /etc/os-release /etc/os-release.real
trap 'mv -f /etc/os-release.real /etc/os-release' EXIT
sed -i 's/^VERSION_ID="26.04"/VERSION_ID="24.04"/; s/resolute/noble/g' /etc/os-release

# --only-shell: bake the headless shell (323MB) but NOT headed Chromium
# (602MB). Agents run Playwright headless — tests and screenshots use the
# shell. headless: false has no binary to launch; rebake without --only-shell
# if a workload ever genuinely needs a headed browser. Playwright's own ffmpeg
# (3.3MB) is included for video recording.
npx --yes "playwright@${PLAYWRIGHT_VERSION}" install --only-shell chromium ffmpeg
chmod -R a+rX /opt/ms-playwright
