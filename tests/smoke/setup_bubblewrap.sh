#!/bin/bash

# Prepares an Ubuntu machine executor for melange's bubblewrap runner.
#
# Ubuntu 24.04 restricts unprivileged user namespaces with AppArmor
# (kernel.apparmor_restrict_unprivileged_userns=1), so bwrap fails with
# "setting up uid map: Permission denied". Rather than lifting the restriction
# for every program, load a profile that allows user namespaces for bwrap only.
# See https://github.com/chainguard-dev/melange/issues/1508.

set -euo pipefail

sudo apt-get update
sudo apt-get install -y bubblewrap

if [[ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2> /dev/null || echo 0)" == "1" ]]; then
    echo "Unprivileged user namespaces are restricted; allowing them for bwrap."
    sudo tee /etc/apparmor.d/bwrap-userns > /dev/null <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile bwrap-userns /usr/bin/bwrap flags=(unconfined) {
  userns,
}
EOF
    sudo apparmor_parser -r /etc/apparmor.d/bwrap-userns
fi

# Fail early, with a clear error, if bwrap still cannot create a user namespace.
bwrap --unshare-user --ro-bind / / true
echo "bubblewrap can create user namespaces."
