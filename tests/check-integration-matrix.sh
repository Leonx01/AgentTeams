#!/bin/bash
# Validate the declarative integration coverage matrix.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MATRIX_FILE="${SCRIPT_DIR}/integration-test-matrix.json"
WORKFLOW_FILE="${SCRIPT_DIR}/../.github/workflows/test-integration.yml"
INSTALLER_FILE="${SCRIPT_DIR}/../install/agentteams-install.sh"
TEAM_CONFIG_TEST="${SCRIPT_DIR}/test-18-team-config-verify.sh"
TEAM_ADMIN_TEST="${SCRIPT_DIR}/test-19-human-and-team-admin.sh"

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

invalid_worker_images=$(jq -r '
    .matrix[]
    | .worker_runtime as $worker_runtime
    | select(
        (.worker_images | type) != "array" or
        (.worker_images | length) == 0 or
        ([.worker_images[] | select(
            . != "openclaw" and . != "copaw" and . != "hermes"
        )] | length) > 0 or
        (.worker_images | index($worker_runtime)) == null
    )
    | "\(.shard)/\(.manager_runtime)/\(.worker_runtime)"
' "${MATRIX_FILE}")
[ -z "${invalid_worker_images}" ] || \
    fail "worker_images must be non-empty, valid, and include worker_runtime: ${invalid_worker_images}"

runtime_switch_missing_images=$(jq -r '
    .matrix[]
    | select(
        (.tests | index("23")) != null and
        (
            (.worker_images | index("openclaw")) == null or
            (.worker_images | index("copaw")) == null
        )
    )
    | "\(.shard)/\(.manager_runtime)/\(.worker_runtime)"
' "${MATRIX_FILE}")
[ -z "${runtime_switch_missing_images}" ] || \
    fail "test 23 shards must load both openclaw and copaw images: ${runtime_switch_missing_images}"

runtime_switch_shards=$(jq '[.matrix[] | select((.tests | index("23")) != null)] | length' "${MATRIX_FILE}")
[ "${runtime_switch_shards}" -eq 1 ] || \
    fail "test 23 must run exactly once because it covers both runtimes itself (found ${runtime_switch_shards})"

unnecessary_worker_images=$(jq -r '
    .matrix[]
    | select(
        (.tests | index("23")) == null and
        (.worker_images != [.worker_runtime])
    )
    | "\(.shard)/\(.manager_runtime)/\(.worker_runtime)=\(.worker_images | join(","))"
' "${MATRIX_FILE}")
[ -z "${unnecessary_worker_images}" ] || \
    fail "non-runtime-switch shards must load only their selected Worker image: ${unnecessary_worker_images}"

for test_file in "${TEAM_CONFIG_TEST}" "${TEAM_ADMIN_TEST}"; do
    grep -Fq 'TEST_WORKER_RUNTIME="${AGENTTEAMS_DEFAULT_WORKER_RUNTIME:-openclaw}"' "${test_file}" || \
        fail "$(basename "${test_file}") must derive Team member runtime from the matrix runtime"
    [ "$(grep -Fc 'runtime: ${TEST_WORKER_RUNTIME}' "${test_file}")" -ge 2 ] || \
        fail "$(basename "${test_file}") must set every Team member Worker runtime explicitly"
done

for runtime in openclaw copaw hermes; do
    grep -Fq "if: contains(matrix.worker_images, '${runtime}')" "${WORKFLOW_FILE}" || \
        fail "workflow does not conditionally download the ${runtime} Worker image"
done
grep -Fq "WORKER_IMAGES: \${{ join(matrix.worker_images, ' ') }}" "${WORKFLOW_FILE}" || \
    fail "workflow does not derive the expected archive count from worker_images"
grep -Fq 'AGENTTEAMS_INSTALL_PRELOADED_WORKER_IMAGES: "1"' "${WORKFLOW_FILE}" || \
    fail "workflow does not enable preloaded Worker image mode"
grep -Fq 'AGENTTEAMS_INSTALL_PRELOADED_WORKER_IMAGES:-0' "${INSTALLER_FILE}" || \
    fail "installer does not support preloaded Worker image mode"
[ "$(grep -Fc 'compression-level: 0' "${WORKFLOW_FILE}")" -ge 3 ] || \
    fail "all image artifacts must disable redundant ZIP compression"
[ "$(grep -Fc -- '--cache-from type=gha' "${WORKFLOW_FILE}")" -ge 3 ] || \
    fail "controller, openclaw-base, and downstream image builds must restore GitHub Actions cache"
[ "$(grep -Fc -- '--cache-to type=gha' "${WORKFLOW_FILE}")" -ge 3 ] || \
    fail "controller, openclaw-base, and downstream image builds must save GitHub Actions cache"
[ "$(grep -Fc 'ignore-error=true' "${WORKFLOW_FILE}")" -ge 3 ] || \
    fail "image builds must not fail when the optional GitHub Actions cache cannot be exported"
[ "$(grep -Fc 'zstd -T0 -3' "${WORKFLOW_FILE}")" -ge 3 ] || \
    fail "all image archives must use fast multi-core zstd compression"
if grep -Fq '| gzip > /tmp/agentteams-' "${WORKFLOW_FILE}"; then
    fail "image archives must not use single-core gzip compression"
fi
grep -Fq 'EXPECTED_IMAGE_COUNT=$((2 + ${#WORKER_IMAGE_NAMES[@]}))' "${WORKFLOW_FILE}" || \
    fail "test shards must count only embedded, manager, and declared Worker images"
if grep -Fq 'pattern: image-common-*' "${WORKFLOW_FILE}"; then
    fail "test shards must not download the build-only controller image"
fi
grep -Fq "find /tmp/images -type f -name '*.tar.zst' -delete" "${WORKFLOW_FILE}" || \
    fail "test shards must remove compressed archives after loading images"
grep -Fq 'make -o build-agentteams-controller build-${{ matrix.target }}' "${WORKFLOW_FILE}" || \
    fail "downstream image jobs must reuse the controller image loaded from the common artifact"

echo "Integration coverage matrix checks passed."
