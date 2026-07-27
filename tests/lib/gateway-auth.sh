#!/bin/bash

# Return success once a chat-completions probe proves that the Manager
# credential passed Gateway authorization. A structured upstream auth error
# still proves the request was forwarded; Higress rejects an unknown consumer
# with an empty 401/403 response.
higress_gateway_authorization_ready() {
    local http_code="$1"
    local response_body="$2"

    case "${http_code}" in
        200)
            return 0
            ;;
        000|"")
            return 1
            ;;
        401|403)
            [ -n "${response_body}" ] &&
                printf '%s' "${response_body}" | jq -e '.error.code? != null' >/dev/null 2>&1
            return
            ;;
        *)
            return 0
            ;;
    esac
}

# Return success only when the upstream model completed the probe. Gateway
# authorization alone is insufficient before tests ask an Agent to act: a
# forwarded 401/503 would otherwise turn into a longer Agent-response timeout.
higress_llm_probe_ready() {
    [ "$1" = "200" ]
}
