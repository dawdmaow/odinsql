#!/usr/bin/env bash
set -euo pipefail

# mkdir -p web

odin_js="$(odin root)/core/sys/wasm/js/odin.js"
# cp "$odin_js" web/odin.js
cp "$odin_js" odin.js

# TODO: remove -debug when done testing
odin build . -target:js_wasm32 -out:index.wasm -debug

echo "WASM build complete: index.wasm"
