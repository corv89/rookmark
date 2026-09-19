# lazybm — Implementation Plan: M9–M11 (Refinement & Hardening)

Self-contained handoff for a coding agent. Supersedes
`ImplementationPlan-M9-M10.md`. Builds on the merged base (M0–M8, plus M6
clustering and M7 utilities). Conventions: **AC** = acceptance criteria,
**VERIFY** = confirm against the installed SDK before relying on it.

## Current state

- macOS-arm64-only CLI; on-device `FoundationModels` LLM, in-process.
- Pipeline: parse (Netscape HTML) → taxonomy → classify (constrained decoding) →
  cluster residue → re-classify → write HTML. SQLite/GRDB for `--stateful`.
- Measured baseline on the 720-bookmark corpus: **539/720 sorted (75%), 30
  folders** with constrained + cluster. Guided mode managed 5% and is being
  removed.

## Global invariants (must not regress)

- No bookmark is ever silently dropped — every input gets a decision.
- `--stateful` stays resumable: per-batch commit, SIGINT-safe.
- Model/embedding work is gated on availability so non-eligible CI stays green.

## Build & measurement order

**M11 → M9 → M10 (opt-in).** Implement determinism first: until variance is
controlled, every other delta is noise. Then M9 (the floor retune needs the M11
instrumentation *and* a stable baseline to be interpretable). M10's contextual
embedder is optional and can come last or be skipped.

---

# M11 — Determinism & variance control

## Why

Run-to-run results vary substantially on identical input, which makes
regressions indistinguishable from noise and invalidates before/after tables. The
variance is mostly designed-in and removable; the goal is to drive it from "high"
to "negligible and measured."

## Sources, in impact order

1. **LLM sampling (dominant).** `respond(...)` samples at non-zero temperature by
   default, so classification, taxonomy generation, cluster naming, and merge all
   differ every run.
2. **Cascade amplification.** The pipeline is sequential; one nondeterministic
   folder name ("Dev Tools" vs "Developer Tools") changes the allowed-folder set
   and shifts every downstream assignment. Small noise compounds.
3. **Input ordering.** Greedy clustering seeds clusters in input order, and batch
   composition depends on order; unstable ordering → different clusters and
   different batch-mates (which bias the model).
4. **Floor boundary flips.** Items near `confidenceFloor` flip in/out of
   `Unsorted` purely from (1).
5. **Residual ANE nondeterminism.** Even greedy on-device decoding isn't always
   bit-identical — the irreducible floor after the above are fixed.

## Changes

### M11.1 — Greedy decoding everywhere (biggest lever)
Pass deterministic `GenerationOptions` (temperature 0 / greedy sampling) to
**every** `respond(...)` call — classification, `TaxonomyBuilder` (`.fresh`),
`Clusterer.name()`, and any LLM merge. Centralize the options in `SessionFactory`
so no call site can forget. **VERIFY** the exact field
(`temperature: 0` and/or `sampling: .greedy`). *This gates the whole milestone.*

### M11.2 — Deterministic input ordering
Sort bookmarks by stable `id` before batching (classification) and before greedy
clustering. Make adaptive-batch shrink decisions a pure function of (ordered
input, token estimate) so identical input yields identical batch boundaries.

### M11.3 — Pin the taxonomy across stateful/resumed runs
In `--stateful`, once a run's `taxonomy_json` is committed, **reuse** it on resume
instead of regenerating — removes the cascade (source 2) for re-runs. Add
`--reuse-taxonomy <runID>` / `--taxonomy-from <path>` so a one-shot run can pin a
known-good taxonomy and isolate classification variance.

### M11.4 — Variance harness
Dev command `lazybm eval --runs N <input.html>` (default N = 5, gated on
availability): runs the corpus N times and reports mean ± stddev (and min/max) of
sort rate, folder count, and the Unsorted-cause split. Run before/after
M11.1–M11.3 to confirm the collapse and quantify the residual ANE floor.

## Config
```
SessionFactory: deterministic GenerationOptions by default (temp 0 / greedy)
CLI (organize):  --reuse-taxonomy <runID> | --taxonomy-from <path>
dev:             lazybm eval --runs N <input.html>
```

## Tests
- **Pure:** ordering is stable (same input → identical batch boundaries &
  cluster-seed order); adaptive-shrink is a pure function of its inputs.
- **Gated:** two consecutive greedy runs on a small fixture produce identical
  decisions (allow a documented ANE tolerance if source 5 proves nonzero).
- **Harness:** sort-rate stddev drops markedly after M11.1–M11.3; record the
  before/after spread.

## AC
- All LLM calls draw greedy/temperature-0 options from a single source.
- Identical input + pinned taxonomy → reproducible classification within a
  documented ANE tolerance.
- `eval --runs N` reports the variance distribution; post-M11 stddev is small
  enough that M9/M10 deltas are interpretable.

---

# M9 — Remove guided mode; restructure the over-cap fallback

## Why

Guided mode emits a free-string `folder` that `validate()` salvages after the
fact; on real data it collapses to ~5% because near-misses ("Tech" vs
"Technology") fail exact/canonical matching and fall to `Unsorted`. Constrained
decoding makes validity structural and is strictly better. Guided's only
remaining role was the over-cap fallback; we remove that role, then delete it.

## Changes

### M9.1 — Replace the fallback with a hard folder cap (do first)
The correct fallback is keeping the taxonomy small enough that constrained
decoding always applies — not free-string.

- Enforce before building the schema:
  `seedFolderCount + acceptedNewFolders ≤ constrainedFolderCap` (default **40**).
- If exceeded, **prune/merge to fit** via the M6 embedding-merge primitive with a
  **count target** instead of a similarity threshold: repeatedly merge the two
  closest folders (by name+rationale embedding) until at/under the cap; the
  **larger** folder's name survives and members reassign. Implement as
  `TaxonomyBuilder.pruneToCap(_:cap:) -> Taxonomy`. Do **not** use
  alphabetical/size-only heuristics — they merge unrelated topics.
- **Dissimilar-pair guard:** if the closest remaining pair is below
  `mergeThreshold`, the taxonomy genuinely holds cap-plus distinct topics — drop
  the **smallest** folder and route its members to the nearest surviving folder
  (≥ `similarityThreshold`, else `Unsorted`) rather than force-merge unrelated
  folders. Rare safety valve; M10.7's cap normally prevents it firing.

### M9.2 — Delete guided
- Remove `ClassifierMode`, the `.guided` branch in `Classifier.classifyBatch`,
  and the `--classify-mode` flag.
- Remove the now-unused `@Generable BatchClassification` / `ItemAssignment` (the
  constrained path decodes `GeneratedContent`). Keep `Classifier.Decision`.
- Constrained becomes the sole, unflagged classification path.

### M9.3 — Simplify `validate()`
Constrained decoding guarantees `folder ∈ allowedFolderNames` with exact casing,
so `validate()` collapses to a membership assert (log if violated — that would
indicate a schema bug), pass-through, else `Unsorted`. **Keep** id→bookmark
mapping, dropped-item backfill, and confidence handling.

### M9.4 — Retune the confidence floor
With validity structural, `confidenceFloor` (default 35) is now the dominant
*artificial* `Unsorted` source, and small-model self-confidence is poorly
calibrated. Lower the default to **15** (keep `--confidence-floor`; 0 disables).
Measure with M9.5; if low-confidence assignments are mostly correct, default to 0
and rely on the model's explicit `Unsorted` choice.

### M9.5 — Unsorted-cause instrumentation
Compute `Unsorted = model-chose-Unsorted + below-floor + id-unmapped/backfilled`.
**Always** print it to stderr at end of run. For `--stateful`, persist it into a
new `runs.summary_json` column (no new table) so `status` can display it and runs
are comparable.

## Config
```
Classifier.Config:  confidenceFloor: Int = 15   // was 35; 0 disables; mode REMOVED
TaxonomyBuilder:    constrainedFolderCap: Int = 40   // single source of truth
```

## Tests
- Remove guided-mode tests.
- `pruneToCap` brings an oversized taxonomy to exactly the cap, reassigning
  members to the surviving nearest folder; the dissimilar-pair guard drops the
  smallest instead of force-merging (pure, synthetic embeddings).
- `validate()`: in-set passes through; out-of-set (schema-bug only) → Unsorted +
  logged.
- Unsorted-cause counters sum to the Unsorted total.

## AC
- No `.guided` code paths remain; `swift build` + `swift test` clean.
- Taxonomy is always ≤ `constrainedFolderCap` before classification.
- Run summary prints the Unsorted-cause breakdown; `status` shows it for stateful.
- On the 720-set (under M11 determinism): sorted **≥ 75%**, expected higher after
  the floor change — capture mean ± stddev.

---

# M10 — Embedder abstraction (sentence default, contextual opt-in)

## Decision

On this corpus `NLEmbedding.sentenceEmbedding` produced a **higher** sort rate
than `NLContextualEmbedding`. Bookmark titles are very short (2–6 words), which
neutralizes the contextual transformer's advantage while its downsides
(mean-pooling few subword vectors, special-token noise) can hurt; the multilingual
fraction is too small to move the aggregate. Therefore **`SentenceEmbedder` is the
default and `ContextualEmbedder` is opt-in** (`--embedder contextual`) for
heavily-multilingual libraries. M10's lasting core is the `BookmarkEmbedder`
abstraction; the contextual machinery (§M10.3, §M10.7, §M10.9) runs only when
explicitly selected.

## Changes

### M10.1 — `BookmarkEmbedder` protocol
```
protocol BookmarkEmbedder: Sendable {
  var modelID: String { get }     // drives cache invalidation, e.g. "sentence.en.v1"
  var dimension: Int { get }
  func vector(for text: String) throws -> [Float]?   // L2-normalized
}
```
`Clusterer` depends on the protocol, not a concrete type.

### M10.2 — `SentenceEmbedder` (default)
Wrap `NLEmbedding.sentenceEmbedding` behind the protocol. Fastest, no assets, no
compilation, and the measured winner on short titles. `modelID = "sentence.<lang>.v1"`.

### M10.3 — `ContextualEmbedder` (opt-in)
Current on macOS 26: `NLContextualEmbedding` is the bundled contextual API (no
newer one; `FoundationModels` has none). BERT-based, **512-dim**, input cap **256
tokens**, returns **per-token** vectors.
- Init **by script** (`NLContextualEmbedding(script:)`, e.g. the multilingual
  Latin model `mul_Latn`) for broad coverage; cache loaded models; lazy-load.
  **VERIFY** init/discovery surface.
- Assets: `hasAvailableAssets`, `requestAssets(...)`, `load()`/`unload()`. First
  `load()` triggers on-device **compilation** (cached under
  `/var/db/com.apple.naturallanguaged/…`), not only a download — warm it in
  `doctor` (§M10.9). **VERIFY** names + async shape.
- Embed: `embeddingResult(for:language:)` → enumerate token vectors → **mean-pool**
  to one 512-dim vector (Accelerate/vDSP) → **L2-normalize**. API element type is
  `Double`; store `Float` in cache. Truncate input ≤ 256 tokens defensively.
  **VERIFY** result/enumeration API.
- Batch internally, reuse the loaded model, `unload()` at pass end.
- Catch `load()` failure cleanly: surface in `doctor`, do not abort a run.

### M10.4 — `EmbedderFactory`
```
enum EmbedderFactory {
  static func make(preferred: String) async -> BookmarkEmbedder?
  // "sentence" (DEFAULT) → SentenceEmbedder
  // "contextual"         → ContextualEmbedder if assets ready,
  //                        else fail fast: "run lazybm doctor --download-assets"
}
```
No silent auto-upgrade to contextual — it is opt-in only.

### M10.5 — Embedding text normalization
`normalizeForEmbedding(_ bookmark:) -> String`: strip title boilerplate
(" | Site", " - SiteName", trailing " (2024)"); embed **title-dominant** text and
drop/down-weight the topic-agnostic domain; do **not** lowercase.

### M10.6 — Cache invalidation by model
The `embeddings` table has `model TEXT, dim INT`. Key all reads/writes on
`embedder.modelID` so switching embedders recomputes automatically and never
serves stale vectors. Verify the lookup filters on `model`.

### M10.7 — Thresholds (contextual only)
The sentence default keeps its tuned thresholds. For contextual, geometry differs,
so ship **static per-model-family defaults** selected by `modelID` prefix (a
hand-tuned lookup, e.g. `contextual.latin → 0.72`) — not runtime auto-computation.
Override via `--cluster-threshold` / `--merge-threshold`. Contextual starting
points (commit from calibration): `similarityThreshold ≈ 0.72`,
`mergeThreshold ≈ 0.86`. Keep `maxNewFolders ≤ constrainedFolderCap − seedCount`.

### M10.8 — Pin folder-naming language
In `Clusterer.name()` and `TaxonomyBuilder` (`.fresh`), instruct the model to name
folders in a single language regardless of item language. Default
`Locale.preferredLanguages.first`; expose `--folder-language`. Prevents a taxonomy
mixing "Cybersecurity", "Cuisine", "Recht".

### M10.9 — `doctor` embedding readiness (contextual only)
Report the selected embedder and `modelID`. `doctor --download-assets` is a
**blocking** command that triggers **both** `requestAssets` and a `load()` (to
force first-run compilation) so `organize` never pays it mid-run; show an
indeterminate "preparing embedding model…" heartbeat (no percentage unless a
`Progress` is exposed). With `--embedder contextual`, `organize` **fails fast**
("run `lazybm doctor --download-assets`") when assets/compilation aren't ready.

## Config
```
CLI (organize):  --embedder {sentence|contextual}   default sentence
                 --cluster-threshold <Double>
                 --merge-threshold <Double>
                 --folder-language <BCP-47>          default = system locale
CLI (doctor):    --download-assets                   (contextual only)
```

## Tests
- **Pure:** protocol conformance via a fake embedder; `normalizeForEmbedding`
  cases; mean-pool + L2-normalize math; cache keyed on `modelID` (model switch →
  recompute, no-stale-hit assertion).
- **Gated (contextual):** returns finite, fixed-`dimension`, normalized vectors;
  cross-lingual sanity — cosine("car","voiture"), cosine("car","Auto") exceed the
  threshold while an unrelated pair does not.
- **Integration (contextual):** a bilingual residue fixture co-clusters same-topic
  items across languages; folder names emerge in the pinned language.

## AC
- Default `organize` uses `SentenceEmbedder`; `--embedder contextual` switches
  backends and fails fast when assets aren't ready.
- Embedding cache invalidates on model change.
- Folder names are single-language.
- `doctor` reports the selected embedder; `--download-assets` works for contextual.

---

# Definition of done

Re-run the 720-bookmark corpus and record **mean ± stddev** over ≥ 5 runs:

| Stage | Sorted | Folders | Unsorted: model / floor / unmapped |
|-------|--------|---------|-------------------------------------|
| Baseline (current) | 539/720 (75%) | 30 | — |
| After M11 (greedy + ordering) | _measure mean±sd_ | _≤cap_ | _measure_ |
| After M9 (floor retune) | _measure_ | _≤cap_ | _measure_ |
| (opt-in) M10 contextual | _measure_ | _≤cap_ | _measure_ |

Measure M11 first — until variance is controlled every other delta is noise.
Default embedder is `SentenceEmbedder`; contextual is opt-in. Guided mode no
longer appears — it no longer exists.

---

# Consolidated VERIFY checklist

1. `GenerationOptions` greedy/temperature field (M11.1) — gates determinism.
2. `NLContextualEmbedding` surface (M10.3), **only if contextual is built**:
   script/language init, `hasAvailableAssets` / `requestAssets` / `load` /
   `unload`, `embeddingResult` + token-vector enumeration, vector element type.
3. (Already verified in M2: `DynamicGenerationSchema` / constrained decoding,
   `SystemLanguageModel.contextSize` / `tokenCount(for:)`.)

# Consolidated CLI surface (after M9–M11)

```
lazybm organize <in.html> [-o out]
        [--fresh] [--stateful] [--batch-size N]
        [--confidence-floor N]                 # M9.4 (default 15)
        [--embedder {sentence|contextual}]     # M10  (default sentence)
        [--cluster-threshold D] [--merge-threshold D]   # M10.7
        [--folder-language BCP-47]             # M10.8
        [--reuse-taxonomy <runID> | --taxonomy-from <path>]   # M11.3
lazybm doctor [--download-assets]              # M10.9 (contextual only)
lazybm eval --runs N <in.html>                 # M11.4 (dev/variance harness)
lazybm import|export|list|search|undo|status|dedup|check-links   # existing
```
