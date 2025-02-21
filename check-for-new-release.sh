#!/bin/bash

set -e -o pipefail

if [[ $# -gt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  echo "Usage: $(basename "$0") [github api auth token]"
  exit
fi

if [[ $# -eq 1 ]]; then
  auth_header="Authorization: Bearer $1"
fi

BUILD_DIR=temp
SOURCE_ROOT=$(jq -r '.projects.cloudflared.sourceRoot' angular.json)
OUTPUT_DIR=binaries
RELEASE_INFO_PATH="${SOURCE_ROOT}/release-info.json"

# extend go linux build constraint to unix
#update_build_tags() {
#    local file="$1"
#    if [ ! -f "$file" ]; then
#        echo "Error: File '$file' not found!"
#        exit 1
#    fi
#    if grep -q '^//go:build.*\blinux\b' "$file"; then
#        sed -i '/^\/\/go:build/ s/\blinux\b/unix/' "$file"
#        echo "Updated file to include unix build constraint: $file"
#    fi
#}

response=$(curl --fail-with-body --silent --show-error -L \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -H "$auth_header" \
  'https://api.github.com/repos/cloudflare/cloudflared/releases/latest') || (echo "$response" >&2; exit 1)
latest_version=$(<<<"$response" jq -r '.name')
echo "Latest version is $latest_version"

if [[ $(jq "has(\"$latest_version\")" "$RELEASE_INFO_PATH") == 'true' ]]
then
  echo "Release already in repo"
  echo "Quitting..."
  exit
fi

tag_name=$(<<<"$response" jq -r '.tag_name')
if [ -d "$BUILD_DIR" ]
then
  rm -rf "$BUILD_DIR"
fi

git clone --branch "$tag_name" https://github.com/cloudflare/cloudflared.git "$BUILD_DIR"

#$BUILD_DIR/freebsd.patch
wget -o "$BUILD_DIR/freebsd.patch"   https://raw.githubusercontent.com/robvanoostenrijk/cloudflared-freebsd/refs/heads/master/freebsd.patch 
git  apply --check  "$BUILD_DIR/freebsd.patch"

# avoid depending on C code since we don't need it
export CGO_ENABLED=0
export TARGET_OS=freebsd
export TARGET_ARCH=amd64

bash "$BUILD_DIR/.teamcity/install-cloudflare-go.sh"

update_build_tags "$BUILD_DIR/diagnostic/network/collector_unix.go"
update_build_tags "$BUILD_DIR/diagnostic/system_collector_linux.go"

make -C "$BUILD_DIR" cloudflared

executable_name="cloudflared-$TARGET_OS-$latest_version"
executable_path="${BUILD_DIR}/$executable_name"
mv "${BUILD_DIR}/cloudflared" "$executable_path"

output_basename_path="${OUTPUT_DIR}/$executable_name"
output_archive_path="${output_basename_path}.7z"
output_sha1_path="${output_basename_path}.sha1"

7z a -mx=9 "${SOURCE_ROOT}/$output_archive_path" "$executable_path"
shasum -a 1 "$executable_path" | awk '{ printf $1 }' > "${SOURCE_ROOT}/$output_sha1_path"

release_info=$(cat "$RELEASE_INFO_PATH")
jq --arg version "$latest_version" \
    --arg build_date "$(date -uIseconds)" \
    --arg release_date "$(<<<"$response" jq -r '.created_at')" \
    --arg output_archive_path "$output_archive_path" \
    --arg binary_sha1_path "$output_sha1_path" \
    '.[$version] = {
        "buildDate": $build_date,
        "platform": "FreeBSD",
        "releaseDate": $release_date,
        "binary7zipPath": $output_archive_path,
        "binarySHA1Path": $binary_sha1_path
    }' <<<"$release_info" >"$RELEASE_INFO_PATH"

rm -rf "$BUILD_DIR"

git add .
git status
git -c user.email='github-actions[bot]@users.noreply.github.com' -c user.name='github-actions[bot]' commit -m "Add version $latest_version"
git push
