#!/bin/bash

finite_task_acceptance_instruction() {
    local runtime="$1"
    local task_id="$2"

    case "${runtime}" in
        copaw)
            printf '%s\n' \
                "Accept this task with taskflow action ack_task and payload {\"taskId\":\"${task_id}\"}."
            ;;
        *)
            printf '%s\n' \
                "Sync shared/tasks/${task_id}/ using your runtime-specific file-sync procedure, read spec.md, and begin the task." \
                "Do not invoke taskflow; it is only available to CoPaw Workers."
            ;;
    esac
}

finite_task_sync_instruction() {
    local runtime="$1"
    local path="$2"

    case "${runtime}" in
        copaw)
            printf '%s\n' "Sync '${path}' to MinIO with filesync push."
            ;;
        *)
            printf '%s\n' \
                "Sync '${path}' to MinIO using your runtime-specific file-sync procedure." \
                "Do not invoke filesync or taskflow unless your runtime provides that tool."
            ;;
    esac
}

finite_task_completion_instruction() {
    local runtime="$1"
    local task_id="$2"
    local summary="$3"
    local deliverables="$4"

    case "${runtime}" in
        copaw)
            printf '%s\n' \
                "Submit the result with taskflow action submit_task and this inline payload:" \
                "{\"taskId\":\"${task_id}\",\"status\":\"SUCCESS\",\"summary\":\"${summary}\",\"deliverables\":${deliverables},\"notes\":[]}" \
                "Do not edit result.md directly because taskflow owns and renders that file."
            ;;
        *)
            printf '%s\n' \
                "Write shared/tasks/${task_id}/result.md with these exact protocol lines:" \
                "STATUS: SUCCESS" \
                "SUMMARY: ${summary}" \
                "DELIVERABLES: ${deliverables}" \
                "Then sync the whole shared/tasks/${task_id}/ directory to MinIO using your runtime-specific file-sync procedure." \
                "Do not invoke taskflow; it is only available to CoPaw Workers."
            ;;
    esac
}
