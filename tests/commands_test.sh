#!/usr/bin/env bash
#
# Tests src/scripts/build.sh, test.sh, keygen.sh and index.sh against a
# stand-in melange that records its arguments, working directory and the
# signing key it was handed, and writes the files keygen would:
#
#   - each command builds exactly the melange arguments expected from its
#     defaults and from every parameter, with no empty argument where an
#     optional list is empty, even on bash < 4.4
#   - arch: empty is this machine's architecture, "all" leaves --arch out
#   - lists split on commas, spaces and newlines without globbing, and local
#     paths in them become absolute while URLs and names stay as they are
#   - extra_args split like shell words, and a $(...) or backtick outside
#     quotes stops the step before melange runs
#   - a key from signing_key_env_var (PEM or base64) reaches melange as a file
#     only this user can read, named after signing_key's file name, and is
#     removed when the step ends, even when melange fails
#   - keygen never replaces a key, and leaves the private key readable by
#     this user only
#   - index writes a signed index for each architecture directory with APKs
#   - bad values stop the step before melange runs, and a failing melange
#     fails the step
#   - parameters reach the CircleCI CLI on stdin, and without the CLI, as on
#     GitHub's runners, are used as they are
#
# The scripts run with the bash first on the PATH, so putting an older bash
# there checks it.
#
# Run from a checkout:
#   bash <this file>

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
until [[ -f "${ROOT}/src/@orb.yml" ]]; do
    if [[ "${ROOT}" == "/" ]]; then
        echo "FAIL: no src/@orb.yml above ${BASH_SOURCE[0]}"
        exit 1
    fi
    ROOT=$(dirname "${ROOT}")
done
SCRIPTS="${ROOT}/src/scripts"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/stubs"
CLI="${WORK}/cli"
mkdir -p "${STUBS}" "${CLI}"
LOG="${WORK}/melange.log"
KEYS="${WORK}/keys.log"

# The melange stand-in. Each call logs "--- <cwd>" and then its arguments, one
# per line. For --signing-key it logs the key file's name, modes and first
# line. keygen writes both key files the way melange does, subject to the
# umask. MELANGE_EXIT sets its exit status.
cat > "${STUBS}/melange" << 'EOF'
#!/bin/bash
{ printf -- '--- %s\n' "$(pwd)"; printf '%s\n' "$@"; } >> "${STUB_LOG}"
previous=""
for arg in "$@"; do
    if [[ "${previous}" == --signing-key ]]; then
        {
            printf 'name: %s\n' "${arg##*/}"
            printf 'mode: %s\n' "$(stat -c %a "${arg}")"
            printf 'dir-mode: %s\n' "$(stat -c %a "$(dirname "${arg}")")"
            printf 'first-line: %s\n' "$(head -n 1 "${arg}")"
            printf 'path: %s\n' "${arg}"
        } >> "${STUB_KEYS}"
    fi
    previous=${arg}
done
if [[ "${1:-}" == keygen ]]; then
    key=${*: -1}
    echo "-----BEGIN RSA PRIVATE KEY-----" > "${key}"
    echo "ssh-rsa public" > "${key}.pub"
fi
exit "${MELANGE_EXIT:-0}"
EOF
# The CircleCI CLI stand-in: env subst reads its value on stdin, fails on any
# other argument, and expands $ORB_TEST_VAR.
cat > "${CLI}/circleci" << 'EOF'
#!/bin/bash
if [[ $# -ne 2 || "$1" != env || "$2" != subst ]]; then
    echo "circleci stand-in: unexpected arguments: $*" >&2
    exit 2
fi
value=$(cat; printf x)
value=${value%x}
value=${value//'${ORB_TEST_VAR}'/${ORB_TEST_VAR:-}}
value=${value//'$ORB_TEST_VAR'/${ORB_TEST_VAR:-}}
printf '%s' "${value}"
EOF
chmod +x "${STUBS}/melange" "${CLI}/circleci"

# The system PATH without a real circleci (cimg images keep git beside it,
# so such a directory is replaced by links to everything else in it).
BASE_PATH=""
SHADOWS=0
IFS=: read -r -a path_dirs <<< "${PATH}"
for dir in "${path_dirs[@]}"; do
    [[ -n "${dir}" ]] || continue
    if [[ -x "${dir}/circleci" ]]; then
        SHADOWS=$((SHADOWS + 1))
        shadow="${WORK}/path-${SHADOWS}"
        mkdir -p "${shadow}"
        for entry in "${dir}"/*; do
            if [[ -e "${entry}" && "${entry##*/}" != circleci ]]; then
                ln -s "${entry}" "${shadow}/${entry##*/}"
            fi
        done
        dir=${shadow}
    fi
    BASE_PATH="${BASE_PATH:+${BASE_PATH}:}${dir}"
done

case "$(uname -m)" in
    x86_64 | amd64) HOST_ARCH=x86_64 ;;
    aarch64 | arm64) HOST_ARCH=aarch64 ;;
    *) HOST_ARCH=$(uname -m) ;;
esac

PEM_KEY=$'-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf9Cnzj4p4WGeKLs1Pt8Qu\n-----END RSA PRIVATE KEY-----'
PKCS8_KEY=$'-----BEGIN PRIVATE KEY-----\nMIIBVQIBADANBgkqhkiG9w0BAQEFAASCAT8wggE7AgEAAkEAqPfgaTEWEP3S9w0t\n-----END PRIVATE KEY-----'

# Each command's parameters, at the defaults its YAML gives them. run reads
# them by name.
# shellcheck disable=SC2034
BUILD_DEFAULTS=(PARAM_CONFIG=melange.yaml PARAM_ARCH= PARAM_RUNNER=docker PARAM_SIGNING_KEY=melange.rsa
    PARAM_SIGNING_KEY_ENV_VAR= PARAM_SOURCE_DIR= PARAM_OUT_DIR=packages PARAM_KEYRING_APPEND=
    PARAM_REPOSITORY_APPEND= PARAM_PACKAGE_APPEND= PARAM_PIPELINE_DIRS= PARAM_ENV_FILE= PARAM_VARS_FILE=
    PARAM_NAMESPACE= PARAM_GENERATE_INDEX=1 PARAM_EXTRA_ARGS=)
# shellcheck disable=SC2034
TEST_DEFAULTS=(PARAM_CONFIG=melange.yaml PARAM_PACKAGE= PARAM_ARCH= PARAM_RUNNER=docker
    PARAM_REPOSITORY_APPEND=packages PARAM_KEYRING_APPEND=melange.rsa.pub PARAM_TEST_PACKAGE_APPEND=
    PARAM_SOURCE_DIR= PARAM_PIPELINE_DIRS= PARAM_ENV_FILE= PARAM_EXTRA_ARGS=)
# shellcheck disable=SC2034
KEYGEN_DEFAULTS=(PARAM_SIGNING_KEY=melange.rsa PARAM_KEY_SIZE=4096)
# shellcheck disable=SC2034
INDEX_DEFAULTS=(PARAM_PACKAGES_DIR=packages PARAM_ARCH= PARAM_SIGNING_KEY=melange.rsa PARAM_SIGNING_KEY_ENV_VAR=)

CASE=0
WITH_CLI=true
PREPARE=""
# run SCRIPT DEFAULTS_ARRAY [VAR=value ...]: runs src/scripts/SCRIPT in a new
# job directory (JOB) holding melange.yaml and a melange.rsa key pair, with
# the command's defaults overridden by the given assignments, and the
# circleci stand-in on the PATH unless WITH_CLI is false. PREPARE names a
# function run in JOB first. Sets RC, OUTPUT, JOB and CALLS (the melange
# calls' arguments, without the cwd lines). (Bash 4.0 takes an empty "$@"
# for an unbound variable, so the assignments are copied only when there are
# some.)
run() {
    local script=$1 defaults_name=$2
    shift 2
    local -a vars=()
    if [[ $# -gt 0 ]]; then
        vars=("$@")
    fi
    local -a defaults
    eval "defaults=(\"\${${defaults_name}[@]}\")"
    local path="${STUBS}:${BASE_PATH}"
    if [[ "${WITH_CLI}" == true ]]; then
        path="${CLI}:${path}"
    fi
    CASE=$((CASE + 1))
    JOB="${WORK}/job ${CASE}"
    mkdir -p "${JOB}" "${WORK}/tmp-${CASE}"
    printf 'package:\n  name: hello\n' > "${JOB}/melange.yaml"
    printf '%s\n' "${PEM_KEY}" > "${JOB}/melange.rsa"
    echo "ssh-rsa public" > "${JOB}/melange.rsa.pub"
    : > "${LOG}"
    : > "${KEYS}"
    if [[ -n "${PREPARE}" ]]; then
        (cd "${JOB}" && "${PREPARE}")
    fi
    OUTPUT=$(cd "${JOB}" && env -i PATH="${path}" HOME="${WORK}" TMPDIR="${WORK}/tmp-${CASE}" \
        STUB_LOG="${LOG}" STUB_KEYS="${KEYS}" \
        SCRIPT_MELANGE_LIB="$(cat "${SCRIPTS}/lib/melange.sh")" \
        "${defaults[@]}" ${vars[@]+"${vars[@]}"} \
        bash "${SCRIPTS}/${script}" 2>&1)
    RC=$?
    CALLS=$(grep -v '^--- ' "${LOG}" | paste -sd' ' -)
}

PASSES=0
FAILURES=0
check() {
    local name=$1
    shift
    if "$@"; then
        PASSES=$((PASSES + 1))
        printf 'ok: %s\n' "${name}"
    else
        FAILURES=$((FAILURES + 1))
        printf 'FAIL: %s\n' "${name}"
        printf '%s\n' "${OUTPUT}" | sed 's/^/    | /'
        printf 'calls: %s\n' "${CALLS}" | sed 's/^/    | /'
    fi
}
rc_is() { [[ "${RC}" == "$1" ]]; }
rc_not() { [[ "${RC}" != "$1" ]]; }
equals() { [[ "$1" == "$2" ]]; }
output_has() { [[ "${OUTPUT}" == *"$1"* ]]; }
calls_are() { [[ "${CALLS}" == "$1" ]]; }
calls_have() { [[ " ${CALLS} " == *" $1 "* ]]; }
calls_lack() { [[ " ${CALLS} " != *" $1 "* ]]; }
not_run() { [[ ! -s "${LOG}" ]]; }
keys_has() { grep -qxF -- "$1" "${KEYS}"; }
keys_lack() { ! grep -qxF -- "$1" "${KEYS}"; }
tmp_empty() { [[ -z "$(ls -A "${WORK}/tmp-${CASE}")" ]]; }

# --- build ------------------------------------------------------------------

run build.sh BUILD_DEFAULTS
check "build runs with the defaults" rc_is 0
check "build's default arguments" calls_are "build melange.yaml --runner docker --out-dir packages --arch ${HOST_ARCH} --signing-key melange.rsa"
check "build runs in the job's working directory" grep -qxF -- "--- ${JOB}" "${LOG}"
check "build shows the melange command it runs" output_has "Running: melange build melange.yaml --runner docker"

run build.sh BUILD_DEFAULTS PARAM_ARCH=all
check "arch all leaves --arch out" calls_lack "--arch"
run build.sh BUILD_DEFAULTS PARAM_ARCH=x86_64,aarch64
check "arch passes a list" calls_have "--arch x86_64,aarch64"
run build.sh BUILD_DEFAULTS "PARAM_ARCH=x86_64 aarch64"
check "a malformed arch fails" output_has "ERROR: arch must be empty, all, or architectures separated by commas"
check "a malformed arch fails before melange runs" not_run

run build.sh BUILD_DEFAULTS PARAM_RUNNER=podman
check "an unknown runner fails" output_has "ERROR: runner must be docker, bubblewrap or qemu, not 'podman'."
check "an unknown runner fails before melange runs" not_run
run build.sh BUILD_DEFAULTS PARAM_RUNNER=bubblewrap
check "the runner is passed" calls_have "--runner bubblewrap"

run build.sh BUILD_DEFAULTS PARAM_CONFIG=missing.yaml
check "a missing configuration fails" output_has "ERROR: The melange configuration missing.yaml does not exist."
check "a missing configuration fails before melange runs" not_run

run build.sh BUILD_DEFAULTS PARAM_SIGNING_KEY=
check "an empty signing_key builds unsigned" calls_lack "--signing-key"
check "an unsigned build warns" output_has "WARN: signing_key is empty, so the packages and their index are not signed."
run build.sh BUILD_DEFAULTS PARAM_SIGNING_KEY=keys/missing.rsa
check "a missing signing key fails" output_has "ERROR: The signing key keys/missing.rsa does not exist."
check "a missing signing key fails before melange runs" not_run

# Keys from an environment variable.
run build.sh BUILD_DEFAULTS PARAM_SIGNING_KEY_ENV_VAR=PROD_KEY "PROD_KEY=${PEM_KEY}"
check "a key from signing_key_env_var builds" rc_is 0
check "the key file is named after signing_key" keys_has "name: melange.rsa"
check "the key file is readable by this user only" keys_has "mode: 600"
check "the key's directory is this user's only" keys_has "dir-mode: 700"
check "the key file holds the key" keys_has "first-line: -----BEGIN RSA PRIVATE KEY-----"
check "the key file is not the one in the job directory" keys_lack "path: melange.rsa"
check "the key file is removed when the step ends" tmp_empty

run build.sh BUILD_DEFAULTS PARAM_SIGNING_KEY=keys/prod.rsa PARAM_SIGNING_KEY_ENV_VAR=PROD_KEY "PROD_KEY=${PEM_KEY}"
check "a key from a variable takes signing_key's file name" keys_has "name: prod.rsa"
run build.sh BUILD_DEFAULTS PARAM_SIGNING_KEY= PARAM_SIGNING_KEY_ENV_VAR=PROD_KEY "PROD_KEY=${PEM_KEY}"
check "a key from a variable without signing_key is named melange.rsa" keys_has "name: melange.rsa"
run build.sh BUILD_DEFAULTS PARAM_SIGNING_KEY_ENV_VAR=PROD_KEY "PROD_KEY=$(printf '%s\n' "${PEM_KEY}" | base64 -w0)"
check "a base64-encoded key from a variable is decoded" keys_has "first-line: -----BEGIN RSA PRIVATE KEY-----"
run build.sh BUILD_DEFAULTS PARAM_SIGNING_KEY_ENV_VAR=PROD_KEY "PROD_KEY=${PEM_KEY}" MELANGE_EXIT=3
check "a failing melange fails the step" rc_is 3
check "the key file is removed when melange fails" tmp_empty
run build.sh BUILD_DEFAULTS PARAM_SIGNING_KEY_ENV_VAR=PROD_KEY
check "an unset key variable fails" output_has "ERROR: PROD_KEY, which signing_key_env_var names, is empty or not set."
check "an unset key variable fails before melange runs" not_run
run build.sh BUILD_DEFAULTS PARAM_SIGNING_KEY_ENV_VAR=PROD_KEY PROD_KEY=not-a-key
check "a variable that holds no key fails" output_has "ERROR: PROD_KEY holds neither a PEM private key nor a base64-encoded one."
run build.sh BUILD_DEFAULTS PARAM_SIGNING_KEY_ENV_VAR=PROD_KEY "PROD_KEY=${PKCS8_KEY}"
check "a PKCS#8 key fails with a hint" output_has "openssl rsa -traditional"
check "a PKCS#8 key fails before melange runs" not_run
run build.sh BUILD_DEFAULTS "PARAM_SIGNING_KEY_ENV_VAR=PROD KEY"
check "a bad variable name fails" output_has "ERROR: signing_key_env_var must name an environment variable, not 'PROD KEY'."

# Lists.
lists_prepare() {
    mkdir -p local-repo pipelines
    echo key > extra.pub
    echo FOO=1 > build.env
}
PREPARE=lists_prepare
run build.sh BUILD_DEFAULTS "PARAM_KEYRING_APPEND=extra.pub, https://example.com/key.rsa.pub
*.pub" "PARAM_REPOSITORY_APPEND=./local-repo https://example.com/os" "PARAM_PACKAGE_APPEND=busybox,bash" \
    PARAM_PIPELINE_DIRS=pipelines PARAM_ENV_FILE=build.env
PREPARE=""
check "local keyring paths become absolute" calls_have "--keyring-append ${JOB}/extra.pub"
check "keyring URLs stay as they are" calls_have "--keyring-append https://example.com/key.rsa.pub"
check "list items are not globbed" calls_have "--keyring-append *.pub"
check "a ./ path becomes absolute" calls_have "--repository-append ${JOB}/local-repo"
check "repository URLs stay as they are" calls_have "--repository-append https://example.com/os"
check "comma-separated packages each get a flag" calls_have "--package-append busybox --package-append bash"
check "pipeline directories are passed" calls_have "--pipeline-dirs ${JOB}/pipelines"
check "env files are passed" calls_have "--env-file ${JOB}/build.env"

source_prepare() { mkdir -p dist; echo vars: > vars.yaml; }
PREPARE=source_prepare
run build.sh BUILD_DEFAULTS PARAM_SOURCE_DIR=dist PARAM_OUT_DIR=out PARAM_VARS_FILE=vars.yaml PARAM_NAMESPACE=acme PARAM_GENERATE_INDEX=0
PREPARE=""
check "source_dir, out_dir, vars_file and namespace are passed" \
    calls_are "build melange.yaml --runner docker --out-dir out --arch ${HOST_ARCH} --signing-key melange.rsa --source-dir dist --vars-file vars.yaml --namespace acme --generate-index=false"
run build.sh BUILD_DEFAULTS PARAM_SOURCE_DIR=dist
check "a missing source_dir fails" output_has "ERROR: source_dir dist is not a directory."
run build.sh BUILD_DEFAULTS PARAM_OUT_DIR=
check "an empty out_dir fails" output_has "ERROR: out_dir must not be empty."
run build.sh BUILD_DEFAULTS PARAM_GENERATE_INDEX=yes
check "a bad boolean fails" output_has "ERROR: generate_index must be true or false, not 'yes'."
check "a bad boolean fails before melange runs" not_run

run build.sh BUILD_DEFAULTS "PARAM_EXTRA_ARGS=--timeout 30m --license 'Apache 2.0'"
check "extra_args split like shell words" calls_have "--timeout 30m --license Apache 2.0"
check "extra_args come last" equals "$(tail -n 1 "${LOG}")" "Apache 2.0"
# shellcheck disable=SC2016 # a command substitution the script must refuse
run build.sh BUILD_DEFAULTS 'PARAM_EXTRA_ARGS=--license $(id)'
check "a command substitution in extra_args fails" output_has "ERROR: extra_args could not be split into arguments: it has a \$(...) or backtick outside quotes."
check "a command substitution in extra_args fails before melange runs" not_run

built_prepare() { mkdir -p "packages/${HOST_ARCH}"; touch "packages/${HOST_ARCH}/hello-1.0-r0.apk"; }
PREPARE=built_prepare
run build.sh BUILD_DEFAULTS
PREPARE=""
check "build lists the packages in out_dir" output_has "  packages/${HOST_ARCH}/hello-1.0-r0.apk"

# The CLI and its absence.
# shellcheck disable=SC2016 # expanded by the circleci stand-in
run build.sh BUILD_DEFAULTS 'PARAM_NAMESPACE=$ORB_TEST_VAR' ORB_TEST_VAR=acme
check "parameters go through circleci env subst" calls_have "--namespace acme"
WITH_CLI=false
# shellcheck disable=SC2016 # left as it is without the CLI
run build.sh BUILD_DEFAULTS 'PARAM_NAMESPACE=$ORB_TEST_VAR' ORB_TEST_VAR=acme PARAM_GENERATE_INDEX=true
check "without the CLI, values are used as they are" calls_have "--namespace \$ORB_TEST_VAR"
check "without the CLI, booleans take true" rc_is 0
WITH_CLI=true

SAVED_STUBS=${STUBS}
STUBS="${WORK}/empty-stubs"
mkdir -p "${STUBS}"
run build.sh BUILD_DEFAULTS
STUBS=${SAVED_STUBS}
check "a missing melange fails" output_has "ERROR: melange is not on the PATH. Run the install command in an earlier step."

# --- test -------------------------------------------------------------------

packages_prepare() { mkdir -p packages/"${HOST_ARCH}"; }
PREPARE=packages_prepare
run test.sh TEST_DEFAULTS
PREPARE=""
check "test runs with the defaults" rc_is 0
check "test's default arguments" \
    calls_are "test melange.yaml --runner docker --arch ${HOST_ARCH} --repository-append ${JOB}/packages --keyring-append ${JOB}/melange.rsa.pub"

run test.sh TEST_DEFAULTS PARAM_PACKAGE=hello=1.0.0-r0 PARAM_TEST_PACKAGE_APPEND=busybox,bash PARAM_ARCH=all \
    PARAM_REPOSITORY_APPEND=https://example.com/os PARAM_KEYRING_APPEND=https://example.com/key.rsa.pub \
    "PARAM_EXTRA_ARGS=--timeout 10m"
check "test passes the package after the configuration" \
    calls_are "test melange.yaml hello=1.0.0-r0 --runner docker --repository-append https://example.com/os --keyring-append https://example.com/key.rsa.pub --test-package-append busybox --test-package-append bash --timeout 10m"
run test.sh TEST_DEFAULTS PARAM_PACKAGE=--debug
check "a package that looks like a flag fails" output_has "ERROR: package must be a package name, not '--debug'."
check "a package that looks like a flag fails before melange runs" not_run
run test.sh TEST_DEFAULTS PARAM_CONFIG=missing.yaml
check "test with a missing configuration fails" output_has "ERROR: The melange configuration missing.yaml does not exist."
run test.sh TEST_DEFAULTS MELANGE_EXIT=1
check "a failing test fails the step" rc_is 1

# --- keygen -----------------------------------------------------------------

no_key() { rm -f melange.rsa melange.rsa.pub; }
PREPARE=no_key
run keygen.sh KEYGEN_DEFAULTS
check "keygen runs with the defaults" rc_is 0
check "keygen's default arguments" calls_are "keygen --key-size 4096 melange.rsa"
check "the private key is readable by this user only" equals "$(stat -c %a "${JOB}/melange.rsa")" 600
check "the public key is readable by everyone" equals "$(stat -c %a "${JOB}/melange.rsa.pub")" 644
run keygen.sh KEYGEN_DEFAULTS PARAM_SIGNING_KEY=keys/ci/local.rsa PARAM_KEY_SIZE=2048
PREPARE=""
check "keygen creates the key's directory" calls_are "keygen --key-size 2048 keys/ci/local.rsa"
check "keygen writes the key in that directory" test -f "${JOB}/keys/ci/local.rsa.pub"

run keygen.sh KEYGEN_DEFAULTS
check "keygen never replaces a key" output_has "ERROR: melange.rsa already exists. Use the existing key, or remove it first."
check "keygen leaves an existing key alone" not_run
only_public() { rm -f melange.rsa; }
PREPARE=only_public
run keygen.sh KEYGEN_DEFAULTS
PREPARE=""
check "keygen never replaces a public key" output_has "ERROR: melange.rsa.pub already exists."
PREPARE=no_key
run keygen.sh KEYGEN_DEFAULTS PARAM_KEY_SIZE=big
check "a bad key_size fails" output_has "ERROR: key_size must be a number of bits, such as 4096, not 'big'."
run keygen.sh KEYGEN_DEFAULTS PARAM_SIGNING_KEY=--help
check "a signing_key that looks like a flag fails" output_has "ERROR: signing_key must be the path of the private key file to write, not '--help'."
run keygen.sh KEYGEN_DEFAULTS PARAM_SIGNING_KEY=
PREPARE=""
check "an empty signing_key fails" output_has "ERROR: signing_key must be the path of the private key file to write, not ''."
check "an empty signing_key fails before melange runs" not_run

# --- index ------------------------------------------------------------------

index_prepare() {
    mkdir -p packages/x86_64 packages/aarch64 packages/empty
    touch packages/x86_64/b-1.0-r0.apk packages/x86_64/a-1.0-r0.apk packages/aarch64/c-1.0-r0.apk
}
PREPARE=index_prepare
run index.sh INDEX_DEFAULTS
check "index runs with the defaults" rc_is 0
check "index indexes each architecture with APKs, in order" \
    calls_are "index --arch aarch64 --output packages/aarch64/APKINDEX.tar.gz --signing-key melange.rsa packages/aarch64/c-1.0-r0.apk index --arch x86_64 --output packages/x86_64/APKINDEX.tar.gz --signing-key melange.rsa packages/x86_64/a-1.0-r0.apk packages/x86_64/b-1.0-r0.apk"
check "index reports what it indexed" output_has "Indexed 2 package(s) in packages/x86_64/APKINDEX.tar.gz."

run index.sh INDEX_DEFAULTS PARAM_ARCH=x86_64 PARAM_SIGNING_KEY=
check "index takes the architectures to index" \
    calls_are "index --arch x86_64 --output packages/x86_64/APKINDEX.tar.gz packages/x86_64/a-1.0-r0.apk packages/x86_64/b-1.0-r0.apk"
check "an unsigned index warns" output_has "WARN: signing_key is empty, so the indexes are not signed."
run index.sh INDEX_DEFAULTS PARAM_ARCH=empty
check "an architecture without APKs fails" output_has "ERROR: packages/empty holds no APKs to index."
run index.sh INDEX_DEFAULTS PARAM_ARCH=s390x
check "an architecture without a directory fails" output_has "ERROR: packages/s390x holds no APKs to index."
run index.sh INDEX_DEFAULTS "PARAM_ARCH=x86_64;id"
check "a malformed arch fails" output_has "ERROR: arch must be empty or architectures separated by commas"
check "a malformed arch fails before melange runs" not_run
run index.sh INDEX_DEFAULTS PARAM_SIGNING_KEY_ENV_VAR=PROD_KEY "PROD_KEY=${PEM_KEY}"
check "index signs with a key from a variable" keys_has "mode: 600"
check "index removes the key from a variable" tmp_empty
PREPARE=""
run index.sh INDEX_DEFAULTS
check "a missing packages_dir fails" output_has "ERROR: packages_dir 'packages' is not a directory."
empty_packages() { mkdir -p packages/x86_64; }
PREPARE=empty_packages
run index.sh INDEX_DEFAULTS
PREPARE=""
check "no APKs at all fails" output_has "ERROR: No directory under packages holds any APKs."

echo
if [[ ${FAILURES} -gt 0 ]]; then
    echo "${FAILURES} of $((PASSES + FAILURES)) checks failed."
    exit 1
fi
echo "All ${PASSES} checks passed."
