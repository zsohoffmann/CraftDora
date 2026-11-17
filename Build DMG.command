#!/bin/bash
# Double-click to build CraftDora and create the DMG.
cd "$(dirname "$0")"
bash build.sh
echo
read -n 1 -s -r -p "Press any key to close…"
