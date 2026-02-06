#!/bin/bash

# Semantic Release Hook - Update version in script.sh
# This script is called by semantic-release to update the VERSION in script.sh

if [ -z "$1" ]; then
  echo "Error: Version number required"
  exit 1
fi

NEW_VERSION="$1"

# Update VERSION in script.sh
sed -i.bak "s/^VERSION=\".*\"/VERSION=\"$NEW_VERSION\"/" script.sh && rm script.sh.bak

echo "Updated script.sh to version $NEW_VERSION"
