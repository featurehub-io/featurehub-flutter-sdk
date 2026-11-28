#!/usr/bin/env bash
# Fails if a library the client SDK compiles into a browser (or WebAssembly)
# build imports a library that does not exist there. dart:io in particular is
# accepted by dart2js and dart2wasm alike, and only fails when it is used at
# runtime, so the compilers do not catch it.
#
# Libraries that are only reached through a `dart.library.io` conditional
# import (or only by tests) are listed in ALLOWED.
set -euo pipefail
cd "$(dirname "$0")/../.."

PACKAGES=(
  featurehub-openfeatures-client-sdk
  featurehub-openfeatures-common
  featurehub-sse-client
  featurehub-client-api
)

ALLOWED=(
  # chosen by `if (dart.library.io)` in featurehub_sse_client.dart
  featurehub-sse-client/lib/src/http/client_factory_io.dart
  # not part of the library: a server-side encoder used by the tests
  featurehub-sse-client/lib/src/encoder.dart
)

pattern="^[[:space:]]*(import|export)[[:space:]]+['\"](dart:(io|ffi|mirrors|cli|isolate|html|js|js_util|indexed_db|svg|web_audio|web_gl)|package:js/)['\"/]"

found=0
for package in "${PACKAGES[@]}"; do
  while IFS= read -r file; do
    allowed=0
    for ok in "${ALLOWED[@]}"; do
      [[ "$file" == "$ok" ]] && allowed=1
    done
    if [[ $allowed == 0 ]]; then
      echo "::error file=$file::imports a library that is not available in browsers or WebAssembly (use a conditional import):"
      grep -nE "$pattern" "$file"
      found=1
    fi
  done < <(grep -rlE "$pattern" "$package/lib" --include='*.dart' || true)
done

if [[ $found == 1 ]]; then
  exit 1
fi
echo "no web-incompatible imports in ${PACKAGES[*]}"
