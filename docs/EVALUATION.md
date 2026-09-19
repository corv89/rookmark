# rookmark — Evaluation & Tuning (single-corpus regimen)

Handoff for the agent. Extends the existing `rookmark eval` command (M11.4) into a
proper evaluation + default-tuning harness. Written for the current reality of
**one labeled corpus** (the ~720-bookmark export); §2 is the constraint that
shapes everything else. Conventions: **AC** = acceptance criteria, **VERIFY** =
confirm against the SDK/API before relying on it.

## 1. The objective (don't optimize the proxy)

Sort rate is **coverage**, not **quality** — `confidenceFloor = 0` plus loose
thresholds maximizes it while producing garbage. Optimize **effective yield**
(acceptable placements ÷ total), subject to guardrails (folder count in band,
inter-run variance below ceiling, latency budget). Coverage vs. precision is a
Pareto tradeoff; most parameters pick a point on it.

## 2. Working with ONE corpus

You cannot hold out a second collection, so generalization can't be truly
estimated and defaults are **provisional**. Minimize (not eliminate) overfitting
with four disciplines:

**2a. Split the problem by pipeline stage — they have different evaluability.**

| Stage | Why | How to evaluate on one corpus |
|-------|-----|-------------------------------|
| **Classification** (item → folder, taxonomy fixed) | per-item; selecting params on the data is the only overfit risk | **tuning/validation split** of labeled placements + **k-fold rotation** + bootstrap CIs |
| **Taxonomy/clustering** (global, holistic) | a single clustering can't be cleanly split | **unsupervised structural metrics** + **subsample stability** + judgment; pick robust values |

Pin a known-good taxonomy (M11.3) when tuning classification params so taxonomy
churn can't confound the sweep.

**2b. Quantify uncertainty — bootstrap everything label-based.** Resample the
labeled placements with replacement (B = 1000), recompute the metric each time,
report the 2.5/97.5 percentiles as a 95% CI. When comparing two configs, use a
**paired** bootstrap over the same items (bootstrap the mean per-item outcome
difference) — it controls for item difficulty and is far more sensitive. A
tuning delta is real only if its paired CI excludes 0; otherwise it's noise.

**2c. Pick plateaus, not peaks.** A peak on one corpus is usually overfit. When a
sweep shows a flat region, choose its middle — the value least sensitive to small
perturbations.

**2d. Budget your degrees of freedom.** Tuning many parameters on one corpus just
fits noise. Tune the few high-leverage ones coarsely (`confidenceFloor`,
`similarityThreshold`, `mergeThreshold`, `maxNewFolders`); leave the rest at
reasoned defaults. Prefer 4–5 candidate values per param, not fine grids.

**2e. Generalization proxy via subsampling.** Run the full pipeline on repeated
random subsets (e.g., 70%, 10 trials); measure how stable the chosen defaults'
metrics and the resulting taxonomy are. Stable-under-subsampling ≈ more likely to
generalize. This is the closest thing to a second corpus you have.

> Build the harness so a corpus is just a parameter. When a second collection
> arrives, the regimen upgrades to true leave-one-corpus-out with no code change.

## 3. Metrics

Label-based (need §4 labels):
- **Coverage** = placed ÷ total.
- **Placement precision** = accepted ÷ placed.
- **Effective yield** = accepted ÷ total. *(the objective)*
- **Placement recall** = accepted ÷ (accepted + wrongly-Unsorted), where
  wrongly-Unsorted is estimated by judging a sample of Unsorted items ("should
  this have had a home?"). Catches an over-aggressive floor.

Label-free (compute from embedder vectors — no labels needed):
- **Taxonomy coherence** = mean intra-folder cosine similarity.
- **Taxonomy distinctness** = 1 − mean folder-centroid nearest-neighbor similarity.
- **Size balance** = stddev (or Gini) of folder sizes; **singleton rate** =
  1-member folders ÷ folders.

Stability:
- **Variance** = stddev of the above across reruns (greedy should make this ~0)
  and across subsamples (§2e).

**Confidence-calibration diagnostic** (settles the open `confidenceFloor`=0
question): bin placements by the model's reported confidence, plot precision per
bin. Flat ⇒ confidence is noise ⇒ floor should be **0**. Rising ⇒ keep a floor at
the precision knee.

## 4. Labeling protocol

Label by **acceptability**, not ground truth (categorization is multi-valued and
the taxonomy is generated). For each `(bookmark, assigned-folder)` pair the system
produces, collect accept/reject + optional "better folder?". 

- Hand-label a **stratified sample** (~150–200 placements) across folders,
  confidence bins, and languages, plus a sample of **Unsorted** items for recall.
- Persist labels in SQLite (`labels(bookmark_id, folder, verdict, source, note,
  labeled_at)`) so they accumulate and are reused across every sweep.
- Report **inter-rater agreement** if more than one labeler (categorization is
  subjective; agreement sets the ceiling on tuning precision).

**Optional LLM judge to scale labeling.** Calibrate a judge against the
hand-labeled subset (report Cohen's κ); if agreement is adequate, use it to label
the rest.
- **Privacy:** a cloud judge sends titles + domains off-device — counter to this
  project's on-device premise. Treat it as **dev-only, opt-in** (`--judge cloud`),
  default **off**. Preferred order: human labels → a locally-run larger model if
  available → cloud judge only with explicit consent. The harness must run fully
  on human labels with no judge at all.

## 5. `eval` command surface

Extend the existing command; storage in the run DB.

```
rookmark eval run    --runs N <corpus>                 # existing variance harness
rookmark eval sample <corpus> [--n 200] [--strata folder,confidence,lang]
                                                     # emit stratified labeling worksheet (CSV/JSON)
rookmark eval import-labels <file>                     # ingest human accept/reject
rookmark eval judge  <corpus> --labels <file> [--judge {none|local|cloud}]
                                                     # calibrate (report κ) then scale; default none
rookmark eval metrics <corpus> [--pin-taxonomy <runID>]
                                                     # all §3 metrics + bootstrap CIs
rookmark eval sweep  --param <name> --values a,b,c [--pin-taxonomy <runID>] <corpus>
                                                     # per-value coverage/precision/yield + paired-bootstrap vs baseline
rookmark eval kfold  --folds 5 --pin-taxonomy <runID> <corpus>
                                                     # rotate validation fold; mean held-out yield ± sd
rookmark eval subsample --fraction 0.7 --trials 10 <corpus>
                                                     # stability of metrics + taxonomy (Jaccard of folder sets)
rookmark eval calib  --pin-taxonomy <runID> <corpus>  # precision-per-confidence-bin reliability curve
```
A `Metrics` module computes everything; `eval` subcommands are thin shells over
it (keep it testable, mirroring `RookmarkKit`).

## 6. Tuning plan (which method per parameter)

Order: settle classification first (cleaner to evaluate), then taxonomy/cluster.

1. **`confidenceFloor`** — run `eval calib`. If flat → set 0. Else `eval sweep
   --param confidenceFloor --values 0,10,15,25,35 --pin-taxonomy <good>`; pick the
   yield knee on the validation split, confirm with paired bootstrap. *(Resolves
   the open M9.4 question with data.)*
2. **`batchSize`** — `eval sweep` over {4,6,8,12}; does precision change, or only
   latency? Pick the largest that fits the token budget without a precision drop
   (paired-bootstrap-significant).
3. **Embedder** — re-confirm `sentence` beats `contextual` under **precision**,
   not sort rate (the earlier call used the weak proxy). Check the multilingual
   subset specifically — that's contextual's only mandate.
4. **`similarityThreshold` / `mergeThreshold`** — `eval sweep` against coherence /
   distinctness / downstream yield; these are unsupervised + yield-driven since
   you can't split a clustering. Pick the plateau middle.
5. **`minClusterSize` / `minResidue` / `maxNewFolders`** — folder-count guardrails;
   tune to keep count in band without stranding placeable items (watch recall).
6. **`.preserve` vs `.fresh`** — evaluate both; if the corpus has good existing
   folders, `.preserve` likely wins; consider auto-selecting on existing-folder
   coherence.

Throughout: deterministic (M11) so each config is one run; verify residual ANE
variance is ~0 with `eval run --runs 5` first, else average 3 seeds per config.

## 7. Lock, document, protect

- Set defaults from §6; report the chosen config's metrics on the **untouched
  validation split** (and subsample-stability), not the tuning split.
- Write defaults **with their evidence** (sweep tables, CIs, the calibration
  curve) into `TUNING.md`. Mark them **provisional — tuned on one corpus**.
- Freeze a **regression baseline**: the locked config's yield/precision (with CI)
  on the full labeled corpus, asserted by `eval metrics` in CI so a prompt tweak
  or a future on-device model update can't silently regress it.
- Re-run `eval run --runs 5` to confirm the locked defaults are stable.

## 8. Tests

- **Pure:** metric math (coverage/precision/yield/recall), bootstrap CI
  (deterministic seed → reproducible interval), paired-bootstrap sign, stratified
  sampler (strata proportions hold), label store round-trip.
- **Gated:** `eval calib` produces a monotone-or-flat curve on a fixture; judge
  calibration reports κ.
- **Harness:** `eval sweep` on a tiny fixture returns per-value metrics with CIs;
  `eval subsample` reports taxonomy Jaccard.

## 9. AC

- `eval` reports effective yield + precision + recall with bootstrap CIs from
  human labels, with **no judge required**.
- The `confidenceFloor` decision is made from the calibration curve, not a guess.
- Embedder default re-confirmed under precision (not sort rate).
- `TUNING.md` records each default with evidence and a "provisional / one corpus"
  caveat; a regression baseline is asserted in CI.
- The harness takes a corpus as a parameter, so adding a second collection later
  needs no code change.

## 10. VERIFY

1. LLM-judge integration (only if `--judge cloud|local` is built): API/runtime,
   and that the **default path uses neither** (human labels only).
2. Everything else reuses verified surfaces (embedder for structural metrics,
   greedy decoding from M11).
