#!/bin/bash
#
# Generates an RSA key pair for signing packages with melange keygen, for the
# keygen command: the private key at signing_key, readable only by this user,
# and the public key next to it with .pub appended. An existing key is never
# replaced.

set -euo pipefail

if [[ -z "${SCRIPT_MELANGE_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_MELANGE_LIB is not set. The command passes the orb's lib/melange.sh in it." >&2
    exit 1
fi
eval "${SCRIPT_MELANGE_LIB}"

SIGNING_KEY=$(melange_subst "${PARAM_SIGNING_KEY}")
KEY_SIZE=$(melange_subst "${PARAM_KEY_SIZE}")

melange_require
if [[ -z "${SIGNING_KEY}" || "${SIGNING_KEY}" == -* || "${SIGNING_KEY}" == */ ]]; then
    echo "ERROR: signing_key must be the path of the private key file to write, not '${SIGNING_KEY}'." >&2
    exit 1
fi
if [[ ! "${KEY_SIZE}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: key_size must be a number of bits, such as 4096, not '${KEY_SIZE}'." >&2
    exit 1
fi
# melange keygen replaces whatever is there, which could be a real key.
for file in "${SIGNING_KEY}" "${SIGNING_KEY}.pub"; do
    if [[ -e "${file}" || -L "${file}" ]]; then
        echo "ERROR: ${file} already exists. Use the existing key, or remove it first." >&2
        exit 1
    fi
done
if [[ "${SIGNING_KEY}" == */* ]]; then
    mkdir -p "${SIGNING_KEY%/*}"
fi

# melange creates both files with mode 0666 less the umask.
(
    umask 077
    melange_run melange keygen --key-size "${KEY_SIZE}" "${SIGNING_KEY}"
)
chmod 644 "${SIGNING_KEY}.pub"
echo "Wrote the private key ${SIGNING_KEY} and the public key ${SIGNING_KEY}.pub."
