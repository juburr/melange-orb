#!/bin/bash

# Convenience script, not used by directly by the production orb, but
# for development purposes when adding SHA-512 checksums to the lookup
# table in install.sh.

set -e
set +o history

# Fetch CLI arguments
# Can also be set as environment variables.
while getopts :v: flag
do
    case "${flag}" in
        v) VERSION=${OPTARG};;
        *) echo "Invalid option: -${OPTARG}" >&2; exit 1;;
    esac
done

# Validate input arguments
if [[ -z "${VERSION}" ]]; then
  echo "Must specify a version number."
  echo "Usage: $0 -v 1.0.0"
  echo "Alternatively: VERSION=1.0.0 $0"
  exit 1
fi

# Download the specified version and get the SHA-512 checksum of
# the melange binary inside. Suppress output for readability; this is
# dev script, so simply re-enable output if you need to debug anything.
cd /tmp
wget "https://github.com/chainguard-dev/melange/releases/download/v${VERSION}/melange_${VERSION}_linux_amd64.tar.gz" -O /tmp/melange.tar.gz -q
tar zxvf /tmp/melange.tar.gz "melange_${VERSION}_linux_amd64/melange" --strip 1 > /dev/null 2>&1
CHECKSUM=$(sha512sum /tmp/melange | awk '{ print $1 }')
echo "[\"${VERSION}\"]=\"${CHECKSUM}\""
rm /tmp/melange
rm /tmp/melange.tar.gz
