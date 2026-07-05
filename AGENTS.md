# Core Project Rules
- Follow your assigned role strictly — it defines scope and boundaries for your actions.
- After finishing a session, review all project documents(readme.md, requirements.md, design.md, etc) to ensure they reflect the current state. Stale docs mislead future sessions.
- Verify every change by running appropriate tests or scripts — never assume correctness without evidence.
- Keep the project in a clean state: no errors, warnings, or issues in formatter and linter output. A broken baseline blocks all future work.
- Follow the TDD flow described below. Skipping it leads to untested code and regressions.
- Write all documentation in English, compressed style. Brevity preserves context window.
- If you see contradictions in the request or context, raise them explicitly, ask clarifying questions, and stop. Do not guess which interpretation is correct.
- **Forward motion after authorization**: once the user has authorized a plan (chosen a variant, agreed to a phase list, or just said "go"), execute it without re-confirming each step. Re-asking is appropriate ONLY when (a) a genuinely irreversible action surfaces that was NOT covered by the original authorization — force push to a shared branch, prod deploy, dropping a database table, sending an external message (Slack, email, PR merge), or any other external side-effect that cannot be undone via git — OR (b) new information surfaces that contradicts the authorized plan (failing precondition, ambiguity discovered mid-flight). "Action looks expensive" or "diff is large" are NOT valid triggers — local code changes are reversible. Test before asking: if the user can only answer "yes" to the question, the question is noise — proceed instead.
- Code should follow "fail fast, fail clearly" — surface errors immediately with clear messages rather than silently propagating bad state. Unless the user requests otherwise.
- When editing CI/CD pipelines, always validate locally first — broken CI is visible to the whole team and slow to debug remotely.
- Provide evidence for your claims — link to code, docs, or tool output. Unsupported assertions erode trust.
- Use standard tools (jq, yq, jc) to process and manage structured output — they are portable and well-understood.
- Do not add fallbacks, default behaviors, or error recovery silently — if the user didn't ask for it, it's an assumption. If you believe a fallback is genuinely needed, ask the user first.
- Do not use tables in chat output — use two-level lists instead. Tables render poorly in terminal and are harder to scan.
- **Decision-level engagement — the human owns decisions, the AI owns code.** The boundary is the level of individual classes/methods: the human initiates and approves every decision *above* it (business rules, architecture, public interfaces / data shapes, new dependencies, key technical trade-offs); the AI decides freely at or below it (local naming, private helpers, test layout).
- **Surface above-class/method decisions before implementing.** When a decision above the class/method line is NOT already settled by an approved plan, present it to the human as options + trade-offs + a recommendation and STOP — wait for the human's call; do NOT self-select a default and proceed.
- **Narrate upward, not in diffs.** Report work in terms of requirements AND the class/method structure you produced (names, responsibilities, relationships), in prose the human can accept WITHOUT reading the code. Every above-class/method decision you made or surfaced MUST appear in that summary — an omitted one is a defect (this keeps mental/cognitive debt at zero above the class/method line). Never make reading the diff the only way to understand what changed.
- **AI owns code review; diff review is optional (Model B).** The AI reviews the code itself and reports a decision-level verdict (task complete? design sound? key risks?); the human is NOT required to read the diff to accept it. Offer the diff for optional inspection — never block the workflow on the human reading code.

---
## Project Rules
- **Native first.** Prefer AppKit/SwiftUI and platform APIs over third-party frameworks. The web engine is an implementation detail of content rendering, never of the app shell (window, toolbar, menus, file handling).
- **Verify UI in the real run target before declaring done.** For menu/toolbar/window changes, build the `.app` bundle and observe the actual UI (menu dump / screenshot). A green `make check` proves it compiles, not that the UI changed.
- **Minimalism is a feature, not a constraint.** This is a read-only Markdown previewer — nothing else. Reject scope creep: no editing, no export pipelines, no plugins, no settings sprawl. Every added control must justify itself against the three priorities below.
- **Priority order (use to break ties):** 1) nativeness, 2) minimalism, 3) UX.
- **Offline & private.** All rendering assets (JS/CSS) are vendored under `Sources/Markio/Resources/vendor` and loaded from disk. No network calls, no CDNs, no telemetry. The `WKWebView` must not reach the network.
- **One in-screen control that matters: line width.** Text content width is adjustable directly on the preview screen (not buried in a settings window). Treat this as a first-class, always-reachable UI affordance.
- **Document before code.** New/changed user-visible behavior → update SRS → update SDS → implement (see TDD Flow and Requirements Lifecycle).

## Project Information
- Project Name: Markio

## Project Vision
A native macOS application for **viewing** Markdown files — nothing more. It renders GitHub Flavored Markdown (GFM) and Mermaid diagrams with a clean, minimal, distraction-free reading experience that feels like a first-class Mac citizen. The single in-screen reading control is **line width**, adjustable directly on the preview. Target users: developers, writers, and note-takers who want a fast, faithful, offline Markdown previewer without an editor or a heavy Electron app.

## Project tooling Stack
- **Language:** Swift 6 (strict concurrency).
- **Build/Packaging:** Swift Package Manager (SPM) — executable target `Markio`.
- **App shell UI:** AppKit + SwiftUI (native window, toolbar, menus, file open / drag-and-drop / recent files).
- **Content rendering:** WebKit `WKWebView` (hybrid). Markdown→HTML and Mermaid diagrams render inside the web view.
- **Vendored web assets (offline, no CDN):** a Markdown-it–class parser with GFM support, `mermaid.js`, a syntax-highlight library, and CSS theme — all under `Sources/Markio/Resources/vendor`, with an HTML shell `template.html`.
- **Task runner:** `Makefile` wrapping `swift build` / `swift test` / `swift run`.
- **Platform:** macOS (Apple Silicon + Intel). No cross-platform target.

## Architecture
Native AppKit/SwiftUI shell hosting a single sandboxed `WKWebView` for content. The shell owns all OS integration; the web view owns only rendering.

```mermaid
flowchart LR
  FS[Markdown file] --> Loader[File loader + FSEvents watcher]
  Loader --> Render[Render pipeline]
  Render --> Web[WKWebView: template.html + vendor JS/CSS]
  Web --> View[Preview surface]
  Slider[Native line-width control] -- JS message --> Web
  Web -- "--content-width CSS var" --> View
```

- **App shell (AppKit/SwiftUI):** window, toolbar, main menu, Open dialog, drag-and-drop, recent files. Hosts the web view via `NSViewRepresentable`/`WKWebView`.
- **File loader + watcher:** opens the selected `.md` file; watches it (FSEvents / `DispatchSource`) for live reload on external edits.
- **Render pipeline:** passes raw Markdown text into the web view; parsing (GFM) + Mermaid + syntax highlighting happen in JS from vendored assets. The web view loads `template.html` via `loadFileURL` with read access scoped to the resource bundle. Network access disabled.
- **Line-width control:** a native slider/stepper on the preview screen sends a message (via `WKScriptMessageHandler`) that sets a CSS custom property `--content-width`; the content reflows live. The chosen width persists across launches.
- **Theming:** follows system appearance (light/dark) via the web view's color scheme + a matching native chrome.

## Key Decisions
- **Hybrid WKWebView rendering** chosen over pure-native text rendering: Mermaid is a JavaScript library and effectively requires a JS engine; GFM consistency is far easier to guarantee with a mature JS Markdown stack than re-implementing it natively. The native priority is preserved by keeping the *app shell* fully native and the web view confined to content.
- **Vendored offline assets, no CDN:** guarantees offline use, privacy, and reproducibility; aligns with "native/minimal/private".
- **SPM executable target** (`Sources/Markio`) with a resource bundle (`Resources/vendor`, `template.html`) over an Xcode project file: keeps the repo text-based, scriptable, and reviewable.
- **Makefile standard interface** over raw `swift` invocations: gives the agent-standard `check`/`test`/`dev`/`prod` verbs without adding a non-Swift toolchain (Deno was considered and rejected to avoid a foreign dependency in a native macOS project).
- **Line width as a live CSS variable** driven by a native control: the one reading setting that lives on the preview screen itself, per the product brief.
- **Read-only previewer scope:** no editing/export/plugins — deliberately out of scope.

## Documentation Hierarchy
1. **`AGENTS.md`**: Project vision, constraints, mandatory rules. READ-ONLY reference.
2. **SRS** (`documents/requirements.md`): "What" & "Why". Source of truth for requirements.
3. **SDS** (`documents/design.md`): "How". Architecture and implementation. Depends on SRS.
4. **Tasks** (`documents/tasks/<YYYY>/<MM>/<slug>.md`): Persistent committed plans/notes per task.
5. **Index** (`documents/index.md`): Agent-maintained navigation aggregator across all linkable artifacts (FR / SDS / NFR). Created on first write, never scaffolded. Task ↔ FR navigation lives inline in SRS as `**Tasks:**` back-pointers, not here.
7. **`README.md`**: Public-facing overview. Installation, usage, quick start. Derived from AGENTS.md + SRS + SDS.

## Interconnectedness Principle — SALP

Cross-references between any two pieces of project knowledge — doc-to-doc, **and code-to-doc** — use the **SALP grammar** (Semantic Anchor / Link Protocol). One mechanism, two tokens, namespace-disambiguated, machine-validated.

- **Anchor** — `[ANC:<ns>:<id>]` — declares a named target. Place it on the same line as the heading it labels, after the title text. Example: `### FR-CMD-EXEC: Command Execution [ANC:fr:cmd-exec]`.

- **Reference** — `[REF:<ns>:<id>]` or `[REF:<ns>:<id> | <display>]` — points at a target. The optional `| display` text is what readers see. Example: `See [REF:fr:cmd-exec | FR-CMD-EXEC] for details.`

- **Namespace grammar (open set)** — `<ns>` matches `[a-z][a-z0-9-]*`. The set is open: any grammar-conformant value is accepted by the validator. Examples currently in use: `fr` (functional requirements), `sds` (design sections), `task` (committed tasks), `nfr` (non-functional requirements), `code` (source-code references), `mx-concept` / `mx-person` / `mx-source` / `mx-answer` (memex pages). New consumers may introduce new namespaces without changing the validator.

- **ID grammar** — `<id>` is lower-kebab (`[a-z0-9][a-z0-9.-]*`). Hierarchical FR IDs preserve the period (`FR-DIST.MARKETPLACE` → `dist.marketplace`).

- **Applies in code too** — when source code needs to reference documentation, the comment carries a SALP REF, not a slug-style identifier or a GFM link. Example: `// [REF:fr:cmd-exec] — execution gate`. The legacy `// FR-<ID>` shortcut and the previous GFM-link form (`// [FR-X](path.md#…)`) are rejected by the validator.

- **Rejected forms** — do NOT use ID-only shortcuts (`[FR-CMD-EXEC]`), wikilinks (`[[X]]`), bare ID strings (`// FR-CMD-EXEC`), custom anchor mechanisms (`{#my-anchor}`, `<a name=...>`), GFM-form cross-references (`[FR-X](path.md#…)`), or salp-short (`[ANC:id]` without namespace). Validators ship with the framework reject all of these.

- **Drift discipline** — removing or renaming an anchor obliges updating every reference to it. Checked mechanically by `scripts/check-salp.ts` (dead-REF / duplicate-ANC / surviving-legacy-grammar) where the project ships such a script.

## Documentation Map

Maps source code paths to documentation sections that describe them. Used by commit workflows to determine which doc sections need updating when files change.

- `Sources/Markio/*App*.swift`, app shell / window / toolbar → SDS §3 (App Shell) + SRS FR-OPEN, FR-APPEARANCE
- `Sources/Markio/*WebView*.swift`, `*Render*.swift` → SDS §3 (Render pipeline) + SRS FR-GFM, FR-MERMAID, FR-HIGHLIGHT
- `Sources/Markio/*Watcher*.swift`, file watching → SDS §3 (File loader + watcher) + SRS FR-LIVE-RELOAD
- `Sources/Markio/*Width*.swift` + line-width control → SDS §5 (Line width) + SRS FR-LINE-WIDTH
- `Sources/Markio/Resources/template.html`, `Resources/vendor/**` → SDS §3 (Render pipeline) + SRS FR-GFM, FR-MERMAID
- `Makefile` → AGENTS.md Development Commands
- `README.md` → only for user-facing changes

If this section is empty or absent, commit workflows use a default mapping:
- New/changed exports, classes, types → SDS (component section)
- New feature, CLI command, skill, agent → SRS (new FR) + SDS (new component)
- Removed feature/component → remove from SRS + SDS
- Changed behavior → SDS (update description)
- Renamed/moved modules → SDS (update paths)
- README.md → only for user-facing changes

## Documentation Rules

Your memory resets between sessions. Documentation is the only link to past decisions and context. Keeping it accurate is not optional — stale docs actively mislead future sessions.

- Follow AGENTS.md, SRS, and SDS strictly — they define what the project is and how it works.
- Workflow for changes: new or updated requirement → update SRS → update SDS → implement. Skipping steps leads to docs-code drift.
- Status markers: `[x]` = implemented, `[ ]` = pending.
- **Traceability**: Every `[x]` criterion requires evidence. Placement depends on evidence type:
  1. **Code-evidenced**: Source files contain a SALP REF (in a `//` or `#` comment) pointing at the relevant SRS / SDS anchor near the implementing logic — e.g., `// [REF:fr:cmd-exec] — execution gate`. The REF IS the evidence; no paths are stored in SRS. Bare `// FR-<ID>` and GFM-form `// [FR-X](path.md#…)` comments are rejected by the SALP validator.
  2. **Non-code evidence** (acceptance tests, URLs, config files without comment support, file/dir existence): Placed directly in SRS/SDS next to the criterion.
  Without evidence of either type, the criterion stays `[ ]`.
- **Acceptance-as-gate**: Every FR in SRS MUST declare a runnable `**Acceptance:**` reference — a test path + test name, a benchmark scenario ID, or a verification command. Prose-only acceptance is not sufficient. An FR stays `[ ]` until its acceptance reference exists and passes on the current commit. Exception: when automation cost exceeds defect cost (pure visual design, external vendor dependency), mark `**Acceptance: manual — <reviewer> — <checklist path>**`. Manual is the exception, not the default.

### SRS Format (`documents/requirements.md`)
```markdown
# SRS
## 1. Intro
- **Desc:**
- **Def/Abbr:**
## 2. General
- **Context:**
- **Assumptions/Constraints:**
## 3. Functional Reqs
### 3.1 FR-CMD-EXEC
- **Desc:**
- **Scenario:**
- **Acceptance:** <test-path::test-name | benchmark-id | `evidence-command` | `manual — <reviewer>`>
- **Status:** [ ] / [x]
---

## 4. Non-Functional

- **Perf/Reliability/Sec/Scale/UX:**

## 5. Interfaces

- **API/Proto/UI:**

## 6. Acceptance

- **Criteria:**

````

### SDS Format (`documents/design.md`)
```markdown
# SDS
## 1. Intro
- **Purpose:**
- **Rel to SRS:**
## 2. Arch
- **Diagram:**
- **Subsystems:**
## 3. Components
### 3.1 Comp A
- **Purpose:**
- **Interfaces:**
- **Deps:**
...
## 4. Data
- **Entities:**
- **ERD:**
- **Migration:**
## 5. Logic
- **Algos:**
- **Rules:**
## 6. Non-Functional
- **Scale/Fault/Sec/Logs:**
## 7. Constraints
- **Simplified/Deferred:**
````

### Tasks (`documents/tasks/`)

- One file per task or session at a date-hierarchy path: `documents/tasks/<YYYY>/<MM>/<slug>.md` (kebab-case slug, max 40 chars).
- Examples: `documents/tasks/2026/03/add-dark-mode.md`, `documents/tasks/2026/03/fix-auth-bug.md`.
- Do not reuse another session's task file — create a new file. Old tasks are persistent canonical records.
- Use GODS format (see below). Architectural decisions are recorded as regular tasks with weighed alternatives in the body — there is no separate ADR primitive.
- Frontmatter: `date` (YYYY-MM-DD; required), `status: to do | in progress | done | superseded` (required), `implements: [FR-...]` (optional — present for FR-driven tasks, omitted for internal/maintenance), optional `tags`, optional `related_tasks` (markdown links to other task files), optional `migrated_from` for provenance, optional `superseded_by` (required when `status: superseded`).
- Status auto-derives from `## Definition of Done` checkbox count on every commit for non-superseded tasks (commit workflows handle this — never edit `status` manually mid-flight). `status: superseded` preserves provenance and is excluded from DoD derivation.
- Directory is **NOT gitignored** — tasks are persistent records. Validated by `scripts/check-task-format.ts` (path regex, status enum, status↔DoD consistency) where the project ships such a script. This Swift/Makefile project ships no `scripts/` (see Command Scripts below); the format is maintained by convention until a `make`-based validator is added.

### GODS Format

```markdown
---
implements:
  - FR-XXX
---
# [Task Title]

## Goal

[Why? Business value.]

## Overview

### Context

[Full problematics, pain points, operational environment, constraints, tech debt, external URLs, @-refs to relevant files/docs.]

### Current State

[Technical description of existing system/code relevant to task.]

### Constraints

[Hard limits, anti-patterns, requirements (e.g., "Must use Deno", "No external libs").]

## Definition of Done

Every DoD item MUST pair with (a) an FR-ID and (b) a runnable acceptance reference. Items without this tuple are wishes, not contracts.

- [ ] FR-XXX: <observable behavior>
  - Test: `<path/to/test>::<test_name>` (or `Benchmark: <scenario-id>`)
  - Evidence: `<command that passes iff the item is done>`
- [ ] FR-YYY: <observable behavior>
  - Test: `...`
  - Evidence: `...`

## Solution

[Detailed step-by-step for SELECTED variant only. Filled AFTER user selects variant.]
```

### Compressed Style Rules (All Docs)

- No changelogs — docs reflect current state, not history.
- English only (except tasks, which may use the user's language).
- Summarize by extracting facts and compressing — no loss of information, just fewer words.
- Every word must carry meaning — no filler, no fluff, no stopwords where a shorter synonym works.
- Prefer compact formats: lists, tables, YAML, Mermaid diagrams.
- Abbreviate terms after first use — define once, abbreviate everywhere.
- Use symbols and numbers to replace words where unambiguous (e.g., `→` instead of "leads to").

## Requirements Lifecycle (Plan → Develop → Review → Commit)

Requirements are only real when a machine can verify them. Each phase of the cycle has a concrete, non-skippable binding between FR and acceptance test.

- **Plan** (`plan` / `epic`): a task plan is not accepted without (a) `implements:` frontmatter listing every FR it touches, (b) each DoD item paired with `(FR-ID, test-path-or-benchmark, evidence-command)`. If an FR is new, add its section to SRS with the `**Acceptance:**` field filled in the same pass.
- **Develop** (TDD): RED = write the acceptance test first, using the path declared in the plan, and confirm it fails. GREEN = minimal code + `// FR-<ID>` comment next to the implementing logic. CHECK = the project's `check` command passes, including the new test.
- **Review** (`review` / `review-and-commit`): for every FR in scope, verify (a) SRS declares runnable acceptance, (b) the acceptance test exists and passes in the current diff, (c) source files carry `// FR-<ID>` markers. Any gap → `[critical]`, verdict cannot be `Approve`. Review also runs a JiT subset that probes for hidden behavioural regressions via ephemeral pass-on-parent / fail-on-diff tests; surviving catching tests are `[critical]` findings.
- **Commit** (`commit` / `review-and-commit`): before committing, if the diff adds/modifies FR sections in SRS, each new/modified FR MUST have a filled `**Acceptance:**` field. If it touches implementing code, the paired acceptance test MUST pass. Missing either → block commit.

Scope discipline prevents over-formalization: (1) pure bug fixes reuse an existing FR — add a regression test, no new FR; (2) refactors that preserve behavior cite the FR already covering the behavior; (3) only user-visible or contract-level changes introduce new FRs. The gate applies to new/changed FRs, not to every edit.

## Planning Rules

- **Environment Side-Effects**: When changes touch infra, databases, or external services, the plan must include migration, sync, or deploy steps — otherwise the change works locally but breaks in production.
- **Verification Steps**: Every plan must include specific verification commands (tests, validation tools, connectivity checks) — a plan without verification is just a wish.
- **Functionality Preservation**: Before editing any file for refactoring, run existing tests and confirm they pass — this is a prerequisite, not a suggestion. Without a green baseline you cannot detect regressions. Run tests again after all edits. Add new tests if coverage is missing.
- **Data-First**: When integrating with external APIs or processes, inspect the actual protocol and data formats before planning — assumptions about data shape are the #1 source of integration bugs.
- **Architectural Validation**: For complex logic changes, visualize the event sequence (sequence diagram or pseudocode) — it catches race conditions and missing edges that prose descriptions miss.
- **Variant Analysis**: A format for comparing alternatives of any kind — approaches, designs, tools, libraries, vendors, data models, configurations. Present each candidate as a labeled option with Pros / Cons / Risks / Best-for, then analyze the trade-offs across options (e.g. speed vs. correctness, cost vs. flexibility). One option is acceptable when the path is clear; when it is non-obvious, surface multiple distinct options.
- **Plan Persistence**: After variant selection, save the detailed plan to `documents/tasks/<YYYY>/<MM>/<slug>.md` using GODS format — chat-only plans are lost between sessions.
- **Proactive Resolution**: Before asking the user, exhaust available resources (codebase, docs, web) to find the answer autonomously — unnecessary questions slow the workflow and signal lack of initiative.

## TDD Flow

1. **RED**: Write a failing test for new or changed logic. When the change maps to an FR (new or modified), the failing test is the **FR's acceptance test** at the path declared in the plan's DoD; it doubles as the gate for `Requirements Lifecycle`. Pure internal refactors may use narrower unit tests.
2. **GREEN**: Write minimal code to pass the test. When implementing an FR, add a `// FR-<ID>` (TS/JS/Go/Rust/Swift) or `# FR-<ID>` (YAML/shell/Python) comment next to the implementing logic.
3. **REFACTOR**: Improve code and tests without changing behavior. Re-run the test.
4. **CHECK**: Run `fmt`, `lint`, and full test suite. You are NOT done after GREEN — skipping CHECK leaves formatting errors and regressions undetected. This step is mandatory.

### Test Rules

- Test logic and behavior only — do not test constants or templates, they change without breaking anything.
- Tests live in the same package. Testing private methods is acceptable when it improves coverage of complex internals.
- Write code only to fix failing tests or reported issues — no speculative implementations.
- No stubs or mocks for internal code. Use real implementations — stubs hide integration bugs.
- Run all tests before finishing, not just the ones you changed.
- When a test fails, fix the source code — not the test. Do not modify a failing test to make it pass, do not add error swallowing or skip logic.
- Do not create source files with guessed or fabricated data to satisfy imports — if the data source is missing, that is a blocker (see Diagnosing Failures).

## Diagnosing Failures

The goal is to identify the root cause, not to suppress the symptom. A quick workaround that hides the root cause is worse than an unresolved issue with a correct diagnosis.

1. Read the relevant code and error output before making any changes.
2. Apply "5 WHY" analysis to find the root cause.
3. Root cause is fixable → apply the fix, retry.
4. Second fix attempt failed → STOP. Output "STOP-ANALYSIS REPORT" (state, expected, 5-why chain, root cause, hypotheses). Wait for user help.

When the root cause is outside your control (missing API keys/URLs, missing generator scripts, unavailable external services, wrong environment configuration) → STOP immediately and ask the user for the correct values. Do not guess, do not invent replacements, do not create workarounds.

## Development Commands

### Shell Environment
- Always use `NO_COLOR=1` when running shell commands — ANSI escape codes waste tokens and clutter output.
- When writing scripts, respect the `NO_COLOR` env var (https://no-color.org/) — disable ANSI colors when it is set.

### Standard Interface
- `check` — the main command for comprehensive project verification. Runs the following steps in order:
  - build the project
  - comment-scan: "TODO", "FIXME", "HACK", "XXX", debugger calls, linter and formatter suppression markers
  - code formatting check
  - static code analysis
  - all project tests
- `test <path>` — runs a single test file or test suite.
- `dev` — runs the application in development mode with watch mode enabled.
- `prod` — runs the application in production mode.

### Detected Commands
> **Status:** Created and verified (`make check` green on macOS 14, Swift 6.3). Native SwiftPM via `Makefile`:

- `check` → `make check` → `swift build` + comment-scan + `swift format lint` + `swift test`
- `test <path>` → `make test ARGS="--filter <suite>"` → `swift test --filter <suite>`
- `dev` → `make dev` → `swift run Markio` (debug build; optional file argument)
- `prod` → `make prod` → `swift build -c release && swift run -c release Markio`

> **Menu / `.commands` / toolbar testing:** verify in a real `.app` bundle (`make app` → `open .build/Markio.app`). The bare `make dev` binary builds a **degraded** main menu — SwiftUI `.commands`, `DocumentGroup` menu edits, and AppKit menu changes do NOT apply there. Inspect the live menu with: `osascript -e 'tell application "System Events" to tell process "Markio" to get name of menu items of menu 1 of menu bar item 3 of menu bar 1'`.

### Command Scripts
> None yet. The standard interface will live in a root `Makefile` wrapping SPM. No `scripts/` wrappers are needed — SPM handles build/test/run directly.

## Code Documentation

- **Module level**: each module gets an `AGENTS.md` describing its responsibility and key decisions. (SwiftPM: a module's `AGENTS.md` lives inside a target source dir, so it MUST be listed in that target's `exclude:` in `Package.swift` — otherwise `swift build` emits an `unhandled files` warning and breaks the zero-warning baseline.)
- **Code level**: Swift doc comments (`///`) for types, methods, and functions. Focus on *why* and *how*, not *what*. Skip trivial comments — they add noise without value.
- **Requirement traceability**: when code implements a requirement from SRS (`documents/requirements.md`), add a `// FR-<ID>` (Swift/TS/JS/Go/Rust) or `# FR-<ID>` (YAML/shell/Python) comment next to the implementing logic. Code references requirements, not the reverse — SRS must not contain file paths. Exceptions: requirements verified by acceptance tests or proven by file existence need no comment.

> **Before you start:** read `documents/requirements.md` (SRS) and `documents/design.md` (SDS) if you haven't in this session. They contain project requirements and architecture that inform every task.
