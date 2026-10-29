#!/bin/bash
#
# Builds APK packages with melange build, for the build command: signed with
# a key file or a key from an environment variable, for this machine's
# architecture unless arch says otherwise, into out_dir/<arch>/ with a signed
# APKINDEX.tar.gz.

set -euo pipefail
# The signing key can come from an environment variable; never trace it.
set +o xtrace

if [[ -z "${SCRIPT_MELANGE_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_MELANGE_LIB is not set. The command passes the orb's lib/melange.sh in it." >&2
    exit 1
fi
eval "${SCRIPT_MELANGE_LIB}"

CONFIG=$(melange_subst "${PARAM_CONFIG}")
ARCH=$(melange_subst "${PARAM_ARCH}")
RUNNER=$(melange_subst "${PARAM_RUNNER}")
SIGNING_KEY=$(melange_subst "${PARAM_SIGNING_KEY}")
SIGNING_KEY_ENV_VAR=$(melange_subst "${PARAM_SIGNING_KEY_ENV_VAR}")
SOURCE_DIR=$(melange_subst "${PARAM_SOURCE_DIR}")
OUT_DIR=$(melange_subst "${PARAM_OUT_DIR}")
KEYRING_APPEND=$(melange_subst "${PARAM_KEYRING_APPEND}")
REPOSITORY_APPEND=$(melange_subst "${PARAM_REPOSITORY_APPEND}")
PACKAGE_APPEND=$(melange_subst "${PARAM_PACKAGE_APPEND}")
PIPELINE_DIRS=$(melange_subst "${PARAM_PIPELINE_DIRS}")
ENV_FILE=$(melange_subst "${PARAM_ENV_FILE}")
VARS_FILE=$(melange_subst "${PARAM_VARS_FILE}")
NAMESPACE=$(melange_subst "${PARAM_NAMESPACE}")
GENERATE_INDEX=$(melange_bool generate_index "$(melange_subst "${PARAM_GENERATE_INDEX}")")
EXTRA_ARGS=$(melange_subst "${PARAM_EXTRA_ARGS}")

melange_require
melange_runner "${RUNNER}"
if [[ ! -f "${CONFIG}" ]]; then
    echo "ERROR: The melange configuration ${CONFIG} does not exist." >&2
    exit 1
fi
if [[ -z "${OUT_DIR}" ]]; then
    echo "ERROR: out_dir must not be empty." >&2
    exit 1
fi
if [[ -n "${SOURCE_DIR}" && ! -d "${SOURCE_DIR}" ]]; then
    echo "ERROR: source_dir ${SOURCE_DIR} is not a directory." >&2
    exit 1
fi
melange_words extra_args "${EXTRA_ARGS}"
melange_arch_args "${ARCH}"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
melange_signing_key "${SIGNING_KEY}" "${SIGNING_KEY_ENV_VAR}" "${WORK}"

ARGS=(build "${CONFIG}" --runner "${RUNNER}" --out-dir "${OUT_DIR}")
ARGS+=(${MELANGE_ARCH_ARGS[@]+"${MELANGE_ARCH_ARGS[@]}"})
if [[ -n "${MELANGE_SIGNING_KEY}" ]]; then
    ARGS+=(--signing-key "${MELANGE_SIGNING_KEY}")
else
    echo "WARN: signing_key is empty, so the packages and their index are not signed. apko refuses an unsigned index unless it ignores signatures." >&2
fi
if [[ -n "${SOURCE_DIR}" ]]; then
    ARGS+=(--source-dir "${SOURCE_DIR}")
fi
melange_path_flags --keyring-append "${KEYRING_APPEND}"
ARGS+=(${MELANGE_FLAGS[@]+"${MELANGE_FLAGS[@]}"})
melange_path_flags --repository-append "${REPOSITORY_APPEND}"
ARGS+=(${MELANGE_FLAGS[@]+"${MELANGE_FLAGS[@]}"})
melange_flags --package-append "${PACKAGE_APPEND}"
ARGS+=(${MELANGE_FLAGS[@]+"${MELANGE_FLAGS[@]}"})
melange_path_flags --pipeline-dirs "${PIPELINE_DIRS}"
ARGS+=(${MELANGE_FLAGS[@]+"${MELANGE_FLAGS[@]}"})
melange_path_flags --env-file "${ENV_FILE}"
ARGS+=(${MELANGE_FLAGS[@]+"${MELANGE_FLAGS[@]}"})
if [[ -n "${VARS_FILE}" ]]; then
    ARGS+=(--vars-file "${VARS_FILE}")
fi
if [[ -n "${NAMESPACE}" ]]; then
    ARGS+=(--namespace "${NAMESPACE}")
fi
if [[ "${GENERATE_INDEX}" == false ]]; then
    ARGS+=(--generate-index=false)
fi
ARGS+=(${MELANGE_WORDS[@]+"${MELANGE_WORDS[@]}"})

melange_run melange "${ARGS[@]}"

if [[ -d "${OUT_DIR}" ]]; then
    echo "Packages in ${OUT_DIR}:"
    find "${OUT_DIR}" -mindepth 2 -maxdepth 2 \( -name '*.apk' -o -name APKINDEX.tar.gz \) -print | LC_ALL=C sort | sed 's/^/  /'
fi
