#!/bin/bash

# Shared helpers for the melange-orb commands that run melange. Each command
# passes this file to its step as SCRIPT_MELANGE_LIB, and its script evals it
# after set -euo pipefail, so it only defines functions.

# melange_subst VALUE: prints VALUE with environment variables expanded. The
# value is piped in on stdin: passed as an argument, a value starting with "-"
# would be parsed as a flag. Without the CircleCI CLI (GitHub Actions, local
# runs), the value is used as is.
melange_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# melange_bool NAME VALUE: prints true or false. CircleCI passes boolean
# parameters as 1 or 0; actions and local callers use true or false.
melange_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *)
            echo "ERROR: ${1} must be true or false, not '${2}'." >&2
            exit 1
            ;;
    esac
}

# melange_require: stops the step unless melange is on the PATH.
melange_require() {
    if ! command -v melange > /dev/null 2>&1; then
        echo "ERROR: melange is not on the PATH. Run the install command in an earlier step." >&2
        exit 1
    fi
}

# melange_runner VALUE: stops the step unless VALUE is a runner melange has.
melange_runner() {
    case "$1" in
        docker | bubblewrap | qemu) ;;
        *)
            echo "ERROR: runner must be docker, bubblewrap or qemu, not '${1}'." >&2
            exit 1
            ;;
    esac
}

# melange_list VALUE: sets MELANGE_LIST to the items of VALUE, separated by
# commas, spaces or newlines. Empty items are dropped, and nothing is
# expanded: an item such as *.apk stays as it is.
melange_list() {
    local item
    local -a items=()
    MELANGE_LIST=()
    IFS=$', \t\n' read -r -d '' -a items <<< "$1" || true
    for item in ${items[@]+"${items[@]}"}; do
        if [[ -n "${item}" ]]; then
            MELANGE_LIST+=("${item}")
        fi
    done
}

# melange_flags FLAG VALUE: sets MELANGE_FLAGS to FLAG and an item for each
# item of the list VALUE (see melange_list), so an empty list adds nothing.
# Items that are paths to something on this machine are made absolute, since
# melange can run its build in another directory; anything else, such as a
# repository URL or a package name, is passed as it is.
melange_flags() {
    local item
    melange_list "$2"
    MELANGE_FLAGS=()
    for item in ${MELANGE_LIST[@]+"${MELANGE_LIST[@]}"}; do
        if [[ "${item}" != *://* && -e "${item}" ]]; then
            item=$(melange_abs_path "${item}")
        fi
        MELANGE_FLAGS+=("${1}" "${item}")
    done
}

# melange_abs_path PATH: prints PATH as an absolute path.
melange_abs_path() {
    if [[ "$1" == /* ]]; then
        printf '%s\n' "$1"
    else
        printf '%s/%s\n' "$(pwd)" "${1#./}"
    fi
}

# melange_host_arch: prints this machine's architecture as melange names it.
melange_host_arch() {
    local machine
    machine=$(uname -m)
    case "${machine}" in
        x86_64 | amd64) echo x86_64 ;;
        aarch64 | arm64) echo aarch64 ;;
        *) printf '%s\n' "${machine}" ;;
    esac
}

# melange_arch_args VALUE: sets MELANGE_ARCH_ARGS to melange's --arch flag
# for the arch parameter: empty is this machine's own architecture, "all"
# leaves the flag out so melange uses every architecture the package lists,
# and anything else is a comma-separated list passed as it is.
melange_arch_args() {
    local arch=$1
    MELANGE_ARCH_ARGS=()
    if [[ "${arch}" == all ]]; then
        return 0
    fi
    if [[ -z "${arch}" ]]; then
        arch=$(melange_host_arch)
    fi
    if [[ ! "${arch}" =~ ^[a-z0-9_]+(,[a-z0-9_]+)*$ ]]; then
        echo "ERROR: arch must be empty, all, or architectures separated by commas, such as x86_64,aarch64, not '${arch}'." >&2
        exit 1
    fi
    # shellcheck disable=SC2034 # read by the script that evals this file
    MELANGE_ARCH_ARGS=(--arch "${arch}")
}

# melange_signing_key PATH ENV_VAR WORK_DIR: sets MELANGE_SIGNING_KEY to the
# private key file melange signs with. Without ENV_VAR, it is PATH (empty for
# unsigned packages), which must exist. With ENV_VAR, the key comes from that
# variable, as PEM or base64-encoded PEM, and is written to a directory only
# this user can read, under WORK_DIR, with PATH's file name (melange.rsa
# without PATH): melange names each signature after the key's file name, and
# apko finds the public key by that name. The caller's EXIT trap removes it.
melange_signing_key() {
    local path=$1 env_var=$2 work_dir=$3 name value
    MELANGE_SIGNING_KEY=""
    if [[ -z "${env_var}" ]]; then
        if [[ -n "${path}" && ! -f "${path}" ]]; then
            echo "ERROR: The signing key ${path} does not exist. Run the keygen command first, set signing_key_env_var, or set signing_key to an empty value for unsigned packages." >&2
            exit 1
        fi
        MELANGE_SIGNING_KEY=${path}
        return 0
    fi
    if [[ ! "${env_var}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "ERROR: signing_key_env_var must name an environment variable, not '${env_var}'." >&2
        exit 1
    fi
    name=${path##*/}
    name=${name:-melange.rsa}
    value=${!env_var:-}
    if [[ -z "${value}" ]]; then
        echo "ERROR: ${env_var}, which signing_key_env_var names, is empty or not set." >&2
        exit 1
    fi
    if [[ "${value}" != *"-----BEGIN"* ]]; then
        if ! value=$(printf '%s' "${value}" | base64 -d 2> /dev/null) || [[ "${value}" != *"-----BEGIN"* ]]; then
            echo "ERROR: ${env_var} holds neither a PEM private key nor a base64-encoded one." >&2
            exit 1
        fi
    fi
    if [[ "${value}" != *"-----BEGIN RSA PRIVATE KEY-----"* ]]; then
        echo "ERROR: ${env_var} must hold an RSA private key in PKCS#1 PEM (-----BEGIN RSA PRIVATE KEY-----), which melange keygen writes and melange reads." >&2
        echo "  Convert a PKCS#8 key with: openssl rsa -traditional -in key.pem -out melange.rsa" >&2
        exit 1
    fi
    mkdir -p "${work_dir}/signing-key"
    chmod 700 "${work_dir}/signing-key"
    (
        umask 077
        printf '%s\n' "${value}" > "${work_dir}/signing-key/${name}"
    )
    # shellcheck disable=SC2034 # read by the script that evals this file
    MELANGE_SIGNING_KEY="${work_dir}/signing-key/${name}"
}

# split_shell_words STRING: splits STRING into the SHELL_WORDS array the way
# the shell splits a command line into words, but expands and executes
# nothing. Single quotes keep everything literal. Inside double quotes a
# backslash escapes only ", \, $, ` and newline, as in bash. Outside quotes a
# backslash escapes the next character, and a backslash-newline joins lines.
# A # that starts a word starts a comment, which runs to the end of the line.
# Spaces, tabs and newlines separate words, and '' is an empty word. Returns 1
# if a quote is never closed, 2 if the input ends in a backslash outside
# quotes (which escapes nothing), 3 for bash's $'...' or $"..." quoting, which
# it does not implement, 4 for a $(...) or backtick outside quotes, which it
# would not run, and 5 for a shell operator (| & ; < > ( )) outside quotes,
# such as a redirection or a <(...) process substitution.
split_shell_words() {
    local input=$1 word="" in_word=false quote="" char next i
    SHELL_WORDS=()
    for ((i = 0; i < ${#input}; i++)); do
        char=${input:i:1}
        if [[ "${quote}" == "'" ]]; then
            if [[ "${char}" == "'" ]]; then quote=""; else word+=${char}; fi
        elif [[ "${quote}" == '"' ]]; then
            if [[ "${char}" == '"' ]]; then
                quote=""
            elif [[ "${char}" == "\\" ]] && ((i + 1 < ${#input})); then
                next=${input:i+1:1}
                case "${next}" in
                    '"' | "\\" | '$' | '`') word+=${next}; i=$((i + 1)) ;;
                    $'\n') i=$((i + 1)) ;;
                    *) word+=${char} ;;
                esac
            else
                word+=${char}
            fi
        else
            case "${char}" in
                ' ' | $'\t' | $'\n')
                    if [[ "${in_word}" == true ]]; then
                        SHELL_WORDS+=("${word}")
                        word=""
                        in_word=false
                    fi
                    ;;
                "'" | '"') quote=${char}; in_word=true ;;
                "#")
                    if [[ "${in_word}" == true ]]; then
                        word+=${char}
                    else
                        while ((i + 1 < ${#input})) && [[ "${input:i+1:1}" != $'\n' ]]; do
                            i=$((i + 1))
                        done
                    fi
                    ;;
                "\\")
                    ((i + 1 < ${#input})) || return 2
                    i=$((i + 1))
                    if [[ "${input:i:1}" != $'\n' ]]; then
                        word+=${input:i:1}
                        in_word=true
                    fi
                    ;;
                '$')
                    case "${input:i+1:1}" in
                        "'" | '"') return 3 ;;
                        "(") return 4 ;;
                    esac
                    word+=${char}
                    in_word=true
                    ;;
                '`') return 4 ;;
                '|' | '&' | ';' | '<' | '>' | '(' | ')') return 5 ;;
                *) word+=${char}; in_word=true ;;
            esac
        fi
    done
    [[ -z "${quote}" ]] || return 1
    if [[ "${in_word}" == true ]]; then
        SHELL_WORDS+=("${word}")
    fi
}

# melange_words PARAMETER VALUE: sets MELANGE_WORDS to VALUE split like shell
# words (see split_shell_words), naming PARAMETER in any error. Nothing in it
# is expanded or executed: a $(...) or backtick that reached a parameter
# through an environment variable (a branch name, a commit message) reaches
# melange as text inside quotes, and fails the step outside them.
melange_words() {
    local status=0
    split_shell_words "$2" || status=$?
    case "${status}" in
        0) ;;
        1)
            echo "ERROR: ${1} could not be split into arguments: it has a quote that is never closed." >&2
            echo "  A literal ' or \" needs a backslash before it, or quotes of the other kind around it." >&2
            exit 1
            ;;
        2)
            echo "ERROR: ${1} could not be split into arguments: it ends in a backslash." >&2
            echo "  A literal \\ at the end needs another \\ before it." >&2
            exit 1
            ;;
        3)
            echo "ERROR: ${1} could not be split into arguments: \$'...' and \$\"...\" quoting is not supported." >&2
            echo "  Use '...' or \"...\" instead." >&2
            exit 1
            ;;
        4)
            echo "ERROR: ${1} could not be split into arguments: it has a \$(...) or backtick outside quotes." >&2
            echo "  ${1} is not run as shell code, so the command would not run. Quote it to pass it to melange as text." >&2
            exit 1
            ;;
        *)
            echo "ERROR: ${1} could not be split into arguments: it has one of | & ; < > ( ) outside quotes." >&2
            echo "  ${1} is not run as shell code, so pipes, redirections and <(...) would not work. Quote it to pass it to melange as text." >&2
            exit 1
            ;;
    esac
    # shellcheck disable=SC2034 # read by the script that evals this file
    MELANGE_WORDS=(${SHELL_WORDS[@]+"${SHELL_WORDS[@]}"})
}

# melange_run ARG...: prints the melange command line, shell-quoted, then
# runs it.
melange_run() {
    local quoted
    quoted=$(printf ' %q' "$@")
    echo "Running:${quoted}"
    "$@"
}
