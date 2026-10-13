#!/bin/bash
set -euo pipefail

# Push a depth model into Hypnos's Documents folder on the device, where
# CoreMLDepthProvider loads it from (see DepthProvider.findModelURL). This keeps
# the ~186MB model out of the app bundle (fast builds) and lets you swap models
# without rebuilding — push a different .mlmodelc/.mlpackage and relaunch.
#
# Usage:
#   ./scripts/push-depth-model.sh path/to/Model.mlmodelc      # precompiled (fast load)
#   ./scripts/push-depth-model.sh path/to/Model.mlpackage     # compiled on-device first launch
#
# A precompiled .mlmodelc loads immediately; an .mlpackage is compiled + cached
# on the device on first launch. Generate Small/Base/Large .mlpackages at any
# resolution with scripts/convert-depth-model.py (handles the fp16-overflow
# wave artifact via a validated precision ladder).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="$SCRIPT_DIR/build-signing.conf"

MODEL_SRC="${1:-}"
if [[ -z "$MODEL_SRC" || ! -e "$MODEL_SRC" ]]; then
    echo "ERROR: pass a path to a .mlmodelc or .mlpackage" >&2
    exit 1
fi

REQUESTED_DEVICE_NAME="${DEVICE_NAME:-}"
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"
DEVICE_NAME="${REQUESTED_DEVICE_NAME:-${DEVICE_NAME:-AVP}}"
BUNDLE_ID="${BUNDLE_ID:-${BUILD_BUNDLE_ID:-com.illixion.hypnos}}"

# devicectl accepts a device name or identifier directly. Its human-readable
# table changes between Xcode versions (and names can contain spaces).

BASENAME="$(basename "$MODEL_SRC")"
echo "==> Pushing $BASENAME to $DEVICE_NAME Documents/ ..."
xcrun devicectl device copy to \
    --device "$DEVICE_NAME" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    --source "$(cd "$(dirname "$MODEL_SRC")" && pwd)/$BASENAME" \
    --destination "Documents/$BASENAME"

echo "Done. Relaunch Hypnos to load it."
