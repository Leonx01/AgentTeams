#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT_DIR}/install/agentteams-install.sh"
AGENTTEAMS_KNOWN_STABLE_VERSION="v1.1.2"

eval "$(
    sed -n \
        -e '/^_ver_lt()/,/^}/p' \
        -e '/^_use_legacy_image_env()/,/^}/p' \
        "${INSTALLER}"
)"

assert_legacy() {
    if ! _use_legacy_image_env "$1"; then
        echo "FAIL: expected legacy env compatibility for $1" >&2
        exit 1
    fi
}

assert_current() {
    if _use_legacy_image_env "$1"; then
        echo "FAIL: did not expect legacy env compatibility for $1" >&2
        exit 1
    fi
}

assert_legacy "v1.1.2"
assert_legacy "v1.1.9"
assert_legacy "latest"
assert_current "v1.2.0"
assert_current "v1.2.0-beta.1"
assert_current "v1.3.0"
AGENTTEAMS_KNOWN_STABLE_VERSION="v1.2.0"
assert_current "latest"

legacy_prefix='HIC''LAW_'
compat_block="$(
    sed -n \
        '/# Begin pre-v1.2 image compatibility/,/# End pre-v1.2 image compatibility/p' \
        "${INSTALLER}"
)"

for suffix in \
    REGISTRATION_TOKEN \
    MINIO_USER \
    MINIO_PASSWORD \
    MANAGER_IMAGE \
    WORKER_IMAGE \
    COPAW_WORKER_IMAGE \
    HERMES_WORKER_IMAGE \
    MATRIX_DOMAIN \
    MATRIX_URL \
    MINIO_ENDPOINT \
    FS_BUCKET \
    CONTROLLER_URL \
    DOCKER_NETWORK \
    RESOURCE_PREFIX
do
    if ! grep -Fq "${legacy_prefix}${suffix}=" <<<"${compat_block}"; then
        echo "FAIL: legacy compatibility block is missing ${legacy_prefix}${suffix}" >&2
        exit 1
    fi
done

echo "PASS: installer injects legacy image env only below v1.2.0"
