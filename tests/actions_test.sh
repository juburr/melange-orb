#!/usr/bin/env bash
#
# Tests for the GitHub Actions in actions/, run offline. It checks that:
#
#   - every orb command has an action of the same name, and every action a
#     command, so the two can't drift apart
#   - each action takes the command's parameters as inputs, with the same
#     defaults, passes each to its script as the same PARAM_ variable the
#     command sets, and runs the scripts the command includes
#   - inputs only reach a step through env, never inside a run script, where
#     GitHub would paste them in as code
#   - every action another one uses is pinned to a full commit SHA
#   - actions/run_script.sh runs a script and passes on what it exports for
#     later steps: PATH entries through GITHUB_PATH, in order, and other
#     variables through GITHUB_ENV, multi-line values included; it passes on
#     nothing when the script fails, and keeps its exit code
#
# Run from a checkout:
#   bash PATH_TO_THIS_FILE

# The bodies of the scripts run_script.sh runs, and the patterns grep
# matches, are single-quoted to keep them from expanding here.
# shellcheck disable=SC2016

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
until [[ -f "${ROOT}/src/@orb.yml" ]]; do
    if [[ "${ROOT}" == "/" ]]; then
        echo "FAIL: no src/@orb.yml above ${BASH_SOURCE[0]}"
        exit 1
    fi
    ROOT=$(dirname "${ROOT}")
done
RUN_SCRIPT="${ROOT}/actions/run_script.sh"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

FAILURES=0
OUTPUT=""
DETAIL=""
RC=0

begin() {
    echo "--- $1"
}

check() {
    local description=$1
    shift
    DETAIL=""
    if "$@"; then
        echo "  ok: ${description}"
    else
        echo "  FAIL: ${description}"
        while IFS= read -r line; do
            echo "    | ${line}"
        done <<< "${DETAIL:-${OUTPUT}}"
        FAILURES=$((FAILURES + 1))
    fi
}

same() {
    if [[ "$1" == "$2" ]]; then
        return 0
    fi
    DETAIL="expected: $2"$'\n'"got:      $1"
    return 1
}
none() {
    if [[ -z "$1" ]]; then
        return 0
    fi
    DETAIL=$1
    return 1
}
rc_is() { [[ "${RC}" -eq "$1" ]]; }
output_has() { [[ "${OUTPUT}" == *"$1"* ]]; }

# fields FILE BLOCK: "name=default" for each entry of a top-level mapping
# (parameters: in a command, inputs: in an action), sorted. A default's
# quotes are dropped, so true and "true" match.
fields() {
    awk -v block="$2:" '
        $0 == block { inside = 1; next }
        /^[^ #]/ { inside = 0 }
        !inside { next }
        /^  [a-z_][a-z0-9_]*:[ ]*$/ { if (name != "") print name "=" value; name = $1; sub(/:$/, "", name); value = ""; next }
        /^    default:/ { value = $0; sub(/^    default:[ ]*/, "", value); gsub(/^"|"$/, "", value) }
        END { if (name != "") print name "=" value }
    ' "$1" | LC_ALL=C sort
}

# passed FILE PATTERN: the "PARAM_X=y" pairs a file sets, from lines such as
# "PARAM_X: << parameters.y >>" or "PARAM_X: ${{ inputs.y }}", sorted.
passed() {
    sed -nE "s/^ +(PARAM_[A-Z0-9_]+): ${2}$/\\1=\\2/p" "$1" | LC_ALL=C sort
}

# --------------------------------------------------------- command and action
for command_yml in "${ROOT}"/src/commands/*.yml; do
    name=$(basename "${command_yml}" .yml)
    action_yml="${ROOT}/actions/${name}/action.yml"
    begin "${name}"
    check "has an action at actions/${name}" test -f "${action_yml}"
    [[ -f "${action_yml}" ]] || continue
    check "takes the command's parameters as inputs, with the same defaults" \
        same "$(fields "${action_yml}" inputs)" "$(fields "${command_yml}" parameters)"
    check "passes each input to its script as the command does" \
        same "$(passed "${action_yml}" '\$\{\{ inputs\.([a-z0-9_]+) \}\}')" \
        "$(passed "${command_yml}" '<< parameters\.([a-z0-9_]+) >>')"
    missing=""
    while IFS= read -r script; do
        [[ -n "${script}" ]] || continue
        grep -qF "/src/${script}\"" "${action_yml}" || missing+="${script} "
    done < <(grep -oE '<< include\((scripts/[^)]+)\) >>' "${command_yml}" | sed -E 's/<< include\((.*)\) >>/\1/')
    check "runs every script the command includes" none "${missing}"
done
for action_yml in "${ROOT}"/actions/*/action.yml; do
    name=$(basename "$(dirname "${action_yml}")")
    begin "actions/${name}"
    check "has an orb command of the same name" test -f "${ROOT}/src/commands/${name}.yml"
    # An input may appear in env (NAME: ${{ inputs.x }}) and in if:
    # conditions, which GitHub evaluates as expressions, not code.
    check "uses inputs only in env and if: conditions" none "$(grep -nF '${{ inputs.' "${action_yml}" \
        | grep -vE '^[0-9]+: +[A-Z_][A-Z0-9_]*: \$\{\{ inputs\.[a-z0-9_]+ \}\}$' \
        | grep -vE '^[0-9]+: +if: ')"
done

begin "pinned actions"
unpinned=$(grep -nE '^\s+(- )?uses: ' "${ROOT}"/actions/*/action.yml "${ROOT}"/.github/workflows/*.yml 2> /dev/null \
    | grep -vE 'uses: \./' \
    | grep -vE 'uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40} # v[0-9]+(\.[0-9]+)*$')
check "every action used is pinned to a commit SHA, with its version in a comment" none "${unpinned}"

# --------------------------------------------------------------- run_script.sh
# run SCRIPT_BODY [VAR=value ...]: runs a script with that body through
# run_script.sh, with fresh GITHUB_ENV and GITHUB_PATH files. Sets RC and
# OUTPUT.
run() {
    local body=$1
    shift
    rm -rf "${WORK}/case" && mkdir -p "${WORK}/case"
    printf '#!/bin/bash\nset -euo pipefail\n%s\n' "${body}" > "${WORK}/case/script.sh"
    : > "${WORK}/case/env"
    : > "${WORK}/case/path"
    RC=0
    OUTPUT=$(env GITHUB_ENV="${WORK}/case/env" GITHUB_PATH="${WORK}/case/path" "$@" \
        bash "${RUN_SCRIPT}" "${WORK}/case/script.sh" 2>&1) || RC=$?
}
github_path() { cat "${WORK}/case/path"; }
github_env() { cat "${WORK}/case/env"; }
# env_value NAME: the value GITHUB_ENV gives NAME, read as GitHub reads it.
env_value() {
    awk -v name="$1" '
        !inside && index($0, name "<<") == 1 { end = substr($0, length(name) + 3); inside = 1; value = ""; first = 1; next }
        inside && $0 == end { inside = 0; printf "%s", value; exit }
        inside { value = value (first ? "" : "\n") $0; first = 0 }
    ' "${WORK}/case/env"
}

begin "run_script.sh: PATH"
run 'printf '"'"'export PATH=%q:"${PATH}"\n'"'"' /opt/tool/bin >> "${BASH_ENV}"'
check "succeeds" rc_is 0
check "adds the directory to GITHUB_PATH" same "$(github_path)" "/opt/tool/bin"
check "and nothing to GITHUB_ENV" none "$(github_env)"
run 'printf '"'"'export PATH=%q:"${PATH}"\n'"'"' /opt/second >> "${BASH_ENV}"
printf '"'"'export PATH=%q:"${PATH}"\n'"'"' /opt/first >> "${BASH_ENV}"'
check "writes several directories last first, so GitHub keeps their order" same "$(github_path)" $'/opt/second\n/opt/first'
run 'printf '"'"'export PATH=%q:"${PATH}"\n'"'"' /usr/bin >> "${BASH_ENV}"'
check "leaves out a directory already on the PATH" none "$(github_path)"

begin "run_script.sh: other variables"
run 'printf '"'"'export %s=%q\n'"'"' TOOL_DIGEST sha256:abc >> "${BASH_ENV}"'
check "passes a variable through GITHUB_ENV" same "$(env_value TOOL_DIGEST)" "sha256:abc"
check "ended by a random delimiter" grep -qE '^TOOL_DIGEST<<ghadelimiter_[0-9a-f]{32}$' "${WORK}/case/env"
run 'notes=$'"'"'line one\n\nline three'"'"'
printf '"'"'export %s=%q\n'"'"' NOTES "${notes}" >> "${BASH_ENV}"'
check "keeps a multi-line value" same "$(env_value NOTES)" $'line one\n\nline three'
run 'printf '"'"'export %s=%q\n'"'"' KEPT "$KEPT" >> "${BASH_ENV}"' KEPT=same
check "leaves out a variable it doesn't change" none "$(github_env)"
run 'printf '"'"'export %s=%q\n'"'"' QUOTED "a \"b\" \$c \`d\`" >> "${BASH_ENV}"'
check "passes quotes, dollars and backticks as they are" same "$(env_value QUOTED)" 'a "b" $c `d`'

begin "run_script.sh: the script's own result"
run 'echo "to stdout"; echo "WARN: to stderr" >&2'
check "shows the script's output" output_has "to stdout"
check "and its warnings" output_has "WARN: to stderr"
check "writes nothing when nothing is exported" none "$(github_env)$(github_path)"
run 'printf '"'"'export PATH=%q:"${PATH}"\n'"'"' /opt/tool/bin >> "${BASH_ENV}"; exit 3'
check "keeps a failing script's exit code" rc_is 3
check "and passes nothing on" none "$(github_env)$(github_path)"
run 'printf '"'"'export %s=%q\n'"'"' LEAK yes >> "${BASH_ENV}"' BASH_ENV=/nonexistent/job-bash-env
check "gives the script its own BASH_ENV, not the job's" same "$(env_value LEAK)" "yes"
run 'true' GITHUB_ENV=
check "refuses to run without GITHUB_ENV" rc_is 2
check "saying so" output_has "ERROR: GITHUB_ENV is not set."

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} check(s) failed."
    exit 1
fi
echo "All GitHub Actions checks passed."
