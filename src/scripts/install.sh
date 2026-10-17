#!/bin/bash
#
# Installs melange for the install command: the Linux amd64 or arm64 build
# that matches this machine, verified against the checksum table in this file
# before it is installed.
#
# Every juburr orb's install.sh has the same three parts:
#   1. tool definition: what to download and how to install it (melange only)
#   2. shared install logic: identical in every orb
#   3. checksum table: one SHA-512 per release and architecture
#
# Add the checksums for a new release with:
#   src/scripts/install_hash.sh -v <version>

# CircleCI runs steps with /bin/sh when the image has no bash, and macOS ships
# bash 3, which lacks associative arrays.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    echo "ERROR: Installing melange needs bash 4 or newer. Use an executor image that has it." >&2
    exit 1
fi
set -euo pipefail

# >>> tool definition >>>
ORB_NAME="melange-orb"
TOOL_NAME="melange"
TOOL_BINARY="melange"
TOOL_ARCHES="amd64 arm64"
# The default install_path, under HOME.
TOOL_DEFAULT_INSTALL_DIR="bin"

# tool_asset_name VERSION ARCH: the release asset to download.
tool_asset_name() {
    printf 'melange_%s_linux_%s.tar.gz\n' "$1" "$2"
}

# tool_asset_urls VERSION ARCH ASSET: where to download it, one URL per line,
# tried in order.
tool_asset_urls() {
    printf 'https://github.com/chainguard-dev/melange/releases/download/v%s/%s\n' "$1" "$3"
}

# tool_archive_member VERSION ARCH: the binary's path inside the asset. The
# checksum table holds the SHA-512 of that file.
tool_archive_member() {
    printf 'melange_%s_linux_%s/melange\n' "$1" "$2"
}

# tool_version BINARY: prints the installed version without using the network.
tool_version() {
    "$1" version
}
# <<< tool definition <<<

# >>> shared install logic >>>
# Everything from here to the end marker is identical in the install.sh of
# every juburr orb, so change it in all of them together. Tool-specific
# behavior belongs in the tool definition above.
#
# Parameters arrive as PARAM_VERSION, PARAM_VERIFY_CHECKSUMS,
# PARAM_INSTALL_PATH and PARAM_CACHING. The checksum table (sha512sums) is
# defined after this block.

orb_info() { printf '%s\n' "$*"; }
orb_warn() { printf 'WARN: %s\n' "$*" >&2; }
orb_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Expands environment variables in a parameter value. The value is piped in
# on stdin: passed as an argument, a value starting with "-" would be parsed
# as a flag. Without the CircleCI CLI (local runs), the value is used as is.
orb_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# CircleCI passes boolean parameters as 1/0; local callers use true/false.
orb_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *) orb_die "${1} must be true or false, not '${2}'." ;;
    esac
}

# Reads an absolute directory parameter: NAME VALUE HOME_SUBDIR. Environment
# variables and a leading ~/ are expanded, trailing slashes are removed, and
# an empty value means $HOME/HOME_SUBDIR.
orb_dir_param() {
    local value
    value=$(orb_subst "$2")
    if [[ -z "${value}" || "${value}" == \~ || "${value}" == \~/* ]]; then
        if [[ -z "${HOME:-}" ]]; then
            orb_die "HOME is not set, so ${1} has no default. Set ${1} to an absolute path."
        fi
        if [[ -z "${value}" ]]; then
            value="${HOME}/${3}"
        else
            value="${HOME}${value:1}"
        fi
    fi
    while [[ "${value}" == */ && "${value}" != "/" ]]; do
        value=${value%/}
    done
    if [[ "${value}" != /* ]]; then
        orb_die "${1} must be an absolute path, not '${value}'."
    fi
    printf '%s\n' "${value}"
}

orb_require_tools() {
    local tool package
    for tool in "$@"; do
        if ! command -v "${tool}" > /dev/null 2>&1; then
            case "${tool}" in
                tar | gzip) package=${tool} ;;
                *) package=coreutils ;;
            esac
            orb_die "Installing ${TOOL_NAME} needs '${tool}', which is not available. Install it in an earlier step," \
                "for example with 'microdnf install -y ${package}' on Red Hat UBI images."
        fi
    done
}

# Newest version in the checksum table.
orb_latest_version() {
    local key
    for key in "${!sha512sums[@]}"; do
        printf '%s\n' "${key%/*}"
    done | sort -uV | tail -n 1
}

orb_detect_arch() {
    local os machine
    os=$(uname -s)
    machine=$(uname -m)
    if [[ "${TOOL_ARCHES}" == "noarch" ]]; then
        ORB_ARCH="noarch"
        orb_info "  platform:         noarch (${os} ${machine})"
        return 0
    fi
    if [[ "${os}" != "Linux" ]]; then
        orb_die "This orb installs Linux builds of ${TOOL_NAME}, but this machine runs ${os}."
    fi
    case "${machine}" in
        x86_64 | amd64) ORB_ARCH="amd64" ;;
        aarch64 | arm64) ORB_ARCH="arm64" ;;
        *) orb_die "Unsupported CPU architecture '${machine}'. Supported: x86_64 (amd64), aarch64/arm64 (arm64)." ;;
    esac
    if [[ " ${TOOL_ARCHES} " != *" ${ORB_ARCH} "* ]]; then
        orb_die "${TOOL_NAME} is not published for ${ORB_ARCH}. Supported: ${TOOL_ARCHES}."
    fi
    orb_info "  platform:         linux/${ORB_ARCH} (uname -m: ${machine})"
}

# Decides how this install is verified, before anything is downloaded.
orb_lookup_checksum() {
    ORB_EXPECTED_SHA512=${sha512sums["${ORB_VERSION}/${ORB_ARCH}"]:-}
    if [[ -n "${ORB_EXPECTED_SHA512}" && ! "${ORB_EXPECTED_SHA512}" =~ ^[0-9a-f]{128}$ ]]; then
        orb_die "The checksum table entry for ${ORB_VERSION}/${ORB_ARCH} is malformed."
    fi
    if [[ "${ORB_VERIFY_CHECKSUMS}" == "false" ]]; then
        orb_warn "verify_checksums is false, so ${TOOL_NAME} will be installed WITHOUT checksum verification. This is not recommended."
        ORB_EXPECTED_SHA512=""
    elif [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        if [[ "${ORB_VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            orb_warn "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), and verify_checksums is known_versions."
            orb_warn "Installing an UNVERIFIED binary. Upgrade this orb, or submit a PR with the checksum."
        else
            orb_die "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), so it cannot be verified (verify_checksums: strict)." \
                "Use a version this orb lists (the newest is $(orb_latest_version)), upgrade the orb, or opt out with verify_checksums: known_versions."
        fi
    fi
}

orb_init() {
    ORB_VERSION=$(orb_subst "${PARAM_VERSION:-}")
    ORB_VERSION=${ORB_VERSION#v}
    # The version is part of the download URL, so only release versions pass.
    if [[ ! "${ORB_VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
        orb_die "Invalid ${TOOL_NAME} version '${ORB_VERSION}'. Expected a release version such as $(orb_latest_version)."
    fi
    ORB_VERIFY_CHECKSUMS=${PARAM_VERIFY_CHECKSUMS:-strict}
    case "${ORB_VERIFY_CHECKSUMS}" in
        strict | known_versions | false) ;;
        *) orb_die "verify_checksums must be strict, known_versions or false, not '${ORB_VERIFY_CHECKSUMS}'." ;;
    esac
    ORB_INSTALL_PATH=$(orb_dir_param install_path "${PARAM_INSTALL_PATH:-}" "${TOOL_DEFAULT_INSTALL_DIR}")
    ORB_BIN_DIR=${ORB_INSTALL_PATH}
    ORB_CACHING=$(orb_bool caching "${PARAM_CACHING:-false}")

    orb_info "Installing ${TOOL_NAME} ${ORB_VERSION}"
    orb_info "  install_path:     ${ORB_INSTALL_PATH}"
    orb_info "  verify_checksums: ${ORB_VERIFY_CHECKSUMS}"
    orb_info "  caching:          ${ORB_CACHING}"
    orb_detect_arch
    orb_lookup_checksum

    ORB_ASSET_NAME=$(tool_asset_name "${ORB_VERSION}" "${ORB_ARCH}")
    ORB_ARCHIVE_MEMBER=$(tool_archive_member "${ORB_VERSION}" "${ORB_ARCH}")
    orb_require_tools sha512sum mktemp
    if [[ -n "${ORB_ARCHIVE_MEMBER}" ]]; then
        orb_require_tools tar gzip
    fi

    ORB_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${ORB_NAME}.XXXXXX")
    ORB_CLEANUP=("${ORB_WORK_DIR}")
    trap 'rm -rf "${ORB_CLEANUP[@]}"' EXIT

    # Restored and saved by install.yml. Files are stored by version and
    # architecture, so a cache restored for another version is never used.
    # Nothing is created here unless a verified asset is stored, so an
    # unverified install leaves nothing for save_cache to save.
    ORB_CACHE_FILE=""
    if [[ "${ORB_CACHING}" == "true" && -z "${HOME:-}" ]]; then
        orb_warn "HOME is not set, so the cache is not used."
        ORB_CACHING=false
    elif [[ "${ORB_CACHING}" == "true" ]]; then
        ORB_CACHE_FILE="${HOME}/.cache/${ORB_NAME}/${ORB_VERSION}/${ORB_ARCH}/${ORB_ASSET_NAME}"
    fi
}

# orb_download DEST URL...: downloads the first URL that works to DEST.
# Transient failures are retried with backoff; a 404 moves on to the next URL.
orb_download() {
    local dest=$1 url help option attempt rc
    local -a fetch
    shift
    if command -v curl > /dev/null 2>&1; then
        # A stalled transfer counts as a failure and is retried.
        fetch=(curl -fsSL --proto '=https' --proto-redir '=https' --retry 8 --retry-max-time 300
            --connect-timeout 30 --speed-limit 1 --speed-time 60)
        # curl added --retry-connrefused in 7.52, and lists it under --help all
        # since 7.73. The output is captured, not piped, so curl can't hit a
        # closed pipe.
        help=$({ curl --help all || curl --help; } 2>&1) || true
        if [[ "${help}" == *--retry-connrefused* ]]; then
            fetch+=(--retry-connrefused)
        fi
        fetch+=(-o)
    elif command -v wget > /dev/null 2>&1; then
        fetch=(wget -q)
        # Only the retry options this wget supports (BusyBox wget has none).
        help=$(wget --help 2>&1) || true
        for option in --tries=20 --waitretry=30 --retry-connrefused --timeout=60 --retry-on-http-error=429,500,502,503,504; do
            if [[ "${help}" == *"${option%%=*}"* ]]; then
                fetch+=("${option}")
            fi
        done
        fetch+=(-O)
    else
        orb_die "Neither curl nor wget is available. Install one of them in an earlier step."
    fi
    for url in "$@"; do
        # curl retries timeouts and HTTP 5xx itself, but not a connection
        # dropped partway through, so that gets two more attempts here. An
        # HTTP error such as a 404 (curl exit code 22) moves on to the next
        # URL. wget retries both itself.
        for attempt in 1 2 3; do
            orb_info "Downloading ${url}"
            rc=0
            "${fetch[@]}" "${dest}.partial" "${url}" || rc=$?
            if [[ "${rc}" -eq 0 ]]; then
                mv -f "${dest}.partial" "${dest}"
                return 0
            fi
            if [[ "${fetch[0]}" != "curl" || "${rc}" -eq 22 || "${attempt}" -eq 3 ]]; then
                break
            fi
            orb_warn "The download failed (curl exit code ${rc}). Retrying in $((attempt * 10)) seconds."
            sleep $((attempt * 10))
        done
        orb_warn "Could not download ${url}."
    done
    rm -f "${dest}.partial"
    return 1
}

# orb_extract ASSET MEMBER: sets ORB_VERIFIED_FILE to the file the checksum
# table describes, which is MEMBER extracted from ASSET, or ASSET itself
# when MEMBER is empty.
orb_extract() {
    local asset=$1 member=$2 dir
    if [[ -z "${member}" ]]; then
        ORB_VERIFIED_FILE=${asset}
        return 0
    fi
    dir="${ORB_WORK_DIR}/extract"
    rm -rf "${dir}"
    mkdir "${dir}"
    if ! tar -xzf "${asset}" -C "${dir}" --no-same-owner -- "${member}" 2> "${ORB_WORK_DIR}/tar.log"; then
        orb_warn "Could not extract ${member} from ${ORB_ASSET_NAME}: $(head -c 300 "${ORB_WORK_DIR}/tar.log")"
        return 1
    fi
    ORB_VERIFIED_FILE="${dir}/${member}"
    if [[ ! -f "${ORB_VERIFIED_FILE}" || -L "${ORB_VERIFIED_FILE}" ]]; then
        orb_warn "${member} in ${ORB_ASSET_NAME} is not a regular file."
        return 1
    fi
}

# orb_verify FILE: checks FILE against the checksum table, when verifying.
orb_verify() {
    local actual
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        return 0
    fi
    actual=$(sha512sum "$1" | awk '{ print $1 }')
    orb_info "Verifying the SHA-512 checksum of ${1##*/}..."
    orb_info "  expected: ${ORB_EXPECTED_SHA512}"
    orb_info "  actual:   ${actual}"
    if [[ "${actual}" != "${ORB_EXPECTED_SHA512}" ]]; then
        orb_warn "Checksum verification failed."
        return 1
    fi
    orb_info "Checksum verification passed."
}

# orb_temp_beside FILE: sets ORB_TEMP to a new, empty file in FILE's
# directory, to be renamed over FILE, and registers it for cleanup. mktemp
# creates it exclusively, so a file planted in a shared directory isn't
# written through.
orb_temp_beside() {
    ORB_TEMP=$(mktemp "${1%/*}/.${1##*/}.XXXXXX") || return 1
    ORB_CLEANUP+=("${ORB_TEMP}")
}

# Saves a downloaded asset for save_cache. Only verified assets are kept, so
# the cache never supplies a file the checksum table didn't vouch for.
orb_store_cache() {
    if [[ "${ORB_CACHING}" != "true" ]]; then
        return 0
    fi
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        orb_info "Not caching ${ORB_ASSET_NAME}, since it was not verified."
        return 0
    fi
    if mkdir -p "${ORB_CACHE_FILE%/*}" && orb_temp_beside "${ORB_CACHE_FILE}" \
        && cp "$1" "${ORB_TEMP}" && mv -f "${ORB_TEMP}" "${ORB_CACHE_FILE}"; then
        return 0
    fi
    orb_warn "Could not save ${ORB_ASSET_NAME} to ${ORB_CACHE_FILE%/*}; continuing without the cache."
}

# Fetches the release asset, from the cache when possible, and verifies it.
# Leaves the verified file in ORB_VERIFIED_FILE. A cached asset that fails
# verification is discarded and downloaded again. The cache is only read
# when there is a checksum to verify the cached asset against.
orb_fetch_verified() {
    local asset="${ORB_WORK_DIR}/${ORB_ASSET_NAME}" use_cache=${ORB_CACHING} from_cache urls
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        use_cache=false
    fi
    while true; do
        from_cache=false
        rm -f "${asset}"
        if [[ "${use_cache}" == "true" && -f "${ORB_CACHE_FILE}" ]]; then
            orb_info "Using ${ORB_ASSET_NAME} from the cache."
            cp "${ORB_CACHE_FILE}" "${asset}"
            from_cache=true
        else
            mapfile -t urls < <(tool_asset_urls "${ORB_VERSION}" "${ORB_ARCH}" "${ORB_ASSET_NAME}")
            if ! orb_download "${asset}" "${urls[@]}"; then
                orb_die "Could not download ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}). Check that this version" \
                    "was published for ${ORB_ARCH}, or re-run the job if the download host was failing."
            fi
        fi
        if orb_extract "${asset}" "${ORB_ARCHIVE_MEMBER}" && orb_verify "${ORB_VERIFIED_FILE}"; then
            break
        fi
        if [[ "${from_cache}" == "true" ]]; then
            orb_warn "The cached ${ORB_ASSET_NAME} failed verification. Discarding it and downloading it again."
            rm -f "${ORB_CACHE_FILE}"
            use_cache=false
            continue
        fi
        orb_die "${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}) failed verification and was not installed."
    done
    if [[ "${from_cache}" == "false" ]]; then
        orb_store_cache "${asset}"
    fi
}

# orb_install_file SOURCE DEST: installs SOURCE as the executable DEST,
# replacing any existing file in a single rename.
orb_install_file() {
    local dir=${2%/*}
    if ! mkdir -p "${dir}"; then
        orb_die "Could not create ${dir}. Choose an install_path this job's user can write to without root."
    fi
    if [[ -d "$2" ]]; then
        orb_die "Cannot install to $2, which is a directory."
    fi
    if ! { orb_temp_beside "$2" && cp "$1" "${ORB_TEMP}" && chmod 0755 "${ORB_TEMP}" && mv -f "${ORB_TEMP}" "$2"; }; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
}

# The default for tools that ship a single binary.
orb_install_binary() {
    orb_fetch_verified
    orb_install_file "${ORB_VERIFIED_FILE}" "${ORB_INSTALL_PATH}/${TOOL_BINARY}"
}

# Adds DIR to the PATH of later steps, unless it is already there.
orb_export_path() {
    local found
    if [[ ":${PATH}:" == *":$1:"* ]]; then
        # Later steps see this PATH, so an earlier copy of the binary wins.
        # -ef accepts the same file reached through a symlinked directory.
        found=$(command -v "${TOOL_BINARY}" || true)
        if [[ -n "${found}" && ! "${found}" -ef "$1/${TOOL_BINARY}" ]]; then
            orb_warn "${found} comes before $1 on the PATH, so later steps will run it instead of the ${TOOL_BINARY} installed here."
        fi
        return 0
    fi
    if [[ -n "${BASH_ENV:-}" ]]; then
        # ${PATH} is expanded when BASH_ENV is sourced, not now.
        # shellcheck disable=SC2016
        printf 'export PATH=%q:"${PATH}"\n' "$1" >> "${BASH_ENV}"
        orb_info "Added $1 to the PATH for later steps."
    else
        orb_warn "$1 is not on the PATH. Add it to run ${TOOL_BINARY} by name."
    fi
}

# Runs the installed binary once, which catches a build that can't run here.
orb_smoke_test() {
    local output rc=0 line
    if ! declare -F tool_version > /dev/null; then
        return 0
    fi
    output=$(tool_version "${ORB_INSTALL_PATH}/${TOOL_BINARY}" 2>&1) || rc=$?
    if [[ "${rc}" -eq 126 || "${rc}" -eq 127 ]]; then
        orb_die "The installed ${TOOL_BINARY} cannot run on this machine (exit code ${rc}): ${output}"
    fi
    orb_info "${TOOL_BINARY} reports:"
    while IFS= read -r line; do
        orb_info "  ${line}"
    done <<< "${output}"
    if [[ "${rc}" -ne 0 ]]; then
        orb_warn "Asking ${TOOL_BINARY} for its version exited with code ${rc}."
    fi
}

orb_install_main() {
    orb_init
    if declare -F tool_install > /dev/null; then
        tool_install
    else
        orb_install_binary
    fi
    orb_export_path "${ORB_BIN_DIR}"
    orb_smoke_test
    orb_info "Installed ${TOOL_NAME} ${ORB_VERSION} to ${ORB_INSTALL_PATH}."
}
# <<< shared install logic <<<

# >>> checksum table >>>
# SHA-512 checksums keyed "<version>/<arch>", newest release first, where arch
# is amd64, arm64, or noarch for a release that is the same everywhere.
# tool_archive_member says which file each checksum covers.
declare -A sha512sums=(
    ["0.61.2/amd64"]="6ed6b9b46284331616ccde70d6ffdd2ef41ee89c18f561c66a302039f3a91d11fd4466d5eb98eb469aebc4033c2c07b9237d77392aa9f91b0ae59c75e1522485"
    ["0.61.2/arm64"]="86a27f944d12f4639b9a328413af0a0ffa3de1e308a15872afc8d22405b97bbe0d71840eac0233e41df3d17d987d0f3e2c37aefaf2f14973ab64c34ae3f472e7"
    ["0.61.1/amd64"]="e58355833de335da8c44d716caa5ae3e0b77e82d89a89dfff8815c245b71775c95a42a77232a7640cb83e20c41350b818c2e8dfd197b6c3b533cc2ab6fe7303d"
    ["0.61.1/arm64"]="f1149cf82b0ad3f54c08530c4766d1bdfb6edc17d24bcdf508826776c443c1c5f86707eef2c321197613587b1c01df2e6bff6ecaa8b2c369c535ee0d19c159ff"
    ["0.61.0/amd64"]="dda153ef09072f93080e68a441e917a82930617972ed3a2fcb4b4610db19229d9d8a34c48fa3b0ee8151ea01a17c39cb8717e2bf0592978f0015c059c49f8508"
    ["0.61.0/arm64"]="521fdd4523702520ba0281353e2fcf299b2ecb2f0a75967f2f37fbc9a71b34a5a7bc1d36bf138b5c098ebe49c44591fd23c61ecac670e937ce3cae6271f54432"
    ["0.60.0/amd64"]="4a7428e32040c4906a4c08707de086b8886a11e741c0b1fb1b67a1690056e0c5fce0908bff20ef16516ee04ebae68804fd3bea11c0c561c7d78c84dc02938635"
    ["0.60.0/arm64"]="863192bf4c985c3e07c03d7411f72cf4718a5b49515c06c3e411ecdc6b7f1e6b8e76a328df329fbbca6fc3d59def7123bb10f84344f4bbe557d247cfbf1fe08e"
    ["0.59.5/amd64"]="6daefc895a4f19792dade595bed21ef7afd1387b89808cc56f99b5e8c6a3ebe03d26f455ef45750d39d76ef789ae488388f707df22fb6e954cee8829d19a58a1"
    ["0.59.5/arm64"]="0b365600bebce417dfa668f457da0c898c87a7bbaa851e65e2561cce259fa4cd42c0cc5dfd1392140a0f0ce3eee52f927d8c95189c9e41ed221c23d675e96b26"
    ["0.59.4/amd64"]="b1e0780b3511cdbfb3cbcfcb97c206aeacf6040f48759da98c248023a58ef60965227707e1d765aa182530f683199364995a59e06963b7c5748a85dbda8282b1"
    ["0.59.4/arm64"]="e00109ea8c1e90838f410dd5fb7e08adea4d7805eabfba4694c2f7f734098d5ea4941eb6eaec9fe4db766c3b81bc4788a4e1284c7cbb48cdb0c1b8815ee82fc4"
    ["0.59.3/amd64"]="d8755a5c9c077cae9f7db67519e2e66b12c4ca8fd25eea95f846dffa1ccb8f1e9ce00a81c7fe377a3122b684b015702a88515a18dd17181041a756af51a30270"
    ["0.59.3/arm64"]="c3fd7a93b4a984f2a08bf668eb64caee3147b9959b48c60971a3ca7d72aa5c420fab5f764ce3a2fb520a014ff0d262de99f4f4547f32cb5a1ae66599924b38dc"
    ["0.59.2/amd64"]="4a8c96fab54fd4da5a8f94ee053d47cb3b40bb941ee0ad8ecf0f3d181ea4ab375d059210f81d4d8de86d256ef2a63ecd4090465347bced6e501c939e027f7bc4"
    ["0.59.2/arm64"]="7af881cde82f04230c676ad27ea7c67b84b544318e9ce9756ffded055dae87b6dc0c7b880b71adbd7b3a3b0d98c354454d9a3dabda47272a48ddaa604dcbca0b"
    ["0.59.1/amd64"]="897e76e49f9dbe944643ab35af153b489519b5eff848843675e9fd8fd8327f22f482ca3510e41e776ad32ee1170e18f1d1b04cb95ad571989bba3b211a10e124"
    ["0.59.1/arm64"]="cdcc88e12bebf2b4ab8c84f3e9aa5e091087464c67a9a9e4bf7f696eae784846c2749d41f96bf4a6ec751b0781dfdafce563bf3a569f8ec11fee6f185ace1f78"
    ["0.59.0/amd64"]="b5c9354c52c13326cd302e33f48bcd10762185740db40e49e6e0d1b64f55a3cd6dd21b0d23aad9e170c8ab8646033f900f92e6b8f60c2d9c83fd6d15e9484390"
    ["0.59.0/arm64"]="63a0dfad7734c2c955ff53714c58f4431f37172c085e0e5fa100c42b993af933f5b304c3eeca51b265631fda1479ee1ea7eeef9224bc6ca5aed6e6961a265d91"
    ["0.58.0/amd64"]="8b1f6a4f6d08ec266999f120acf86aed76e2a4776d75aa14c2616aa1ec2b6b15c0055eeca5f2fc894d9ec208647993e9f9708445ee375c0737e082cdafb16746"
    ["0.58.0/arm64"]="955bcba110b810e9fab74dd23b5530e2995c4a414d696a950d0e46a94252bf7ba2240e37f7c5fefc8699bc88a187ca578261a30bccdc46f9c01333fc66c6da75"
    ["0.57.0/amd64"]="ad9115b7d2544f24679dc64c01657a43217bd7580ac56d7ec59deb896e4b4f946650b7a471203ecf4abf27ac72790800fb1bde21e88a5e3eb4fe268a2c2a71c6"
    ["0.57.0/arm64"]="61261457284574e933083830bfb0f05db75ed6264e029a57f3c07d6784ffd48bb2a6ead57891e0bd21ede45b1afce4a1b50e51f79bb7f74606362a038007558b"
    ["0.56.5/amd64"]="44d87c4f39f472800ad8ae1e8d6869f5795545f4e099ae5f9cc43af49709d762eb0e2051f8367be77ad2b6782fb5bc04a51b0beff7fbe7a9fd456af08bc5a1f9"
    ["0.56.5/arm64"]="41cfd1b576ebe77e46e85fd40906a7b3cac445750aa0c900eb15f2d83fc6360fbeae58ed3f7ff9580eadec2f08bd5a776cca4a403ffe3b0d960db5125b452166"
    ["0.56.4/amd64"]="acde4ba2b00983f519af895abad165ac493c35e4ee5e0d7dd7d1bf5655a2e298a80b0487263d0ce6cf41e030e53723fca73734b047854f9f73d8280bfef8b29d"
    ["0.56.4/arm64"]="ff0a7c2eef1a40afd9f7866af939e03eab853ac2bbdabf190ab1714219228b06fa807a7d706013c21e2ff8fa9c544967e3ecc6a111849cf2e216bc174cad858c"
    ["0.56.3/amd64"]="adedc75012992e1f1dc60d57c3c636feb140f4f7dcd94b41e42d4379b814f8542f3b695eef2eca2dff0db65d8628fc0b51e023628ab852f0eea8bf45fadddc7d"
    ["0.56.3/arm64"]="ea47d79d979815c155f96c2aed415c890f3e22b1d2d68a89b75cbe9fa6db0849c25f356ebea4dcc476da72069c21c4676b669bde7f3443cb5106cd83e2f20591"
    ["0.56.2/amd64"]="ab91fa247343211d4dcdbb6ba7c5214ad0ea45567481d453e30850205d76382a59e378705aa9a2cba0de33f01ba29129977e7c6ad9dda4191f6428f403ef76c6"
    ["0.56.2/arm64"]="49442507184d7a7f0b2f26dfe96a0ab89c50386da4ec6baff0dd67fea0690a663ee15774efe896807dc7b847b0bd113060eca878cb243b0809e00f7bba96fdfb"
    ["0.56.1/amd64"]="ca3337ad7e688eee02685833c77a75d09872c7fba6fff2212b2cef3ba398b1bf56bef5c0bb4f46848d70634def26e626955849fc285e95c362bef2a3a7c0af85"
    ["0.56.1/arm64"]="b6b86f221b92afc69269f056bfb5c4338802bf548da2bc7c592977dcbea72727999b636f527480718a4c102a7f51b9e02be90ad3edd558c675bddf461d6b2347"
    ["0.56.0/amd64"]="2b9baa2e9c70961678acdaeeb7b2b79ae05c4b57c453cfa287ab542ad2b687be572c3e62bd88a5db33098dec9932076319bc40fc426cc81abbda5778cd526ea6"
    ["0.56.0/arm64"]="a0ac65ebe3464340e9c609e7d9cc22ec1848e369a94b2813d79cadd0d18d380bf3e5cbb647574565b3154c11d240c67dc2d2d13e878ece9af0be921b1149fa99"
    ["0.55.0/amd64"]="69696856138168ab7c8b8acde79850200b762fa010c787782d708bb4b3cfc23dbea8272a5f2919a0ac78a6ad553aa79006e50abc5c6118fa30a33f312d72944c"
    ["0.55.0/arm64"]="928519730007d9051defaa12096fa9b75a57ed869b5ee07389efdeebda6a3015c2ac1c86e634d911d7e10666cce0600232210dd094b958a83c218b0985087bdd"
    ["0.54.0/amd64"]="91c251d18028d5796a7e01bd0ef51d9358721293ee64358746fd93ba8c6631fb139acfec9548029f97e24002cac0b3dc4ec412e330b2e97265ddd3d9753bcac7"
    ["0.54.0/arm64"]="1c1a9393bf9b9bff8ab4c8e153e29818c29d8623a75bfd4093fbdc7ba233f448b7df47e93eb2f372f938a11fcc186550e0cc270198dcd0cab87fc07dff76db39"
    ["0.53.3/amd64"]="7ab754cbe2c578192dfa3d798cfb96447f4404874ff1684f8d142edab5a31323bf0a04122311f5b08d8fa981a0bcb55248d8c28ff874ad88872851c5ee89be3e"
    ["0.53.3/arm64"]="14fa4e859c9015169c7fc561873054ee809232963b50b4f9e22dcd3645a4774c83e337fe5c8a1a4dc9f7446845be3e757d4bb5cba7e04dc4e78e543ed0524224"
    ["0.53.2/amd64"]="0396d2ea4b709ac05bb4fc83e8e2772ec247fc07e76ad623d0df3b83b157edf8367f1b176b906a77d28dfd0e83d528ca8a68d0eb2c9f42307465de4537577326"
    ["0.53.2/arm64"]="48a46356929324f5fdba15693de9fe45e3bd37660d4b972a2e4052c8f829e3b9d93131aea123fedff3a929224802b0916b583d524ba9ad2dff12384c6624f541"
    ["0.53.1/amd64"]="15b099cba52144c134af6ee671d909d4dd8f55a0ef2325c644f126ff164bb8c792e103a32d66d40647fc41bc40ad5e9e12540ebfcdad98c559d1500d95bda11e"
    ["0.53.1/arm64"]="888ea55429ca347cbd412998649388c32110278bd13e1eda8d1b028d0682f17d27c505afb533909e342313f9a1675b9a61a7efd64d75b4c79efc0724f67eca96"
    ["0.53.0/amd64"]="e9e1f41629398c325419393833f518a2243e6c559af45b91755f59bd7f8eb6f02b28b079a6e3b03619642b6bcba29ce85339e39dd059c364a8561a23b66309df"
    ["0.53.0/arm64"]="de6dba8531ecc5a2961136e8d6fc5b98905dc275e12e7add50aff801b573a0293d3c5ed5dadd27f3a547fc05ec398c7ec1a2d4c6be620de0cb7f38a6b74be913"
    ["0.52.1/amd64"]="06c07c5f139ffef6523a5d81a7f6694ddff8e17f806389570a0c532bcfa0656b24be252db82294133398c217d75818037317f35a6b1700d47750fb30cb0dcd6c"
    ["0.52.1/arm64"]="0bc8c03b7530e584954e07d0eb61bd558a73c768e53322676f90111709fdb1e55bf6340800a32c5984af94f6320743424f4de34117d023c323343e1578da1acf"
    ["0.52.0/amd64"]="2e568a69a540cdfa2950da9eeb0ed122a50335381db715bd077a15f222582a211184781dbaceb46346a61c6858a317aa43fa8ab60f8e99cbb7ae530a7a84da5f"
    ["0.52.0/arm64"]="b63a8bb64422c7f35cd358a7d7d5f95913599d919b02625414fafec11d69644748265090f9198b08674668959d5cb1a8e4568632b43ad9df679e9fd67acc3e44"
    ["0.51.0/amd64"]="77d2b74503dc6dde32276d0e6e98b87f9883122f85b5d6c2df11b83cefb8604d0a0a92b98d5cc6e643e0159a84d354f666343414bfa1eb970fdfa9934af6706c"
    ["0.51.0/arm64"]="80f83aaca2799088aee37a8dc889dab31212441e078b508a19ba5431286a45a8841330c8a7f6278f47413e3fe36b5481d60b2b4c926407fe324e3cbe414a5def"
    ["0.50.8/amd64"]="6059d281715143a0962c6fb48b5500aa560b941fa446a686d50121146d84462832efb1eb68039786a8c3095e4db3b595d9c4e5c0efb641e8ecfffb0ea9f3650f"
    ["0.50.8/arm64"]="a9ae8c374e9270713f0f535c80bc509d68c2d690adb10a0f78c4d776e60068c517d3e3318debb5b6828386cd7b8506362b4a66ac5d882fc984e65b01823c7dd1"
    ["0.50.7/amd64"]="84bf7908f773be254292248644a2326bf2596c099d1509f2f2466705dcd2b6d8a67c7a2a4718ce31c263621ce59fdb76c056226ebab06abb256b90b1f12d8383"
    ["0.50.7/arm64"]="36668933dc50fd3e00d2fc6c065c3d663e5eb86a728fb627f9d2f642cb0fb9cc49b755a6959d6ccfc47455a646d3bbd3d5938acb78b9358cd463ece33585f5c7"
    ["0.50.6/amd64"]="2c872c151143be30bcc921b211c4ae6e277b5beb666340baa34f51e7fe4b3c412ad42422a8f749bab8a562252b7dcac3d820b5088f5302475945b40ec5e0a252"
    ["0.50.6/arm64"]="cfaf054941eb7882e2fba97fa1315b18321d08beaa5a2f14b4159934ed183eef264d3caca6d4e1863965dab2c2a138fc06fc5ae9e0067955ae1f8d23e6237cac"
    ["0.50.5/amd64"]="4082e2ae4906ececc534d13776eedef41024655a29ab749ec8c6a63ef181552cd36cdd72c1e4e935707c5e132d0d158bd1015fff0d58e3d917ad93f6d86e0be4"
    ["0.50.5/arm64"]="ece6909dd1bd70e961208d0a61a362252f51aefc60a8dafbd48a2a1a2545f8ed0d8f3b2d9467a21d779ee365c8c467a32401c7352131c6d1460f07e934cdff27"
    ["0.50.4/amd64"]="70083334c558c3075d7ec2cd9b662422a5fafc51c9e241033ef9c4bb38feaf5cb38e827cacca87ed66864c17ed778cd23ddf259d4986b7552bd8580d41c2f602"
    ["0.50.4/arm64"]="37b466910a11399751322b734a275c8a1efc4e557b03b51a56c152c34aeb5ddcd566d349636eb0f54baa720ffbf22a1f0b5a19a24e46f897f825e4b046989cd5"
    ["0.50.3/amd64"]="05deceffd10e25237f070f5c6a15edc38971f90885ac25a101f15c98dd89a051363eb54768b43e7113da6e842b4ebd7788dc994e67fa5038f724f4b88083e5e3"
    ["0.50.3/arm64"]="2c2853765d665d98a6d059a3954f3f5a63f1ff32b0196501e09d8207e5d5535e8f3706b81c8da94acb683fcd2950532e383d72752dd5ce6d9169ab908ce1cb0a"
    ["0.50.2/amd64"]="b0378c529d7547c0e8e5cd9472ca1f28b2d3de9fc1c8d09143549c9822f2c3ade363423d58d43e882b6f6fcdf766705db10ac7b9f01a9a9bcf66c73409a4ee7b"
    ["0.50.2/arm64"]="31646412546dcdd5fe7b3ba354e84d1a28b052b696bec20c374ee5a6fc7802abd18976e0e2d1053d8eb672880aa774d8035972a4103ea95d4dcb4750ebdef1bd"
    ["0.50.1/amd64"]="65086d49d03b97d78154ef91a4924cc994bf4646317b5760c9e2da6edad3846a077d6e76a78f057619536930ad85582ff6fe6faa5ee98a3a05bc57aaa59f5345"
    ["0.50.1/arm64"]="aa2295d966fd26bcf45d4aa5c961f48045f6aae99092a7e4a79ff4c615292cde80257697c325eef886700536ba6bcac73bf5ad7340f5c2620dd3f80cb535ec31"
    ["0.50.0/amd64"]="5fff54b9169db0695338a77c7f695b73bc9b942e888f61fd2588d1290f8d9801e7f0009f89566f4d7dc81a56e02f8b465ee51ea37cdfd3b967b91f8882f67acf"
    ["0.50.0/arm64"]="5da51ddb4ef3ec81c60db5ff2eec8f2f73d0195142f7680d7a24d0bf67c66708ae6bc094d7e38526e7f047207d96a2d303aaedb01818794ea1d81d72a5de8d96"
    ["0.49.0/amd64"]="c6575a124784cced38728a2eabf7916f730ce7f484a6b5976f8637202d85b6931727fe26c44fc1502fd46420c09fa4d5f0de57026eeb77782f11ff7a3b75295f"
    ["0.49.0/arm64"]="92231ad75ba81650749fcb841bb6a5c49a1c12dec88942c87cea0766fa14b2351c42af098f2191a60340771bab813962117c6112794fb3b21312441b1ec98997"
    ["0.48.2/amd64"]="5bb705a428410bdbb16b1dfd0e3cbd3956e3503d9497abb205eadd1d1f0be2a3f0a2c0070726b4ec32dba5b38ce21fee780b4bb3be6d56d6ad336c33867108d4"
    ["0.48.2/arm64"]="852a79c55d129ba6d5fd50069bf59229c631075a06bbbb7a92857d72c35c7106dd0f42e46c8090609f474bac3477ac13fe5f731fbe2db4d7e29e3aad35b000f4"
    ["0.48.1/amd64"]="67bd9a74a6c732387d650e234418785fa12b1d3f9fae21651d69dd8fd779597501969a4ad6dc3c0520c95db5199b9239143f690dea543d4be6e33aa14554cb56"
    ["0.48.1/arm64"]="c6cd53a089817982ee7fb96ecee024b6c4b173f5ac8d60f9a0db7583633e0f089804f2ea51237eb1d2394664674e14bf6321cbe171a6479d47d6e79a644bee5b"
    ["0.48.0/amd64"]="64076ddb55b9f06de14187e7ab53423e2b72e43efe69040accbd6ad69553405ade8eab434249e1485b2e2f51a54d37ef0eee4279dad383d29cbb59c402d32330"
    ["0.48.0/arm64"]="c3ea9f5d3c23e9d6fe088ee93cc17ab263f6d74881abbe55656412dd8382d1cc49fa8e9fe6f6a5673646f66fb4751e573e27b40448c074194e8475326e886f7e"
    ["0.47.0/amd64"]="176313bbc6d6a891ea08275aa85b859a92fb96acfa536f1bc8ccfcbbd37b418ab024700b41dd08e2b2152f7500d48af40f257233e5536224660b362bb1d7a6f4"
    ["0.47.0/arm64"]="28489655d8acaac42785fe5fd6ebbd073daeecbf90ea1aa4905fcc6be1728b5cd1403eef4ce277a866e73134307af43f46c554d10d1ff5cff5b871148524f637"
    ["0.46.1/amd64"]="ca97c84474041dbab298b87bdbb186db25b268780974645ea8e7fed0ba3bb1b90de74b67196df536e78c8e944168f19c7a01fe4897f2a4297e44d35574d2304e"
    ["0.46.1/arm64"]="f2c47c60ca082a50a4d1b21942ec84648d72de8cf0fd5ec8626eade816b031336ec4136712e05ef74c65138f3aa4dd154cfb29b7116999a91fcace302c17ac2c"
    ["0.46.0/amd64"]="a48e7d344fb73f887d44e4cc3ef96c4d5c6ba1a97c395c1adea2ba9dedf28dd4777aabc091f3cc2d9fa2f47ba98cd5792c82cbf53bd5cec2d737be618e2c089c"
    ["0.46.0/arm64"]="78234626d257accb2bb0894fe8af6161c7522b1510cc270f62736061cd2768befbe0a3d77a1deb227d11fe3c80219fec8e65270a38d144bec28385b205578f77"
    ["0.45.4/amd64"]="f23c7cb6c301f2f9a09ab59fa581dba94b5531f63b506c632218bf0d114acda6734bb30d04a8d26727c3a7d3c874954c1ac2633e6c9e62e5f2d409e549a56621"
    ["0.45.4/arm64"]="4266f12e6aeb002137d48f738603484782a294fb4e0ccdcc1db69356f73d5d24dfe92ad2a6fa93ac5ea5ec28aafa6cef9cac6714c563c6d348fd27d6a78688f7"
    ["0.45.3/amd64"]="3c2236958d0cce569960186d7600672b4376a7b7d6447d49abaec986e6c5838f0e204ebb381faa8f3456b25d815c8bbf822d08f4b309b6aabc9cd78e36942af8"
    ["0.45.3/arm64"]="7894b92c065579aefcb9e33e7d5454af611da62b6fceec59673698e56a5f172bf9b3ac2c74c091a117d9124ecd27f5a6fef5025670abc9ced565f477b28ac321"
    ["0.45.2/amd64"]="6128ff922ac9bbbd546cf8997dc789c411eb63788522728f29dee81b5893e6091b74813122947afcd6efa16f6774dd5e505ec3f859628f5fbc786ce37af6d7d3"
    ["0.45.2/arm64"]="ddfe698175f29f67e1fccd755fda9c1cc2debe9e3bcdc99d8784568478529db94a16bb74be36021e41e7e6e68c1f42e5a959b3b9ad892e06556b2a3063ca2c3f"
    ["0.45.1/amd64"]="b9734b45d24a10cbc0620cc359896b7be2db9229750f144f6c5195ee8631be123a158cf6750d29df838434f82da63a65c0e0e53cac5d1ce796e20c6eadfc56f0"
    ["0.45.1/arm64"]="bd8f914961cae03fd3c958c3bde1575684428f9abae6169445fb22e5e46ce0b85b0f26523a9059d11f6841a71b7da0d4374ba2649fc33ea2b9c337f6a94476de"
    ["0.45.0/amd64"]="420ef45fc377639330a611ee74695e0a5313202824f124303dcae8207d086d98a6ede8f7bdd4373221b9fd5ff32f9de2b2d394bf2d5369a7df0f2e625584d53d"
    ["0.45.0/arm64"]="3d587d4155381613d7a94d8ee3e98d0eb33b95e44be968a9345f077211b1f9eb9ab3f2dc088178cd414f20120beeec392bd110631aa1c868bd3f2c576a1b5319"
    ["0.44.0/amd64"]="5223494c4d824a1bf6177df1e0a860ea4da2c9d181e113e4eec13882a2a26fa620d836b41464f0bd0fb20dfb8ddef39d1bff403ffee387a9bc6fddaa3198cbf1"
    ["0.44.0/arm64"]="e2b9d74f46ca205e94f256e32fffa870ea3fc2be5958be09dcfcf76f71974c22e0f950e7f03e081da01b6924782bb3110d4ccbe27f1197eb06979b21414d2a7e"
    ["0.43.7/amd64"]="c1dd732abe22fae37e54b626b3e6130d213b8b7a4c248fdc6c98fb44c5f008cc8003c002552e79df6ed9eaa76d8d3b71bf0d6c35275c418ab5a276bb77308fa4"
    ["0.43.7/arm64"]="0151bcafbfb36c99e33399eb6a2d1cc2391ff33715b0436c632d927bae11a70cc73227def053acadef5ed1d88dd9a1e65519945356fb63ee6c60f61a54c63ffb"
    ["0.43.6/amd64"]="cc4c3012e8cb7fb7c26d0ca44b968e263ae2c1d4b7abff84f806fc96e1c4f9a0ffb9775be385d41e15fe28a03595921dd72997e5e0f3530327228b7bfd2683c0"
    ["0.43.6/arm64"]="ed7056ac8e88ffd5d4740177449b4e2e0ddcf9c34b03f7c3ae5ae549a5672b5d90f2e05ef00b7eebbc9fcbafdffce030dc3f465c4a4f026fdd0a2bff1d2f613a"
    # Version 0.43.5 did not release correctly.
    ["0.43.4/amd64"]="7a338bfd671c74cff1cf90d44f79291e8b70a5da9de0abc0d2492a6e0b2ef7d09d4a75938d60e11ab214436bb4c7ec9014a4b96a819e754d4c672972902029e5"
    ["0.43.4/arm64"]="2a1ef9da634c22c7c4dc8e4196bccf763077fadfe826f4de73ba45b7c57a7ba87c52d2443c170f488408177a294a149814fef64c8cc0be4f0c11e40e07d019a1"
    ["0.43.3/amd64"]="7592704cfe6d6a40c7ae64d65fe3a515e2de7c9f12cbe88b0ab211419e849eb958bf21a4eaa7194fda2bf0464c93b332910c8591398553775c8b2b5ed94f54b2"
    ["0.43.3/arm64"]="1b9b484ab0651cdcb538294fbb3f97bf001762f6410faa961e96b03ac5b70e37f43f9670a85956f2e034bf422fdeb3119363c2433c1a17623d183d43ad18debd"
    ["0.43.2/amd64"]="2c38cc9277a4841ee13ec105ed4fa2a0890268c99470cdb488dae0e0fec566560dfbf6e661d6d599a55dcebe0019f8fb1a3ff598699064f65a564ddb3f23112c"
    ["0.43.2/arm64"]="eba46b69d6205c59a8a6a40669c3892a23301454d211b38edd2b079507797a9176def3bb4aaf4ec8adc203972a63c249f78c08e25469abe198ce8c7097be1620"
    ["0.43.1/amd64"]="1146725471422de2e51c6c6eafd4c0bd4f28dba809939d4b6cca7c376063e3785fb03c428482862808f5a7186fac734a552435f34ea00cce74da2a8e57f53e03"
    ["0.43.1/arm64"]="294c0aae25c92bde48f34f3e78570343ee6cec879a813a36d984ea89215073bc7f9000ed59b3a90f2f2649a578694f8977408ff54b561bd845ab4f5a3e004792"
    ["0.43.0/amd64"]="21098fbb8078354e7e2c062cfab2e1893824d189c4ab4a124982fb511f7fd3a4f6854229aed31a410c7259fd9917b5d6d37148f1fb7d09d267208a4f31475888"
    ["0.43.0/arm64"]="bad494d265baad67c94caf7ead157e084e8a2658ceb355f53a65391eb4f06ec5c0317b230e9127b0a6a492263dca0bc5e660bfd4b07e21cc1543626c81ecebf0"
    ["0.42.0/amd64"]="61f720093dc031870183f17f69c201ff4b6ffe3112349e2160ebcc496d4b2c084469619b1c08d7cf2a4e829f81fdc54890ccae8ffa89688e5eef75002f497939"
    ["0.42.0/arm64"]="4aae3c3228c4ae364481e0de75ed378fa87fb4cbd595d0c5a81c0be954616d53d0abfcde5018dc6f43be779929d286570205cedbd4df608d008cd46a02f0f56b"
    ["0.41.1/amd64"]="46dfaff0cf553f47990690a01bca32e4c06a1364a5bc7c8ff62af7f580e035271827f75ff83fc2ff1dea6a47153c47c2503673b851b8b2bfbf99ef4306bb44ba"
    ["0.41.1/arm64"]="0603a8c85f31ca512863a104513dfc00c70f397b119e866a7a91e0d4349e8fff0fe4dc3139212006245c03472fc13efbb094943599509d59eab056167b686142"
    ["0.41.0/amd64"]="7fd15484194fcde837d14f93e39dfd883f2e51f9cce07792027bbde33d277f0056ff6703f5060650f6e030ae4cf9bcb6ebdf1f20a214303e6cd004540e78f707"
    ["0.41.0/arm64"]="930386a174c032e3c6e3b91fff3518384b5f01826fa4174548802951c10249ff77ddf999153d396ff24f9d55079a5a75bd97c4cff16f60d0847af62036193aee"
    ["0.40.5/amd64"]="3fdef21d19a265499b37c9ddb6bda14a5bbd216688aaa300c57f5d7d484155fa9b6b7b279d12433729e3be8cb06cef3c322a4e8acdeb9baf8514d541717ea5ce"
    ["0.40.5/arm64"]="2ce201ebc9f023f774527a2aee717db6227eeeb2d29182f99341dc7a02df1d590d114251d0c6ec2567c63ecf3d31d39e8c047776da5d084d7ae0cecfedd7ce56"
    ["0.40.4/amd64"]="63d61e708af898e4908ceff45692ef13191bf2a841dc49373774c4a27bda3b1d78380946392941262a621e8e4535b0996033c7788896bf0f424bfefcbbc04270"
    ["0.40.4/arm64"]="27b146683d17779cd15c2c40cff6c1efd5833b326e0b236ab232c84e5eb3be70b0908dad1c27f01ea090eb9bfe25910acdc296e214469fb447c90d413264323b"
    ["0.40.3/amd64"]="560de2cc6306bc40eb6134e59ae73ef6bc44c6f14e54a27465fb1b23dbade305242f20b595c99f538b27b89791c78e285c69ff5c4027e0a3383fccb5b9361b0e"
    ["0.40.3/arm64"]="ed34c54d35bbd33861094ec08d314d54823d8bd42de3db9952a975d0323ce6c1e987bb821cb254b1ea64b6080c46e3b19ad608cc4761b66f229e0907d3183852"
    ["0.40.2/amd64"]="20213f2a3a988135cf7049e5b0a90115306b6c30a97b67c05bc95697a7df637129fcd166d14f4e691cdc78f6863ba987822d113609cc7b9fafaaa3c7612c10c7"
    ["0.40.2/arm64"]="82acd7d8d8d8bb883190f46b884ae0f0c020acc24cbcf5379fd2089f40e1ef846fd5b8c461f7185d9e0b7eb8651113537b600f100a93ca7ac3d02f8313838b8b"
    ["0.40.1/amd64"]="8e0bab8c47b4021813724ec4367f54aba55b2931df76ee71e7d5f322c91ff1a3312489c2c3cd9fd77f88180dc27e0f0394bbd8b3e89037f522d74d758d34b5a5"
    ["0.40.1/arm64"]="a176f7d253d9fee628cde79c4519ba151a4622eb6329ac4ba06cba999d2feba15495bd5f082dd7a0ee9f0682a48f87aaba5607f53b1d65838047a3d9303af1c8"
    ["0.40.0/amd64"]="dd712b62298bccc7ac52e1481b4a667d9ff8c03ece83632ec7c03cbf46eec9a352521d3d297861e58fa709b40fab4ddff56bed534ff5aa9a6061c174dbcbf5d9"
    ["0.40.0/arm64"]="5c7cf6000833e953f8aebe64773f1877dac0db8ace82582f2a12225640be1a97c44c5046f770e5b07dc60a3de1cf8b8c2c0ff11fc7885be5cc13852c401d99d6"
    ["0.39.0/amd64"]="b6e5ea391eb2270a5d27838607bf1974afb3495c8b7d979a6bd40106a7cf0e7eaffb4c0a2bda82a871ceb4506118b634777128cf3a955e38880eaaa244e95507"
    ["0.39.0/arm64"]="2b6c7dbfeca9118fad46c6081a75e9486b201d4b5b9c0b21b62013bc2c5eb7b7eca03f797686162ea64ba5da06a7d6c56b881675524bcbee5eb288d59f747aa7"
    ["0.38.1/amd64"]="e512c13726411ae5a8c7139660d191a6c3ec3137c550bfa4a1d7641c61b4c6d8ded80e711a31ab6a38a9ae0d119ed55241de95d6bfdd1a1b554682a2900247d4"
    ["0.38.1/arm64"]="ae19a3508c897bbf08fd46240dd60a651490893634ba91317b065d052927c25480ffaefbee7c55d4a103a1959587036ed4acf9dc1bd2ba7b64d177f7e57f48c8"
    ["0.38.0/amd64"]="b9ffaecec4415218f4126e44640987577c3b47fedf99d94baeeb3145ebee01c4e1574d63452d09c65b9a90b91d7078a5593fdfaf1fe3a7fb1db0abbd7de9f1e7"
    ["0.38.0/arm64"]="5ca1fcf3c2feae89df9b36b4b831aed29c5fea34449aad3837a9de31f0c87cba60d1f79cc0cbec63a33244218e0a2dc437980d93c2dfd9d85ec6502d0fed6ca9"
    ["0.37.5/amd64"]="0d38e5e4f5919d242d8bf441525068a82fceb87b3e5529c8383e27d7c0b2062881b44f8d8de0d70c670a4f059c6feb19c337be32f5907f08abdd73b9cc310138"
    ["0.37.5/arm64"]="1039bd6cea047b197d84f76308a24d064daac0365234acec63eeeaa35311afeda0c6ec193504bc5067673b87d217a169964b7111ae26014b61d6ffbf376e4eef"
    ["0.37.4/amd64"]="14f5f5b5fde38b0788a1671a427a1997bcaeb4c184d275bcd082fc017497764db4fec9a2df72de6baaba30faa41c4ce8915a118985573820292c4e8b20fc44b3"
    ["0.37.4/arm64"]="e1cedb8047d8bd17500107e3100dd7019274638a2b474d97b5f25a0f5dd37a8d649364875c753d3a4cb6b700323227f851b8091804aa16c1f57cab6db4fc6620"
    ["0.37.3/amd64"]="1b8a29f00f45fcde49785ce608efee86e3a1ac42bfdd61ab38debb1806519c595ed9b2c8af8e02b65bd739b25fe3db0db853e9501703c035aa21f67a5e779f13"
    ["0.37.3/arm64"]="170da67ad87217a66543cff3afb81670a960180b59e4ea12ecb6faccb5a628dfe45e04689b8d0347a0557178ff1184f55d4d3910af6dc34d0e6d878a8059f49d"
    ["0.37.2/amd64"]="bc67b108ae7dd4cbff09cc95ab2e9127c3263031c23dd6c6503789dfda49d70b1756bee243f39ef52c9431a13d075484807559094f9a718d1c74cc943c147bf5"
    ["0.37.2/arm64"]="0ac7cf8bdca348c189531385b39b0a4861f59115ed11bfbad010865031e00583641fa774baf454eb4a3e432fe6e5e59578cca87974004c4f6bcb2ed459eeeca2"
    ["0.37.1/amd64"]="bc0e0095022155622b79c67a00201ae2072eeff789d679710691f0311f86c015e8cafbe76f6d66900f564b3e42c4bb6c5620556f2376fb62ed3e2a404804f344"
    ["0.37.1/arm64"]="0bbc4031052627503f7142b08c1aa49a7b424c32572b7fc2bcf781614530be0856e094b2b84ea1011728ee19dabdedcd5137694a7aac7339617b67cac926b0fd"
    ["0.37.0/amd64"]="51dfea369a69d109b8c73abe9363d5f38d41a6b56153d68e99fa266165800e4dbc24dba42ea1bd799e9eea989306a22e06b48683f3e364e60208791a6fde71ac"
    ["0.37.0/arm64"]="37f3ea4634fa10356d99dcb2c9b84c9dc699771f609f95260ece0cba0f3f4e0c5c87e951a4621a0a4dcebf6b124e698508362a642bf39284d5ecbe901a2a00ad"
    ["0.36.0/amd64"]="e279025f620abab3da4f4801265505bebadb3f7630b69cd8903ad04b552bc8efe06b579fc1f6667e4503381fd918bfd2b198dafa3bb1eeab158819e805a61d80"
    ["0.36.0/arm64"]="81c2a4f85c29ece1e2d6260f6b8bd424b76381ffc8f8e0947e37dad678cc97d31451733e837caf3e9b880871594c4409fcccfd8d26f1668c3dbc0f04a16fc318"
    ["0.35.1/amd64"]="3cde4d48f024fca9e5b58874d6b74e5485dda318575587803c4e103d2f77c4c5ecd2e2cfaad66d942efee26b2cd02ed2e4d3819aaec8a55083129717b70a68d7"
    ["0.35.1/arm64"]="bad6feb58ad7528fcb978d10981a3ea03a26de0e4dc89c6ce5f4b4158847a8389167efb919284d437e3f2ec49e2c8c6426824e18dc3ec72685d7453c3430046b"
    ["0.35.0/amd64"]="d447408c1ecef1ee5948757f3a9192885570ef93b572e908501407e2d81890bb5d93f4ff7bc51f02105eb396b45eaedeb8ce6aa0b4ee1e39869d6cc7f54c7ff4"
    ["0.35.0/arm64"]="c3ce9352dd4808670c3c91ced04c5e7244f40298c29e872e8b9bf3b2937cd6e6a403d4feee4707e8cc5303c2651e4819d0936845bc7b4dc526090e50f12670e4"
    ["0.34.3/amd64"]="f5310316bac75578fea2abd592321de1a8c782720d7a35173cf1d2d907d1d6d85b4cf5151cd25ad2f05274d527339a46322e54f3006783a76d380ba4cdf718c8"
    ["0.34.3/arm64"]="56d21cb838f450809dd00b0901d84f3c3e454bd5cce9f0b9a813e9b25412eec2820f611c7da629dcafd2503c92ed480902c583bc6c91c98c8db192f36a43920c"
    ["0.34.2/amd64"]="3557d9579f6d466edac3d2d55fbec60ace0f64a02566f79017042750851a5ac842deb03fbffafd4aaa4dc5cc3a575a68200f86df048f11ff7eb9d8cad890d14f"
    ["0.34.2/arm64"]="3c05c0e974b60ed9d8c73aa5fff8894ded83e92ed958abdd8ab28a059668bfadeb0345b6e6507c43f17673790fecfdd49fa02c6cc6a7f91364b2010c20fbee9f"
    ["0.34.1/amd64"]="6cb544e511d0b43d9174cb630463639616f88568d7bf58086790cbc39f694898a5e1ea1a3652f11565665d0a5d89973429573c15eaff6c17a301586e462d4dbd"
    ["0.34.1/arm64"]="2e50949120bf3fc2192e891043527b962df975008982d2ad7d9e616f9758ab14c4400566bbd0013b288bb83e5ba9593fe841865b4db0aa79963e6727e3ea1bd1"
    ["0.34.0/amd64"]="2f6dc603af6fbad087b7843eb2b81c22be75d2a487aea214a865f97d619a5ec8cf31e09766bd8a815e4af3175119d2507bf1afe04a382294f42f4d0ec9e5711b"
    ["0.34.0/arm64"]="81b2311fb1a1d12228d9a14cf77abe9736645001c70195bbb5e9d25e39af2b6e928fc37e741bebd74328adc3c50c2fc2bc2ee2d63dbcf759e5fd5113e0a38a63"
    ["0.33.2/amd64"]="a313912d010f685a2f3ea0588d55762668dabcda6eb670738d96f1bf2aa47aa26f5c58cded2c5e2a3ca6b7c3b10d3bb814827f0f02eafafe8a47ca6a4ac48d5e"
    ["0.33.2/arm64"]="36409a628aa186c5583ced855d8bfa349a7ec2183b7879a4fe8727f02a27abd39acaf5a04589ca21cf3f5c2d9fd3f2f9a6f60c24eb7b034adb5f788de1656578"
    ["0.33.1/amd64"]="bf7119260bd8ba8e6717de0e66c75f21eb8d58655a2c10edf70c545b29171ad14e4ac1544015434b5b84e48f1a3061cb7f0383856cdd1d043e524702c42e4487"
    ["0.33.1/arm64"]="ecbc2e48a53d050e9dd267104eabb9bdf2615de52eb7ce12524ec2987fe4e931e52e08a33a83fa3ce6f7d74271aa9885183ca3e0d260079fbe12f954778101c9"
    ["0.33.0/amd64"]="a9c835a552c0dd4fe9a6ac6f8747c4df075058adc97db6615eb654d9fa1a8b77172ecad1004f324e674cd2cd76f2c01e0796b2345610f97be286394a616a9248"
    ["0.33.0/arm64"]="f1bab066aec09eb004649d5ee818bbc14207c65da4964e44f4800cf42f147df98ec95564260341b9e631fc7a8f2d26eef29f7b74e59c48b6922686e3aed50c52"
    ["0.32.0/amd64"]="dd1bb86ff46ba8b3c3e7b4e43b1170c194c38308a4fa7cb8ad6bd68b570ceb716a22390a7d2160725f027daa7baf81486e1d771146682d6973dcf5a8fe2ee507"
    ["0.32.0/arm64"]="5777e9ae2a4a4640d935616aa3164c58c76a3326ed28ca638fda06bd14ddad6c524de96f24a314092988411acda39ecc554512277f10165da6a77fb4a6f3ebd7"
    ["0.31.9/amd64"]="73e40c9ad826f8c73f24d13aeace9baedfc87d16fef259b7f0bc1c4b30a00ff823da1b3498792cb66ff9340e112a6160a866532af3baa8721b01a9a14ce75c20"
    ["0.31.9/arm64"]="6167293f846484ba415534f31caba4be6eeb4bf8744f62a8022c0ce52118d1c1034a6fac6e9125430fa6c39b427930b29f09e64c315b3be037d86271d58ff96f"
    ["0.31.8/amd64"]="d9f1cb40cd60a35d1cd4b2918f8f3795793d974e1220609b62e7cc3507b2979a0c9a60d056d911348f2d9c1e89ce4493f6057d52161cd4ca4d40ed25976b6953"
    ["0.31.8/arm64"]="0f93d7741011338a6cf17f2a0f480ac73e9284868c7536a018876af25fdb5ed831263b46e37b5e8d79fa8c08a07dc9bb0f902fd045097ff01cdf9c615eb0f015"
    ["0.31.7/amd64"]="f35232df0760e156962fb15900491b932fb50d728105b7a09a219fb50c2fc509472e9af651715f15c83461323a57a4cae6d547dc366e02ac89423a57c171c5e7"
    ["0.31.7/arm64"]="9d6cc92bb5289bdf249ad218e3fb6e0799bb3c373643a73f6acb4d045d52a690a48c3566f0870e3d0d18f110c9b36590d3e7c7a6c5102ad88431c493d33c1a70"
    ["0.31.6/amd64"]="a55dad2db710ed8b3c8066bb9e8ae34240c673595a56704eee0ddcacdb78c6187d2e01463dcc48d64925e03322e0f270ca7fc470d065dd9b290cb7aee8687f4d"
    ["0.31.6/arm64"]="5aae7d4a0dcad22be6755e76414a400dd44e76d724bb0dccb5aee6221dfe74a80da2d4746ffb67be245c9094d9815e22b47a42133980735e75ec2e8613968f29"
    ["0.31.5/amd64"]="d9ceeebbfe43a73fab3752863fbf7fea9b20b6d07e930d9d8584b4a98999d92812cd63a46b45c06b5f4c37517cdc4febae6a6c590aa699b51ff8da806dc18387"
    ["0.31.5/arm64"]="eb69620a6087d26a31659f42b56d7a6f942914f56c95cf8a8706c59ef2e8e1cb94351dfd2e6f356605cc3f94aab29b39f478831dc26cb959f8931cdf281386a6"
    ["0.31.4/amd64"]="12c1749a8f2cfa9251dc2f897bb8ed4d9af63f6585efa7431317c68a8e33063054fba98b4949f928a5c7dcfc8eba338fd798b7ddca2efddb553bbd53dbb8ab90"
    ["0.31.4/arm64"]="52875a0d7439f7379dac8eedb9eb5f78a291700fb53a6e4622c15548525ab536b60f1c00dedcb9e9b39cb76e54e43a139fd90e441afc154d07085e7f66a0cc26"
    ["0.31.3/amd64"]="bba07a8526c8e23c339634069146526c615fd1cc219899aad738805c2449ce1cd13338d475b8663f02561b918ce7503ceb47b6c779fd31a6c99e3ce220a85a7d"
    ["0.31.3/arm64"]="9a6415fc0fdb524e9a15a12b37e1621e2411fbd55de7555d176a52128e9189601eab03692e04284420584b3cc38052c684ae6f63d2ab70769bafe224cb9da105"
    ["0.31.2/amd64"]="e631a2c3f3570f8f95349159f4ec19d819755886f9d25b27b1fcd29abbebcf9cbe9970f771b3a82518073fe61e90c712251638ddb9aefe642b7c87e7b66b5427"
    ["0.31.2/arm64"]="24a9bcbc240dea537b425f4f7872b23eee3a3c0953c911e9a12000bb942ca24b4dd6c606085b755f2967dbcd7c85fbae91ecfba940035439aa8308ccff682593"
    ["0.31.1/amd64"]="26465ed5a89e566771f31c76cd857f83e055277d02ddd2cdedd01ab8b6bbc3ae7068bf785b6754fa4e78d201f9950767a716b4565139dede347dbe8173022c18"
    ["0.31.1/arm64"]="456c5d51cc70f1459df3ce6568788a2cc400244c2a4e17016fa38e8bcfb3ed8cee652ff50746adf81141447fc9834de21e02668e93985c1081f7948d18c9eea7"
    ["0.31.0/amd64"]="2fb9c2058bbd877596c3078d9b90b5bd2605dbc977ac9ae3c00203803575e70ce78cb997398f31719844d1560b74ceec04b2101405084e9870e00773eb47f219"
    ["0.31.0/arm64"]="5a8f4a5b7f8698cebb22a4bccd5da46091d6f95271564d8abe5f64ee3e6bf818ab83fe5af30c39e93d9643f0a16ee0791ea94bb56dd4c16c3ad0474993fbb7d6"
    ["0.30.6/amd64"]="486294e270130219258ba22920b7d447b629abeab2dcec748b30e7d9ee95e7eb8760597c3b15bede4b9fe1bcba489b27301485b771ede2060e9b08187ed2b0b9"
    ["0.30.6/arm64"]="345f54a24b1f59818c2491ab6fb623c976a99799511f52b98b6381647e97d72970338ef376f8184361261a849ecb1954219de97d92a2d7af77b145fde9662c5e"
    ["0.30.5/amd64"]="b58aa93726e9e745dadb16319a22c27e2605e8f3a6d45ec579dfbda8f183f462559007b503f4bf94c3386a8266f1a9f359b46cfff205ad10f756d3da785f908d"
    ["0.30.5/arm64"]="909871b6460c67bafa36b727f45955842c80afd57155ec5bfd534403f27334cfa36b29afae3fc669aadbf6ff83c38f1e794509956a81f3b8612a744c6befd920"
    ["0.30.4/amd64"]="953c2f91fd49bdeb8aa033b45f852cf953a08a57506e114052727b06b92cdbdecf414acb36e03361f5d98b6ddf7b3c58b226eb3b2995327b81bf3abf51c87f08"
    ["0.30.4/arm64"]="6e6962b03665d7e6a83f2b223bffb1549e73c729a493d4fea9e5126da6727c3efe760def9c4758b3a31049da6da236d07394bb18d4aea603e4c7e05d8abeacdc"
    ["0.30.3/amd64"]="80800d525ee68c8f962dd9663a9c960069cf77d47f17037a8eb8442c3bb7df0fa9a00e448574993ccf9394f968e79a4496d54cd5a50a07d9fccc9c34587bbb6c"
    ["0.30.3/arm64"]="367a168b3bdf983596564875c5c732f10fc1832362e401f0370fa404db0b569eb0cd17442b76b660f77c01ac57f4bdc0214292e3b5ffdb146103636353ee507c"
    ["0.30.2/amd64"]="1d477874435312463ca6db90d0c474e60f57de185b4f070fef0e4c55055837ace3181c0a5d13f47d3043dfd0417002eea5b011ea9c08bccbe159783fe2271283"
    ["0.30.2/arm64"]="80d40878e0e681eb10bebc4a120a4f58f94d4d7cd9ecee51b9c8d4c3243b58a0e7be41021b1e7a4c18291f51cd5d9a013e1029505f18fbf36eac0d8340d03b3c"
    ["0.30.1/amd64"]="ed5e90340fc008a3a9929ffc5fb7de0485d8270635f95966dfc71a10496dd4c3ed994b089236c99927b46f38356c1d6f7686efc8721fa2bb0d73ec65b61215df"
    ["0.30.1/arm64"]="f08fc88f7b2b40ed07949bfeb31826f74b9a19918dad6feafed76ae8668f723928dad16ba81ba7d07a090f2aa9f8d5974f6b6393e638c10d4999660f9e4ceae1"
    ["0.30.0/amd64"]="b29f55b2ba06ce10473220994edcded8cf267bcd5780c26e94fa82676943ebe146afdb3d4efede8b2050f5ebb532789a7bb078323f00b7802e7b5f8467516bda"
    ["0.30.0/arm64"]="a26822f8dbe520b38dd1f9cda1864deef6b6a55ccaa0971844e2074008a14cfc137cb9f6fb4905f23fc9306751d36619be49df8cb16a4f039cf6f9170240ac3c"
    ["0.29.7/amd64"]="cdc117a3f6cb84930362588f35c800a3510924616ce30c815db637ec1f511b3005e4674dcc6526b94e76ffb2aa548050ff51788d4aee53a3a01afc05a088f906"
    ["0.29.7/arm64"]="d9b00d35b2d39955dc25a03835b14ab6e15541acb3a216a1f7f15b254a4b8d28ccf3acd540400006ccb3650c23fcbfa6a3d10180bf1177711c062b2877c02cec"
    ["0.29.6/amd64"]="f82c9495ebd7e94ca97d7d702ae73b8b248484eb51930c907c0a20e2a11253b54719afe4f54813e7b38674923b387881af4a22db10878de54b71ea06fa8d19aa"
    ["0.29.6/arm64"]="c6965b866d15f288ccdae2a9a7658428ff80f1d9122225f0ff564b5503bd7c7bdd3bff48dd218a9ba792ca76269892b278675f559215ed66bf53b9178542afcd"
    ["0.29.5/amd64"]="5d275d0383383c9c8e647c6241880765411c344e753d9ea35b5ad35ea53b1825c0a0e0a58f80f17cbf8881c09d826439327d9061b5eb3020c3a9cdd354959c9f"
    ["0.29.5/arm64"]="cdd7bd151aba610dca28d26bf6fa0a9ca706bedb29c0715f958e9f80a7267f1e6f2d41fb394ead8b1cefb4469a93bb7cd9660fab315b2ba010844aa82c660463"
    ["0.29.4/amd64"]="3bbf31c3078b2a67c80060c9c7e4e852e0392850e6093a2d3bc230b4da93ac1ecd385dd096789d59bcabe4cc0bb93e06750d89b0210dc408b1656a827fe49d8a"
    ["0.29.4/arm64"]="6b2a494f580113aea31148eadaea83b9213a8460b0c0332bef6a5ed4038a4d2de43643946bb30bd8360a00ab6ac26059e77a9d5fc80c6fc92da3b9620e033a69"
    ["0.29.3/amd64"]="35f7f738264b6a2803dcafebba24c997436fb29edaef20570c4e882b205d3d8aff86b9dfd4e968e82d66609304d12698cb48222f344581d753225229b232a8c8"
    ["0.29.3/arm64"]="3f76ab27960090faded119bb845488c60a160c57ccbafc5f39e64498652896f784b81c1fd7edcea6e0c66b38ac46fc1b7cf192a85ee42cdd6354cb2a6928edff"
    ["0.29.2/amd64"]="4049825d54fdb95ecbca75f8dc5c39bb13f2c185b005fdd1e4f58d406ed2260a230b1f8b090fd5307c14fe2e275a5ca2a8dbf1433f6f73898a3094e21f9a434d"
    ["0.29.2/arm64"]="461138ead525f4602576a316cf90684cf65ab4d473c4d35967689fdeee11b8ba5a761965e7aaa7412185eaf22b8459d959c0e0fcb4532460a193173eedb7caf2"
    ["0.29.1/amd64"]="36fb4963b45f27606dd62363b5be5bb6620dfd239ffeb91ad695fa43e90eca27fc5d9e48db8bcf797ecae063fcbfa660e1d69067e5f2017c150f00c29b8c94af"
    ["0.29.1/arm64"]="3e858d899ba1981b6bf13053921d2c43d4c4af6196150546961a7927812a506c70cac9d56f1bcb59b4a7d807d36ace827ef002116de8ed07a5caea40b23deb6a"
    ["0.29.0/amd64"]="ed404d950bfba39b16be604e6e57434d01a943a03bf42595231831c41cff9a0911d0d7c621124f90c0c36af199f655c1646ca6b3cffdf4ee6af4a6a2a985f433"
    ["0.29.0/arm64"]="d8d3e95373217a9df72b18f435d1dfa3ff48bce7172ca524cb8ac96b35eb15406132a1517e9c5272dd53c15ed798e8c0862b94026970659006f24276f87adbbe"
    ["0.28.0/amd64"]="335a3f68961f54ae976c636674305498bdce54cdfa543d059327c72b8e5446008cf6fd6441786b55df41ef37c2126e5ab8a2d64a768521d885806f73d5c3a4d5"
    ["0.28.0/arm64"]="1162812993292a1175900dca277dc4bf7de7f7ba157971d75707bf306afe0db3ea81605596c2950ba541bb9b0875afd7a41c5562241ab19e4f942a5e36e420e1"
    ["0.27.0/amd64"]="90c89134c7b9b1099791bab8b6542d44c59ca4511078778df8ac8e8aeb142f469a08f8afcef7595276e7b3974096bd8ecd4456a883c6c850eaa64a7064e9425d"
    ["0.27.0/arm64"]="e3405dcacfdebd20279cbccc970b1638d92d0bd0ed38db6ebbbc7718b8d310b9ff079120b37491b9ce005251c58ddb908e038edf7cd16aba060868602f3ff0cc"
    ["0.26.13/amd64"]="d0050e870d6ea8f46f71a92b61cafeae7b21c7b37670fbc6900cba0264dab16d04a0cd11e517a4a1210bcd2875b2d2fdb06cbedc1f22cecc414c1e9d17c0c105"
    ["0.26.13/arm64"]="71bbab7abdaa6055c66ffe7352843aef2ea8ed352a9fe5c85b8a3b10de188ecd0beaeb1e929343920d385a3a39d4c17e0f3d336769ee78a4ef9078677988c18f"
    ["0.26.12/amd64"]="aa85e6b24dc5479d8375f9431510ee23c876bc48f5ec2c4a3fd9feb7dd9f535bd6ca28caf31cce29db7ebcf27a7e2ef38a06359004b2be6f1aa56a81d9d0a143"
    ["0.26.12/arm64"]="a59324f96551f6072dede1f9fc035948f7861c877cc01fce8a78f454a6ae7eba269f960859f20d75d48e774d7f2adef36d5467d459f6f2468473479e448cb121"
    ["0.26.11/amd64"]="9d1a5d607b55184ca1c09fd5004616bd44c1c3b0fcdc6b6dcf5463e014858a5e1e57845fc61d3284c421c575f31718234d76c44c03c7d8c5e4b63a4ecdcfa398"
    ["0.26.11/arm64"]="7427a8cad4d8a3258932ef19ccf50a1e6a736322dd5e8a6ae9e1b0207f4887744a566b0c8910fce3dd07666f2d19f62928e8527b15bed4440ae8a6e18e823be7"
    ["0.26.10/amd64"]="53ee924c0437688aa193aad8c1ccdb35794526468a5b29a7665f80ebbe5b9d4dbf2ee39015fcc70a87f9a21210ef9f5ec164824c16bd30af8d668f0da112535f"
    ["0.26.10/arm64"]="2222b3f77927e958fbcb0de64decc45de5014efda39dbf26e57b7a6c726ef055c8f5756a56abfc7e2872a5f436ed039787e9cb80edc549f18908f271522d67c1"
    ["0.26.9/amd64"]="ec1dd7612559241243ceaf947fc1d1306ac14944c62a3abf8a8feb8003856d8a0264c6a4c602c8040512d1c98a8bca3dc904cf6a1f45e3f5f14b6fbb58ed300c"
    ["0.26.9/arm64"]="426dea6da79bb5aecc0e596f9fe83e4b3490c09d066673c150985712ee3728da306679be3a6c714e6e6753ffda7c83ef7c2c23de3da525c56b682c00bf41adf8"
    ["0.26.8/amd64"]="4838cbc4282ed8761ba4ef53b963a3f65cc37c70501d3d627130898f89f148c6b51cdf826ab1fea196a2deea24bce87ab1cc4224f19a4eb57679937bb1a779f6"
    ["0.26.8/arm64"]="5e739548ee64ec8161e6eaf09a2da5079c5b06cd53dee7663bdbc49d22974cfddbdb3230c3dfb4937321cdf679bb915a10570e830265a2b4f218c1605935aa9e"
    ["0.26.7/amd64"]="16d54d79d659841a672fbd5178576b287a6b96d3f98998f58fb0a922314ae4acf39e504b8ada5a5bc3b971c33c8b2877cfd634e0c86fc56f07af4f5e04dbabd9"
    ["0.26.7/arm64"]="a3bbe76b3ad01d85a839ccfc1b36ddad9215dfadfe1fe94b72573631c13ca55f632a6d3a75fc62db77175e6b88c1ead6d29ffb1ef30ed614586f5b4828eb0132"
    ["0.26.6/amd64"]="49ef4bb8a47a333b701b05597550052655af8ccf6ee8da6fd679bc8a7d8660338442d1318ddd326379be6759cf40cc187f28a90dd397ed11441a40265e2b51f1"
    ["0.26.6/arm64"]="3bef4a7319b92041904b31cff40aecff35e8df4d229ef32901e6e60e0121ab042331d5b4b43b05124efe8ca6131af2c55d25da0398bbae896bb18f45a0e31d7d"
    ["0.26.5/amd64"]="47e01c4b774617b39525fed69fe4729d9f8a539723de7c627eefee6887b308561ca166027ae94b45cc2ab685582d38722d0c75e8b12bbe864837f113801b18ed"
    ["0.26.5/arm64"]="70acd0ba3ea0997da2ffd50839b0f4da27e9b7130a0947c626c25177e8e36341d1525514d04c642bf533ff01ba99e03b4d16380365b48fc4dfb7bdb884d25121"
    ["0.26.4/amd64"]="1cadd8e79f83f29c2d7b10ecf4f616a565f76573d821c276ab6f944e71a16d8ebb30127069c4746a9d4d75cea7d98fc1ae83d673b920837af70315dd2db882d0"
    ["0.26.4/arm64"]="9154db8063f0a9e3764dc848342814836518fc29f80265faaa525df2b723948decf1e41b7b806e4398d05665f68af2b5dac5cc98120d8e46edc2308227fa266e"
    ["0.26.3/amd64"]="1034854a3e8056ee120094071e938096ebe550d26ac0df9eef9d0050661e600266c441614c948d2d00f567393819e353eb38b776c66562cc82445dc6dcc3cd6d"
    ["0.26.3/arm64"]="b7812e6c1432a3e69948624a5b7de0714f3cf1ef3d38ad4d0197c7732fe6f9046f598073a131fd90cee9cfb8d558b75a657a9c1be9c3dcd043acb530db4475a9"
    ["0.26.2/amd64"]="e11ae9f6a04fa7892017df9bd772f477d3fa8b1347b0ef8ec3efc3a3dc0a22125d6fd63f5405d49e71043e65d7d2209cf497cc2c201f7ac03d285ff82a9030eb"
    ["0.26.2/arm64"]="5f629899ddb826436fd119e2c066f17e9dbf2c3835a1109c2fe528496fea894dc89ed7609e190fb8c2220ac6b67e81602ba5ae936f03227ee22f456ef65bd72c"
    ["0.26.1/amd64"]="39bf8b77201adffdd2bcd2ad52a6dd369fdbc9c7dd53a2d39df9a8a6a8dc103dfb5376abe3a56801a51e4820674aad2274cb21bbc584597e5c0db8aca5464d6a"
    ["0.26.1/arm64"]="0e42967328b2436668200c1b39d91b10d27696dcba7311b69d8ff3ff43e6e2af0a158ec00f199fcff356e1b1223b570772edca05b13e95f723c61f5ce3c27dac"
    ["0.26.0/amd64"]="1a0b578353bf789ccde568fcbb16a6f4fd092348ae5ab93338e17b996c051d959209f4ac58d0b12ab903d7d2e9b08d37a87a521729cce10b34b158e0bef9e10b"
    ["0.26.0/arm64"]="d4f3ce44654f5c19106f83043466d0fb3f8f3061f36755d4a92b8051258e65c10ec0ed5266a57207cf1811e526a65058e3e1079abc317766d5db6e9b7fccf943"
    ["0.25.1/amd64"]="c461ab63d4c0183b71875fa65a3cfec70acbcece43cf5fc32d78ec8b805f8f081c4b428b69c0339c7d31d3d0e443951f70301b4053dc3c07bfd10092483f68f5"
    ["0.25.1/arm64"]="fa3a727e910035eb4fc74b8b7c2d1d0ceb8fb9beb05d5a656c10497ed4fb635c23c838e49f67af0efd7d8207c67022ed92dbbb92d32fd0b9577f56479a0446a5"
    ["0.25.0/amd64"]="b14b41c77e04e4029c38f720e684bd5d67efd4dc7c997a4265359ae232c591d15a349f937d291c4d785d6d9dea5895ded5bd9cc23e72ef27c1449fa7f4937cea"
    ["0.25.0/arm64"]="e52f17ebba6871dfcee15f3920dcc1d5927a7141492db369c0284b5e89374662b8ef818c158d79d24c001bfa324bea30a308e84368e766ea34615859443f5ea7"
    ["0.24.0/amd64"]="9c88b218206be29d48ad08adcd36cb24c6562fd49be43263dbfe5d1d7ac51efeee8b9eb86d9a31eb2ae35ece136fc0d6a105a42537c0ca4994660c73e80f01bc"
    ["0.24.0/arm64"]="e885e2d39ed72707b2079fec227105fff3ecaf3cf763f914e063c34d68ba63aa7d99b4a41388a7f736b65d085fcd668b89934912b689a2bcb3048459fadc18f2"
    ["0.23.17/amd64"]="8fa1d9a6ff66c760261094ad0d7640fe4d2ce5cb3b9d7e2c39b5b6c9322b96253f51cc95a4ddc46ca66e7050516da6ee1ad2287058531a7338d765ee45a5b0d5"
    ["0.23.17/arm64"]="06d4e19257d4af7661e5aa526055fb06e594068ed51c750c36d9eaed36b4fa297ac4f17c5aae4632de6f0e6a7388afeccf918d4b1551681daeaef138f3ee0302"
    ["0.23.16/amd64"]="a92ab519f922256457318e2d7dd4a7c61c7b03a4d287f8f51e026fbc53bf692c1f5eaf5dbb07a8bedff38dfc556a58cc4a87a1fb1fc15c4a133f03c0d1cd9121"
    ["0.23.16/arm64"]="5206a66a73741b3d66f7907c4835f02495ffb58b2b2af3aebe7b639443f28fea952358ef64d58f752740844a3b152eb9370064ab8e8d86813f0bd32aa36ef3f1"
    ["0.23.15/amd64"]="60bf77e254dd9ca6e0d15cb3f03213ba50230102d5699e164d3164a7885f7fa97379387ff5b402fd86fcf628ba189d3daaad634d1c585efdfea5a8bf5a988acd"
    ["0.23.15/arm64"]="43d1a24e267832c2bde8a4e05fbffe26a5c8e0726100e951feb0eeb08b9559e46c0b2433d0aa1340cca127a654cfbc29a46d729b65f46319aff2efd9601fd661"
    ["0.23.14/amd64"]="1e1040030a6ee7c0bda248a8c30d944acc395d30314e4d8c1f3f2631feb04ec1eb2f802cd8826e02fe6a4d6c99a3cfeda7e63f297b89635104803d9b0c5b4071"
    ["0.23.14/arm64"]="e69c6c0da3bb407ee309a9c0b9b9e6204c9e6ebd7fcc23e834bc765bae7d49b82ae6d20874faeabb3668303c9d0a09d11630f698513cd73e2e19f7027f03e312"
    # Version 0.23.13 did not release correctly.
    ["0.23.12/amd64"]="074413507a81225e3999472ba165d0f9041d815c1008008e4451378408e22b9adac22e4e44603ab1254f6e218a051318f3af7bf7f266b246b05bd37d68e79263"
    ["0.23.12/arm64"]="c55b82d33bfd3b77365c9d2fb1c736db6f7ae318e004fbde72b7d546f4e316775fa1931df07ebcc758668e718e78c48d4b1c4cec065d98d6b00a9f17d5a7479f"
    ["0.23.11/amd64"]="d915064feb32a0c6b56bb397c44dcf65f8cb5d6c39f301b1249da3ecce4d627f017587fb58c4571c8ce257127338a38c58a23da840c2bfac5d9e5301c76d0115"
    ["0.23.11/arm64"]="13f5d6e61b46f4e5f6fd0731ca131da039be1f14a991ba350a9ba2a9989f745f4e11a18ece125e604ceef96b679476b021d3a9cc23da13f24f6f0714e44a1f5e"
    ["0.23.10/amd64"]="dc20d74c1e8b0f974dda055934ad7f709186ce99f3d7aa03445347fff1b5fc45fccf9eca5e22d8c5e3c4032eb53a8440566725bb51f18abd10b8e3e634b8126b"
    ["0.23.10/arm64"]="b9ed8f48b15af624dfc6dd48cf216241feb5127a5c4a95eb6226b07bcb632ea07a905c3251f496445a063f51a1be66d290a1199e648da04e4074b9458ca9ed8b"
    ["0.23.9/amd64"]="29551bd985d276a0afc08bdfa2682d097123c0dffd66ef600144ef4efa7f12478d3253fc6d9adb26911bade9e71df832d54e443e97997d83ede6bf49ff694baa"
    ["0.23.9/arm64"]="2c819d442cde8eda7d8229c913702a0d4883c100c6e326141d1c580e57e34bcbe7e4678b506a5375832318eb329a79db3d0df9c9828e3b707719a3dae7a81e3a"
    ["0.23.8/amd64"]="6b9204067cab2fca75f2dce1bb09266863bd2d95056e80e3fbdd6c77adff23a6650d47df7ab3bdc91a9ac0a195935cd24a25face14a382e93d62f5c5829f41f3"
    ["0.23.8/arm64"]="8d3a926fbd2d519794469da1d58ce34a4451992da0469f4904290452cd6ff7ef88dde83034f1873e672d0f4ef2ff782d6780b37b2739beafeee99dcc0af17ff5"
    ["0.23.7/amd64"]="0a3d706da5876de98f8013dc9a0a9e5e0586a1530dcb74adf3c2c600788158493dde8b3ab1df209c86cdc04ad6257b37178a2ae4d1d491f02595ae906a2aa557"
    ["0.23.7/arm64"]="491f3d5630eb08935bdce82e71996c376526ab3510615007eaf307e9b811a381ffa690a23b8803ec4bb633f165cebfefcfc40137118baeb8451b9f5da4bad671"
    ["0.23.6/amd64"]="8113eb982d53fbb33c6646b07b525b838c6f3aa8ef799de6f172c3a23aa5ef289bbcb534bb83e3aa7632bdf77fabb34b41f7060643f7a03cf569471c19cc31b4"
    ["0.23.6/arm64"]="ff0a2d02063cf80d14fb548ef4e2e3b95866feaa099f6090dca05ceff55fce54419c736cafe3562c72ff74f38cd583310d95e760eb00d94683938bc558a44d49"
    ["0.23.5/amd64"]="7a425716a884afaeb075b82aea9c6a1f7f29a6303ecbc2641056e0b6c77e1bc8c7e596b28e0838fb14e04049f62c871eb10205dbfa38ae81138e85e506601ad1"
    ["0.23.5/arm64"]="00b02b146c57091fe30d1bb16be7b7717a7d529d530b781aea2a8b4c32010154990305a5535adabdf77be450638b262beb5344ca0b62f90b4a9f56f5831b6976"
    ["0.23.4/amd64"]="0777ba5090f325c3c322ce1a12c2b151bac0e1c98f526d9bfeb26bea403baa622d662ea087a6e4e848e60c712df81c3b79c1f42f5f5a87b60b53909442944049"
    ["0.23.4/arm64"]="545163e391896ad53b08773902150e1aeb623f10028771eef147fc7a8e58b5b6c1d76e7ca0ee5abda56bd9ba4f7a235d28fff3576d9caa91bfdb4464130bdb56"
    ["0.23.3/amd64"]="d3cc113ed1b3ae267b457b5c8e5b84a96249376711568779ca09252bb15596351c4325d0ab3948f6adac31045eaee5d4ec4608162dc7db3213adcc182a727f87"
    ["0.23.3/arm64"]="f8775a8b00d823dbf5cb0338ae049ffb4ba911f0ca679862a375c88842f5b6aa1158d5786c65c8e5b9ce4f0bfc70d0bdc8b5c5ddebe14e88dd28ca01854d7ec8"
    ["0.23.2/amd64"]="d6fedf9bd7aea2e64d7dbe076e77dc7f5c522d1c420ac895c1b422ea57544a9e8a4f804b4f0ae069ca36ddce91a8436b03e48a6bf7c0b302b2874b0e15265704"
    ["0.23.2/arm64"]="c2484109ad86e6f4a82b1d6afbcf8c2f7e2fc3b5f8da7c936d78cd0e06b069c9f1d86d7e14e46f46426b7fc2478d9493616af42ee0db26bf7bdeac8d50293f0a"
    ["0.23.1/amd64"]="ec54dafdcc5e5967f56c997ebc7fa9288c411ee9ff9854ad21705654e43ee5963e8e3d8f1d0c1686ab650bcc23698f1aaf5483c0a139b74fe993a4543f58b9b6"
    ["0.23.1/arm64"]="698fa28d2d399d2b75fc3b101c1d38f5e932c6e3a1dfd042b70208508c9e3c376351fa3612843543eae1f6b5a622bf34083e3f847b3f1e61d8e759e439516a25"
    ["0.23.0/amd64"]="a561fbe2e11bea24f0015155e8a7548bfc4de2e4cbe13b306953bbd17d4a75e51caf9ba80839328f710fd2f38b47146ed02513c225ecdd6e2d85d960a709d86a"
    ["0.23.0/arm64"]="e6911346f890fa19a2379a5f15341fab2f577a3984103f405420c5336a09d628e70bc179fa85635274ef3d3f838d805e06015fb6c40f853aa21e2e8f3778b836"
    ["0.22.2/amd64"]="af3ed5e886d7af4491b5460da6539e5cc9c2a32e317802a1eab5dea690c30bf2f3eb4ff281da544e1d5a202965c44f22eea0283fbd0b6776bf4fa177445d5fb1"
    ["0.22.2/arm64"]="481ea627d8ae94ec3db4d6b1fe62c8963a7aa0392eb963669bda24a4dbfc092a7585a3a9ac957dead120eb29d07c8c259a90de3c9d2f4b57f04714e1f008e114"
    ["0.22.1/amd64"]="e1e901fb112db66a46b40433d97565b30273456e87248094e229f39a7b2a57290d930cd5b873780ac9023f4ea8aa83351109ace15c28b4c4e8eb0989cd8f5e3d"
    ["0.22.1/arm64"]="c5454c1501b158b8f9341f64256de370692bdb65cbd863af7aeb67401d6b2da5200ec7d0393c581903640b7c5c994bfad39dbcc435f669f8d97b7b03679f5353"
    ["0.22.0/amd64"]="ba6339ab667ccf4811d937e91c622f18ca45da07fc4c1362660696f094843fa4fdc0c4715b61f1da75ce617775d471cba7b46f9b2d6e6879a003620a1ebb3d8b"
    ["0.22.0/arm64"]="e4b60cd99a208d4acb4c2034f9b3fe20b94aabbbc3065ab69aa505bf76e453d39c170e5ef48194439871adb307d51c9a3c8b3767c62ec55cdc86814527c43e3f"
    # Version 0.21.2 did not release correctly.
    ["0.21.1/amd64"]="63fd96f840a38294c880142fa3e46828e4096c4bf055a88b87149e3acc0718c0549294fb0b94443c714b5661783a0806532a1d150259e4c3d5c11a1ad48275f1"
    ["0.21.1/arm64"]="e1571c906b90e30b543738d43a0709c06a42b2dfb28a213ff2c70aa3a7a52b4f245216b25dcde10621e4766ed45fb84d4e03b4c383ddef0c593e233008f3d212"
    ["0.21.0/amd64"]="195b45d672839821f0d2049ee5ae4f92e21a185e8ae3e8cc57aa439a0aa73a1c5b7648253901ff00d4e2e85429ccdb5bcf8e4bdfb7d2d08d6233f6f1d1ff64f1"
    ["0.21.0/arm64"]="30f977265213138ab922eb635de53b08970be0b41c654a606dc8fc89f0168b515d870cb9dcc383d3ff3e4da57ee0ac735e32c273fd6b464b4c840a3923e1c713"
    ["0.20.1/amd64"]="8435ea82360be9f29cbb83e4302837d7ce292ed1ca708409efc8ba84186d407807f5d6a6c818e6afef70102581bf6e0d11612b67d013924552d48724586fd100"
    ["0.20.1/arm64"]="cbe073cbd830bf2a54d236fb8d6baba1e916c5bb42634a9866ee6f528e701bcdf968132cbb393e5db5cf6e57f963f67d076d2221e7e307f7aad3ff7f4979b5ea"
    ["0.20.0/amd64"]="af13ce2189e51c7561424d1bf175f7ed9ae0f063d017665373ec3fc417f20d81975eb4050a536dfc198e7fe2acb3f47382534ef687a3b4b6105a847af0628635"
    ["0.20.0/arm64"]="891453a7d70e88f1f79560bc0fb3cfb590132c0daabbe3ad438f939974b9a0fef2f11faead0977fe37c38035ee2b7d97ad79faafbdabef4da687a8c1b6302614"
    ["0.19.5/amd64"]="f95b626470f01fbf35484c730d409ea6a3c141026d3679c3d22e540007aecbff756b8b7c41136b0ca8c9b8a6983a89bbe1c49022785bface5d866a2ebd14000e"
    ["0.19.5/arm64"]="1e02b76880e1772fac369ea8ce35cfb4ab54b34aef8a7e7a7a2f6d42add7dba8036d9ab707a6acdab5591c4798593170efb394f8a911dffca17cd09a771d3da4"
    ["0.19.4/amd64"]="9d76ebef16b6484c928d0fbd63692a573e94b669aaf24a5d176cde5313ac648c3eb5eeff934294949f549529cd5878ca9b302fd30590597e9b019b08d8035d77"
    ["0.19.4/arm64"]="f0d459c21881d628e0a694b967a862ff92e178d306983b9389c71d14aed2e802756763599b7e0b33352f9cf37e55ae3f03b518235457e1b904a79d212665e636"
    ["0.19.3/amd64"]="b5fa0630aeb1174be53220a98489b890d788e520d14b05245dc9c78e3f2daf322bd93493c80f356e09b52cfdf3cdaa7d3d82ef4c8f63bf7a71f4db03a7d7f796"
    ["0.19.3/arm64"]="b08b93a0eac03161b874a0fef54b505c6a511e1563b624ea6ff05bcd2efa69ac8e31a3c6dd808668a6827950820b32158bb1f7a69a3711adb2221b17b0f7389b"
    ["0.19.2/amd64"]="8dc6e1a17a991aac3967c5f95482ad8c305d02ed2b22ac6b3f9eb3a0589551991206c6889dc946324cd839b365b48ce909b4f28be0c3617b69f0543f14b40773"
    ["0.19.2/arm64"]="1515dd535a07f559d83bec84782cc07120711143ed2902882b719cccc340711ab99bb1fbc609a1bf1b4c8a920ff0758b65060f656b48f228ebbfde348a853d2a"
    ["0.19.1/amd64"]="3e78b941915be855e8afc6dfb1b58692c042cfabb856166aac2dad3fb7b7d7c1fbb10ed87fdaca6a44e7bcb125a9bd75002837ade4792ad618a7fff5902326de"
    ["0.19.1/arm64"]="d9bd0c26d4584d84e54eafdc90513941f4143e13c4d7c6f58a81ca8435bc74c43e69d7a2f2b9a386698e94c1ee101df9c4f23bf24a91c1c3832eeb104fba8a04"
    ["0.19.0/amd64"]="4cd37271b829284fff4383399eeb4bc20cfdb26692f40d7971c376a9e636153302134426d0a861a888365765ee7009c40d6391e62e33f96710028d88c2f71840"
    ["0.19.0/arm64"]="0716ec64f256ea0c4b80d2c722e04a9167b908666be93a67ec7ddea7c3bee33b1b40e4475d8bac92b6de87e8adf771cd6386fb62cead7d9a572723a9c8a15587"
    ["0.18.3/amd64"]="fa46be2c957f9e846cca9cff0ba8fb89ab202031c3e9f58de756c95b6529533982c4a459ee4ed4da927e007f56af9744985237051459fe9a9d4afd88ce5bc86f"
    ["0.18.3/arm64"]="1d4b8b0cf62e4143ce82e0fb7c2d316a818c9006b981f93e5edab58cf1377eb67ffeb7cc667499a7969abb3f29f02ae063736a463bc3592af480806dc58eb409"
    ["0.18.2/amd64"]="201ae924f5dfb69883286a53755677589c7401bba79e597db0f9094206cd744accebfe37f86a2f9cf0abc4b9ed12859773a8d2cc054dbc08c9adcb0db4f03fd9"
    ["0.18.2/arm64"]="56d344c7f1359f0a70222280ec22753456b1e4c5d9b2ba2487e4cd6fc34701ff595cf2bdf2537da682eaf7a14764db88e42ab67f1e7f00343acf9a4c825a908b"
    ["0.18.1/amd64"]="c2f405b3f9f3b3124e0569677459b84f494c584ad996be19dfd5a05ab3171775d2aa39276d67ac1b197e57da078fe358825d4534018f18f37556dbd391303195"
    ["0.18.1/arm64"]="94bf8b6f855e2bdd422c2f9c9513f8c6066c772fe8fc1143edcde7740021a326f172e697047ff09c3d6e06bf4befb16a3ba482e918ccc765f4a89304b9bb7f65"
    ["0.18.0/amd64"]="aa0407a64406bbc3a5dcabdd896a05fe0834c0602a3d7cacde10ea163b63dbe0eb9207a18322d2e5fc77f90276bd345ef2d5b835103d60b653e7ab04850e3336"
    ["0.18.0/arm64"]="0a34184774025f58df9c8c01676578abf85c61c0f2e7b8a0394ec9eec239a6291aad8a75ca8b436967a3df2186a7d1bc2c37b6623534559e52efc8fbce4e3eb7"
    ["0.17.7/amd64"]="8a720896e9e2ed7ccec609333aa6cea6c1ded90d64088b3ae5148cc5a857fadd4137857ab1b7ca5b5293770eae47a56213d343224b768f85acf994130b73fce8"
    ["0.17.7/arm64"]="2800f82ab6c5b605f45207fcf04e64aba43f45e2fafda44e85f5b78cf5720e6b7e7372d87c55e5308260e167aa10925e871d87539efe0beedf658f285118618c"
    ["0.17.6/amd64"]="1e8448e8881f72e2c2a12819ea6c8efad5c59bde175859a90c05af8c22dd9e3300da26160df6015943211ca465107eada34cd2a3f6d5f6092ec24ede1896a9e8"
    ["0.17.6/arm64"]="044fc796b0e8bcc5186f0a07c5af710e2a777a737a94951cb30a3a23be1d875759e82609a8aeb1a36cb99b7075fb487bd1bbd6a7c67f2880d8f54e04d55f0685"
    ["0.17.5/amd64"]="b7f38cbb86f3307e98f4153538648c4d11adef22177cb5d82cdbfeedc815efb030757fbf219ae725893aec75055742314f41592e7cfce05fd71326087b09269a"
    ["0.17.5/arm64"]="60122c973b0d072a0b45b63d087cc75f6e92c7912d75dcced50786f69a3463c9555b2daee400c88c68d0f870a78e89652d5861a2275d5550b4b57d9c56404989"
    ["0.17.4/amd64"]="ab3bd7901448b070a1e637be279a7b6fc342829b982b39ddd3cc2939bb9614c568a476e513bc45ba796c62ef1e8712229a609e506b3b44d660ca47e6f7dcf404"
    ["0.17.4/arm64"]="cae543121463a81d98b05e6d3b28018a94dd20b08b83fb4568e34f8aeb25cddf75969e261b572e721592ff08e280d5f257dcf41bd2f6f15c414dc700c45e4974"
    ["0.17.3/amd64"]="ca04e02701d256cedd500cf237dcb2fa4bbc0e81ba2478110f9e989ffa1a0ca0e8531fdb358c3023d3c25add0ad1b0f6cf00aa8a4a0552ba0c2a9f5231976b9e"
    ["0.17.3/arm64"]="2e80c7526227635786fc2df42a20987b24dcb9ae67afbe0dfe543f0ae217cdf745ec7d3abb8f6e4e67dd40c8b6626c7aef959dc578e467b00cd1f065caa532a7"
    ["0.17.2/amd64"]="29f179afebca0bcb7aa130d7e4b4dc18523ed71d385bd906e389dc36ee7bf75eec9f68639d73d098da3b5072842231947b89b4b32451df48fe5df02bc534a9eb"
    ["0.17.2/arm64"]="a2d5259b43d44dfc3d0083fbb3e84017766ab6c13b41e7e76798f6803c8bccc687257b431674e3ceaa061563fb504c77f7b82a4b39de993eb7d60486b04a78d8"
    ["0.17.1/amd64"]="a9b93afef1fb38dd19ddedf9c491f33068e9094020e1c1b221ca66b272f1f3bc12b6d6b0183a96b8f0bc9dfd5ec4055e6c0442c9d4ff42b370cebe3d09d0283d"
    ["0.17.1/arm64"]="22ba21acf8e3f18ef704143f808f26348d7c02f64e13ad152dd7a00ee2989e8074e302e92cd897d9bf701f7a151d77f7630c54c76691443e5c485d5c8e06ab72"
    ["0.17.0/amd64"]="403ac168dc7c41dfdaa7751893c76ca5fd84ddc4fbd86691a3c8d6edc92b3237c2fe9c3db99f5377a9f0d03b1b7debd4656d312bf9ea6221b2e4e9987da689a2"
    ["0.17.0/arm64"]="08c26ad42dad27edd63c12e38a5073b477a15fe06590d9787544f937d73b45cbebac3f9a492cb2af9d0a1b7a7e08b9dd1be49e610b0af1d8b6554f318127de99"
    # Version 0.16.0 did not release correctly.
    ["0.15.14/amd64"]="2137b42e0e61e1eaff8d1bff42d83fc56cc48fd04d637b74291c93d413b8340575d23a70ad9b23e583e7b130c67a906f5949726de47891bcdd6bdd9d4da15e1c"
    ["0.15.14/arm64"]="7fdc327ebdff1bb698d39ac4465c9ce4dc00cffa648426acd9ed5de58d66edabc0381fb69f42e549f2d210ab2439ddbc1d043151b0f8dcf9959a395e7fad15a0"
    ["0.15.13/amd64"]="a333f101bb4ebf4a3196213d31cb6f5dbc1eb67b78f846cf3b7097c4460f5b89b9ef9d0141f4082f93a93fd5e6d9b54cb2e3b4dcaf90d90299983c808a1a0fbc"
    ["0.15.13/arm64"]="1ef9d3a6bf1fbf0fa60e401c46782492299a6802075bfafd01baa27aedafd4eda551092da9e3dac2f45fc97147ea84b9f970b1dfc904ac2a04106646290405e1"
    ["0.15.12/amd64"]="00a1b60ffcb80135069aa37c76f70f461138f769d1a520b3d21e85ce98134771ac1b1e2f01ee672b3b3586ed62293156edf79999cc083877e0a87beed219e46f"
    ["0.15.12/arm64"]="dd8b7f509b820713ad3b54751a45b8ad774c64df468a3fd191100f6692aa72e36564fa2da5c7ee07a6b159224c2eea6efba506d96be3fbaa313a214da7625ba7"
    ["0.15.11/amd64"]="8db23b9c30b9f5c027b0e25a918e0be0893364d5ce5f6f9a98914e16a31dbb58e61d2ebb16ce5ee384f171e5a49f64d90847dad5141a7e1d892d0c380ac21f36"
    ["0.15.11/arm64"]="5740a9f474c78b0abc2ce81a065717f6b003d11408b285352a0dfa906975288b223c5054264fd4b0dc073c321621d64280b2b6a909dbe43757a57ff1f81b2d93"
    # Versions 0.15.0 through 0.15.10 did not release correctly.
    ["0.14.10/amd64"]="d4f9e7b9514981a5298cdb80d8df6c7c53308878d2174e6ba16e13e3beef4cb8f41d9d4a68f62f01c2d703f8c4ddc877b9dc574e2a00401b75e5f9a1c1a283fe"
    ["0.14.10/arm64"]="8eaa1cd0f8413ec512d8bcc2d1fdc8f099a310e1576fbef6c29f631aa6b2b3ccef5228843ebc582a597cdf729955b57342a9d3c017eec9cfa2cf881811d0bc64"
    # Versions 0.14.8 and 0.14.9 did not release correctly.
    ["0.14.7/amd64"]="1239aa51f1e3ababe291dd8ac3a2981e7e93a60af17e19c01fd603837557a7264a24b6b84ccf94ce6958f5ce966d1f8a8f537c04f6a3deec6f6205bccab653a9"
    ["0.14.7/arm64"]="6f4afc6a5f545ac3865c33d641e99d247e00750b218488acd1c1e9c5689d9ffc7b5cd4b98aa9be2ce954a80e7087f66a408bf7b1e474cfcb0d72ebb845e46fcc"
    # Versions 0.14.5 and 0.14.6 did not release correctly.
    ["0.14.4/amd64"]="7d40c44cd86e0d31b47686d7bd10e3aa5560e1eea0f4c2bd81453999dcfda2a8c304a3937ba2cb727a044262a8cb5e5b120615a945bacc99469c64e3b88f7f1e"
    ["0.14.4/arm64"]="2ef557b43161528fbfb3eb47d32737294f16e1d7779e40fe2dcbabbba66091180e46bccac4c36f2c40406f67600a38b4ad043f4ece097bf67cab8a1ea57862bf"
    # Versions 0.14.2 and 0.14.3 did not release correctly.
    ["0.14.1/amd64"]="cee0262a7f469e4ba68ed2985669097f992b38a32c59da1541ed0f1e97f8821f5f089279d5b815b0b8e76b12b3d88789bb55512ccc6118272c7fb3d46ce4b189"
    ["0.14.1/arm64"]="a5a4a97cd8fecea6c5d737309f92bdc9f05aecb9969dd8251383fbc2891754eb9f68b93faef4646ae4b5761bfa47358a767742ced47965a3c49f16f9db5a9fd3"
    ["0.14.0/amd64"]="c2331cd3f3ffcadafbcca96795ebe9764c906d4547c4aa59326ac5a0b7aa44be3f334af97e4cdcd778f647fcfdf1f23d6e955ee1cba47e8b9d73def04aeb680a"
    ["0.14.0/arm64"]="c83ff34e20e3c48d9d6e799a0cf7603a9a352a066451855a0548ea1268561b4b8fddbf30b6fa4fa9ddb56b3fceca303fc6e8bc41741a01a41f21669dbd3b2405"
    ["0.13.7/amd64"]="1542e182b1d89b3c7089864c4537bb134416327653ec9c413362c2ca33595ac6f0fbd97fba265ab52e3d2ec237b3692846a044197461f84a45f3dbcacc30e0aa"
    ["0.13.7/arm64"]="84c8c3a8bad87f008ad4d139b4ab16c48ceebdf1dd658ea05b922cee0c75718c476fb885fe7610c9bb14b3b3ff9ba76a705938a481de9de70b706f04002f32e2"
    ["0.13.6/amd64"]="179c5da4649e61d034932c72558fe56247cb4a552c2baf8e3c699558d00e4762b5ffc0880fcc191bf6c92d8fab4a6ee7887f09d4db809db3f4892cc5574d805a"
    ["0.13.6/arm64"]="361df2a27804e319a7a5d43d04ff3ca5e6b376639c614ef476c4871a71725fee752566d4fe56af5617888c8ac66cdbc66eaa376f4a573e4f0dc15ccc3e71f003"
    ["0.13.5/amd64"]="0fb784e63dc134658e6d43ac6864bd871c8c94e2d77580c68e2e5c84eb6d03cc7e30341ee9b7c9aa5ef708ab2a1f4b6aa01d8ec08fe2ecc4e74108bcd34f154e"
    ["0.13.5/arm64"]="b25a00a1ab9ff8a818cfc8aa2113fce9c22c0ee5a58904872410551f5965391bf579c3cd758cf733cf871eadf4f45b6bb3ac3ffa0b6f1dfae74b1ec763b9341d"
    ["0.13.4/amd64"]="374574ce34a2cf333a304809ee4cbdb6a18ee6147d572ef56ca7349aea94c1c892df4462f76995239cfc20ed877b1a8e59e0a0a4337bcc86db940b2a9253866b"
    ["0.13.4/arm64"]="37743640ad543317e1ac65c351832a1423607883602273558cccb3b6ade740339e3befa935b999c3ec09647356511af760a8b27dd38bc6aa92b38a7d046b2044"
    ["0.13.3/amd64"]="f8c94573cbf1fbc242dbe0024b6eb8b9d0ef72ca159d58c2b49a03191b59325a55a410981754a67f22a0afd63bbc1bc1111e173f6c49c6550a37c9c9e8190c9d"
    ["0.13.3/arm64"]="912c46d059115f0b7b517a642264dd2cdaacfb392dd8aefe39abee57d84b5c03c2a7927c14c9f114b975363aef5425078f83fff0973d556d5356fc5869fdfd3e"
    ["0.13.2/amd64"]="b1199a7241d7f0ebbbe547b93d05d808b9a604a15ccb0f6bdbe25f6aaa33edad950aab6612bb2c720f84c7729c53688df70653c2ebdebf14a38a245a9dfb9468"
    ["0.13.2/arm64"]="2e8e950bf1544451886358400fe0c7f1b3052a702aa2e435f81ef3f404fc960fe94b6670a81a7589e87f4e0b4f7eef48ce35666c3187b9fef4a12ddd92b4e6ca"
    ["0.13.1/amd64"]="5840754c22e37492e031c46eef3b229e77a5e086f9b408e9287197f5de2fdd8d83ec72d6a55598db2c804a96b34407b7ada264849d74e79cfb37f4edbd864cae"
    ["0.13.1/arm64"]="44c67afef66e97dfd90e11af25603123fec02aff31dab0f20731de5a347bfabc64d8f299ab3705013ff70350021b1c88d72e838518c1dcbac909fb7cefab1631"
    ["0.13.0/amd64"]="689a549ffa1c16ca6b9eb3bc5bab758d4e1e943d1b8b9a151f94b18f365f921e16a58407e3fae2dde940d0a7a1e0f627e2cf7cfa4fc343cd41a054d6eaaf3eeb"
    ["0.13.0/arm64"]="8e479e2c8b06389a6aac97aeec013ae05bf944d35b9af715038ffaea7dcafa7ce275145c1577ed555bc1706c0855ccff7caaf405404142519de488ca0932b488"
    ["0.12.1/amd64"]="57cf09c3871fcf76ebf75ff14b95f166bcc679c738f6428679250a68b0db7d2c6b83f2bdcbabd7f3a87a3bf389625789ad28517e9bfc5458c3443823514fbeac"
    ["0.12.1/arm64"]="fbdc8a8fb62108c3f4f779cdfce4432e9185aaf866f70332c2e73516e1b024136bedaa955e10948ac354df4bcb52fea9532c01b11bc294329902eef774a260b8"
    ["0.12.0/amd64"]="a78d3dd062d1aca518ecc1d6d15cc74922c8d9b59903c485c3216845e1d46efae989da5e2ef5a479a88817d8b40dc50132e394e61558fe63af18f9ea3366d128"
    ["0.12.0/arm64"]="4a3a65b88f407a65cc5b03d2bb1582b98fe971703cc9585cd5afe151b28e981c5acd7a13127cc6bac80374adc2ed909c7078797cdab25da60eab8dd392dc9755"
    ["0.11.6/amd64"]="bab86120ff5f79a7f1dbf045db8522c0d015bb147d04fc738aa5f221b79f1386382231163e97c50bc9dddfcdd05f42723b29e4e43cc8eab5cfe7d8a73392aa91"
    ["0.11.6/arm64"]="a0d4b38f53d054101fedc0f75b6efc975a3118a76d618f3dccaf34519e2f3b57167a2ab342ff4e2376563abc4a56813fad97fbd608842aa61af10a510745010e"
    ["0.11.5/amd64"]="280e510ff07d7f7fbb7af54e5d822d324d01b294d8b09d652f51fc6d1824b585f71ca7f25d53bda891d2b2b45207c12c83d8a5ec32722b6be21bd70e206fb688"
    ["0.11.5/arm64"]="5f382f20cddf96b0e83b41a11191a798180d42a3e396699a00c1e0e628fcf305662c7642f1423f84f1a7b2053e241db23433be7fc2e56b91a8257baab3fcf257"
    ["0.11.4/amd64"]="82cb14dfa91b8b8c07890cf444a4e9b56d740e7114095cf7e2e560291946c97312bdaaa87711bcbbf4ec2ce1b6dc36536d2a191f2c158fd041a2b007c946d9e6"
    ["0.11.4/arm64"]="e0f2b27ac7aca842216d39aef6eb657b332216a3eafead4bc92b575a623da53b7c5a4444f067463b22c7c5ace775927dfd9d08cbf2bcac9cfb140d9cd47550bc"
    ["0.11.3/amd64"]="5b91eca33cbbb9c10c435e5775eb4511ffddeecb3da606229903ace111e363bec9996c2e8e9b10195e9fa12f6e3219854e5e195d1205578aeb03155828a64041"
    ["0.11.3/arm64"]="48a1042c32f48e360d762e01c7a57c8d274e1d256229d2e619a64779ded657fe4c0572885413274345440e64671c6c19fe221938d7344b6ea23a4434351f63ed"
    ["0.11.2/amd64"]="bfe52365ef73554b0e88490ce9219ee9cf509ae807e7ab8bd5bf3fd75862b26a527b45c8ab12d4f653fd6ea0df6a10b6812eb462cd641c99a6faa633faad80fa"
    ["0.11.2/arm64"]="c4c35ebe404b108c20c6d7398215ffa24d82b1f242ecc6802f4b3395cb68716839425c60775306bf7c0d85ecf5089c8aed18fb282a788031caff079bb37a67ed"
    ["0.11.1/amd64"]="247ff5cf7ddf91140359c98102f98c62d2927fdcdc58ba53f9fc6dc15d38c5b8bb9fb54cf29b5194897be009c592711e712a6f21a976538ec729fd6db7ae6ef7"
    ["0.11.1/arm64"]="66766045497ac32e1e811510f18b0f30d1abbd495bd50f7addf93ee9a1fdac6d50830e5e775feb0f0df807f9e6c0ba2b8838fb4b0c4af52a7a7c9e4d4bd742b8"
    ["0.11.0/amd64"]="17f9dca8e61e980ce5dff78c1c0298ee5a0df3cac47971f73f56d90b3e0b898d60a992c773a1ca295552a75e5a576578a5c79a9b9041bc957da790f0420ac786"
    ["0.11.0/arm64"]="9d717fe147e1acece6d5cac266312732eca8725ae1ea85a58de8ddbc021d6d1c22e6c3ea23e5fade467a322a0be90eaec0b3aa6b0125023bc5df83ed6cb48da3"
    ["0.10.4/amd64"]="d27c9505e08ce43aed65b164f7942dfd8c70a03cc3a137ec7621582b94888c203201e4376b67fdb574fafa003fd31bed99c0aba63a8fcac53ae1e01debc5d72d"
    ["0.10.4/arm64"]="19ca82a72bcdfa20aea77d045f5ceb9f52689fc8339bed21f247e86970ae9f5d677361a7a1b5cacb8426299d8812e76f155b046666f555420d4f8c0f68526deb"
    ["0.10.3/amd64"]="27d2f52a7c64f52677f05951e90e12d5d06eace88d350b5beeab505c42d26d18867d93ccc9d9fa051b8ed85552e3c54f12f2c4734cfff9c137b881453cc795fa"
    ["0.10.3/arm64"]="315e5f14ad8a5567040b5546a6e607c4832f4d58480c05b744a831f7e56909964501b7ef9be8320cef896398cbdd4a410b0212260e73b8a760ca8c9dbc98eea3"
    ["0.10.2/amd64"]="28d4b7bb1978f7e79577857d8959de2dde60a455eb67e2957fd99496800857f2fffb6ca23c4e11d77fb383162046f610c4ac377c6ce6d120c7f969e737cccee9"
    ["0.10.2/arm64"]="43cc8063581991785415dc494b64047156814a44dd7fb8bc9a59997b4d7be1f8f33db1c07bc326b667b29b830592c97a9697849ac75a9b43a11e22228041987e"
    ["0.10.1/amd64"]="1f3a022c54d597ab2c5b42067bc00a6476d70060a66b73cb52b5cce40bd2228babaecfa7f5b59edd4e394874294da975eb66a58ba4d09b95a855d322814945c9"
    ["0.10.1/arm64"]="526f331fb2174e6b4362910f463d102a78a720f5f6c49ec93c48d76b9548bc536e6b249213bf1bfa14a13bf3ddc2b016d1a96bf520aaf53c174f12c4d4b405e9"
    ["0.10.0/amd64"]="3cceffe785300ebaf3a41c9c71a249c741c80d09766c7f55130e98ea6927d3260a9e49b454410077d5f40a65ddad06433e100284bcb9160db856698bc9f9cb20"
    ["0.10.0/arm64"]="b586017620e69d0f01e6b9b75918a3b023f07ce6bd806582b0a91536b3d2ca8f65d8987d97aa5f8a8b322ea78d56f046d2d19303bb2c5d3f75971800020d0068"
    ["0.9.0/amd64"]="887f5e6fd4db2bc9a1202236c968c363a91c3bf1996ea3a9b57f91f5cbfdff1c9288a2af8c58eaa1851ba0aa252fcc7582d3e01176f7a5d5abd723fa7f981ac9"
    ["0.9.0/arm64"]="74937f357289d5554b3b732273d6130bc542a575a54a47806b26848ee17ff2b8fd03fe5c49eb548268a2b86c48777daddbf0e660f9030576f8383fa1145238ba"
    ["0.8.6/amd64"]="c47277c0a07b7d1bb858beece76f61a25b5eb3f3f11f0e04a000f35c50b3279aa6677d1a69a3b0165b6b07f5aeb7a3d26d5b2fcaca1d9ca1dd91c23d3a26c644"
    ["0.8.6/arm64"]="db60c7f2113e432d4dd00dcee737c495408a1ce6464fad2e0ac8a3807cf842026769c2296fa82b6672be3dd3171aef7ca910ff9f1987afbb1be1365d73b73cb9"
    ["0.8.5/amd64"]="3af79f4eefc5e6d70254db4bbaf9d4fd6266456b25785df23abd614ee9a27798201d6e3d6a8f4add9a8a264052ae6592e90a0c00b067d6173beaf0e6bf415b10"
    ["0.8.5/arm64"]="f8bfedb7f07c0ee87274ffc1da045a25f44799ac3f767e619743188c8c8cd1cb5381b09e73ae472fe53b2b57ff091444e2699507adb71f0ae73e3246e86c0510"
    ["0.8.4/amd64"]="403b271f5f8a22103e0cef834656f7897ee2e5d8aa8525ed1af7993d0934224013bfeb344b57a8add331e0df77cfa15484aea2f047c0ebc9accee185a6c9d62a"
    ["0.8.4/arm64"]="36371da2c65338879e91b38e3e5db8cce7dc7e927a7213c6ec915c28d0309c060975f579d6290c2db7c7a36696966dd7f9d37c65242498e6f9c1e57cab773322"
    ["0.8.3/amd64"]="8722c0694b63e8c093a3f55f26f783a95f2ec0c6a4901af92512bed1fc942fb7b31f30f504e434cb1eec39fcbf994e55b4587dcdaa77403f41fa58d084f17801"
    ["0.8.3/arm64"]="058140c71605e44a7201d6509abb143a93f1ed102c39e7c243d71ebaa1e9cb0e7ba360dfe96c353490da4aa771a9e248a60a16c773dc9179f0940d938579bfcd"
    ["0.8.2/amd64"]="602e77f7f033ef1751b4f08a174ee8d8dbd2a11269520f9548b802d4b1d59ba8db6e2cb41c337fdef4d89fcfca45ef39d040c29382bcaae19812893b9769f40d"
    ["0.8.2/arm64"]="fa4ece5b7ad8750cbdd4c09277e9c42966ed900e9e2162e2fac3bf3fa72e2d0d4265d34cd03032e8bd1c23e635f64633e391ac69f580795110b6471a5ef07f0d"
    ["0.8.1/amd64"]="3c9c7369747605c0c1acbbe33a591b74299bc7aba420bb2e52bfa9030f08b69aa29edb35e151e38fb3da93594a5b47811494d6f869c62347ae53a5c3d3f1d552"
    ["0.8.1/arm64"]="fff0e3c549b104c3085d715195c7b137d4ea22f9e2b86f30baa50d203211e4c7437899886e95ab6e6a9e140e80d092e344ac3b06da7c32dd85c7345b1dab26a8"
    ["0.8.0/amd64"]="4985bbae2b97412123b21eee7334d55deb88d7a4597b29fd7c4e65f58713a8f1cb3269d4ca184cfdfdd7d2a92a315068049ee0b160c288cc3f971db8b1f5fd37"
    ["0.8.0/arm64"]="54120bd8842c0c661034ca32f53f4d365d43d2af4cfad7bf29b3f0468a2c47fbb097bc24c3e6eec40902c931a1791f29b43b763d5e94d6a7e8dab6236384000d"
    ["0.7.0/amd64"]="fce4d2ec87012c18c9d251148bcd0cd318a87e9642cc1120977c56cfbe1e31d81062fbac0d4276004ffbb5f09c2cf7d75a0c6012f7827b834c28ac3b8afa8e4b"
    ["0.7.0/arm64"]="bf861ec140d35c562c6923e5b9618e63673a2af44eba85d462b3c9e600b55dff54d61fc26c92f084a40e6841ba598799be01011ee44bc713c94e3cb590f9f6fb"
    ["0.6.11/amd64"]="f5d799639b91def79a8d73a6720609789d92845de311d2bbb38b8d3fa344936c70b7a0a11bf48dbbcb59b5f458ee430481c95007bcaa2c0d834df95631eb4fdb"
    ["0.6.11/arm64"]="0e9f17c6cda5171a03827672bca44fab7ef139b40d6f0851c8937c2471470807afb0af0afef0390bf2669974bcb2c98c947737215a92f1706e8650f7a8261840"
    ["0.6.10/amd64"]="3ae4965abc312dd95b955e5155ccd9bf646c60e36756ddb3579e2d7b6ac81ff339dfa9d6754eb381a41ca185b47dc9688fef4d537c70791d205a14fcce7ebfca"
    ["0.6.10/arm64"]="491c3b138e598953cb8db2457b8eedd4f55fc66e490a8ac36999ff1298b94e539c3e3765ad840edf40c4bd13f5cfbe5cb5ef470d9c244c9f648133c7ac3e29ed"
    ["0.6.9/amd64"]="f47d3a91155b4ea2269c37611207717539afab576b2d9268284f456c02142d8f0078319c667d88a2480d61f704a70740bd1c5865af22ec0f28e1bb139483ee16"
    ["0.6.9/arm64"]="50c22bfc1fc4058e3e59f77243172927af0169ed938bfbf8232bd3e18cb1962edde74e54c5c8394eebbef053e2826fd3a3f63bf97a38edc874ddab491cc7ceba"
    ["0.6.8/amd64"]="419f08728e109ec2f52f55bb2908d7bdeb60db5757dd91e2472060f89291293728cadfc0d92081e16b829f1442e12ae3187dd6c9add0d8e8bd4dc42242cf1fb2"
    ["0.6.8/arm64"]="ead8682648cb3f1164b5d893b5e477846b1f3bb363294c401831cfe0630c9ee3dabdd4e20fe63766cb8040491e39880bd23b2830b5ec31abf38a45466c8f2e51"
    ["0.6.7/amd64"]="a18d929253357d9189c4dcdce51309b716c2690027156a346bf5642e3d8df3a7fa8c194b123314c20659d3f98c8e62617191dee0b44347712a1db48613fc675e"
    ["0.6.7/arm64"]="0bea113761f83bfa2c074a826c11db1996acced910f841d4aa28a5b9ca418b241694120d9483ade68753f4dffcd4b37a3113cb83b8568dd88d5afb034f877b88"
    ["0.6.6/amd64"]="eeecdffd0ed9ff9d2b7b563f139bbf108baf1e7eea5e0a489f9418c45c2a9ccd22a332e4a67c139c9db1c35b2d8045f9457173c18e94978838cea883833c861b"
    ["0.6.6/arm64"]="6b2230785b73519427fedcaf56cecd9ee21e402bbb9491029f8a4c85fc7979ed5fde2ce7348dee156461caa0b372eec4397238edd76d10e15dab2b8b1c92ad74"
    ["0.6.5/amd64"]="66270ecf604ea242b4f28a58c68a455b5dd4ab39bbb7d903aec2a545adec766b20b8fc209e8ffdd49f30f6fa3e87421046ecc7e42855d2d5b4ca60d5f623bb92"
    ["0.6.5/arm64"]="84e28db5984684e35a9dad5fcea9d46043659060741724b71818cec27c5eae6671eeb2dce8f4cd85d11bc89eeba8411201b258c05ca915503da1a818c0c64ac1"
    ["0.6.4/amd64"]="af813728cd7040694d0a40dfeb6203c2fc2446970fdd924a2dc18d9aebfc0337b17623f41a7c5e5ed87d3da488486377a2de2597d3bd949a4717f4929db24c47"
    ["0.6.4/arm64"]="acf42d95bb5b2fc718fd19ae09e6aafb974ab515db1c47c2d7400efad7d3bfdb7d35def136fe54548b8d1b03664462afa7947c4cc33b379b0fa0bf5e6b0995b1"
    ["0.6.3/amd64"]="794ba1e0d32e47378adca16abd029712070806b5d252d9a2e282421766a20ed17114357dd6aafb6df7c73f7dca81adcf105fcb1c7ecaf4a1bbbdff3a3f66e41e"
    ["0.6.3/arm64"]="dd8161744cbded182dde60674ec6ab865d2a510005d085d275222f80f45f74907f657548aec0fcf910ab75c86d52e3bb35dffee4747f0ea53657063ccb9c2524"
    ["0.6.2/amd64"]="082add1100fb5a3025d7332bcb9939203f1425ee8bdf84a181fe35c97af82ff452e2a151580dda87046f0d4c46a0fb4b0a9dcbe06aaa82cbe0a488ddfa76ae59"
    ["0.6.2/arm64"]="6ee6ca30acc2fffe2364e6bb743b2bd98f5d58ba104b9675968b3ebeca4653ef6f175f1a29b0ba2476fd87bb9af67f87f3fd18b2a48e44a0afcc8d32c023b0ab"
    ["0.6.1/amd64"]="1b21849ca1d74739f3a79506d04aee001e55a70e20427a80e01fb664d757a46187adcab95d152a50f634a5abaf567b2dfd670015f6761447e7f3e3f482fab06b"
    ["0.6.1/arm64"]="20e0186f976d815cca44efade76d314c1a9df5191e3ac63084232df726a873ebe555015a4bbff6c8ce543a11e087437024368d3efa1aad424fcd4ee76837a3bc"
    ["0.6.0/amd64"]="6ccdbf261aecf7c9ecb44cd19161eb049faa854db326fd44e8b88499c1f2da4377a76673ec4a70b6abdf3f5e2ec2b736adce70e18386a63b4b46359087d6575e"
    ["0.6.0/arm64"]="fa61e3622ebbd8ac81f1b55a6952d5b93168621beb30313ab856c86fe026837ef33708fc8ffe04c0e01740e932b191ec95cb93a55b4902a21e94f2bffb53f75a"
    ["0.5.10/amd64"]="2b8677eb166386b5f3d21d8541316794cd6d43475284e23ab31c572f5cd388d057cfa6907d852b127b7ebedc7f3db8e4054d512482cec7ace4d271b499c84c6b"
    ["0.5.10/arm64"]="87a6c21369ef366e1b730a36e503989740c1b79c9a5eef334008a43236d16b152731d23f618486ad3c2e4945cb76f5f436b13bc1d4d875a34077cf3c6f92a4a4"
    ["0.5.9/amd64"]="8d6fd064f5d04b8eb48324cec12bb9f8c22426d10e6e6f4399039efcf23d85abf103455364175c08abdf7fff820e1a519b6ab1685d701c03ce9dc5264f1649af"
    ["0.5.9/arm64"]="2e8ed98dc101ba8f74373e9be1bed7205efa6d0a649c2986996d400de4b28c12f1bb4fed80c220d4f289e88df95eda447becaf598b9b1796337ded5d1405298e"
    ["0.5.8/amd64"]="8ea5146590603d7c15000e78bef9341247b62e1988e89a8831ca7f1708d31621165770832d0b845c1f1d89116fbddfc27b5b34f87a7b29b7040f319ca7da3f16"
    ["0.5.8/arm64"]="90655bf734de897ed9dec98e409fe328c19c8f260ee3e6889265f5bd63283cc83f1770e74106307adf7361496f06b13851fbd4927bf61fc1c28ae8bdea423fb7"
    ["0.5.7/amd64"]="68cad59fc7f78352bd06e74d61ede14426c9ce4c6e5007b1617e034f927a6b5b66a61ea5a0196fc6d7dbf81ef488bbe76519eda37658054c3c18da3ad1dd2912"
    ["0.5.7/arm64"]="7d919ddfe569d672d5c1f622932c5a45f465a0ee266d691a769986514f8ff8b56220e0eec8a6efde054ab2f78d3b3ad268cb4cacce5af877d5f9160ecee1cd96"
    ["0.5.6/amd64"]="25bb4e831371db4ce325625cad8a9b5256cf012a1fdce76481f9da8dba24987aabb8dd2f7d8acff5d16c6f5c3b318cd98450189d5e6469c1f2dc692e91f6e5e0"
    ["0.5.6/arm64"]="7409cee52efb86133022dbc90b02c128d012492cd4b208ce26c7dae880d1581416c24f49fc584caa5ad4e941dbf734c11dee42ddc2ac81c9316cbd4852506d57"
    ["0.5.5/amd64"]="ac17f734f414da9f724e46ab9c82bff6cff1f7fdef8f2010c31e571b2a0ca236c5be800e1f7837eb4a15e9ca20a351fe7e929af918d9ab32a129f02643f11ae9"
    ["0.5.5/arm64"]="dda1a3fa87c04b3e773ea5032948649200af2b097a1466dc1ef0abe30a438e635fe59040b0cdd304af09bb828fdc6e429e903752965f84406442a38210cbc79d"
    ["0.5.4/amd64"]="ec06f922dddb9a42d0376bcaa0035077e46d7caebde052d7bd6b06af2af856d56bd4b7e0088fab6fca38779fdd7c5e8608e9e955ac6352c44fc0433598793dab"
    ["0.5.4/arm64"]="744b643919655feff108ae4e3f9edfef4f4fb187abfa339a99c10586bd95790a8074a3909829d6d3f9e52c7e7dd6e8f7f288af5a90b03b51433381798cd72305"
    ["0.5.3/amd64"]="3a62253bcf3b8ce1d3c7cdaf0885443720f9c9e1a4bad8a48f3982e43b0bb78aefdf7e31758b8dbcda6c95b6fd0fcd110b4e914dcaa0705e22164005e6b25eff"
    ["0.5.3/arm64"]="2d8e3a5971e8303a3d426ca9dcc472afffdaa954a1fb99790d09a1b67b2291837824e3f4cc3e254bb7af0b3c3e61a076942561397291c6e8f9c0885c91f82d08"
    ["0.5.2/amd64"]="a9d6ae04419933deeb81a60d917c52f0469f9262ca89d213e0d3f9e927ff678f4dd78b23f2720c6db9ae9e230bc8ab3face50a6abb691874a3940daf67088c30"
    ["0.5.2/arm64"]="f5c0011d1231c16b67cd9c5b1340eca85bb54e5a4e91077ded5b01921458144d74bf94e7563383160c8861b3a5702a42db3c4a67c9ccb86a5ae7e2cafea1195e"
    ["0.5.1/amd64"]="7ffde96df149d11bf3cb6f747052b31a75ea5b6568802190b16cedb4762fa8f35f16aff2f3afba01abd4981c0d66762a030baa60b92eadf4ae12aaef641db229"
    ["0.5.1/arm64"]="17dedfaafa4fcc9caa9b3ce9c3999bf6d5228f3d0a155ae4cf42cf370eb704c156c8d11221bac9ce19a359229e3f106f17b1caf754d5e47755e8b7bd10715146"
    ["0.5.0/amd64"]="163999727f591bd68634a138705e76c9ee482ae3fe37c2fa40ad58c83ff3cd1441616434992b8b07991770ea2fc34bf23bc51dd9766f7d8fe25c749cbaeac64f"
    ["0.5.0/arm64"]="7994889b1b31f72c5856e6e2791db4f2d4d2d31f150657af689376a9aec96fe5f06badc6f9359dc71f82f151a8d3e00949a5cb2fa4db85ce158af8198426a879"
    ["0.4.0/amd64"]="f3d4b0c3bcc2ad5cc7c765f6646f752dddf33be4a12ea784e4c7cd1bb4d5c2503206ad0fa0e624b8d628a58c6034e4aeebfffe0d7c289ac5c755e227647e104a"
    ["0.4.0/arm64"]="1eee1e5adce18c2c1c69f83e8a749bcf2c8623ff998c4922951dd5f239cbc58a026cc69436fbe8ad4d864b2b1bcda1af28d942ac713e08d9b780cdac829806ac"
    ["0.3.2/amd64"]="0fae623aaa60670519dfe9232cba01ac71763f7d3d7edb66db2e73f6244d3274b6049de22f0d2179ef8738c5d74b88ea8d93f35687d8b130ca883d10296758a4"
    ["0.3.2/arm64"]="f111558939777342c5d0b0e28538283aea2d1c6b22a4b7c6e3717924f96dbfb1b71e97aa5a4d8d81f8a0b648fd554a6e9c828122a93ff1da386074f396841d0c"
    # Versions 0.3.0 and 0.3.1 did not release correctly.
    ["0.2.0/amd64"]="a823f1f8da8dd606291255b347eb41eb351f3b97cf1fd770d04758f740a36b1207f32a1e6b9b942e701e87fbe2aa69fe7ea1685e6b80f8cbbe669a164d55ebe7"
    ["0.2.0/arm64"]="0ff98cc701381b258b56544adc10cc03cfab7aa626f13a2552ac86aadc4659468b64c86f78c5344b383f62cd85dc18d3c6e3ae9cfe601a72b82291d5ac18ab87"
    ["0.1.0/amd64"]="1eeb0e9c947702b689f9b6833323966c50d35c9f4de7d3f249ad0aede18a28e985f471aba8628a673e9e044280d590094a781e4ac6797aad946ee244c827d518"
    ["0.1.0/arm64"]="524918c2cf036e28968a374b4506febb12fa397186dd24720587ed5e2f05793ff73d3a16668ba8f269467cff2cce9f22067b1ce92552de2da75da44928c158ed"
)
# <<< checksum table <<<

orb_install_main
