#!/bin/bash
# Removes all .build directories under /Applications/iPhonePhotosBackup

TARGET_DIR="/Applications/iPhonePhotosBackup"

if [ ! -d "$TARGET_DIR" ]; then
    echo "Error: '$TARGET_DIR' does not exist."
    exit 1
fi

cd "$TARGET_DIR" || exit 1

echo "Cleaning .build directories in $TARGET_DIR..."
find . -name ".build" -type d -exec rm -rf {} +
echo "Done."
