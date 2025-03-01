#!/bin/bash

set -e -o pipefail

# Function to print usage information
print_usage() {
  echo "Usage: $(basename "$0") [github api auth token]"
}

# Check for arguments and print usage if needed
if [[ $# -gt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  print_usage
  exit
fi

# Set authorization header if a token is provided
if [[ $# -eq 1 ]]; then
  auth_header="Authorization: Bearer $1"
fi

BUILD_DIR=temp
SOURCE_ROOT=$(jq -r '.projects.cloudflared.sourceRoot' angular.json)
OUTPUT_DIR=binaries
RELEASE_INFO_PATH="${SOURCE_ROOT}/release-info.json"

# Fetch the latest release information from GitHub
response=$(curl --fail-with-body --silent --show-error -L \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -H "$auth_header" \
  'https://api.github.com/repos/cloudflare/cloudflared/releases/latest') || (echo "$response" >&2; exit 1)
latest_version=$(<<<"$response" jq -r '.name')
echo "Latest version is $latest_version"

# Check if the release already exists in the release info file
if [[ $(jq "has(\"$latest_version\")" "$RELEASE_INFO_PATH") == 'true' ]]; then
  echo "Release already in repo"
  echo "Quitting..."
  exit
fi

tag_name=$(<<<"$response" jq -r '.tag_name')

# Remove the build directory if it exists
[ -d "$BUILD_DIR" ] && rm -rf "$BUILD_DIR"

# Clone the repository with the specific tag
git clone --branch "$tag_name" https://github.com/cloudflare/cloudflared.git "$BUILD_DIR"

# Navigate to build directory
cd "$BUILD_DIR"

# Download the patch file
wget -O "freebsd.patch" https://raw.githubusercontent.com/robvanoostenrijk/cloudflared-freebsd/refs/heads/master/freebsd.patch

# Apply the patch with different -p options, automatically accepting the patch
echo "y" | patch -p1 < "freebsd.patch" || \
echo "y" | patch -p0 < "freebsd.patch" || \
echo "y" | patch -p2 < "freebsd.patch" || \
(echo "Error: Failed to apply patch. Please check the patch file and directory structure." && exit 1)

# Set environment variables to avoid depending on C code
export CGO_ENABLED=0
export TARGET_OS=freebsd
export TARGET_ARCH=amd64

# Check if the install script exists
if [ ! -f ".teamcity/install-cloudflare-go.sh" ]; then
  echo "Error: install-cloudflare-go.sh script not found!"
  exit 1
fi

# Run the install script
bash ".teamcity/install-cloudflare-go.sh"

# Build the project
make cloudflared

# Move the built executable
executable_name="cloudflared-$TARGET_OS-$latest_version"
executable_path="cloudflared"
mv "$executable_path" "../$executable_name"

# Navigate back to the source root
cd ..

# Create archive and checksum
output_basename_path="${OUTPUT_DIR}/$executable_name"
output_archive_path="${output_basename_path}.7z"
output_sha1_path="${output_basename_path}.sha1"

7z a -mx=9 "$output_archive_path" "$executable_name"
shasum -a 1 "$executable_name" | awk '{ printf $1 }' > "$output_sha1_path"

# Update release information
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

# Clean up build directory
rm -rf "$BUILD_DIR"

# Commit and push changes to the repository
git add .
git status
git -c user.email='github-actions[bot]@users.noreply.github.com' -c user.name='github-actions[bot]' commit -m "Add version $latest_version"
git push
