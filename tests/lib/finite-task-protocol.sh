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
    local room_id="${5:-}"
    local coordinator="${6:-}"

    case "${runtime}" in
        copaw)
            printf '%s\n' \
                "Submit the result with taskflow action submit_task and this inline payload:" \
                "{\"taskId\":\"${task_id}\",\"status\":\"SUCCESS\",\"summary\":\"${summary}\",\"deliverables\":${deliverables},\"notes\":[]}" \
                "Do not edit result.md directly because taskflow owns and renders that file."
            ;;
        openclaw)
            printf '%s\n' \
                "Write shared/tasks/${task_id}/result.md with these exact protocol lines:" \
                "STATUS: SUCCESS" \
                "SUMMARY: ${summary}" \
                "DELIVERABLES: ${deliverables}" \
                "Then sync the whole shared/tasks/${task_id}/ directory to MinIO using your runtime-specific file-sync procedure." \
                "Do not invoke taskflow; it is only available to CoPaw Workers."
            if [ -n "${room_id}" ] && [ -n "${coordinator}" ]; then
                printf '%s\n' \
                    "After the sync succeeds, use the message tool with channel=matrix and target=room:${room_id} to send this exact completion notification:" \
                    "${coordinator} TASK_COMPLETED: ${task_id} - ${summary}" \
                    "Send it once through the message tool; do not rely on a streamed final reply to notify the coordinator."
            fi
            ;;
        hermes)
            printf '%s\n' \
                "Write shared/tasks/${task_id}/result.md with these exact protocol lines:" \
                "STATUS: SUCCESS" \
                "SUMMARY: ${summary}" \
                "DELIVERABLES: ${deliverables}" \
                "Then sync the whole shared/tasks/${task_id}/ directory to MinIO using your runtime-specific file-sync procedure." \
                "Do not invoke taskflow; it is only available to CoPaw Workers."
            if [ -n "${coordinator}" ]; then
                printf '%s\n' \
                    "After the sync succeeds, finish your Matrix response with this exact completion notification so the coordinator is woken:" \
                    "${coordinator} TASK_COMPLETED: ${task_id} - ${summary}" \
                    "Include the full Matrix ID exactly once; do not finish with an unmentioned summary."
            fi
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
