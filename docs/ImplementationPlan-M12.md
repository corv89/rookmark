# M12 — Content Enrichment + Contextual Embeddings Default

## Executive Summary

**Goal**: Improve classification accuracy from 71.7% to 80%+ by:
1. Making contextual embeddings the default (with Y/N download confirmation)
2. Fetching meta descriptions to provide richer context to the classifier
3. Detecting and reporting dead links as a bonus feature

**Expected Impact**:
- +3.2% accuracy from contextual embeddings (confirmed: 74.9% vs 71.7%)
- Additional +5-10% from meta descriptions (estimated)
- Dead link detection as zero-effort bonus feature

**Timeline**: ~15 hours implementation + testing

---

## Key Design Decisions (Based on Your Answers)

### 1. Contextual Embeddings Default
- **Change**: Default from `.sentence` to `.contextual` in `EmbedderFactory.make()`
- **Download prompt**: "Contextual embedding model not downloaded. Download now? (Y/N) [~500MB]"
- **Fallback**: If N, proceed with sentence embeddings with warning

### 2. Meta Tag Priority
- **Order**: `og:description` → `twitter:description` → `description` → body text fallback
- **Rationale**: Open Graph descriptions are typically more concise and well-written
- **Truncation**: 300 chars max to stay within token budget

### 3. Dead Link Detection
- **Thresholds**: HTTP 404/410/500+, timeout >15s, DNS failure, connection refused
- **Reporting**: Print to stderr during classification
- **Format**: `⚠️  Dead link: "Old Article" - https://example.com/dead (HTTP 404)`

### 4. Enrichment Scope
- **First run**: Enrich all bookmarks (~5-10 minutes for 720 bookmarks)
- **Subsequent runs**: Use cache (instant, skip already-enriched bookmarks)
- **Stateful mode**: Check enrichments table before fetching

### 5. Cache TTL
- **Persistence**: Indefinite until force-refreshed
- **Refresh flag**: `--refresh-enrichments` to re-fetch all meta tags
- **No automatic expiration**: Meta descriptions rarely change for stable content

### 6. Batch Sizing
- **With enrichments**: Start at batch size 4 (meta descriptions add ~50-70 tokens)
- **Without enrichments**: Start at batch size 6 (current default)
- **Adaptive recovery**: Halve on overflow, increment on success (already implemented)

---

## Implementation Phases

### Phase 1: Contextual Embeddings Default (2 hours)
1. Update `EmbedderFactory` to default to `.contextual`
2. Add asset availability check
3. Add Y/N download confirmation prompt in `Organize.swift`
4. Implement `requestAssetsAsync()` with progress reporting
5. Add fallback to `.sentence` with warning
6. Update README with first-run setup instructions
7. Test download prompt, Y/N responses, and fallback behavior

### Phase 2: Database Schema (1 hour)
1. Add `enrichments` table migration:
   ```sql
   CREATE TABLE enrichments (
       bookmark_id TEXT PRIMARY KEY,
       meta_description TEXT,
       is_dead_link INTEGER NOT NULL DEFAULT 0,
       http_status INTEGER,
       fetched_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
   )
   ```
2. Create `Enrichment` model in `Sources/LazyBookmarksKit/Model/Enrichment.swift`
3. Add cache methods to `Store.swift`: `getEnrichment()`, `setEnrichment()`, `clearEnrichments()`
4. Test table creation, round-trip serialization, cache hit/miss

### Phase 3: ContentEnricher Module (4 hours)
1. Create `ContentEnricher` actor in `Sources/LazyBookmarksKit/Enrichment/ContentEnricher.swift`
2. Implement meta tag extraction with priority order (og → twitter → description → body)
3. Implement dead link detection (HTTP status, timeout, DNS failure)
4. Implement fetch strategy: 5 concurrent requests, 15s timeout, 1 retry
5. Integrate cache: check before fetch, write after fetch
6. Add progress reporting: "Enriching bookmarks... 150/720"
7. Report dead links as detected: `⚠️  Dead link: [title] - [url] (HTTP 404)`
8. Test meta extraction, dead link detection, caching, concurrency, retry logic

### Phase 4: Integration with Classification (3 hours)
1. Update `Organizer.swift` to add enrichment phase before classification
2. Modify `Classifier.renderPrompt()` to include meta descriptions:
   ```
   b0 | Title | URL | Meta description (if available)
   ```
3. Update `Classifier.Config` to accept `hasEnrichments` parameter
4. Set initial batch size: 4 with enrichments, 6 without
5. Update system prompt to mention meta descriptions for disambiguation
6. Test prompt rendering, batch size adaptation, accuracy improvement

### Phase 5: CLI Integration (1 hour)
1. Add CLI flags to `Organize.swift`:
   - `--no-enrich`: Skip content enrichment
   - `--refresh-enrichments`: Re-fetch meta tags even if cached
2. Pass flags through to `OrganizerOptions`
3. Update help text with examples
4. Test flag behavior and help text

### Phase 6: Testing & Validation (3 hours)
1. Unit tests: `ContentEnricherTests`, `ClassifierTests`, `OrganizerTests`, `StoreTests`
2. Integration tests: Full pipeline, dead link reporting, cache behavior, batch adaptation
3. Performance tests: Benchmark with/without enrichment, verify cache hit rate >95%
4. Accuracy tests: Run on user's collection, target 80%+ precision
5. Edge cases: Untitled bookmarks, dead links, long descriptions, non-English, rate limits

### Phase 7: Documentation (1 hour)
1. Update README: Add "Content Enrichment" section, document flags, note dead link detection
2. Update EVALUATION.md: Document accuracy improvement, show examples
3. Update ImplementationPlan.md: Add M12 to milestone list
4. Add troubleshooting guide: Download failures, slow enrichment, dead links, stale meta tags

---

## Acceptance Criteria

### Functional Requirements
- [ ] Contextual embeddings are default (with Y/N download prompt)
- [ ] Fallback to sentence embeddings if download declined
- [ ] Meta descriptions fetched for all bookmarks (unless `--no-enrich`)
- [ ] Dead links detected and reported to stderr
- [ ] Enrichments cached in SQLite database
- [ ] Cache persists across runs (no automatic expiration)
- [ ] `--refresh-enrichments` flag forces re-fetch
- [ ] Classifier uses meta descriptions when available
- [ ] Batch size adapts (4 with enrichments, 6 without)
- [ ] Progress reported during enrichment phase

### Performance Requirements
- [ ] First-run download: ~500MB, completes in <5 minutes on broadband
- [ ] Enrichment phase: ~5-10 minutes for 720 bookmarks
- [ ] Subsequent runs: <1 second (cache hit)
- [ ] Memory usage: <500MB during enrichment
- [ ] Classification time: Not significantly slower than baseline

### Accuracy Requirements
- [ ] Contextual embeddings: 74.9% precision (confirmed)
- [ ] Contextual + enrichment: 80%+ precision (target)
- [ ] Dead link detection: >95% accuracy (few false positives)
- [ ] Meta description extraction: >90% success rate (most sites have meta tags)

---

## Example Usage

### First Run (with Download)
```bash
$ lazybm organize bookmarks.html

Contextual embedding model not downloaded. Download now? (Y/N) [~500MB] Y

Downloading contextual model... 100% [==========] ✅

Enriching bookmarks... 720/720 ✅
⚠️  Dead link: "Old Article" - https://example.com/old (HTTP 404)
⚠️  Dead link: "Broken Link" - https://broken.com/page (timeout)

✅ Enriched 720 bookmarks (2 dead links detected)

Classifying bookmarks... 720/720 ✅

✅ Organized 720 bookmarks into 19 folders
Output: bookmarks.organized.html
```

### Subsequent Run (with Cache)
```bash
$ lazybm organize bookmarks.html

Enriching bookmarks... 720/720 ✅ (all cached)

Classifying bookmarks... 720/720 ✅

✅ Organized 720 bookmarks into 19 folders
Output: bookmarks.organized.html
```

---

## Risk Assessment

### High Risk
- **Download fails or slow**: Mitigate with clear error messages, fallback to sentence embeddings
- **Enrichment too slow**: Mitigate with concurrency (5 parallel), caching, progress indicator

### Medium Risk
- **Low-quality meta descriptions**: Mitigate with priority order (og → twitter → description), truncation
- **Dead link false positives**: Mitigate with conservative thresholds, report to stderr (don't auto-remove)

### Low Risk
- **Database migration fails**: Mitigate with non-destructive migration, testing, rollback instructions
- **Batch size adaptation fails**: Mitigate with extensive testing, fallback to batch size 1

---

## Success Metrics

### Quantitative
- **Accuracy**: 71.7% → 74.9% → 80%+ (target)
- **Performance**: ~15 min baseline → ~20-25 min first run → ~15 min subsequent runs
- **Dead links**: Expected 20-50 in user's collection

### Qualitative
- **User experience**: Y/N prompt clear and non-intrusive
- **Progress reporting**: Helpful, not annoying
- **Documentation**: Complete and easy to use
- **Error handling**: Graceful with actionable messages

---

## Next Steps

1. Review and approve this plan
2. Begin Phase 1 (Contextual Embeddings Default)
3. Test incrementally after each phase
4. Validate accuracy improvement on user's collection
5. Update documentation and release notes

## TODO:

[✓] Step 0: Prerequisites — doctor + release build
[✓] Step 1: Reference run + labels worksheet + import
[✓] Step 2: Settle confidence floor via calib
[#] Step 3: Confirm embedder (sentence vs contextual)
[ ] Step 4: Tune clustering params (structural, label-free)
[ ] Step 5: Tune batch size (labels, pinned taxonomy)
[ ] Step 6: Robustness check (subsample)
[ ] Step 7: Lock defaults + freeze baseline
[ ] Step 8: Regression check (ongoing)
[ ] Step 9: Optional LM Studio judge

## Future ideas

Create simple SwiftUI with drag-and-drop of bookmarks-export.html

Or, better yet, also offer a button that exports from Safari automatically
