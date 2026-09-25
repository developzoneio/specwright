# End-to-end walkthrough

> **Looking for something you can actually run?** This walkthrough is illustrative prose, not a
> runnable project. For a real, runnable, non-.NET example you can clone and drive yourself -
> including a committed `.specs/` tree from an actual `/sd:feature` run - see
> [`../examples/fixture-project/`](../examples/fixture-project/).

This is a fictional but realistic example. The project is `inventory-service`, an ASP.NET Core 8 + PostgreSQL backend with JIRA tickets matching `^INV-\d+$`. The walkthrough covers:

1. First-time setup with `/sd:setup`.
2. A feature workflow (`/sd:feature INV-2501`) end-to-end.
3. A batch review catching a layer violation.
4. Cost breakdown (with batch vs per-task comparison).
5. Cost breakdown.
6. Three months later: searchable knowledge.

Output is illustrative - exact wording will differ from your runs.

---

## Step 1: `/sd:setup` (one-time per project)

```
$ cd ~/repos/inventory-service
$ claude
> /sd:setup
```

Bootstrap detects `partial` state because the project already has a `CLAUDE.md` from a prior `/init`:

```
specwright: setup
  State detected: post-init (has CLAUDE.md, no .specs/, no .claude/)
  Plan:
    - Backup CLAUDE.md to CLAUDE.md.bak.20260114-090015
    - Regenerate CLAUDE.md from template, merging stack hints
    - Scaffold .specs/ (constitution + index + scratchpads)
    - Scaffold .claude/ (project-config + settings)
```

It asks 3 questions:

```
Q1: Ticket system?
  1. JIRA  2. GitHub Issues  3. Linear  4. None
> 1

Q2: Ticket pattern?  (default: ^[A-Z]+-[0-9]+$)
> ^INV-\d+$

Q3: Shell?
  1. PowerShell  2. Bash/Zsh  3. Both
> 2
```

Then writes files:

```
[OK] CLAUDE.md (backup: CLAUDE.md.bak.20260114-090015)
[OK] .specs/constitution.md (12 <<placeholder>> tokens to fill)
[OK] .specs/index.md (empty registry)
[OK] .specs/_explorations/ (empty)
[OK] .specs/_reviews/ (empty)
[OK] .specs/_adr/ (empty)
[OK] .claude/project-config.json
[OK] .claude/settings.json

Setup complete.

Next steps:
  1. Fill placeholders in CLAUDE.md and .specs/constitution.md.
  2. Enable MCP servers under "mcp" in .claude/project-config.json.
  3. Restart Claude Code so hooks are picked up.
```

Trong Tran (the developer) opens `.specs/constitution.md` and fills it out. Excerpt of the result:

```markdown
## §1. Architectural non-negotiables

### §1.1. Layer rules
- Dependency direction: Domain -> Application -> Infrastructure -> WebServer.
  A layer NEVER depends on an outer layer.
- Cross-layer data: only DTOs. Never pass EF entities into Application.
- Controllers never call repositories directly; always via MediatR handlers.

### §1.2. Pattern rules
- CQRS: read paths use Dapper; write paths use EF Core.
- Validation: FluentValidation registered per request type.

## §2.3. Error handling
- Domain exceptions: NotFoundException, ValidationException, ConflictException.
- Never catch Exception to swallow; global middleware translates to HTTP.

## §3. Quality bars
| Metric | Threshold |
|---|---|
| Test coverage (line) | >= 80% on changed lines |
| Integration tests | Required for any cross-layer change |
```

Trong Tran also fills `CLAUDE.md` with build/test/lint commands and points to the constitution. Then restarts Claude Code.

---

## Step 2: `/sd:feature INV-2501`

The ticket: "Add low-stock alert webhook. When inventory drops below threshold, POST to subscriber webhooks."

```
> /sd:feature INV-2501
```

### Phase 0 - Bootstrap

```
Reading CLAUDE.md... OK
Reading .specs/constitution.md... OK
Reading .claude/project-config.json... OK
Reading .specs/index.md... OK
Ticket pattern matches: INV-2501. Fetching from Atlassian MCP...
FEAT-INV-2501 currently not-found; will start at Phase 1.
```

### Phase 1 - Spec

The architect fetches the JIRA ticket and produces `.specs/FEAT-INV-2501/00-spec.md`. Excerpt:

```markdown
---
id: FEAT-INV-2501
type: feature
status: draft
jira: INV-2501
created: 2026-01-14
linked_specs: []
---

# Add low-stock alert webhook for inventory threshold breaches

## Why
Operations team currently misses ~12 low-stock events per week because they
manually check the dashboard. Adding webhook notifications eliminates the
manual poll and reduces mean time-to-restock by an estimated 4 hours.

## What

### Scenario 1: Subscribe to alerts
- Given an authenticated operator
- When they POST /api/notifications/subscribe with {url, secret}
- Then a subscription is created and 201 returned with subscription ID

### Scenario 2: Trigger on threshold breach
- Given an active subscription for productId=X
- When inventory for X drops below configured threshold
- Then the webhook fires within 5s with HMAC-signed payload

### Scenario 3: Failed webhook retries
- Given a subscription whose webhook URL returns 5xx
- When the alert fires
- Then the system retries 3x with exponential backoff (1s, 2s, 4s), then deadletter

## Success criteria
- [ ] POST /api/notifications/subscribe returns 201 with subscription ID
- [ ] Webhook fires within 5s of inventory drop below threshold
- [ ] Failed webhooks retry 3x with exponential backoff, then deadletter
- [ ] HMAC signing with subscriber-provided secret
- [ ] p95 latency on subscribe endpoint < 100ms
- [ ] Unit + integration tests cover all scenarios above

## Out of scope
- Email or SMS notifications (webhooks only in this iteration)
- Per-product threshold configuration UI (threshold is global)
- Tenant isolation (single-tenant project)

## Constitution check
- §1.1 Layers: webhook firing logic lives in Application layer; HTTP client
  for webhook delivery in Infrastructure.
- §1.2 CQRS: subscription read uses Dapper; subscription create uses EF.
- §2.3 Errors: NotFoundException when productId is unknown.
- §3 Quality: >=80% coverage on changed lines; integration test for
  the threshold-breach -> webhook-fire path.

```

(Cross-references live in the `linked_specs` frontmatter field, written by `/sd:spec link` -
not in a body section.)

Then Gate 1:

```
=== ⛔ Gate 1 - Spec approval ===
Approve spec FEAT-INV-2501 for planning? (yes / refine / abort)
> yes

Status: draft -> approved. Added to .specs/index.md.
```

### Phase 2 - Impact

The code-explorer maps impact:

```markdown
## Impact analysis (sd-code-explorer)

### Direct callers (1-hop)
- src/Application/Inventory/UpdateStockHandler.cs:42 - this is where threshold
  checks would be added (existing stock-update path)
- src/Application/Inventory/StockReservationHandler.cs:67 - same path

### Test coverage scan
- src/Application/Inventory/UpdateStockHandler.cs: tests/.../UpdateStockHandlerTests.cs (84% coverage)
- src/Application/Inventory/StockReservationHandler.cs: tests/.../StockReservationHandlerTests.cs (91%)

### DI / config grep
- Program.cs:38 - inventory module registration

### Public API surface
- None affected (this is additive)

### Risk assessment
- Low: additive feature with existing test coverage in adjacent code.
- Watch: webhook retry timing on transient subscriber failures.
```

### Phase 3 - Plan + tasks

The architect produces `01-plan.md` and `02-tasks.md`. Six atomic tasks:

```
T01 - Add WebhookSubscription entity + EF configuration
  Files: src/Domain/Notifications/WebhookSubscription.cs,
         src/Infrastructure/Persistence/Configurations/WebhookSubscriptionConfig.cs
  Layer: Domain + Infrastructure
  ...

T02 - Add subscription create/list endpoints
  Files: src/WebServer/Controllers/NotificationsController.cs,
         src/Application/Notifications/CreateSubscriptionHandler.cs,
         src/Application/Notifications/ListSubscriptionsQuery.cs
  Layer: Presentation + Application
  ...

T03 - Add threshold-breach detector
  Files: src/Application/Inventory/LowStockDetector.cs,
         src/Application/Inventory/UpdateStockHandler.cs
  Layer: Application
  ...

T04 - Add webhook delivery client with HMAC signing
  Files: src/Infrastructure/Webhooks/WebhookClient.cs,
         src/Infrastructure/Webhooks/HmacSigner.cs
  Layer: Infrastructure
  ...

T05 - Wire LowStockDetector to WebhookClient via event bus
  Files: src/Application/Inventory/UpdateStockHandler.cs,
         src/Application/Events/LowStockEventHandler.cs
  Layer: Application
  Estimated complexity: L
  ...

T06 - Integration test: end-to-end stock-drop -> webhook fire
  Files: tests/integration/Notifications/LowStockWebhookFlow.cs
  Layer: Tests
  ...
```

Gate 2:

```
=== ⛔ Gate 2 - Plan approval ===
Approve plan FEAT-INV-2501 for execution? (yes / refine / abort)
> yes

Status: approved -> in-progress.
```

### Phase 4 - Execute (no per-task reviewer)

Tasks are executed in dependency order. For each task, the main thread invokes `sd-implementer`, runs the task's test, and does a lightweight self-check (scope, test pass, obvious violations). No reviewer subagent is spawned per-task.

Sample output for T03:

```
T03: Add threshold-breach detector
  Invoking sd-implementer...
  Files touched: LowStockDetector.cs, UpdateStockHandler.cs
  Running scoped test... PASS
  Self-check: scope OK, test OK, no obvious violations.
  [x] T03 checked off in 02-tasks.md.

T04: Add webhook delivery client with HMAC signing
  Invoking sd-implementer...
  ...

T05: Wire LowStockDetector to WebhookClient via event bus
  Estimated complexity: L -> ESC-FEAT-04 fires.
  05-retro.md: escalation: sd-implementer haiku -> sonnet (trigger: ESC-FEAT-04)
  Invoking sd-implementer (model: sonnet)...
  ...
```

T05 is the one task whose `Estimated complexity` is `L`, so the main thread raises that single
invocation to sonnet per the `sd-model-escalation` skill (a `Reversibility: hard` task would trip
`ESC-FEAT-04b` the same way). T06 starts back at the haiku default.

All 6 tasks complete without spawning a single reviewer. Violations that would have been caught per-task (like T03's layer issue - see Phase 5 below) are caught in the batch review instead.

### Phase 5 - Integration + batch review

First, integration tests and lint:

```
Running: dotnet test --no-build
  Passed: 247 / 247 (3 new tests for INV-2501)
Running: dotnet format --verify-no-changes
  OK
```

Then, the reviewer is invoked **once** for the entire changeset (all files changed across T01-T06):

```markdown
# Batch review: FEAT-INV-2501 (holistic)

Verdict: 1 🔴 BLOCK, 0 🟠 WARN, 1 🟡 SUGGEST, 4 🟢 PASS across 12 files.

---

## 🔴 BLOCK

### B1: LowStockDetector directly opens DbContext
- **File:line**: `src/Application/Inventory/LowStockDetector.cs:23`
- **Constitution**: §1.1 layer dependency direction
- **Finding**: `LowStockDetector` (Application layer) instantiates `InventoryDbContext`
  directly. The Application layer must not reference EF Core; it should accept an
  `IInventoryReader` (interface defined in Application, implemented in Infrastructure)
  via constructor injection.
- **Suggested direction**: define an interface in `src/Application/Inventory/` for the
  read it needs, inject it, let Infrastructure provide the EF-backed implementation.

## 🟡 SUGGEST

### S1: Threshold value hardcoded
- **File:line**: `src/Application/Inventory/LowStockDetector.cs:31`
- **Finding**: threshold is hardcoded to `10`. Spec acceptance says "configured threshold",
  implying it comes from configuration.
- **Suggested direction**: read from `IOptions<InventoryOptions>` registered in Program.cs.

## 🟢 PASS

### P1: §2.3 error handling respected at LowStockDetector.cs:18
### P2: Cross-task naming consistency - all handlers follow {Action}{Entity}Handler
### P3: DI wiring complete in Program.cs for all new services
### P4: HMAC signing implementation matches spec requirements
```

The BLOCK is routed back to the implementer for a targeted fix:

1. Adds `IInventoryReader` interface in Application.
2. Implements it in Infrastructure with EF.
3. Updates `LowStockDetector` to depend on the interface.
4. Re-runs the test.

Reviewer re-runs on the fix diff only:

```
Verdict: 0 🔴 BLOCK, 0 🟠 WARN, 0 🟡 SUGGEST, 2 🟢 PASS.
```

```
=== ⛔ Gate 3 - Integration + review pass ===
All clean for FEAT-INV-2501? (yes / address findings / abort)
> yes
```

### Phase 6 - Close-out

`05-retro.md` is appended:

```markdown
## 2026-01-14 close-out

- Tasks completed: 6/6 (T01-T06).
- Surprises:
  - T03 caught by batch reviewer in Phase 5: LowStockDetector instantiated
    DbContext directly. Routed back for fix; one extra iteration. Net: ~5 min.
    With per-task review this would have surfaced earlier but at ~6x the
    reviewer cost.
  - HMAC verification edge case (clock skew on subscriber side) surfaced
    during T04; deferred to FEAT-INV-2503 (see Spawned).
- Deferred follow-ups:
  - HMAC clock-skew tolerance: FEAT-INV-2503 (reserved).
  - Webhook delivery observability: FEAT-INV-2504 (reserved).
- Constitution exceptions taken: none.
- Status: in-progress -> done.
```

Index is updated; status transitions to `done`.

---

## Cost breakdown

For this run, approximate cost (illustrative):

| Step | Model | ~Cost | Notes |
|---|---|---|---|
| Phase 1 spec (architect, 1 call) | sonnet | $0.40 | Includes JIRA fetch context |
| Phase 2 impact (explorer, 1 call) | haiku | $0.06 | Read-only navigation |
| Phase 3 plan (architect, 1 call) | sonnet | $0.30 | 6-task plan + sequencing |
| Phase 4 execute (implementer x5, no reviewer) | haiku | $0.30 | Self-check by main thread |
| Phase 4 T05 (`Estimated complexity: L`, escalated by `ESC-FEAT-04`) | sonnet | $0.20 | One invocation; T06 is back on haiku |
| Phase 5 batch review (reviewer x1 + 1 re-review after fix) | sonnet | $0.25 | Single holistic pass + fix cycle |
| **Total** | | **~$1.51** | |

Compare with the per-task reviewer approach (~$2.39): the batch pattern saves ~37% on this 6-task feature by eliminating 6 redundant reviewer spawns. Each reviewer invocation loads the full context (CLAUDE.md + constitution + spec + changed files), so avoiding that repetition is where the savings come from.

---

## Three months later: searchable knowledge

Fast-forward to April 2026. A new engineer joins the team. They're tasked with adding email notifications. They run:

```
> /sd:spec search "webhook"
```

Output:

```
.specs/FEAT-INV-2501/00-spec.md:3:  type: feature
.specs/FEAT-INV-2501/00-spec.md:6:  jira: INV-2501
.specs/FEAT-INV-2501/00-spec.md:18:  ## Scenario 3: Failed webhook retries
.specs/FEAT-INV-2501/03-decisions.md:14:  ### Public API surface: none affected
.specs/FEAT-INV-2501/05-retro.md:8:    HMAC verification edge case (clock skew on subscriber side)
.specs/FEAT-INV-2503/00-spec.md:5:  type: feature  (spawned by FEAT-INV-2501)
```

Now they can read prior decisions instead of re-deriving them:

```
> /sd:spec show FEAT-INV-2501
```

The new engineer sees the architecture: subscriptions, HMAC signing, retry strategy, why per-product thresholds were out of scope, why a separate spec (FEAT-INV-2503) handles clock-skew tolerance. They author FEAT-INV-2510 (email notifications) with `linked-to FEAT-INV-2501` and reuse the subscription model.

This is the long-tail payoff. The constitution did not change between January and April. The team's accumulated decisions did. The new engineer reads them in 5 minutes instead of asking 4 people what they remember.

---

## Lessons from this walkthrough

### Discipline pays off in obvious places

The hard gates feel like friction in the moment. The Phase 5 batch review catching the T03 layer violation is exactly the kind of issue that, without the workflow, ships to main and surfaces three sprints later as a "weird tangle". Five minutes inline > one hour later.

### Batch review is a deliberate trade-off

The batch reviewer catches the same violations that per-task review would, but in one pass instead of N. The trade-off: issues surface later (after all tasks complete, not mid-loop). For most features this is fine - the batch review catches everything before close-out. For features with >10 tasks, consider splitting into multiple features for earlier feedback.

`§1.1` is the most common constitution rule violated in fast-moving Clean Architecture projects. The reviewer's severity tagging (`BLOCK` for layer violations, `SUGGEST` for hardcoded values) means real problems get loud and minor preferences stay quiet - whether caught per-task or in batch.

### Cost-aware models are not just about money

The fact that the implementer is `haiku` shapes the workflow: tasks must be atomic enough for `haiku` to execute well. That constraint cascades upward: the architect produces atomic tasks because the implementer demands them. The constraint is design discipline expressed as a tool choice.

### The retros are the memory

`05-retro.md` is the most-read file three months later. It captures the *judgements* - what surprised us, what we deferred, what we'd do differently. Specs document the plan; retros document the lived experience. Both matter.

### When to skip

This workflow is **overkill for a 50-line endpoint that ships in 20 minutes**. The author would have used `/sd:explore` to locate the right file and edited directly. The system rewards proportionate use: heavy machinery for changes that earn it.