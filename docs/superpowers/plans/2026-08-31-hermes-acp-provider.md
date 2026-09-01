# Hermes ACP Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Hermes Agent (`hermes acp`) as a built-in ACP provider driver, mirroring the Cursor/Grok template, upstream-PR-ready.

**Architecture:** Per-provider files on the shared generic ACP runtime (`apps/server/src/provider/acp/AcpSessionRuntime.ts`). New code: contracts settings schema, `HermesAcpSupport` (spawn + runtime factory), `HermesProvider` (snapshot/probe), `HermesAdapter` (port of `CursorAdapter`), `HermesTextGeneration` (port of `CursorTextGeneration`), `HermesDriver`, registration. Fork-only web polish lands as a separate final commit.

**Tech Stack:** TypeScript, Effect (read `.repos/effect-smol/LLMS.md` before adapter work), effect-acp, vitest via `vp test run`.

**Spec:** `docs/superpowers/specs/2026-08-31-hermes-acp-provider-design.md`

**Verified live-CLI facts (probe on VM 104, hermes v0.21.0):**
- `initialize` → `protocolVersion: 1`, `agentCapabilities: { loadSession: true, promptCapabilities: { image: true }, sessionCapabilities: { fork, list, resume } }`, `authMethods: [{ id: "custom" }, { id: "hermes-setup", type: "terminal" }]`, `agentInfo: { name: "hermes-agent", version: "0.21.0" }`.
- `session/new` → returns `models.availableModels` catalog (`moa:default`, `anthropic:*`, `gemini:*`, …) with `models.currentModelId` — same parameterized-model shape Cursor uses, **without** needing the `parameterizedModelPicker` client capability.
- `hermes --version` prints `Hermes Agent v0.21.0 (2026.8.31) …` (parseable by `parseGenericCliVersion`).
- Session resume: `session/load` supported (`loadSession: true`).

**Template mapping (read these before each port):**
- Settings/driver shape: `GrokSettings` (`packages/contracts/src/settings.ts:497-521`), `GrokDriver.ts`.
- Adapter + models + textgen: Cursor (`CursorAdapter.ts`, `CursorProvider.ts`, `CursorTextGeneration.ts`) — Hermes's per-session model catalog matches Cursor, and Cursor has no XAI-style extension.
- No `AcpExtension` for Hermes in v1.

**Ground rules:** TDD per task. `vp test run <file>` for touched tests only; targeted typecheck; no repo-wide checks. Conventional commits. The upstream-candidate commits must not contain the spec, this plan, or web polish.

---

### Task 0: Worktree and branch

**Files:** none (setup)

- [ ] **Step 1: Create worktree on a feature branch off upstream main**

```bash
cd /home/raman/projects/t3code
git fetch origin main
git worktree add ../t3code-hermes -b feat/hermes-acp-provider origin/main
cd ../t3code-hermes
```

- [ ] **Step 2: Install deps (t3.json setup normally does this; run explicitly)**

Run: `vp i`
Expected: install completes; if module resolution breaks later, re-run this.

- [ ] **Step 3: Sanity-check test tooling**

Run: `vp test run packages/contracts/src/settings.test.ts`
Expected: PASS (baseline green before any change).

---

### Task 1: Contracts — `HermesSettings`

**Files:**
- Modify: `packages/contracts/src/settings.ts` (three spots: schema after `GrokSettings` ~line 521, `HermesSettingsPatch` next to `GrokSettingsPatch` ~line 867, `providers` struct ~line 728 + patch-struct + type export)
- Test: `packages/contracts/src/settings.test.ts`

- [ ] **Step 1: Write failing tests** (append to `settings.test.ts`, mirroring the existing Grok cases in that file — copy their describe structure):

```ts
describe("HermesSettings", () => {
  it("decodes defaults", () => {
    const decoded = Schema.decodeSync(HermesSettings)({});
    expect(decoded.enabled).toBe(false);
    expect(decoded.binaryPath).toBe("hermes");
    expect(decoded.customModels).toEqual([]);
  });

  it("is reachable via ServerSettings defaults", () => {
    const settings = Schema.decodeSync(ServerSettings)({});
    expect(settings.providers.hermes.enabled).toBe(false);
    expect(settings.providers.hermes.binaryPath).toBe("hermes");
  });
});
```

Note: if the existing Grok default-decode test asserts `binaryPath` differently (e.g. empty string with fallback applied elsewhere via `makeBinaryPathSetting`), mirror the Grok assertion exactly instead of the literals above.

- [ ] **Step 2: Run to verify failure**

Run: `vp test run packages/contracts/src/settings.test.ts`
Expected: FAIL — `HermesSettings` not exported.

- [ ] **Step 3: Implement.** After the `GrokSettings` block in `settings.ts`:

```ts
export const HermesSettings = makeProviderSettingsSchema(
  {
    // Off by default (like Cursor, Grok, and OpenCode): the binding is not
    // yet stable enough to probe on every install. Users opt in from Settings.
    enabled: Schema.Boolean.pipe(
      Schema.withDecodingDefault(Effect.succeed(false)),
      Schema.annotateKey({ providerSettingsForm: { hidden: true } }),
    ),
    binaryPath: makeBinaryPathSetting("hermes").pipe(
      Schema.annotateKey({
        title: "Binary path",
        description: "Path to the Hermes Agent binary.",
        providerSettingsForm: { placeholder: "hermes", clearWhenEmpty: "omit" },
      }),
    ),
    customModels: Schema.Array(Schema.String).pipe(
      Schema.withDecodingDefault(Effect.succeed([])),
      Schema.annotateKey({ providerSettingsForm: { hidden: true } }),
    ),
  },
  {
    order: ["binaryPath"],
  },
);
export type HermesSettings = typeof HermesSettings.Type;
```

Next to `GrokSettingsPatch`:

```ts
const HermesSettingsPatch = Schema.Struct({
  enabled: Schema.optionalKey(Schema.Boolean),
  binaryPath: Schema.optionalKey(TrimmedString),
  customModels: Schema.optionalKey(Schema.Array(Schema.String)),
});
```

In the `ServerSettings.providers` struct (after `grok`):

```ts
    hermes: HermesSettings.pipe(Schema.withDecodingDefault(Effect.succeed({}))),
```

And the matching `hermes: Schema.optionalKey(HermesSettingsPatch)` entry wherever `GrokSettingsPatch` is wired into the patch struct (search `GrokSettingsPatch` usages — mirror every one).

- [ ] **Step 4: Run tests**

Run: `vp test run packages/contracts/src/settings.test.ts`
Expected: PASS. If the file has an exhaustive provider-key assertion (search for `["codex", "claudeAgent", "cursor", "grok", "opencode"]`), add `"hermes"` there too.

- [ ] **Step 5: Typecheck contracts, commit**

Run: `cd packages/contracts && vp run typecheck` (or the package-scoped equivalent in its package.json)

```bash
git add packages/contracts/src/settings.ts packages/contracts/src/settings.test.ts
git commit -m "feat(contracts): add Hermes provider settings schema"
```

---

### Task 2: Server settings restore wiring

**Files:**
- Modify: `apps/server/src/serverSettings.ts` (lines ~237, ~247-290, ~334, ~446-452)
- Test: `apps/server/src/serverSettings.test.ts`

`restoreUsedProviders` re-enables opt-in providers that appear in session history. Hermes must join Cursor/Grok/OpenCode in every list.

- [ ] **Step 1: Write failing test.** Find the existing `serverSettings.test.ts` case covering Grok restore (search `restore` + `grok`) and clone it for hermes: persisted settings without `providers.hermes.enabled`, provider history containing `hermes`, expect restored `providers.hermes.enabled === true`.

- [ ] **Step 2: Run to verify failure**

Run: `vp test run apps/server/src/serverSettings.test.ts`
Expected: FAIL (hermes not restored / property missing).

- [ ] **Step 3: Implement.** Mirror every `grok` touchpoint found by `grep -n "grok" apps/server/src/serverSettings.ts`:
  - persisted-shape struct (~237): add `hermes: Schema.optionalKey(Schema.Struct({ enabled: Schema.optionalKey(Schema.Boolean) }))`
  - instance-driver check (~265): add `|| instance.driver === "hermes"`
  - restore merge (~282): add

```ts
      hermes: {
        ...settings.providers.hermes,
        enabled: persisted.providers?.hermes?.enabled ?? usedProviders.has("hermes"),
      },
```

  - defaults-with-undefined block (~334): add `hermes: { ...DEFAULT_SERVER_SETTINGS.providers.hermes, enabled: undefined },`
  - both SQL `provider_name IN ('cursor', 'grok', 'opencode')` lists (~446, ~452): add `'hermes'`.

- [ ] **Step 4: Run tests**

Run: `vp test run apps/server/src/serverSettings.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/server/src/serverSettings.ts apps/server/src/serverSettings.test.ts
git commit -m "feat(server): restore Hermes enablement from provider history"
```

---

### Task 3: `HermesAcpSupport`

**Files:**
- Create: `apps/server/src/provider/acp/HermesAcpSupport.ts`
- Test: `apps/server/src/provider/acp/HermesAcpSupport.test.ts`

Template: `GrokAcpSupport.ts` minus runtime-mode args, minus OAuth referrer env, minus XAI extension. Auth method is `"custom"` (from live initialize). Spawn is always `<binary> acp`.

- [ ] **Step 1: Write failing tests** (mirror `GrokAcpSupport.test.ts` structure):

```ts
import { describe, expect, it } from "vitest";
import { buildHermesAcpSpawnInput, HERMES_AUTH_METHOD_ID } from "./HermesAcpSupport.ts";

describe("buildHermesAcpSpawnInput", () => {
  it("spawns the configured binary with the acp subcommand", () => {
    const input = buildHermesAcpSpawnInput({ binaryPath: "/opt/hermes" }, "/work/dir", {
      PATH: "/usr/bin",
    });
    expect(input.command).toBe("/opt/hermes");
    expect(input.args).toEqual(["acp"]);
    expect(input.cwd).toBe("/work/dir");
    expect(input.env?.PATH).toBe("/usr/bin");
  });

  it("falls back to the default binary name", () => {
    const input = buildHermesAcpSpawnInput({ binaryPath: "" }, "/work/dir");
    expect(input.command).toBe("hermes");
  });
});

describe("HERMES_AUTH_METHOD_ID", () => {
  it("targets the Hermes custom-credentials auth method", () => {
    expect(HERMES_AUTH_METHOD_ID).toBe("custom");
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `vp test run apps/server/src/provider/acp/HermesAcpSupport.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement:**

```ts
import type { HermesSettings } from "@t3tools/contracts";
import * as Crypto from "effect/Crypto";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Scope from "effect/Scope";
import * as ChildProcessSpawner from "effect/unstable/process/ChildProcessSpawner";
import * as EffectAcpErrors from "effect-acp/errors";

import * as AcpSessionRuntime from "./AcpSessionRuntime.ts";

/** Auth method advertised by `hermes acp` for pre-configured runtime credentials. */
export const HERMES_AUTH_METHOD_ID = "custom";

type HermesAcpRuntimeHermesSettings = Pick<HermesSettings, "binaryPath">;

interface HermesAcpRuntimeInput extends Omit<
  AcpSessionRuntime.AcpSessionRuntimeOptions,
  "authMethodId" | "clientCapabilities" | "spawn"
> {
  readonly childProcessSpawner: ChildProcessSpawner.ChildProcessSpawner["Service"];
  readonly hermesSettings: HermesAcpRuntimeHermesSettings | null | undefined;
  readonly environment?: NodeJS.ProcessEnv;
}

export function buildHermesAcpSpawnInput(
  hermesSettings: HermesAcpRuntimeHermesSettings | null | undefined,
  cwd: string,
  environment?: NodeJS.ProcessEnv,
): AcpSessionRuntime.AcpSpawnInput {
  return {
    command: hermesSettings?.binaryPath || "hermes",
    args: ["acp"],
    cwd,
    ...(environment ? { env: { ...environment } } : {}),
  };
}

export const makeHermesAcpRuntime = (
  input: HermesAcpRuntimeInput,
): Effect.Effect<
  AcpSessionRuntime.AcpSessionRuntime["Service"],
  EffectAcpErrors.AcpError,
  Crypto.Crypto | Scope.Scope
> =>
  Effect.gen(function* () {
    const acpContext = yield* Layer.build(
      AcpSessionRuntime.layer({
        ...input,
        spawn: buildHermesAcpSpawnInput(input.hermesSettings, input.cwd, input.environment),
        authMethodId: HERMES_AUTH_METHOD_ID,
      }).pipe(
        Layer.provide(
          Layer.succeed(ChildProcessSpawner.ChildProcessSpawner, input.childProcessSpawner),
        ),
      ),
    );
    return yield* Effect.service(AcpSessionRuntime.AcpSessionRuntime).pipe(
      Effect.provide(acpContext),
    );
  });
```

Check `AcpSpawnInput`'s `env` field type before finalizing (`AcpSessionRuntime.ts:64` region); if `env` is required like Grok's usage, pass `env: { ...environment }` unconditionally.

- [ ] **Step 4: Run tests**

Run: `vp test run apps/server/src/provider/acp/HermesAcpSupport.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/server/src/provider/acp/HermesAcpSupport.ts apps/server/src/provider/acp/HermesAcpSupport.test.ts
git commit -m "feat(server): add Hermes ACP spawn support"
```

---

### Task 4: `HermesProvider` snapshot/probe

**Files:**
- Create: `apps/server/src/provider/Layers/HermesProvider.ts`
- Reference: `apps/server/src/provider/Layers/CursorProvider.ts` (port base), `GrokProvider.ts`

Port `CursorProvider.ts` with these deltas (this is a mechanical port — keep structure, rename `Cursor`→`Hermes`, then apply the list):

- [ ] **Step 1: Port with deltas**

1. Presentation:

```ts
const HERMES_PRESENTATION = {
  displayName: "Hermes",
  badgeLabel: "Experimental",
  showInteractionModeToggle: false,
} as const;
```

2. Fallback models (used before ACP discovery succeeds):

```ts
const HERMES_BUILT_IN_MODELS: ReadonlyArray<ServerProviderModel> = [
  {
    slug: "default",
    name: "Hermes (configured default)",
    isCustom: false,
    capabilities: EMPTY_CAPABILITIES,
  },
];
```

3. Version probe: spawn `<binaryPath> --version`, parse with `parseGenericCliVersion` (output `Hermes Agent v0.21.0 (2026.8.31)`), 4s timeout like the template.
4. Model discovery: keep the Cursor ACP-discovery flow (ephemeral runtime, read `models.availableModels` from session setup) but call `makeHermesAcpRuntime` and drop the `CURSOR_PARAMETERIZED_MODEL_PICKER_CAPABILITIES` / min-version-date gating — Hermes returns the catalog unconditionally (verified live). Keep the 15s discovery timeout.
5. Failure message:

```ts
const HERMES_ACP_MODEL_DISCOVERY_FAILED_MESSAGE = [
  "Hermes ACP model discovery failed.",
  "Hermes may not be configured on this machine yet; run `hermes setup` (or `hermes acp --setup`), then retry.",
  "Check server logs for ACP details.",
].join(" ");
```

6. Remove `apiEndpoint` plumbing entirely (Hermes has none).
7. Auth-required detection: if the template inspects auth state, treat the `"custom"` method as authenticated when the probe succeeds; a failed `authenticate` surfaces the discovery-failed message above.
8. Exported names (Task 7 imports these exactly): `buildInitialHermesProviderSnapshot`, `checkHermesProviderStatus`, `enrichHermesSnapshot`.

- [ ] **Step 2: Typecheck**

Run: `cd apps/server && vp run typecheck`
Expected: clean for this file (driver not wired yet — export only what compiles standalone).

- [ ] **Step 3: Commit**

```bash
git add apps/server/src/provider/Layers/HermesProvider.ts
git commit -m "feat(server): add Hermes provider snapshot and probe"
```

---

### Task 5: `HermesAdapter`

**Files:**
- Create: `apps/server/src/provider/Layers/HermesAdapter.ts`
- Reference: `apps/server/src/provider/Layers/CursorAdapter.ts` (port base, 1193 lines)

This is the big port. Read `.repos/effect-smol/LLMS.md` first. Keep CursorAdapter's structure function-for-function.

- [ ] **Step 1: Port with rename table**

| Cursor | Hermes |
|---|---|
| `PROVIDER = ProviderDriverKind.make("cursor")` | `ProviderDriverKind.make("hermes")` |
| `CURSOR_RESUME_VERSION = 1` | `HERMES_RESUME_VERSION = 1` |
| `makeCursorAcpRuntime(...)` | `makeHermesAcpRuntime(...)` (no apiEndpoint arg) |
| `parseCursorResume` | `parseHermesResume` (same `{ sessionId }` shape — `session/load` is supported) |
| `CursorSettings` | `HermesSettings` |
| `makeCursorAdapter` (export, ~line 313) | `makeHermesAdapter` (same options shape minus apiEndpoint) |

Deltas beyond renames:
1. Keep the mode-alias resolution helpers (`ACP_PLAN_MODE_ALIASES` etc.) as-is — Hermes advertises no modes today, the helpers no-op safely, and keeping the port faithful minimizes diff review cost.
2. Keep cwd handling identical (`path.resolve(input.cwd.trim())` after the non-empty check) — no new validation per spec.
3. Model selection: keep Cursor's `applyRequestedSessionConfiguration` flow; model ids are Hermes catalog ids (`anthropic:claude-fable-5` etc.) passed through verbatim. If CursorAdapter routes through a Cursor-specific `applyCursorAcpModelSelection` helper in `CursorAcpSupport.ts`, add the equivalent thin helper to `HermesAcpSupport.ts` (same logic, renamed) rather than importing Cursor's.
4. Permission requests: keep the full `request_permission` brokering including `selectAutoApprovedPermissionOption` for full-access mode. Do not special-case Hermes shell hooks — `--accept-hooks` is deliberately not passed.
5. Delete any Cursor desktop-launcher/forwarder rejection logic if present (Cursor-specific).

- [ ] **Step 2: Typecheck**

Run: `cd apps/server && vp run typecheck`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add apps/server/src/provider/Layers/HermesAdapter.ts
git commit -m "feat(server): add Hermes ACP adapter"
```

---

### Task 6: `HermesTextGeneration`

**Files:**
- Create: `apps/server/src/textGeneration/HermesTextGeneration.ts`
- Test: `apps/server/src/textGeneration/HermesTextGeneration.test.ts`
- Reference: `CursorTextGeneration.ts` + `CursorTextGeneration.test.ts` (port base)

Cursor's implementation runs an ephemeral ACP session per generation and parses JSON from `agent_message_chunk` text. Identical mechanism works for Hermes.

- [ ] **Step 1: Port the test file first** (`CursorTextGeneration.test.ts` → Hermes names, `makeHermesTextGeneration(config, env)` signature — same as Grok/Cursor two-arg form).

- [ ] **Step 2: Run to verify failure**

Run: `vp test run apps/server/src/textGeneration/HermesTextGeneration.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Port the implementation.** Renames only, plus: replace `makeCursorAcpRuntime({ cursorSettings, ... })` with `makeHermesAcpRuntime({ hermesSettings, ... })`; rename `CURSOR_TIMEOUT_MS` to `HERMES_TIMEOUT_MS` (same value, `180_000`); keep prompt builders and sanitizers from `TextGenerationPrompts.ts` / `TextGenerationUtils.ts` untouched. Export as `makeHermesTextGeneration(hermesSettings, environment?)`.

- [ ] **Step 4: Run tests**

Run: `vp test run apps/server/src/textGeneration/HermesTextGeneration.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/server/src/textGeneration/HermesTextGeneration.ts apps/server/src/textGeneration/HermesTextGeneration.test.ts
git commit -m "feat(server): add Hermes text generation"
```

---

### Task 7: `HermesDriver` + registration

**Files:**
- Create: `apps/server/src/provider/Drivers/HermesDriver.ts`
- Modify: `apps/server/src/provider/builtInDrivers.ts`
- Test (modify): `apps/server/src/provider/Layers/ProviderRegistry.test.ts`, `apps/server/src/provider/Layers/ProviderInstanceRegistryLive.test.ts`

- [ ] **Step 1: Update registry tests first.** Both files assert over the built-in driver set (search for `grok` / driver counts / kind lists). Add `"hermes"` to expected kind lists and bump any counts. Run to verify they FAIL against current code:

Run: `vp test run apps/server/src/provider/Layers/ProviderRegistry.test.ts apps/server/src/provider/Layers/ProviderInstanceRegistryLive.test.ts`
Expected: FAIL (hermes missing).

- [ ] **Step 2: Implement `HermesDriver.ts`** — port `GrokDriver.ts` structure with Hermes pieces:

```ts
import { HermesSettings, ProviderDriverKind, type ServerProvider } from "@t3tools/contracts";
// ...same infra imports as GrokDriver (Crypto, Effect, FileSystem, Path, Schema,
// HttpClient, ChildProcessSpawner, BackgroundPolicy, ServerConfig,
// ServerSettingsService, ProviderDriverError, ProviderEventLoggers,
// makeManagedServerProvider, defaultProviderContinuationIdentity,
// mergeProviderInstanceEnvironment, providerMaintenance, providerUpdateSettings)

import { makeHermesTextGeneration } from "../../textGeneration/HermesTextGeneration.ts";
import { makeHermesAdapter } from "../Layers/HermesAdapter.ts";
import {
  buildInitialHermesProviderSnapshot,
  checkHermesProviderStatus,
  enrichHermesSnapshot,
} from "../Layers/HermesProvider.ts";

const decodeHermesSettings = Schema.decodeSync(HermesSettings);
const DRIVER_KIND = ProviderDriverKind.make("hermes");
```

Body: identical to `GrokDriver.create` with `Grok`→`Hermes` substitutions, `metadata: { displayName: "Hermes", supportsMultipleInstances: true }`, maintenance resolver `makeManualOnlyProviderMaintenanceCapabilities({ provider: DRIVER_KIND, packageName: null })`. Export `HermesDriverEnv` as the same union type GrokDriver exports (adjust if HermesProvider/Adapter need fewer services — declare only what's used).

- [ ] **Step 3: Register.** In `builtInDrivers.ts`: import `HermesDriver`/`HermesDriverEnv`, add `HermesDriverEnv` to `BuiltInDriversEnv`, append `HermesDriver` after `GrokDriver` in `BUILT_IN_DRIVERS`.

- [ ] **Step 4: Run registry tests**

Run: `vp test run apps/server/src/provider/Layers/ProviderRegistry.test.ts apps/server/src/provider/Layers/ProviderInstanceRegistryLive.test.ts`
Expected: PASS.

- [ ] **Step 5: Server typecheck, commit**

Run: `cd apps/server && vp run typecheck`

```bash
git add apps/server/src/provider/Drivers/HermesDriver.ts apps/server/src/provider/builtInDrivers.ts apps/server/src/provider/Layers/ProviderRegistry.test.ts apps/server/src/provider/Layers/ProviderInstanceRegistryLive.test.ts
git commit -m "feat(server): register Hermes as a built-in provider driver"
```

---

### Task 8: Env-gated live CLI probe

**Files:**
- Create: `apps/server/src/provider/acp/HermesAcpCliProbe.test.ts`
- Reference: `GrokAcpCliProbe.test.ts` / `CursorAcpCliProbe.test.ts` (port base)

- [ ] **Step 1: Port the probe test.** Gate on `T3_HERMES_ACP_PROBE=1` (skip otherwise, same mechanism as the Grok probe's env gate). The probe: build runtime via `makeHermesAcpRuntime`, start a session in a temp dir, send a trivial prompt, assert streamed `agent_message_chunk` output arrives.

- [ ] **Step 2: Verify skip-by-default**

Run: `vp test run apps/server/src/provider/acp/HermesAcpCliProbe.test.ts`
Expected: PASS (skipped).

- [ ] **Step 3: Live run.** The dev box has no local `hermes`. Two options: run this step on VM 104 (checkout there), or create a local ssh shim **outside the worktree** (`~/bin/hermes-ssh`: `#!/bin/sh` + `exec ssh hermes '~/.hermes/hermes-agent/venv/bin/hermes' "$@"`) and point the probe's binary-path env override at it — ACP is stdio, so it tunnels over ssh cleanly. Do not commit the shim.

Run: `T3_HERMES_ACP_PROBE=1 T3_HERMES_BINARY=~/bin/hermes-ssh vp test run apps/server/src/provider/acp/HermesAcpCliProbe.test.ts` (support the binary override env in the probe file the same way the Grok probe supports its override, if it has one; otherwise wire binaryPath from env in the probe test only)
Expected: PASS with real streamed output.

- [ ] **Step 4: Commit**

```bash
git add apps/server/src/provider/acp/HermesAcpCliProbe.test.ts
git commit -m "test(server): add env-gated Hermes ACP live probe"
```

---

### Task 9: User docs

**Files:**
- Create: `docs/user/providers-hermes.md` (shipped-product voice — no repo tooling, no source paths)
- Modify: `docs/README.md` (add to the providers listing where the other provider pages are linked)

- [ ] **Step 1: Write the page.** Sections: what Hermes is (link `github.com/NousResearch/hermes-agent`); requirements (Hermes installed and configured on the machine running the T3 server — `hermes setup`); enabling (Settings → Providers → Hermes, optional binary path); models (catalog comes from your Hermes configuration); limits (experimental; local binary only; no remote Hermes endpoint support). Mirror the structure of an existing provider page in `docs/user/` — read one first and match its headings exactly.

- [ ] **Step 2: Commit**

```bash
git add docs/user/providers-hermes.md docs/README.md
git commit -m "docs(user): add Hermes provider setup guide"
```

---

### Task 10: Fork-only web polish (separate, final — NOT for the upstream PR)

**Files:**
- Modify: `apps/web/src/components/settings/providerDriverMeta.ts`
- Modify: `apps/web/src/components/settings/providerIconUtils.ts` (or wherever driver icons resolve — read both files first)

- [ ] **Step 1: Add hermes entries** following the exact shape of the grok entries in each file (display meta + icon; if no Hermes SVG is available use the existing initials fallback with an accent color).

- [ ] **Step 2: Typecheck web**

Run: `cd apps/web && vp run typecheck`

- [ ] **Step 3: Commit with a fork-only marker**

```bash
git add apps/web/src/components/settings/providerDriverMeta.ts apps/web/src/components/settings/providerIconUtils.ts
git commit -m "feat(web): add Hermes provider meta and icon [fork-only]"
```

The upstream PR branch is everything **before** this commit; if we PR, branch from the Task 9 commit.

---

### Task 11: Verification pass

- [ ] **Step 1: Full touched-scope test run**

Run: `vp test run packages/contracts/src/settings.test.ts apps/server/src/serverSettings.test.ts apps/server/src/provider/acp/HermesAcpSupport.test.ts apps/server/src/textGeneration/HermesTextGeneration.test.ts apps/server/src/provider/Layers/ProviderRegistry.test.ts apps/server/src/provider/Layers/ProviderInstanceRegistryLive.test.ts apps/server/src/provider/acp/HermesAcpCliProbe.test.ts`
Expected: all PASS.

- [ ] **Step 2: Targeted typecheck + lint** for `packages/contracts`, `apps/server`, `apps/web`.

- [ ] **Step 3: Integrated dev pass (ask the user first per repo rules).** With user approval: `vp run dev` in the worktree, seed `.t3` per AGENTS.md test-data instructions, set hermes binaryPath to the ssh shim, enable Hermes, create a project, run a turn end-to-end. This is the one primary-agent integration check; subagents must not launch dev servers.

- [ ] **Step 4: Push feature branch to fork**

```bash
git push -u fork feat/hermes-acp-provider
```

---

## Deployment follow-up (separate session, no code)

VM 104: clone fork, `vp i`, run server, pair to T3 Connect (slot 2/3), create standing project at `/home/raman` titled "Hermes", add repo projects. Then update discussion #8987 with results and decide on the upstream PR (branch from Task 9 commit; body per CONTRIBUTING: problem, fix, verification evidence, scope fences, model/harness credit).
