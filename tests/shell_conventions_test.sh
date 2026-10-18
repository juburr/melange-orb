#!/bin/bash
#
# Checks the shell conventions every juburr orb's src/scripts follow. The same
# file is in every orb; keep the copies identical.
#
#   1. The first line is #!/bin/bash.
#   2. The first command is `set -euo pipefail`. Libraries under lib/ are
#      eval'ed by a script that already set it, so they have no set line.
#      A script that must not stop on errors says why on a line
#      `# shell-conventions: no-errexit <reason>` and uses `set -uo pipefail`.
#   3. No `set +o history` (a no-op in a non-interactive shell), and no set
#      command that turns xtrace on (it would print secrets).
#   4. Messages start with ERROR: or WARN: and go to stderr: every echo or
#      printf command that prints one of them starts its text with it and
#      has >&2 (or is inside a { ...; } >&2 group on the same line).
#      Error:, FATAL:, WARNING: and Warning: are not used.
#   5. Exports written by echo or printf quote every value with printf %q,
#      so no value can end the quoting or run a command when later steps
#      source $BASH_ENV.
#   6. eval only runs code the orb itself includes: a variable whose name
#      ends in _LIB or _SCRIPT. This covers eval behind command, builtin or
#      variable assignments, and inside $(...).
#
# Each line is split into its commands at ;, && and || outside quotes, and
# every command is checked on its own. A >&2 only counts outside quotes and
# comments. Commands that span lines, or a
# { ...; } >&2 group over several lines, are not followed: write one message
# command per line with its own >&2.
#
# The shared install code (install.sh, install_hash.sh and cache_key.sh) is
# not checked here. It is kept identical across the orbs as a unit, and
# install_hash.sh sends a function's messages to stderr where it calls it,
# which a line-by-line check can't see.

set -euo pipefail

root=$(cd "$(dirname "$0")" && pwd)
while [[ ! -f "${root}/src/@orb.yml" ]]; do
    [[ "${root}" != / ]] || { echo "ERROR: src/@orb.yml not found above $0" >&2; exit 1; }
    root=$(dirname "${root}")
done

failures=0
fail() {
    printf 'FAIL: %s\n' "$*"
    failures=$((failures + 1))
}

# split_commands LINE: sets the commands array to LINE's commands, split at
# ;, && and || outside single and double quotes, and the skeletons array to
# the same commands with quoted text and a trailing # comment removed.
split_commands() {
    local line=$1 current="" skeleton="" quote="" char prev=" " i
    commands=()
    skeletons=()
    for ((i = 0; i < ${#line}; i++)); do
        char=${line:i:1}
        if [[ "${quote}" == "'" ]]; then
            [[ "${char}" != "'" ]] || quote=""
        elif [[ "${char}" == "\\" ]]; then
            current+=${char}
            i=$((i + 1))
            char=${line:i:1}
        elif [[ "${quote}" == '"' ]]; then
            [[ "${char}" != '"' ]] || quote=""
        elif [[ "${char}" == "'" || "${char}" == '"' ]]; then
            quote=${char}
        elif [[ "${char}" == "#" && "${prev}" =~ [[:space:]] ]]; then
            break
        elif [[ "${char}" == ";" ]]; then
            commands+=("${current}")
            skeletons+=("${skeleton}")
            current=""
            skeleton=""
            prev=${char}
            continue
        elif [[ "${char}" == "&" || "${char}" == "|" ]] && [[ "${line:i+1:1}" == "${char}" ]]; then
            commands+=("${current}")
            skeletons+=("${skeleton}")
            current=""
            skeleton=""
            i=$((i + 1))
            prev=${char}
            continue
        else
            skeleton+=${char}
        fi
        current+=${char}
        prev=${char}
    done
    commands+=("${current}")
    skeletons+=("${skeleton}")
}

if [[ ! -d "${root}/src/scripts" ]]; then
    echo "ERROR: ${root}/src/scripts does not exist" >&2
    exit 1
fi
# A command substitution, so set -e stops here if find fails.
listing=$(cd "${root}" && find src/scripts -name '*.sh' -type f \
    ! -path src/scripts/install.sh ! -path src/scripts/install_hash.sh ! -path src/scripts/cache_key.sh |
    LC_ALL=C sort)
scripts=()
if [[ -n "${listing}" ]]; then
    mapfile -t scripts <<< "${listing}"
fi
if [[ ${#scripts[@]} -eq 0 ]]; then
    echo "No scripts to check besides the shared install code."
    exit 0
fi

# Where a command word starts within one command: after keywords, !, {, (,
# variable assignments and redirections, and behind the command or builtin
# wrappers.
lead='^[[:space:]]*((if|then|do|else|elif|while|until|!|\{|\()[[:space:]]+|\()*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|[0-9]*[<>]+&?[[:space:]]*[^[:space:]<>]+)[[:space:]]+)*((command|builtin)[[:space:]]+)*'
allowed_eval='eval[[:space:]]+"\$\{[A-Z0-9_]+_(LIB|SCRIPT)\}"[[:space:]]*(#.*)?$'

for script in "${scripts[@]}"; do
    path="${root}/${script}"

    # 1. Shebang.
    if [[ "$(head -n 1 "${path}")" != "#!/bin/bash" ]]; then
        fail "${script}: the first line must be #!/bin/bash"
    fi

    # 2. The first command, skipping comments, blank lines, and the bash
    # version guard install.sh runs before it.
    if [[ "${script}" != */lib/* ]]; then
        want="set -euo pipefail"
        if grep -qE '^# shell-conventions: no-errexit [^ ]' "${path}"; then
            want="set -uo pipefail"
        fi
        first=$(awk '
            /^[[:space:]]*(#|$)/ { next }
            /^if \[ -z "\$\{BASH_VERSION:-\}" \]/ { guard = 1 }
            guard { if ($0 ~ /^fi$/) guard = 0; next }
            { print; exit }
        ' "${path}")
        if [[ "${first}" != "${want}" ]]; then
            fail "${script}: the first command must be '${want}', not '${first}'"
        fi
    fi

    # Checks 3 to 6 read code lines only: comment lines are skipped, and so
    # are lines with no echo, printf, set or eval (base64 payloads, data).
    lineno=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        lineno=$((lineno + 1))
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ "${line}" =~ (echo|printf|set|eval) ]] || continue
        where="${script}:${lineno}"
        split_commands "${line}"

        # A { ...; } >&2 or ( ...; ) >&2 group on this line sends every
        # command in it to stderr.
        group_to_stderr=false
        if [[ "${skeletons[-1]}" =~ ^[[:space:]]*[\}\)][[:space:]]*(1?>&2)([[:space:]]|$) ]]; then
            group_to_stderr=true
        fi

        for ((c = 0; c < ${#commands[@]}; c++)); do
            cmd=${commands[c]}
            skeleton=${skeletons[c]}
            # 3. History and xtrace: any -...x... option or -o xtrace.
            if [[ "${cmd}" =~ ${lead}set[[:space:]] ]]; then
                if [[ "${cmd}" =~ [[:space:]]\+o[[:space:]]+history ]]; then
                    fail "${where}: remove 'set +o history'; it does nothing in a non-interactive shell"
                fi
                if [[ "${cmd}" =~ [[:space:]]-[A-Za-z]*x[A-Za-z]*([[:space:]]|[\)\}&|]|$) || "${cmd}" =~ -o[[:space:]]+xtrace([[:space:]]|[\)\}&|]|$) ]]; then
                    fail "${where}: do not enable xtrace; it prints secrets"
                fi
            fi

            if [[ "${cmd}" =~ ${lead}(echo|printf)([[:space:]]|$) ]]; then
                # 4. Message prefixes.
                # A prefix is a whole word: failOnError: is a YAML key.
                if [[ "${cmd}" =~ (^|[^A-Za-z0-9_])(Error|FATAL|WARNING|Warning): ]]; then
                    fail "${where}: use ERROR: or WARN:, not ${BASH_REMATCH[2]}:"
                fi
                if [[ "${cmd}" =~ (^|[^A-Za-z0-9_])(ERROR|WARN): ]]; then
                    prefix=${BASH_REMATCH[2]}
                    if ! [[ "${cmd}" =~ [\"\'](ERROR|WARN): ]]; then
                        fail "${where}: start the message text with ${prefix}:"
                    fi
                    if [[ "${skeleton}" != *">&2"* && "${group_to_stderr}" == false ]]; then
                        fail "${where}: ${prefix}: messages go to stderr (>&2)"
                    fi
                fi
                # 5. Exports: each export NAME= written before the first
                # redirection takes its value from %q, or from text with no
                # expansion or conversion in it.
                rest=${cmd%%>*}
                export_re='export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*|%[a-z])=([^[:space:]\\]*)'
                while [[ "${rest}" =~ ${export_re} ]]; do
                    value=${BASH_REMATCH[2]}
                    rest=${rest#*"${BASH_REMATCH[0]}"}
                    if [[ "${value}" != "%q" && ( "${value}" == *'$'* || "${value}" == *%* || "${value}" == *'`'* ) ]]; then
                        fail "${where}: write exports with printf 'export %s=%q\\n' NAME \"\$value\""
                        break
                    fi
                done
            fi

            # 6. eval at a command position, or inside $(...) or backticks.
            if [[ "${cmd}" =~ ${lead}eval([[:space:]]|$) ]]; then
                if ! [[ "${cmd}" =~ ${lead}${allowed_eval} ]]; then
                    fail "${where}: eval may only run orb code (\"\${NAME_LIB}\" or \"\${NAME_SCRIPT}\")"
                fi
            elif [[ "${cmd}" =~ (\$\(|\`)[[:space:]]*((command|builtin)[[:space:]]+)*eval([[:space:]]|$) ]]; then
                fail "${where}: eval may only run orb code (\"\${NAME_LIB}\" or \"\${NAME_SCRIPT}\")"
            fi
        done
    done < "${path}"
done

if [[ ${failures} -gt 0 ]]; then
    echo "${failures} shell convention failure(s) in ${#scripts[@]} scripts."
    exit 1
fi
echo "All ${#scripts[@]} scripts follow the shell conventions."
