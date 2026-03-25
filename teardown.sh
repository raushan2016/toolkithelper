#!/bin/bash

# Exit on any error
set -e

# Change to the directory where this script is located
cd "$(dirname "${BASH_SOURCE[0]}")"

if [ ! -f "cluster.conf" ]; then
    echo "Error: cluster.conf not found. Please ensure your configuration file is present."
    exit 1
fi
source cluster.conf

export PATH="$PWD:$HOME/.local/bin:$PATH"

if [ ! -d "$DEPLOYMENT_NAME" ]; then
    echo "Error: Deployment directory '$DEPLOYMENT_NAME' not found."
    echo "Cannot teardown an environment that hasn't been deployed locally."
    exit 1
fi

if ! command -v gcluster &> /dev/null; then
    echo "Error: gcluster could not be found. Please ensure it is installed and in your PATH."
    exit 1
fi

echo "==============================================================="
echo "WARNING: Tearing down deployment $DEPLOYMENT_NAME"
echo "==============================================================="
echo ""
echo "Initiating teardown via gcluster destroy..."

gcluster destroy "$DEPLOYMENT_NAME" --auto-approve

echo "==============================================================="
echo "Teardown successful."
echo "==============================================================="
