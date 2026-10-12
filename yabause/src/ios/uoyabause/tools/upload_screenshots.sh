#!/bin/bash
# Uploads the captured screenshots to App Store Connect.
#
# The App Store Connect API key lives in the project's GitLab CI variables,
# which is the one place it is already kept; this reads it from there at run
# time rather than adding a second copy on disk. Requires `glab auth login`.
#
# Usage: tools/upload_screenshots.sh [lite] [screenshots path]
#
# With no path it uploads the simulator screenshots snapshot captured; pass
# ./screenshots/marketing/YabaSnashiro for the set tools/store_screenshots
# builds from the design canvas.
set -euo pipefail
cd "$(dirname "$0")/.."

for v in APP_STORE_CONNECT_API_KEY_KEY_ID APP_STORE_CONNECT_API_KEY_ISSUER_ID \
         APP_STORE_CONNECT_API_KEY_KEY APP_STORE_CONNECT_API_KEY_IS_KEY_CONTENT_BASE64; do
  value=$(glab variable get "$v" 2>/dev/null) || {
    echo "could not read $v from GitLab; is glab logged in?" >&2
    exit 1
  }
  export "$v=$value"
done

# Only pass lite when it is wanted: fastlane hands the value through as a
# string, and "false" is truthy in Ruby, which would target the Lite app.
args=()
case "${1:-}" in
  lite) args+=("lite:true"); shift ;;
  "")   [ $# -gt 0 ] && shift ;;   # the caller's placeholder for "not lite"
esac

[ -n "${1:-}" ] && args+=("path:$1")

bundle exec fastlane upload_screenshots ${args[@]+"${args[@]}"}
