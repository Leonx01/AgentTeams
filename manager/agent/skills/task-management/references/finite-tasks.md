# Finite Task Workflow

## Choosing task type

- **Finite** — clear end state. Worker delivers result, it's done. Examples: "implement login page", "fix bug #123", "write a report".
- **Infinite** — repeats on schedule, no natural end. See `references/infinite-tasks.md`.

**Rule**: if the request contains a recurring schedule or implies ongoing monitoring, use infinite. Everything else is finite.

## Assigning a finite task

1. Generate task ID: `task-YYYYMMDD-HHMMSS`
2. Create task directory and files:
   ```bash
   mkdir -p /root/agentteams-fs/shared/tasks/{task-id}
   ```
   Write `meta.json` using the taskflow-compatible schema:
   ```json
   {
     "task_id": "{task-id}",
     "project_id": "standalone",
     "task_title": "{title}",
     "assigned_to": "@{worker}:{domain}",
     "room_id": "{room-id}",
     "status": "assigned"
   }
   ```
   Then write `spec.md` with requirements, acceptance criteria, and context.

3. Push to MinIO **immediately** — Worker cannot file-sync until files are in MinIO:
   ```bash
   mc cp /root/agentteams-fs/shared/tasks/{task-id}/meta.json ${AGENTTEAMS_STORAGE_PREFIX}/shared/tasks/{task-id}/meta.json
   mc cp /root/agentteams-fs/shared/tasks/{task-id}/spec.md ${AGENTTEAMS_STORAGE_PREFIX}/shared/tasks/{task-id}/spec.md
   ```
   **Verify the push succeeded** (non-zero exit = retry). Do NOT proceed to step 4 until files are confirmed in MinIO.

4. **MANDATORY — Register in state.json before dispatching** (this step is NOT optional, even for coordination, research, or management tasks):

   a) Get the Worker's `room_id`:
   ```bash
   agt get workers -o json
   ```

   b) Add the task before sending any Matrix assignment:
   ```bash
   bash /opt/agentteams/agent/skills/task-management/scripts/manage-state.sh \
     --action add-finite --task-id {task-id} --title "{title}" \
     --assigned-to {worker} --room-id {room-id}
   ```
   If task belongs to a project, append `--project-room-id {project-room-id}`.
   **WARNING**: Registering after dispatch races fast Workers that may finish before the task is tracked. Do not notify the Worker until this command succeeds.

5. Notify Worker in their Room (never in admin DM):

   **HARD RULE:** Do **not** put @worker task-assignment text in your admin DM reply. Workers cannot read the admin DM. The admin DM reply must only confirm to the admin (for example: assigned `{task-id}` to `{worker}`). The full dispatch with @mention MUST go to the Worker's Matrix room using the protocol below.

   a) Get your Manager runtime from the controller (source of truth):
   ```bash
   agt get managers -o json | jq -r '.managers[0].runtime'
   ```

   b) Compose the body the Worker must receive (full Matrix @mention so they wake):
   ```
   @{worker}:{domain} New task [{task-id}]: {title}. Use taskflow to accept the task, read shared/tasks/{task-id}/spec.md, and submit your structured result through taskflow. @mention me when complete.
   ```

   c) Send that body to the Worker's room, branching on runtime from step (a):

   - **`openclaw`** — use the **message** tool with `channel=matrix` and `target=room:<ROOM_ID>` (the literal `room_id` value from step (a), prefixed with `room:`). Do not rely on the implicit current room when you are in an admin DM.

   - **`copaw`** — use the shell tool:
   ```bash
   copaw channels send \
     --agent-id default \
     --channel matrix \
     --target-session "<ROOM_ID>" \
     --target-user "@{worker}:${AGENTTEAMS_MATRIX_DOMAIN}" \
     --text '@{worker}:{domain} New task [{task-id}]: {title}. Use taskflow to accept the task, read shared/tasks/{task-id}/spec.md, and submit your structured result through taskflow. @mention me when complete.'
   ```
   (Quote `--text` so the shell preserves spaces and @mentions.)

## On completion

1. Pull task directory from MinIO (Worker has pushed results):
   ```bash
   mc mirror ${AGENTTEAMS_STORAGE_PREFIX}/shared/tasks/{task-id}/ /root/agentteams-fs/shared/tasks/{task-id}/ --overwrite
   ```
2. Verify the structured `result.md`, then update `meta.json`: status=completed, fill completed_at. Push back to MinIO.
3. Remove from state.json:
   ```bash
   bash /opt/agentteams/agent/skills/task-management/scripts/manage-state.sh \
     --action complete --task-id {task-id}
   ```
4. Log to `memory/YYYY-MM-DD.md`.
5. Notify admin — read SOUL.md first for persona/language, then resolve channel:
   ```bash
   bash /opt/agentteams/agent/skills/task-management/scripts/resolve-notify-channel.sh
   ```
   Re-read runtime if needed: `agt get managers -o json | jq -r '.managers[0].runtime'`.

   - **`openclaw`:** If `channel` is not `"none"`, use the **message** tool with the resolved `channel` and `target` (same mapping as channel-management / primary-channel docs). Send `[Task Completed] {task-id}: {title} — assigned to {worker}. {summary}`.

   - **`copaw`:** If `channel` is not `"none"`, use **`copaw channels send`** with the resolved channel and target (Matrix: `--channel matrix`, `--target-session` = room id without `room:` prefix when the script returns `room:!...`, `--target-user` = admin Matrix ID). If you are **in an admin DM session** for this turn, do **not** CLI-send to the admin DM — put `[Task Completed] ...` in your **final reply only** (avoids duplicate messages; see copaw-manager-agent AGENTS.md). If you are in a Worker or project room session, use `copaw channels send` per the resolved JSON.

   - If `channel` is `"none"`: the admin DM room is not yet cached. Discover it now — list joined rooms, find the DM room with exactly 2 members (you and admin), then persist:
     ```bash
     bash /opt/agentteams/agent/skills/task-management/scripts/manage-state.sh \
       --action set-admin-dm --room-id "<discovered-room-id>"
     ```
     After persisting, retry `resolve-notify-channel.sh` and send the notification. If discovery fails, log a warning and move on — heartbeat will catch up.

## Task directory layout

```
shared/tasks/{task-id}/
├── meta.json     # Taskflow state shared by Manager and Worker
├── spec.md       # Manager-written
├── base/         # Manager-maintained reference files (Workers must not overwrite)
├── plan.md       # Worker-written execution plan
├── result.md     # Taskflow-written structured final result
└── *             # Intermediate artifacts
```
