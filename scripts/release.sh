#!/bin/zsh
# Copyright (C) 2026 romkas228
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
projectRoot="${0:A:h:h}"
exec /usr/bin/python3 "$projectRoot/scripts/release.py" "$@"
