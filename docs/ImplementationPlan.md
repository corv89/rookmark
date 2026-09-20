# rookmark — Implementation Plan

A macOS CLI that reorganizes a browser bookmark **HTML export** into sensible,
topic-based folders using the **on-device Foundation Models** LLM bundled with
macOS — no cloud, no Ollama, no external runtime.

This document is the authoritative spec. It is written to be handed to a coding
agent: each milestone has concrete deliverables and acceptance criteria. The
accompanying skeleton already contains a compiling-or-near-compiling scaffold;
items marked **VERIFY** depend on the exact installed SDK and must be confirmed
before being relied upon.

---

## 1. Lineage & what changes

This is the third incarnation of the "lazybookmarks" idea:

1. **Chrome extension (original):** 3-phase pipeline — build a *taxonomy* of
   existing folders, *cluster* uncategorized bookmarks by theme, then *classify*
   each into the best-fit folder — driven by Chrome's Gemini Nano Prompt API with
   JSON-schema structured output.
2. **Nim CLI PR (withdrawn):** same pipeline over Ollama's native `/api/chat`
   with grammar-constrained decoding; SQLite storage; async sliding-window
   concurrency; plus non-LLM `dedup` / `check-links`. Withdrawn explicitly "in
   favor of a different approach (without Ollama)."
3. **This version:** the model moves **in-process** via Apple's
   `FoundationModels`. That deletes the entire runtime/model-management layer and
   all subprocess shelling (`ollama`, `curl`, `xargs`).

Three consequences drive every design decision:

- **In-process model.** `import FoundationModels`; one system model, no catalog.
  The Nim `model-list`/`model-set`/`model-download` commands are **removed**.
- **Guided generation replaces JSON-parse-and-repair.** Annotate a Swift type
  with `@Generable`/`@Guide`, call `respond(to:generating:)`, get a typed value
  back. No tag-stripping, no JSON repair.
- **macOS-arm64 only.** `FoundationModels` requires macOS 26+, Apple Silicon, and
  Apple Intelligence enabled. There is **no Linux/Intel target** — this overrides
  the usual "target Linux/Arm64" default for this project specifically.

## 2. Hard constraints (confirmed)

- **Context window = 4096 tokens, fixed**, shared across instructions + every
  prompt + every response in a `LanguageModelSession`. Recovery from overflow =
  start a new session.
- macOS/iOS **26.4** added `SystemLanguageModel.contextSize` (back-deployed) and
  `tokenCount(for:)` — use them rather than hardcoding 4096.
- The overflow error can fire even below 4096 (e.g. at 4092) because the
  **response** must also fit. Always reserve output headroom (`TokenBudget`).
- The on-device model is a **single shared, serialized resource** — parallel
  sessions buy little. Optimize for correctness + resumability, not throughput.
- Guardrail **refusals** are a normal, recoverable per-item outcome on some OS
  point releases — never let one crash a run.

## 3. Non-goals (v1)

- **`--enrich`** (fetching page `<title>`/meta for untitled bookmarks): deferred.
  Classification uses **title + registrable domain only**.
- **LoRA / adapters:** deferred. System model as-is.
- **Nested taxonomy:** v1 taxonomy is **flat** (single level) to protect the
  4096-token budget. Sub-foldering is a later enhancement.
- **GUI / browser integration:** CLI only; user re-imports the output HTML.

## 4. Stack & layout

- **Language/build:** Swift 6, SwiftPM, `swift build` (no `.xcodeproj`; Zed-friendly).
- **CLI:** `swift-argument-parser`.
- **Storage:** SQLite via **GRDB.swift** (stateful mode only).
- **LLM:** `FoundationModels` (only `RookmarkKit` imports it).
- **No shell-outs anywhere** — link checking uses `URLSession` + structured concurrency.

```
rookmark/
├── Package.swift                         platforms: [.macOS("26.0")]
├── Sources/
│   ├── rookmark/                           CLI only (no domain logic)
│   │   ├── Rookmark.swift                  root command
│   │   └── Commands/{Organize,Doctor,Stubs}.swift
│   └── RookmarkKit/                 testable core
│       ├── Model/Bookmark.swift          Bookmark, ParseResult, Taxonomy
│       ├── Parsing/NetscapeBookmark{Parser,Writer}.swift
│       ├── LLM/{SessionFactory,TokenBudget,Schemas}.swift
│       ├── Pipeline/{TaxonomyBuilder,Classifier,Organizer}.swift
│       ├── Store/Store.swift             GRDB (stub)
│       └── Util/{URLNormalizer,LinkChecker}.swift
└── Tests/RookmarkKitTests/
```

## 5. Data flow

```
HTML export ──▶ NetscapeBookmarkParser ──▶ ParseResult { bookmarks, existingFolders }
                                                   │
                              TaxonomyBuilder ◀─────┘   (Phase 1)
                                   │ Taxonomy (flat)
                                   ▼
              Classifier.classify(bookmarks, taxonomy)  (Phase 3)
                                   │ [Decision]   ← adaptive batches, fresh session each
                                   ▼
              apply onto bookmarks → NetscapeBookmarkWriter ──▶ organized.html
```

Phase 2 (clustering of poorly-fitting bookmarks into *new* proposed folders that
fold back into the taxonomy) is **M6**, layered in after the straight-through
path works.

## 6. The classifier (core algorithm)

Implemented in `Pipeline/Classifier.swift`. Rules:

- **Local ids.** Items are presented to the model as `b0 | title | domain`; the
  long URL never enters the prompt. Map `bN` back to the real `Bookmark.id` after.
- **Fresh session per batch.** Prevents transcript accumulation against 4096.
- **Token-budgeted batches.** Before sending, check `TokenBudget.fits`; the batch
  carries the full taxonomy block (it is prepended every time) + N item lines.
- **Adaptive batching.** On `exceededContextWindowSize` → halve batch, retry. On
  `refusal` with >1 item → drop to size 1 to isolate. A size-1 item that still
  fails → routed to `Unsorted`. **No bookmark is ever silently dropped.**
- **Validation + confidence floor.** Even on the free-string path, the returned
  folder is validated against the allowed set (exact → case/space-insensitive →
  `Unsorted`); assignments below `confidenceFloor` are demoted to `Unsorted`.
- **Concurrency.** `maxConcurrency` defaults to **4** via a sliding-window
  TaskGroup (fixed-size chunks, no cross-chunk adaptive batch resizing).
  Measured (2026-09-20, 200-item corpus): ~10% wall-clock win at
  maxConcurrency=4 vs. 1, no significant precision/yield cost — see
  TODO.txt item 2. `=1` is still exact-equivalent to the old sequential path.

### Classification output: two paths

- **Primary (M3, SDK-stable):** compile-time `@Generable BatchClassification`
  with a free-string `folder`, via `respond(to:generating:)`. Validated in Swift.
  Depends only on documented, stable API.
- **Upgrade (M8, optional):** `ConstrainedClassificationSchema.make(...)` builds a
  runtime `GenerationSchema` constraining `folder` to the exact folder set, making
  invalid folders *structurally impossible*. **VERIFY** the `DynamicGenerationSchema`
  / `GenerationSchema(root:dependencies:)` API and the `GeneratedContent` decode
  calls before switching the classifier over; keep Swift-side validation as
  defense-in-depth regardless.

## 7. Token budgeting

`TokenBudget(total:, outputReserve:)`:

- `total` = `await SessionFactory.contextSize()` (live; falls back to 4096).
- `inputBudget = total − outputReserve` (default reserve **768**).
- `estimate(_:)` is a conservative ~3.5 chars/token heuristic. **VERIFY** and
  replace with `try await SystemLanguageModel.default.tokenCount(for:)` (26.4+),
  keeping the heuristic as the offline fallback.
- Taxonomy size is bounded so the rendered folder block never dominates the
  input budget; `TaxonomyBuilder` caps folder count and may run a merge pass.

## 8. CLI surface

| Command | Status | Behavior |
|---|---|---|
| `organize <in.html> [-o out] [--fresh] [--stateful] [--batch-size N]` | **M4** | The headline path: parse → taxonomy → classify → write HTML. One-shot/in-memory by default. |
| `doctor` | **M2** | Reports `availability()` and `contextSize()`; non-zero exit if unavailable. |
| `import` / `export` / `list` / `search` / `undo` / `status` | **M5** | SQLite-backed: idempotent import, HTML export, inspection, resume, undo. |
| `dedup` | **M7** | `URLNormalizer`-based grouping; exact-normalized (high) + domain+title (medium) tiers; interactive review. |
| `check-links` | **M7** | `LinkChecker`: bounded async HEAD/GET, redirect-follow, status classification. |

Removed vs the Nim port: `model-list`, `model-set`, `model-download` (single
system model). `doctor`/`status` now report Apple-Intelligence/model state, not
an Ollama health check.

## 9. Storage (stateful mode)

GRDB `DatabaseQueue`, WAL. Tables:

- `runs(id, source_path, started_at, taxonomy_json, status)`
- `bookmarks(id PK, run_id, title, url, original_path_json, added_at, assigned_folder, confidence, committed)`
- `snapshots(id, run_id, created_at, payload_json)` — for `undo`
- `link_status(bookmark_id PK, status, checked_at)` — `check-links` cache

Resume: classify in batches; **commit each batch in its own transaction**. A
SIGINT handler cancels the `Task` tree; re-running `organize --stateful` resumes
from the first `committed = 0` bookmark. `undo` restores the latest snapshot.

## 10. Milestones (build order)

- **M0 — Skeleton.** Package builds; `swift build` succeeds. *(scaffold present)*
- **M1 — Parser.** `NetscapeBookmarkParser` + `URLNormalizer` + `BookmarkID`,
  round-tripping real Chrome/Firefox/Safari exports. **AC:** parser tests green;
  nested folders → correct paths; entities decoded; tracking params stripped.
- **M2 — `doctor` + SessionFactory.** Availability gating, `contextSize()`,
  one end-to-end `respond(...)` round trip. **AC:** `doctor` prints availability
  and 4096; a hello-world `@Generable` returns a typed value on-device.
- **M3 — Classifier (primary path).** Adaptive batching, fresh session per batch,
  validation, confidence floor, refusal/overflow handling, no dropped bookmarks.
  **AC:** classify a fixed 50-bookmark fixture against a hardcoded taxonomy;
  100% of items receive a decision; forced overflow shrinks and recovers.
- **M4 — `organize` one-shot.** `TaxonomyBuilder` (`.preserve` + `.fresh`) →
  `Organizer.organize` → `NetscapeBookmarkWriter`. **AC:** real export in →
  importable HTML out; ≥X% non-Unsorted on a hand-labeled sample (set X after
  first measurement; expect tuning).
- **M5 — Persistence.** `Store`, `--stateful`, `import/export/list/search/undo/status`,
  SIGINT-safe resume. **AC:** kill mid-run, re-run, no duplicate work, consistent DB.
- **M6 — Clustering (Phase 2).** Propose folders for poorly-fitting bookmarks;
  fold into taxonomy; optional merge-similar / split-crowded passes.
- **M7 — Cleanup utilities.** `dedup`, `check-links` (native async).
- **M8 — Constrained-decoding upgrade.** Switch classifier to the runtime
  `GenerationSchema` enum path **after** SDK verification.

## 11. Testing

- **Unit (no model):** parser (fixtures from each major browser, including
  malformed/unclosed-tag exports), `URLNormalizer`, writer round-trip,
  `Classifier.validate`, `TokenBudget.fits`.
- **Model-dependent (gated):** skip when `availability() != .available` so CI on
  non-eligible runners stays green; run on a self-hosted Apple-Silicon runner.
- **Golden classification:** a small hand-labeled set; track accuracy across
  prompt/taxonomy tweaks. Treat as a regression signal, not a hard gate.

## 12. CI / distribution

- Single GitHub Actions lane: `macos-26` arm64 → `swift build -c release` +
  `swift test` (model tests gated/skipped unless a self-hosted eligible runner).
- Distribute as a release tarball or a Homebrew tap. No runtime deps to document
  beyond "macOS 26+, Apple Silicon, Apple Intelligence enabled."
- Sign + notarize only if distributing broadly.

## 13. SDK items to VERIFY before relying on them

1. `SystemLanguageModel.default.contextSize` — name + throwing/async shape (26.4+).
2. `SystemLanguageModel.default.tokenCount(for:)` — exact signature.
3. `LanguageModelSession.GenerationError` cases — `.exceededContextWindowSize`,
   `.refusal`, and the catch-all.
4. `respond(to:generating:)` return shape (`.content`).
5. `DynamicGenerationSchema` initializers (`anyOf:`, `type:`, `arrayOf:`,
   `Property`), `GenerationSchema(root:dependencies:)`, and `GeneratedContent`
   decoding — for the M8 upgrade only.
6. `SystemLanguageModel.Availability.UnavailableReason` case names.

## 14. Risks & mitigations

- **Small context dominates design.** A large existing-folder set may not fit in
  the per-batch taxonomy block → cap folder count; consider top-level-first
  taxonomy if users routinely exceed it.
- **Refusal bursts on some OS builds.** Already handled as route-to-Unsorted;
  surface a summary count so users notice if it spikes.
- **Throughput.** On-device + serialized = slow for thousands of bookmarks.
  `--stateful` resume + a clear progress bar make long runs tolerable; set
  expectations in `--help`.
- **Quality on a ~3B model.** Title+domain-only is the floor; `--enrich` and a
  fine-tuned adapter are the known levers, both deliberately deferred.
