# Hermes ACP Provider — Design

Date: 2026-08-31
Status: draft, pending approval
Upstream signal: [discussion #8987](https://github.com/pingdotgg/t3code/discussions/8987)

## Goal

Add Hermes Agent (github.com/NousResearch/hermes-agent) as a first-class provider in the
raman325/t3code fork, driveable from the hosted web and mobile clients via T3 Connect.
Build the driver to upstream-quality standards so the same diff can become a PR if
discussion #8987 gets a positive signal.

## Decisions

1. **Integration path: ACP.** Hermes ships a standard ACP server (`hermes acp`,
   protocolVersion 1, verified on v0.21). The driver reuses the generic ACP runtime in
   `apps/server/src/provider/acp/` exactly the way Grok does. No bespoke adapter — that
   is the mistake that sank upstream attempt #8929.
2. **One Hermes profile.** No assistant/coder instance split. Hermes has no workspace of
   its own (`terminal.cwd: .`) and adapts to context (`coding_context: auto`); its
   identity (memories, kanban, SOUL.md) lives in `~/.hermes` regardless of cwd. T3 just
   hands it a directory.
3. **Assistant threads are a convention, not a feature.** A standing project rooted at
   `/home/raman` on VM 104 (Hermes's de-facto default workspace — same context as an
   interactive `hermes` session), retitled "Hermes". Coding threads are ordinary repo
   projects. Zero code: `projectId` stays non-optional, no contract or client changes.
   The home dir is not a git repo, so checkpointing is skipped silently — verified
   graceful in `CheckpointReactor.ts` (capture bails, revert shows an honest message).
   Repo projects get checkpoints/diffs as normal.
4. **Upstreamable core / fork-only split.** The driver diff carries no product opinion.
   Deployment, the standing project, and web polish stay out of it.

## Upstreamable core (the PR candidate)

Mirror the Grok template file-for-file:

| Component | File | Notes |
|---|---|---|
| Settings schema | `packages/contracts/src/settings.ts` | `HermesSettings`: `enabled` (default false), `binaryPath` (default `hermes` via `makeBinaryPathSetting`), hidden `customModels`. Plus `HermesSettingsPatch`, wiring into `ServerSettings`/`ServerSettingsPatch`. |
| ACP support | `apps/server/src/provider/acp/HermesAcpSupport.ts` | Spawn `<binaryPath> acp`; no user-configurable args in v1. Build spawn input + hand off to `AcpSessionRuntime.layer` like `GrokAcpSupport.ts:47-86`. |
| Driver | `apps/server/src/provider/Drivers/HermesDriver.ts` | `configSchema: HermesSettings`, env via `mergeProviderInstanceEnvironment`, snapshot/probe via `makeManagedServerProvider` (binary presence check; enabled=false → disabled status). |
| Registration | `apps/server/src/provider/builtInDrivers.ts` | 3-line registration per its docblock. |
| Docs | `docs/user/providers-hermes.md` | Shipped-product voice: install Hermes, set binary path, enable. |
| Tests | see Testing | Focused, per repo norms. |

### Models

On session start, report what Hermes's ACP initialize/advertisement exposes; if it
exposes nothing, report a single `default` entry — Hermes manages its own model config
(litellm-backed). No custom model UI.

### Text generation (titles, commits, branches, PRs)

v1: explicitly unsupported via the existing `makeUnsupportedTextGeneration` pattern.
Honest and small. Revisit only if Hermes's ACP surface makes a clean helper possible.

### Permissions / runtime modes

The generic ACP runtime already brokers `session/request_permission` per T3
`runtimeMode`. v1 passes no mode-specific CLI args (Hermes's `--accept-hooks` governs
shell-hook trust, not ACP permissions — do not conflate them). Verify actual
`request_permission` traffic against the live CLI during implementation and map modes
only if the default brokering proves insufficient.

### Scope fences (also stated in #8987)

Local binary only, spawned per session. No remote-Hermes transport, no MCP credential
forwarding, no session import, no Hermes-specific UI. Hosted clients render the unknown
driverKind generically by design.

## Fork-only pieces

- **Web polish (optional, local builds only):** ~15 lines in
  `apps/web/src/components/settings/providerDriverMeta.ts` + `providerIconUtils.ts`.
  Kept in a separate commit so the PR branch can drop it.
- **Ops (no code):** run the fork's server on VM 104 so Hermes is a local child process;
  pair as a second T3 Connect environment (slot 2 of 3); create the standing project at
  `/home/raman` titled "Hermes"; add repo projects under `~/projects/` as needed.
  Directory-uniqueness compares roots for equality, not ancestry, so nesting is fine.

## Error handling

- Missing/broken binary → probe reports warning/error status per the managed-server
  pattern; no crash.
- Nonexistent cwd → existing upstream behavior (spawn failure surfaces); v1 adds no new
  validation.
- Provider start failures terminalize through existing orchestration paths; nothing
  Hermes-specific.

## Testing (TDD)

- `packages/contracts/src/settings.test.ts` — schema round-trip + defaults.
- `ProviderRegistry.test.ts` / `ProviderInstanceRegistryLive.test.ts` — registration
  assertions updated (adding a built-in driver changes counts; #8929 hit the same).
- `HermesAcpSupport.test.ts` — spawn command/args/env unit tests.
- Env-gated live probe (`T3_HERMES_ACP_PROBE=1`) that starts the real CLI, runs a turn
  through the adapter, and checks streamed output — skipped by default.
- `vp test run <files>` + targeted typecheck/lint only. No repo-wide checks.

## PR strategy

- Feature branch off upstream `main`, containing only the upstreamable core. This spec
  and the web-polish commit stay off that branch.
- PR only on a positive signal in #8987. Body: problem in a sentence, the Grok-shaped
  fix, verification evidence, scope fences, model + harness credit. Expect possible
  defer-forever; the fork is the operating vehicle either way.

## Open questions (resolve during implementation planning)

1. What does `hermes acp` advertise on `initialize` (models, capabilities, auth
   methods)? Probe the live CLI first; it determines the snapshot/models code.
2. Does Hermes support `session/load` for resume, or new-session-per-restart? The
   generic runtime handles both; affects the resumeCursor shape.
3. Does Hermes emit `request_permission` at all, or auto-execute? Determines whether
   runtimeMode mapping is needed in v1.
