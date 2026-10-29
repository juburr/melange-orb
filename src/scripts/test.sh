#!/bin/bash
#
# Runs a package's test pipelines with melange test, for the test command. The
# test environment installs the package under test from repository_append,
# by default the packages build wrote, trusting the keys in keyring_append,
# by default the public key keygen wrote.

set -euo pipefail

if [[ -z "${SCRIPT_MELANGE_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_MELANGE_LIB is not set. The command passes the orb's lib/melange.sh in it." >&2
    exit 1
fi
eval "${SCRIPT_MELANGE_LIB}"

CONFIG=$(melange_subst "${PARAM_CONFIG}")
PACKAGE=$(melange_subst "${PARAM_PACKAGE}")
ARCH=$(melange_subst "${PARAM_ARCH}")
RUNNER=$(melange_subst "${PARAM_RUNNER}")
SOURCE_DIR=$(melange_subst "${PARAM_SOURCE_DIR}")
KEYRING_APPEND=$(melange_subst "${PARAM_KEYRING_APPEND}")
REPOSITORY_APPEND=$(melange_subst "${PARAM_REPOSITORY_APPEND}")
TEST_PACKAGE_APPEND=$(melange_subst "${PARAM_TEST_PACKAGE_APPEND}")
PIPELINE_DIRS=$(melange_subst "${PARAM_PIPELINE_DIRS}")
ENV_FILE=$(melange_subst "${PARAM_ENV_FILE}")
EXTRA_ARGS=$(melange_subst "${PARAM_EXTRA_ARGS}")

melange_require
melange_runner "${RUNNER}"
if [[ ! -f "${CONFIG}" ]]; then
    echo "ERROR: The melange configuration ${CONFIG} does not exist." >&2
    exit 1
fi
if [[ -n "${SOURCE_DIR}" && ! -d "${SOURCE_DIR}" ]]; then
    echo "ERROR: source_dir ${SOURCE_DIR} is not a directory." >&2
    exit 1
fi
if [[ "${PACKAGE}" == -* ]]; then
    echo "ERROR: package must be a package name, not '${PACKAGE}'." >&2
    exit 1
fi
melange_words extra_args "${EXTRA_ARGS}"
melange_arch_args "${ARCH}"

ARGS=(test "${CONFIG}")
if [[ -n "${PACKAGE}" ]]; then
    ARGS+=("${PACKAGE}")
fi
ARGS+=(--runner "${RUNNER}")
ARGS+=(${MELANGE_ARCH_ARGS[@]+"${MELANGE_ARCH_ARGS[@]}"})
if [[ -n "${SOURCE_DIR}" ]]; then
    ARGS+=(--source-dir "${SOURCE_DIR}")
fi
melange_path_flags --repository-append "${REPOSITORY_APPEND}"
ARGS+=(${MELANGE_FLAGS[@]+"${MELANGE_FLAGS[@]}"})
melange_path_flags --keyring-append "${KEYRING_APPEND}"
ARGS+=(${MELANGE_FLAGS[@]+"${MELANGE_FLAGS[@]}"})
melange_flags --test-package-append "${TEST_PACKAGE_APPEND}"
ARGS+=(${MELANGE_FLAGS[@]+"${MELANGE_FLAGS[@]}"})
melange_path_flags --pipeline-dirs "${PIPELINE_DIRS}"
ARGS+=(${MELANGE_FLAGS[@]+"${MELANGE_FLAGS[@]}"})
melange_path_flags --env-file "${ENV_FILE}"
ARGS+=(${MELANGE_FLAGS[@]+"${MELANGE_FLAGS[@]}"})
ARGS+=(${MELANGE_WORDS[@]+"${MELANGE_WORDS[@]}"})

melange_run melange "${ARGS[@]}"
