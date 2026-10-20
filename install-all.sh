#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# One-shot installer: rebuild the Twelve Actors plugin from source, install it, then
# install the nine improved RCBot2 waypoint files. Run as root:
#   sudo bash $HERE/install-all.sh
HERE=$(cd "$(dirname "$0")" && pwd)
set -euo pipefail

echo "############ 1/2  Twelve Actors plugin (timer validity fix + watchdog) ############"
bash $HERE/install-source-build.sh

echo
echo "############ 2/2  RCBot2 waypoints (defend/crouch coverage) ############"
bash $HERE/install-waypoints.sh

echo
echo "== done =="
echo "Waypoints take effect at the next map change; the plugin is live immediately."
