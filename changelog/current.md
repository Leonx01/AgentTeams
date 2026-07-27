# Changelog (Unreleased)

Record image-affecting changes to `manager/`, `worker/`, `copaw/`, `hermes/`, `openclaw-base/`, `agentteams-controller/`, and release-facing install/chart changes here before the next release.

---

**Bug Fixes**

- **Runtime-aware finite-task completion**: Keep CoPaw Workers on taskflow while directing Hermes and OpenClaw Workers to write and sync the same structured terminal result through their supported file-sync workflow. ([67c43fe](https://github.com/agentscope-ai/AgentTeams/commit/67c43fe))
- **Deterministic integration regression**: Run controller-only cases alongside Manager scenarios, stop on the first failure, correlate Matrix and taskflow events exactly, and wait for generated Team and heartbeat state without reducing scenario coverage. ([8b34c46](https://github.com/agentscope-ai/AgentTeams/commit/8b34c46))
- **Team runtime configuration convergence**: Propagate Team storage scope through Worker credential refreshes, wait for runtime-specific configuration, and materialize CoPaw prompts, skills, and runtime config before startup. ([8b34c46](https://github.com/agentscope-ai/AgentTeams/commit/8b34c46))
- **Structured task terminal state**: Require taskflow-backed terminal results before Manager completion and keep TeamHarness and CoPaw task metadata synchronized across delegation and submission. ([8b34c46](https://github.com/agentscope-ai/AgentTeams/commit/8b34c46))
- **Multi-runtime integration stability**: Bound project-room joins and collaboration waits, handle pending Hermes invites and CoPaw assignment phrasing, and make integration assertions runtime-aware without reducing scenario coverage. ([a245cdc](https://github.com/agentscope-ai/AgentTeams/commit/a245cdc))
- **CoPaw Team Leader assets**: Overlay Team Leader prompts and built-in skills when a Team references an existing CoPaw Worker, while preserving CoPaw runtime configuration ownership. ([95201a2](https://github.com/agentscope-ai/AgentTeams/commit/95201a2))
- **Worker config sync stability**: Merge remote `openclaw.json` updates without overwriting the live local Matrix token or rewriting unchanged configuration. ([4efb7f9](https://github.com/agentscope-ai/AgentTeams/commit/4efb7f9))
- **Team deletion convergence**: Confirm ambiguous Tuwunel invite failures against current room membership so already-joined Manager users do not block Team finalizers. ([4efb7f9](https://github.com/agentscope-ai/AgentTeams/commit/4efb7f9))
- **Team Worker room boundary convergence**: Remove Manager again after standalone Worker infrastructure reconciliation restores regular Team Worker personal-room membership. ([b5b0add](https://github.com/agentscope-ai/AgentTeams/commit/b5b0add))
- **Team Worker reference enforcement**: Keep referenced Worker CRs protected during direct deletion and reject Team API members whose required role is empty. ([d96f1ed](https://github.com/agentscope-ai/AgentTeams/commit/d96f1ed))
- **Team Worker room membership**: Force Manager out of regular Team Worker personal rooms when equal Matrix power levels prevent a normal kick. ([43545c2](https://github.com/agentscope-ai/AgentTeams/commit/43545c2))
- **CoPaw Team assignment localparts**: Route Team Leader assignments that mention a Team Worker by Matrix localpart from Leader DM to Team Room. ([973e291](https://github.com/agentscope-ai/AgentTeams/commit/973e291))
- **CoPaw Team coordination routing**: Route Team Leader worker assignments sent through the `message` tool from Leader DM to Team Room, matching the Matrix channel send path. ([92c8145](https://github.com/agentscope-ai/AgentTeams/commit/92c8145))
- **Pinned OpenClaw source fetch**: Fetch the pinned OpenClaw commit directly so the base image build does not depend on a retired-brand external branch name. ([b0081c2](https://github.com/agentscope-ai/AgentTeams/commit/b0081c2))

**Branding and Compatibility**

- **Complete AgentTeams runtime rename**: Rename installer and Helm entrypoints, the controller Go module and CLI, and container filesystem paths to AgentTeams while preserving thin compatibility aliases and upgrade migration for existing HiClaw installations. ([3121f5f](https://github.com/agentscope-ai/AgentTeams/commit/3121f5f))
- **Hard-cut AgentTeams naming**: Remove retired-brand installer wrappers, environment fallbacks, CLI aliases, Helm naming branches, runtime path migrations, and active source paths so fresh AgentTeams deployments use one canonical contract end to end. ([d20e606](https://github.com/agentscope-ai/AgentTeams/commit/d20e606617edefbbc42c28c1201c5629fa73fd88))
- **Hard-cut Team and Worker resources**: Make Worker CRs the sole owners of runtime configuration and lifecycle, make Team CRs reference existing Workers through `spec.workerMembers`, and remove inline-member, registry, migration, and dependent-script compatibility paths. ([b3cf360](https://github.com/agentscope-ai/AgentTeams/commit/b3cf360))
- **Terminal Team API consumers**: Preserve Team admin and human-member fields in `agt` JSON output, and update integration cleanup and Team DAG setup for independently managed Worker CRs. ([cd05efe](https://github.com/agentscope-ai/AgentTeams/commit/cd05efe))
- **Terminal Team room topology**: Remove Manager from regular Team Worker personal rooms while retaining the Leader room, and restore Manager membership when Workers return to standalone operation. ([a5d6435](https://github.com/agentscope-ai/AgentTeams/commit/a5d6435))
