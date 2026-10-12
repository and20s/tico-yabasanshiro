#!/bin/bash
# Overwrites the "What's New" text of the version being prepared on App Store
# Connect, from release_notes/app_store_release_notes.txt.
#
# Reads the App Store Connect API key from the project's GitLab CI variables,
# the same way tools/upload_screenshots.sh does. Requires `glab auth login`.
#
# Usage: tools/upload_release_notes.sh [lite] [--apply]
#
# Without --apply it prints what would be sent and writes nothing. Nothing but
# the What's New text is ever touched: no binary, screenshots, description or
# keywords.
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

dry_run=true
args=()
for a in "$@"; do
  case "$a" in
    # fastlane hands options through as strings, and "false" is truthy in Ruby,
    # so lite is only passed when it is actually wanted.
    lite)    args+=("lite:true") ;;
    --apply) dry_run=false ;;
    *)       echo "unknown argument: $a" >&2; exit 1 ;;
  esac
done
args+=("dry_run:$dry_run")

bundle exec fastlane upload_release_notes ${args[@]+"${args[@]}"}
