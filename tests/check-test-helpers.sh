#!/bin/bash
# Verify assertion helpers remain reliable for large captured content.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TEST_CONTROLLER_CONTAINER="test-controller"
export TEST_AGENT_CONTAINER="test-agent"
# shellcheck source=lib/test-helpers.sh
source "${SCRIPT_DIR}/lib/test-helpers.sh"

large_haystack="needle"
printf -v large_haystack 'needle%*s' 1048576 ''

assert_contains "${large_haystack}" "needle" "large exact assertion"
assert_contains_i "${large_haystack}" "NEEDLE" "large case-insensitive assertion"

if [ "${TESTS_FAILED}" -ne 0 ]; then
    echo "FAIL: large assertions were misclassified under pipefail" >&2
    exit 1
fi

if sed -n '/^assert_contains()/,/^}/p' "${SCRIPT_DIR}/lib/test-helpers.sh" |
    grep -Fq '| grep -q'; then
    echo "FAIL: assert_contains must not use an early-exit pipeline under pipefail" >&2
    exit 1
fi
if sed -n '/^assert_contains_i()/,/^}/p' "${SCRIPT_DIR}/lib/test-helpers.sh" |
    grep -Fq '| grep -qi'; then
    echo "FAIL: assert_contains_i must not use an early-exit pipeline under pipefail" >&2
    exit 1
fi

echo "Test helper checks passed."
