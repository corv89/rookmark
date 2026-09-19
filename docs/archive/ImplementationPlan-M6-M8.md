# rookmark — Implementation Plan, Addendum: M6 & M8

Continuation of `ImplementationPlan.md`. Covers the two deferred milestones now
that M0–M5 + M7 are merged (`swift build` clean, 46 tests green). Same
conventions: **AC** = acceptance criteria, **VERIFY** = confirm against the
installed SDK before relying on it.

**Global invariants both milestones must preserve (from M5):**
- No bookmark is ever silently dropped — every input gets a decision.
- `--stateful` runs remain resumable: per-batch commit, SIGINT-safe.
- Non-eligible CI stays green: model/embedding work is gated on
  `availability()`.

**Recommended sequencing: M8 first, then M6.** M8 is small, the schema API is
already verified (M2), and it's an immediate correctness win. M6 is the larger
feature and enlarges the taxonomy, which is the one place the two interact
(see §M6.8).

---

# M8 — Constrained-decoding upgrade (`DynamicGenerationSchema`)

## Goal

Make an invalid folder name **structurally impossible** by constraining the
classifier's `folder` field to the exact allowed set at decode time, instead of
relying on post-hoc Swift validation to catch invented folders.

## What changes (and what deliberately doesn't)

- **Construct the schema once per classification *pass*, not per batch.** The
  taxonomy is fixed within a pass, so build the `GenerationSchema` once, cache it,
  and pass it into every batch. Rebuild only when the taxonomy changes — i.e.
  after M6 augments it (there are then two passes: 3a pre-cluster, 3b post-cluster,
  each with its own schema).
- **Keep the folder block in the prompt.** Constrained decoding guarantees the
  output is a *valid* folder name; it conveys nothing about what each folder
  *means*. The `name: rationale` lines still drive the model's choice and must
  stay. (Minor win: the "choose exactly one from the list / don't invent folders"
  instruction text can be trimmed since validity is now enforced — small token
  saving, optional.)
- **Keep the Swift guard as defense-in-depth.** Validity is now structural, but
  M3's other guarantees still run: id→bookmark mapping, confidence floor →
  Unsorted demotion, and backfilling any item the model omitted. `validate()`
  collapses to: confirm membership (cheap), return the canonically-cased
  taxonomy name (enum cases are already exact strings, so casing is exact),
  Unsorted otherwise.

## Implementation

1. **Schema builder** — finish `ConstrainedClassificationSchema.make(allowedFolders:)`
   in `LLM/Schemas.swift` using the **verified** `DynamicGenerationSchema` shape
   from M2 (replace the scaffold's VERIFY-marked guesses). Fields: `id: String`,
   `folder` = string enum over `taxonomy.allowedFolderNames`, `confidence: Int`
   (range 0–100), wrapped in an `assignments` array.
2. **Sanitize folder names before they become enum cases.** Enforce in
   `TaxonomyBuilder`: Title Case, trim, collapse whitespace, strip characters
   that are awkward as schema enum values. Reject/rename empties. Names are the
   join key between schema, prompt, and writer — keep them clean and unique.
3. **Classifier mode flag.** Add `Classifier.Config.mode: ClassifierMode`
   (`.guided` = current free-string path, `.constrained` = schema path). In
   `classifyBatch`, branch:
   - `.constrained`: `try await session.respond(to: prompt, schema: schema)` →
     decode `GeneratedContent` into `[Decision]`. **VERIFY** the `respond(to:schema:)`
     return type and the `GeneratedContent` decode calls (M2 notes apply).
   - `.guided`: unchanged `respond(to:generating: BatchClassification.self)`.
4. **Auto-fallback.** If schema construction throws, or
   `allowedFolders.count > constrainedFolderCap` (default **40** — large enums can
   degrade decode quality/latency), fall back to `.guided` for that pass and log
   it. This bounds the M6 interaction.
5. **Error handling unchanged.** `exceededContextWindowSize` → shrink+retry,
   `refusal` → isolate → Unsorted. Constrained decoding has been observed to
   shift refusal rates on some OS point releases, so the existing handling stays
   and the run summary should surface refusal counts.

## Config

```
ClassifierMode { case guided, constrained }
Classifier.Config:
  mode: ClassifierMode = .constrained
  constrainedFolderCap: Int = 40
```
CLI: `--classify-mode {constrained|guided}` on `organize` (default constrained),
plus the existing `--batch-size`.

## Tests

- **Pure (no model):** `ConstrainedClassificationSchema.make` succeeds for a
  representative folder set and throws/handles cleanly on empty/duplicate names;
  the cap triggers fallback. Sanitizer maps messy names to valid enum cases.
- **Gated (eligible runner):** decode round-trip — assert the returned folder is
  **always** ∈ `allowedFolderNames` across a fixture batch; confirm confidence
  stays in range.
- **Golden A/B:** run the labeled set under `.guided` vs `.constrained`; record
  invalid-folder rate (expect → 0 under constrained), accuracy delta, and latency
  delta. Promote `.constrained` to default only if accuracy holds and latency is
  acceptable.

## AC

- Across the golden set, `.constrained` produces **zero** out-of-taxonomy folder
  names without relying on Swift validation.
- No regression in dropped-item or resume behavior.
- Fallback to `.guided` is automatic and logged when schema build fails or the
  cap is exceeded.

## Risks

- **Decode quality/latency at large enum sizes** → the cap + fallback.
- **Refusal shifts** → existing handling + visible summary counts.
- **SDK decode API drift** → all VERIFY points centralized in this section.

---

# M6 — Clustering / Phase 2 (propose new folders)

## Goal

For bookmarks that fit no existing folder well, discover natural topic groups and
propose **new** folders, so the taxonomy adapts to the user's actual collection
instead of forcing everything into a seed taxonomy or `Unsorted`.

## Core decision: embeddings group, the LLM only names

The original extension clustered *with the LLM*, which fights the 4 096-token
window. Because we're on macOS, the **`NaturalLanguage`** framework is bundled
right next to `FoundationModels`. Use it:

1. **Embed** each residue bookmark (`title + " " + domain`) into a vector with
   `NLEmbedding.sentenceEmbedding(for:)` — one call per item, no context limit.
2. **Cluster** the vectors with cosine similarity (off-model, deterministic).
3. **Name** each cluster with the LLM on a tiny representative sample.

This keeps the expensive/quadratic grouping entirely off the on-device model and
reserves the model for what it's good at (labeling). **VERIFY** sentence-embedding
availability for the user's language; fall back to averaged word vectors, and
ultimately to LLM-only labeling, if `sentenceEmbedding(for:)` returns nil.
(`NLContextualEmbedding`, macOS 14+, transformer-based and multilingual, is the
higher-quality upgrade — note for v2; it requires asset load + mean-pooling
token vectors, so it's heavier.)

## Pipeline placement: cluster the residue, not everything

Run after a first classification pass; cluster only the `Unsorted` residue:

```
Phase 1   TaxonomyBuilder            → seed taxonomy
Phase 3a  Classifier.classify(all)   → decisions; residue = Unsorted set
Phase 2   ── if residue ≥ minResidue ──
            embed(residue) → cluster → name → merge → accept (size ≥ minClusterSize)
            augment taxonomy with accepted folders
Phase 3b  Classifier.classify(residue, augmentedTaxonomy)   ← re-sort residue only
          apply
```

Re-classifying **only the residue** (not the whole library) avoids churn and
cost. Items still unplaced after 3b stay `Unsorted`. If residue is empty or
below `minResidue`, skip Phase 2 entirely.

**Bonus `.fresh` unification (optional):** a `--taxonomy cluster` mode where the
taxonomy *is* the result of clustering **all** bookmarks and naming the clusters —
a data-driven alternative to M4's LLM-sampled `.fresh` taxonomy. Same machinery,
different input set (all vs residue) and no pre-pass.

## Clustering algorithm

Greedy online clustering by cosine similarity (no dependency, near-deterministic
given a stable input order):

- Sort residue by id for reproducibility.
- For each item vector `v`: find the existing centroid with max cosine sim; if
  `sim ≥ similarityThreshold` assign and update centroid (running mean), else
  start a new cluster.
- After the pass, drop clusters with `size < minClusterSize` (their members
  remain `Unsorted` — we don't propose folders for 2–3 strays).

Cosine sim is computed directly over the vectors (`dot / (‖a‖‖b‖)`); no matrix
library needed. Agglomerative-with-threshold is an acceptable alternative but
O(n²) memory — greedy is fine and scales to large libraries.

## Naming & merging

- **Name** each surviving cluster: send up to `namingSampleSize` (default 8)
  items nearest the centroid as `title | domain`, plus the **existing** folder
  names, and ask for a *new, non-duplicate* folder via a `@Generable` type
  (reuse `GeneratedFolder { name; rationale }`). Sanitize the name (same rules as
  M8 §2).
- **Merge** to avoid near-duplicates ("Tech" vs "Technology", or a proposal that
  really equals an existing folder):
  - Embed each proposed `name + " " + rationale` and each existing folder name.
  - If a proposal is within `mergeThreshold` of an **existing** folder → don't
    create a new folder; its members route to that existing folder in 3b.
  - If two proposals are within `mergeThreshold` of each other → merge clusters,
    keep one name. Optional `enableLLMMerge` pass for a final polish.
- **Accept** proposals up to `maxNewFolders` (default 12), preferring larger
  clusters. This cap should stay **≤ M8's `constrainedFolderCap` minus the seed
  folder count** so the augmented taxonomy doesn't trip M8's fallback.

## Store changes (resume + cost)

Embeddings are deterministic and the most expensive step — cache them:

- `embeddings(bookmark_id PK, run_id, model TEXT, dim INT, vector BLOB)` — vector
  as little-endian `Float` blob; reuse on re-run, recompute only on model change.
- `clusters(id, run_id, label, rationale, accepted INT)` and
  `cluster_members(cluster_id, bookmark_id)` — for resume and `status`/inspection.
- Accepted folders are merged into the run's existing `taxonomy_json`; Phase 3b
  commits per batch exactly as 3a does.

Add migration `v2` registering these tables (don't mutate `v1`).

## Config

```
ClusteringConfig:
  enabled: Bool = false            // opt-in via --cluster (or auto when residue large)
  similarityThreshold: Double = 0.62
  mergeThreshold: Double = 0.80
  minClusterSize: Int = 3
  minResidue: Int = 8              // skip Phase 2 below this
  maxNewFolders: Int = 12
  namingSampleSize: Int = 8
  enableLLMMerge: Bool = false
```
CLI on `organize`: `--cluster`, `--max-new-folders N`, `--taxonomy cluster`
(the all-bookmarks variant).

## New module

`Pipeline/Clusterer.swift`:
```
struct Clusterer {
  init(factory: SessionFactory, budget: TokenBudget, config: ClusteringConfig)
  func embed(_ bookmarks: [Bookmark]) async -> [String: [Float]]   // id → vector
  func cluster(_ vectors: [String: [Float]]) -> [[String]]          // id groups
  func name(_ clusters: [[String]], bookmarks: [Bookmark], existing: [String]) async throws -> [Taxonomy.Folder]
  func merge(_ proposed: [Taxonomy.Folder], existing: [Taxonomy.Folder]) async -> [Taxonomy.Folder]
}
```
`Organizer.organize` gains the Phase 2 block between 3a and 3b, gated on
`options.clustering.enabled` and residue size.

## Tests

- **Pure (no model):** clustering on synthetic vectors (well-separated groups →
  expected clusters; noise below `minClusterSize` dropped); cosine sim; merge
  logic with hand-set embeddings; blob (de)serialization round-trip.
- **Gated:** `embed` returns finite vectors of stable dimension on-device;
  naming returns sanitized, non-duplicate folder names.
- **Integration:** a residue fixture that's obviously two topics → two accepted
  folders; 3b moves those items out of `Unsorted`; strays stay `Unsorted`.
- **Resume:** kill after embeddings cached → re-run recomputes nothing; kill
  mid-3b → resumes without duplicating folders.

## AC

- On a fixture with a clear unsorted topic of ≥ `minClusterSize`, Phase 2
  proposes a sensibly-named folder and 3b relocates those bookmarks.
- Embeddings are cached and reused across runs (verified by a no-recompute
  assertion on second run).
- Augmented taxonomy honors `maxNewFolders` and stays within M8's cap.
- Phase 2 is fully skipped (no model calls) when residue < `minResidue`.

## Risks

- **Embedding quality on a modest sentence model** → threshold tuning; document
  `NLContextualEmbedding` as the multilingual/quality upgrade.
- **Threshold sensitivity** → expose `--cluster-threshold`; ship conservative
  defaults that under-cluster rather than over-merge.
- **Folder explosion** → `maxNewFolders` + prefer-larger-clusters + merge pass.
- **Interaction with M8** → keep `maxNewFolders + seedCount ≤ constrainedFolderCap`;
  otherwise M8 auto-falls back to `.guided` for the augmented pass (acceptable,
  but log it).
```
