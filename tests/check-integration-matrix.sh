#!/bin/bash
# Validate the declarative integration coverage matrix.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MATRIX_FILE="${SCRIPT_DIR}/integration-test-matrix.json"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

jq -e . "${MATRIX_FILE}" >/dev/null

required_tests=$(jq -r '.required_tests[]' "${MATRIX_FILE}" | sort -V)
covered_tests=$(jq -r '.matrix[].tests[]' "${MATRIX_FILE}" | sort -Vu)
if [ "${covered_tests}" != "${required_tests}" ]; then
    printf 'FAIL: matrix test coverage differs from required_tests\nRequired:\n%s\nCovered:\n%s\n' \
        "${required_tests}" "${covered_tests}" >&2
    exit 1
fi

while IFS= read -r test_num; do
    matches=("${SCRIPT_DIR}"/test-"${test_num}"-*.sh)
    [ -e "${matches[0]}" ] || fail "test ${test_num} has no matching script"
done <<< "${required_tests}"

required_pairs=$(jq -r '.required_runtime_pairs[]' "${MATRIX_FILE}" | sort)
actual_pairs=$(jq -r '.matrix[] | "\(.manager_runtime)/\(.worker_runtime)"' \
    "${MATRIX_FILE}" | sort -u)
if [ "${actual_pairs}" != "${required_pairs}" ]; then
    printf 'FAIL: runtime coverage differs from required_runtime_pairs\nRequired:\n%s\nActual:\n%s\n' \
        "${required_pairs}" "${actual_pairs}" >&2
    exit 1
fi

while IFS= read -r pair; do
    manager_runtime="${pair%%/*}"
    worker_runtime="${pair#*/}"
    while IFS= read -r shard; do
        count=$(jq -r \
            --arg manager "${manager_runtime}" \
            --arg worker "${worker_runtime}" \
            --arg shard "${shard}" \
            '[.matrix[] | select(
                .manager_runtime == $manager and
                .worker_runtime == $worker and
                .shard == $shard
            )] | length' "${MATRIX_FILE}")
        [ "${count}" -eq 1 ] || \
            fail "${pair} must contain exactly one ${shard} shard (found ${count})"
    done < <(jq -r '.required_shards_per_runtime_pair[]' "${MATRIX_FILE}")
done <<< "${required_pairs}"

duplicate_entries=$(jq -r '
    [.matrix[] | "\(.shard)/\(.manager_runtime)/\(.worker_runtime)"]
    | group_by(.) | map(select(length > 1) | .[0]) | .[]
' "${MATRIX_FILE}")
[ -z "${duplicate_entries}" ] || fail "duplicate matrix entries: ${duplicate_entries}"

cleanup_not_last=$(jq -r '
    .matrix[]
    | select((.tests | index("100")) != null and .tests[-1] != "100")
    | "\(.shard)/\(.manager_runtime)/\(.worker_runtime)"
' "${MATRIX_FILE}")
[ -z "${cleanup_not_last}" ] || fail "test 100 must be last in: ${cleanup_not_last}"

echo "Integration coverage matrix checks passed."
