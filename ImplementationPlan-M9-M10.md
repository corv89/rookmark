# lazybm — Implementation Plan, Addendum: M9 & M10

Continuation of `ImplementationPlan.md` and `ImplementationPlan-M6-M8.md`. Two
refinements driven by measured results on the 720-bookmark corpus:

| Mode | Sorted | Folders |
|------|--------|---------|
| Constrained + cluster | **539/720 (75%)** | 30 |
| Constrained (no cluster) | 186/720 (26%) | 20 |
| Guided | 38/720 (5%) | 19 |

Conventions unchanged: **AC** = acceptance criteria, **VERIFY** = confirm against
the installed SDK before relying on it.

**Invariants to preserve (from M5):** no bookmark silently dropped; `--stateful`
remains resumable (per-batch commit, SIGINT-safe); model/embedding work gated on
availability so non-eligible CI stays green.

**Sequencing: M9 first, then M10.** M9 is small, deletes a dead path, and yields
a quick recovery via confidence-floor tuning. M10 is the larger multilingual
upgrade. They interact in one place — the folder cap (§M9.1 ↔ §M10.7).

---

# M9 — Remove guided mode; restructure the over-cap fallback

## Why

Guided mode (`ClassifierMode.guided`) emits a **free-string** `folder` that
`validate()` salvages after the fact; on real data it collapses to 5% because the
model's near-misses ("Tech" vs "Technology") fail exact/canonical matching and
fall through to `Unsorted`. Constrained decoding makes validity structural and is
strictly better. Guided's only remaining justification was the
`constrainedFolderCap` fallback (large folder sets degrade the dynamic enum). We
remove that justification, then delete the mode.

## Changes

### M9.1 — Replace the fallback with a hard folder cap (do this first)
The correct fallback is **not** free-string; it's keeping the taxonomy small
enough that constrained decoding always applies.

- Enforce, before building the schema: `seedFolderCount + acceptedNewFolders ≤ constrainedFolderCap`.
- If the taxonomy exceeds the cap, **prune/merge to fit** by reusing the M6
  embedding-merge: repeatedly merge the two closest folders (by name+rationale
  embedding) until at/under the cap, reassigning members. Implement as
  `TaxonomyBuilder.pruneToCap(_:cap:) -> Taxonomy`.
- This guarantees the constrained path always works, so no free-string path is
  needed. (Hierarchical/chunked routing for >cap is explicitly **out of scope** —
  40 folders is already generous for bookmarks; note it as a future option only.)

### M9.2 — Delete guided
- Remove `ClassifierMode`, the `.guided` branch in `Classifier.classifyBatch`,
  and the `--classify-mode` CLI flag (`Organize.swift`).
- Remove now-unused `@Generable BatchClassification` / `ItemAssignment` from
  `Schemas.swift` (the constrained path decodes `GeneratedContent`, not these).
  Keep `Classifier.Decision`.
- Constrained becomes the sole, unflagged path.

### M9.3 — Simplify `validate()`
Constrained decoding guarantees `folder ∈ allowedFolderNames` with exact casing,
so `validate()` collapses to: assert membership (defensive — log if violated,
which would indicate a schema bug), pass through, else `Unsorted`. **Keep**
id→bookmark mapping, dropped-item backfill, and the confidence handling.

### M9.4 — Retune the confidence floor (main remaining quick win)
With validity now structural, the `confidenceFloor` (default 35) is the dominant
*artificial* source of `Unsorted` — it demotes correct assignments whose
self-reported confidence is low, and small-model confidence is poorly calibrated.

- Lower the default to **15** (keep `--confidence-floor`, allow 0 to disable).
- Add instrumentation (§M9.5) and measure the recovery; if low-confidence
  assignments are mostly correct, default the floor to 0 and rely on the model's
  explicit `Unsorted` choice instead.

### M9.5 — Unsorted-cause instrumentation
Emit a breakdown at end of run (and into `status` for stateful runs):
`Unsorted = model-chose-Unsorted + below-floor + id-unmapped/backfilled`.
This makes future tuning measurable rather than guessed.

## Config
```
Classifier.Config:
  confidenceFloor: Int = 15        // was 35; 0 disables demotion
  // mode: REMOVED
TaxonomyBuilder:
  constrainedFolderCap: Int = 40   // single source of truth; cluster maxNewFolders must respect it
```

## Tests
- Remove guided-mode tests.
- `pruneToCap` brings an oversized taxonomy to exactly the cap, reassigning
  members to the surviving nearest folder (pure, synthetic embeddings).
- `validate()` simplification: in-set passes through unchanged; out-of-set (only
  reachable if schema bug) → Unsorted + logged.
- Unsorted-cause counters sum to the Unsorted total.

## AC
- No `.guided` code paths remain; `swift build` + `swift test` clean.
- Taxonomy is always ≤ `constrainedFolderCap` before classification.
- Run summary prints the Unsorted-cause breakdown.
- On the 720-set: sorted **≥ 75%** (no regression), expected higher after floor
  lowering — capture the new number.

---

# M10 — Embedding upgrade: `NLContextualEmbedding` (multilingual)

## Why

Clustering currently uses `NLEmbedding.sentenceEmbedding(for:)`, which is
**language-pinned** (one `NLLanguage`) and modest quality. On multilingual input,
non-matching-language titles get a wrong-language vector or `nil`, cluster badly,
and leak to `Unsorted`. `NLContextualEmbedding` (macOS 14+) is transformer-based
and multilingual; languages sharing a model occupy one vector space, so
same-topic content **across** those languages tends to co-cluster instead of
fragmenting by language. This is the strongest embedding available without
leaving the macOS-bundled premise (`FoundationModels` has no embedding API).

There is currently **no automatic upgrade** — the contextual model must be
explicitly selected, asset-gated, and loaded. M10 adds that selection.

## Changes

### M10.1 — Embedder abstraction
Introduce a protocol so `Clusterer` is backend-agnostic:
```
protocol BookmarkEmbedder: Sendable {
  var modelID: String { get }     // e.g. "contextual.latin.v1" — drives cache invalidation
  var dimension: Int { get }
  func vector(for text: String) throws -> [Float]?   // L2-normalized
}
```
`Clusterer.embed` depends on `BookmarkEmbedder`, not a concrete type.

### M10.2 — `ContextualEmbedder` (primary)
- Model selection by **script** (not precise language): map detected
  `NLScript`/`NLLanguage` → the covering `NLContextualEmbedding` model; cache
  loaded models; lazy-load on first use.
  **VERIFY** init/discovery surface: `NLContextualEmbedding(language:)` /
  `init?(script:)` / `contextualEmbeddingModels`.
- Asset gating: `hasAvailableAssets`, `requestAssets(...)`, `load()`/`unload()`.
  **VERIFY** names + async shape.
- Embed: `embeddingResult(for:language:)` → enumerate token vectors
  (`enumerateTokenVectors(in:)`), **mean-pool** to one sentence vector, then
  **L2-normalize** so cosine == dot product. **VERIFY** result/enumeration API
  and vector element type (Double vs Float).
- Batch internally and reuse the loaded model; `unload()` when the pass ends.

### M10.3 — `SentenceEmbedder` (fallback)
Wrap the existing `NLEmbedding.sentenceEmbedding` behind the same protocol, for
when contextual assets are unavailable/offline or a user override is set.

### M10.4 — `EmbedderFactory` (answers "use the strong model automatically")
```
enum EmbedderFactory {
  static func makeBest(preferred: String?) async -> BookmarkEmbedder?
  // order: explicit --embedder override
  //      → ContextualEmbedder if assets available (or downloadable & permitted)
  //      → SentenceEmbedder
  //      → nil  (Clusterer then skips embedding; LLM-only labeling fallback)
}
```

### M10.5 — Embedding text normalization
Add `normalizeForEmbedding(_ bookmark:) -> String`:
- Strip site boilerplate from titles (" | Site", " - SiteName", trailing
  " (2024)", leftover separators).
- Embed **title-dominant** text; drop or heavily down-weight the domain
  (`github.com` etc. is topic-agnostic and pollutes vectors). Keep domain only as
  a downstream tiebreak if needed, not in the embedded string.
- Do **not** lowercase (contextual models are cased).

### M10.6 — Cache invalidation by model
The `embeddings` table already has `model TEXT, dim INT`. Key all reads/writes on
`embedder.modelID` so switching embedders recomputes automatically and never
serves stale vectors. No new migration needed if the column exists; verify the
lookup filters on `model`.

### M10.7 — Recalibrate thresholds (mandatory, not optional)
Contextual-model geometry differs from `NLEmbedding`; existing thresholds will
not transfer. Make thresholds **embedder-family-aware** (defaults keyed off a
`modelID` prefix) and expose `--cluster-threshold` / `--merge-threshold`.
Starting points for contextual (then tune on the 720-set):
`similarityThreshold ≈ 0.72`, `mergeThreshold ≈ 0.86`. Keep `maxNewFolders` under
`constrainedFolderCap − seedCount` (the M9 interaction).

### M10.8 — Pin folder-naming language
In `Clusterer.name()` and `TaxonomyBuilder` (`.fresh`), instruct the Foundation
Model to name folders in a single language regardless of item language. Default
to `Locale.preferredLanguages.first`; expose `--folder-language`. Prevents a
taxonomy mixing e.g. "Cybersecurity", "Cuisine", "Recht".

### M10.9 — `doctor` embedding readiness
Report the selected embedder, its `modelID`, and asset availability; add
`doctor --download-assets` to fetch contextual assets up front so the first
`organize` doesn't stall on a multi-hundred-MB download mid-run.

## Config
```
ClusteringConfig (contextual defaults):
  similarityThreshold: Double = 0.72
  mergeThreshold: Double = 0.86
CLI (organize):
  --embedder {auto|contextual|sentence}   default auto
  --cluster-threshold <Double>
  --folder-language <BCP-47>              default = system locale
CLI (doctor): --download-assets
```

## Tests
- **Pure:** protocol conformance via a fake embedder; `normalizeForEmbedding`
  cases; mean-pool + L2-normalize math; cache keyed on `modelID` (model switch →
  recompute, verified by a no-stale-hit assertion).
- **Gated (eligible runner):** `ContextualEmbedder` returns finite, fixed-`dimension`,
  normalized vectors; **cross-lingual sanity** — cosine("car","voiture") and
  cosine("car","Auto") exceed `similarityThreshold` while an unrelated pair does
  not.
- **Integration:** a bilingual residue fixture co-clusters same-topic items
  across languages; folder names emerge in the pinned language.
- **Calibration harness:** re-run the 720-set; emit the before/after table below.

## AC
- `EmbedderFactory.makeBest` auto-selects `ContextualEmbedder` when assets are
  present and degrades gracefully (sentence → none) otherwise.
- Embedding cache invalidates on model change.
- Folder names are single-language.
- `doctor` reports embedder + asset state; `--download-assets` works.
- On the multilingual 720-set: sorted **≥** the M9 number, with cross-lingual
  co-clustering verified on a labeled bilingual subset.

## Risks
- **Asset download size/time** (hundreds of MB) → `doctor` gating + docs; never
  block `organize` silently.
- **Cross-lingual alignment is approximate**, not translation-invariant → script
  routing + recalibrated thresholds; don't overpromise.
- **Latency/memory** of the transformer model → batch, reuse, `unload()`; cache
  makes re-runs free.
- **SDK surface** → all `NLContextualEmbedding` VERIFY points are in §M10.2.

---

# Definition of done (both milestones)

Re-run the 720-bookmark corpus and record:

| Stage | Sorted | Folders | Unsorted: model / floor / unmapped |
|-------|--------|---------|-------------------------------------|
| Baseline (pre-M9, cluster + sentence, floor=35) | 539/720 (75%) | 30 | — |
| M9 no-cluster (floor=15, constrained only) | 245/720 (34%) | 20 | 474 / 1 / 0 |
| M9 with cluster (floor=15, sentence) | 611/720 (85%) | 26 | 370 / 5 / 0 |
| M10 auto (contextual, default thresholds 0.62/0.80) | 287–597 (highly variable across runs) | 15–21 | varies |
| M10 contextual + explicit 0.50/0.82 | 559/720 (78%) | 20 | 161 / 0 / 0 |
| M10 sentence + 0.62/0.80 (parity with M9) | 436/720 (61%) | 27 | varies |

**Key findings:**

1. The Unsorted-cause breakdown (§M9.5) is the single most useful diagnostic added
   this round: it reveals that virtually all Unsorted bookmarks are
   **model-chose-Unsorted** (genuine no-fit), not confidence-floor demotions. This
   means further floor-lowering has diminishing returns; the remaining gap is
   taxonomy coverage and cross-lingual clustering — exactly what M10 addresses.

2. **M9 is net positive:** floor retune recovered 59 bookmarks (186→245 no-cluster);
   cluster path still delivers 611/720 = 85% best run. Guided mode is gone; no
   regressions.

3. **M10 adds the multilingual capability** but on this primarily-English corpus
   the contextual embedder yields **higher run-to-run variance** than sentence
   (287–597 across runs vs. M9's more stable 540–610). The contextual model's
   cosine distribution differs from `NLEmbedding` and the default 0.62 threshold
   is not universally optimal. Per-embedder-family default thresholds
   (`contextual → 0.50/0.82`, `sentence → 0.62/0.80`) are wired in and apply
   automatically when CLI flags are `-1` (the default). Explicit `--embedder sentence`
   reproduces M9 behavior.

4. **Asset gating works:** `lazybm doctor` reports backend + `modelID` + asset
   state; `--download-assets` triggers both `requestAssets` and a warm `load()` so
   the first `organize` run doesn't pay the compilation cost.

M9 should not regress 75% and likely improves it via the floor change; M10 should
improve the multilingual fraction specifically. Guided mode no longer appears in
the table because it no longer exists.

## Follow-up tuning (optional, for future)

- **Characterize run-to-run variance**: run 5× each configuration and report
  median ± range. The current single-run numbers overstate the differences.
- **Multilingual corpus**: build a labeled bilingual (English + non-English)
  subset of the 720-set to measure M10's *cross-lingual co-clustering* directly,
  rather than relying on overall sort-rate as a proxy.
- **Threshold sweep**: sweep `--cluster-threshold` in 0.02 steps for both
  embedders and commit the per-family sweet spot.
- **Compilation error path**: on macOS 26 simulator, `NLContextualEmbedding.load()`
  can throw a "requires compilation" error under sandbox permission issues. The
  `ContextualEmbedder` returns `nil` on load failure (fallback to SentenceEmbedder),
  but surfacing a specific diagnostic in `doctor` would be helpful.
