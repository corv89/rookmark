# rookmark — Tuning Runbook & Default Record

Two things in one file: **(1)** the procedure to tune the pipeline's defaults on
your corpus using the eval harness, and **(2)** the record of what you chose and
why. Defaults here are **provisional — tuned on one corpus**; the regimen
minimizes, not eliminates, overfitting (see Caveats).

Tuning is a finite activity: run this once, lock the defaults, then keep only the
regression check (Step 8) running by hand at release / OS-update time.

---

## Objective

Maximize **effective yield** (accepted placements ÷ total) under guardrails:
folder count in a sane band (~12–40), inter-run variance near zero, latency
acceptable. **Do not chase sort rate** — it's coverage, not correctness.

## Why the steps are ordered the way they are

- **Labels are keyed to `(bookmark, folder)`**, so they only stay valid while the
  folder set is fixed. Therefore: tune anything that *changes the folders*
  (embedder, clustering) with **label-free structural metrics**; tune anything
  that operates *given* a fixed taxonomy (floor, batch size) with **labels**, on a
  **pinned** taxonomy.
- The **floor** and **batch-size** decisions are robust to the exact taxonomy
  (they're about confidence calibration and batching, not specific folders), so
  you can label once against an initial run and reuse those labels for both.

---

## Step 0 — Prerequisites

```
rookmark doctor                       # model available, Apple Intelligence on
swift build -c release
```
Determinism (greedy decoding, M11) must be on so each config is a single
reproducible run. Have the corpus export at hand (`corpus.html`).

## Step 1 — Reference run + labels (the foundation)

```
# One stateful run with current defaults → note the runID (call it R0).
rookmark organize corpus.html --stateful

# Stratified labeling worksheet from R0's placements (include some Unsorted rows
# for recall). Pin R0 so the sample reflects the taxonomy you'll reuse.
rookmark eval sample corpus.html --pin-taxonomy R0 --n 200 > worksheet.csv
```

Hand-label `worksheet.csv`: fill `verdict` = accept/reject for each placement,
and for the Unsorted rows mark whether the item *should* have had a home (drives
recall). Then ingest:

```
rookmark eval import-labels worksheet.csv      # → labels DB
rookmark eval metrics corpus.html --pin-taxonomy R0   # sanity: yield/precision/recall + CIs
```

`metrics` is your baseline read. If a judge later helps scale labels, it's Step 9
— don't reach for it unless 200 labels prove too thin.

## Step 2 — Settle the confidence floor (cheapest, highest-value, no re-run)

```
rookmark eval calib --pin-taxonomy R0 corpus.html
```

This bins placements by the model's reported confidence and, using
`Decision.modelChosenFolder`, post-hoc simulates every floor value from one run —
no re-inference. Read the two tables:

- **Precision-per-confidence-bin flat** ⇒ confidence is uncalibrated noise ⇒ set
  **`confidenceFloor = 0`** (the floor only discards correct placements).
- **Rising** ⇒ pick the floor at the precision knee that maximizes yield.

Record the chosen floor in the table below. This resolves the long-open
floor-vs-0 question with data rather than a guess.

## Step 3 — Confirm the embedder under *precision* (not sort rate)

The earlier "sentence beats contextual" call rode on sort rate. Re-confirm, but
note labels don't transfer between the two folder sets, so use **structural
metrics + a targeted multilingual spot-check**, not labeled yield:

```
rookmark organize corpus.html --embedder sentence  --stateful   # → Rs
rookmark organize corpus.html --embedder contextual --stateful  # → Rc   (needs: doctor --download-assets)
rookmark eval metrics corpus.html --pin-taxonomy Rs   # coherence / distinctness / folder structure
rookmark eval metrics corpus.html --pin-taxonomy Rc
```

Hand-check ~20 multilingual placements per run (that subset is contextual's only
mandate). Keep **sentence** unless contextual clearly wins the multilingual
subset *and* doesn't degrade structure.

## Step 4 — Tune clustering parameters (structural, label-free)

These change the folders, so evaluate by structural metrics + folder-count
guardrail + stability — never by the stale labels.

```
rookmark eval sweep --param similarityThreshold --values 0.5,0.6,0.7 corpus.html
rookmark eval sweep --param mergeThreshold       --values 0.78,0.82,0.86 corpus.html
rookmark eval sweep --param maxNewFolders        --values 8,12,16 corpus.html
```

For each, read coherence (↑ good), distinctness (↑ good), folder count (stay in
band), and singleton rate (↓ good). **Pick the middle of the plateau**, not the
peak — a one-corpus peak is usually overfit.

## Step 5 — Tune classifier batch size (labels, pinned taxonomy)

Batch size doesn't change folders, so labels stay valid; pin R0 and judge by
precision/yield + latency:

```
rookmark eval sweep --param batchSize --values 4,6,8,12 --pin-taxonomy R0 corpus.html
```

Take the **largest batch that doesn't drop precision** (paired-bootstrap
non-significant) — larger = fewer model calls = faster, as long as quality holds
and it fits the 4 096-token budget.

## Step 6 — Robustness check (generalization proxy)

```
rookmark eval subsample --fraction 0.7 --trials 10 corpus.html
```

Confirms the chosen defaults' metrics and the taxonomy (folder-set Jaccard) are
stable across random 70% subsets. If a default's metric swings widely, it's
overfit — back off to a more robust value. This is the closest thing to a second
corpus you have.

## Step 7 — Lock defaults + freeze the baseline

Apply the chosen values in code (`Classifier.Config`, `ClusteringConfig`, embedder
default), rebuild, then:

```
rookmark eval baseline labels.db > baseline.json    # frozen yield/precision + labelsHash
rookmark eval run --runs 5 corpus.html              # confirm variance is near zero
```

Paste `baseline.json` into the record below and commit it.

## Step 8 — Ongoing regression check (the one permanent piece)

Not CI-automated (no self-hosted Mac runner). Run **by hand on your own Mac**
after any macOS update (the on-device model can change) and before each release:

```
rookmark eval check labels.db --baseline baseline.json
```

Non-zero exit = yield/precision regressed beyond the baseline CI → investigate
before shipping.

## Step 9 — Optional: scale labeling with the local judge

Only if 200 hand labels prove too thin. Start LM Studio with Qwen loaded, then:

```
rookmark eval judge corpus.html --labels labels.db --judge none    # reports κ vs your human labels
rookmark eval judge corpus.html --labels labels.db --judge local   # only after κ is acceptable
```

Trust the judge to bulk-label only once κ against your human labels is adequate.
Data stays on your machine.

---

## Decisions record (fill in after running)

| Parameter | Chosen default | Evidence | Date |
|-----------|----------------|----------|------|
| `confidenceFloor` | ___ | Step 2 calibration curve | |
| embedder | ___ (expect `sentence`) | Step 3 structural + multilingual spot-check | |
| `similarityThreshold` | ___ | Step 4 plateau | |
| `mergeThreshold` | ___ | Step 4 plateau | |
| `maxNewFolders` | ___ | Step 4 plateau + folder-count band | |
| `minClusterSize` | ___ | Step 4 | |
| `batchSize` | ___ | Step 5 precision-flat | |
| `constrainedFolderCap` | 40 (unchanged) | — | |

## Frozen regression baseline

```json
// paste baseline.json from Step 7
{ "minYield": __, "minPrecision": __, "labelsHash": "__" }
```

## Caveats

- **Provisional — one corpus.** Re-validate with leave-one-corpus-out when a
  second collection arrives; the harness already takes a corpus as a parameter, so
  no code change is needed then. Until then, Step 6 (subsample) is your only
  generalization signal.
- **Structural metrics are proxies** — coherent ≠ correct. Use them to compare
  cluster configs, then spot-check the chosen config's real placements against
  labels.
- **Labels don't transfer across configs that change the folder set** — that's
  why Steps 3–4 use structural metrics and Steps 2/5 pin the taxonomy.
