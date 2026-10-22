#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# One-shot installer: rebuild the Twelve Actors plugin from source and install it.
# Run as root:
#   sudo bash $HERE/install-all.sh
HERE=$(cd "$(dirname "$0")" && pwd)
set -euo pipefail

echo "############  Twelve Actors plugin (timer validity fix + watchdog)  ############"
bash $HERE/install-source-build.sh

echo
echo "== done =="
echo "The plugin is live immediately."
