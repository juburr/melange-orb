#!/bin/bash
#
# Writes a fresh APKINDEX.tar.gz for each architecture directory under
# packages_dir with melange index, for the index command, listing every APK
# in it and signed like build's. Use it when the packages in a directory came
# from more than one build, such as parallel jobs whose packages_dir were
# combined with a workspace, so its index lists them all.

set -euo pipefail
# The signing key can come from an environment variable; never trace it.
set +o xtrace

if [[ -z "${SCRIPT_MELANGE_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_MELANGE_LIB is not set. The command passes the orb's lib/melange.sh in it." >&2
    exit 1
fi
eval "${SCRIPT_MELANGE_LIB}"

PACKAGES_DIR=$(melange_subst "${PARAM_PACKAGES_DIR}")
ARCH=$(melange_subst "${PARAM_ARCH}")
SIGNING_KEY=$(melange_subst "${PARAM_SIGNING_KEY}")
SIGNING_KEY_ENV_VAR=$(melange_subst "${PARAM_SIGNING_KEY_ENV_VAR}")

melange_require
if [[ -z "${PACKAGES_DIR}" || ! -d "${PACKAGES_DIR}" ]]; then
    echo "ERROR: packages_dir '${PACKAGES_DIR}' is not a directory." >&2
    exit 1
fi

# The architectures to index: those named, each of which must hold APKs, or
# else every directory under packages_dir that holds any.
ARCHES=()
if [[ -n "${ARCH}" ]]; then
    melange_list "${ARCH}"
    for arch in ${MELANGE_LIST[@]+"${MELANGE_LIST[@]}"}; do
        if [[ ! "${arch}" =~ ^[a-z0-9_]+$ ]]; then
            echo "ERROR: arch must be empty or architectures separated by commas, such as x86_64,aarch64, not '${ARCH}'." >&2
            exit 1
        fi
        ARCHES+=("${arch}")
    done
else
    for dir in "${PACKAGES_DIR}"/*/; do
        dir=${dir%/}
        if [[ -d "${dir}" ]] && compgen -G "${dir}/*.apk" > /dev/null; then
            ARCHES+=("${dir##*/}")
        fi
    done
    if [[ ${#ARCHES[@]} -eq 0 ]]; then
        echo "ERROR: No directory under ${PACKAGES_DIR} holds any APKs." >&2
        exit 1
    fi
fi

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
melange_signing_key "${SIGNING_KEY}" "${SIGNING_KEY_ENV_VAR}" "${WORK}"
if [[ -z "${MELANGE_SIGNING_KEY}" ]]; then
    echo "WARN: signing_key is empty, so the indexes are not signed. apko refuses an unsigned index unless it ignores signatures." >&2
fi

for arch in "${ARCHES[@]}"; do
    dir="${PACKAGES_DIR}/${arch}"
    APKS=()
    if [[ -d "${dir}" ]]; then
        while IFS= read -r apk; do
            APKS+=("${apk}")
        done < <(find "${dir}" -mindepth 1 -maxdepth 1 -type f -name '*.apk' | LC_ALL=C sort)
    fi
    if [[ ${#APKS[@]} -eq 0 ]]; then
        echo "ERROR: ${dir} holds no APKs to index." >&2
        exit 1
    fi
    ARGS=(index --arch "${arch}" --output "${dir}/APKINDEX.tar.gz")
    if [[ -n "${MELANGE_SIGNING_KEY}" ]]; then
        ARGS+=(--signing-key "${MELANGE_SIGNING_KEY}")
    fi
    melange_run melange "${ARGS[@]}" "${APKS[@]}"
    echo "Indexed ${#APKS[@]} package(s) in ${dir}/APKINDEX.tar.gz."
done
