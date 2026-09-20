<p align="center">
  <img src="media/icon.png" width="128" height="128" alt="Rookmark icon">
</p>

<h1 align="center">Rookmark</h1>

<p align="center">
  Sorts a pile of browser bookmarks into sensible topic folders, using the
  on-device language model built into macOS.<br>
  Nothing is uploaded, nothing is deleted, and no account is required.
</p>

_Rooks cache things and remember where they put them, that's why!_

## Problem & Solution

If you're anything like me, you keep finding interesting content around the web
but never take the time to organize it properly. Or, a botched browser migration
wipes what you've painstakingly organized by hand.

Rookmark sorts your pile of bookmarks automatically and proposes a new home for
each one, without exposing any of your content.

<p align="center">
  <img src="media/screenshot.png" width="800" alt="Rookmark reviewing a live classification run: a sidebar of folders with counts, a table of bookmarks sorted least-confident-first, and a run-progress card">
</p>

## Requirements

- macOS 26 or later, Apple Silicon, with Apple Intelligence enabled
- Xcode 26+ toolchain to build

The classifier is Apple's `FoundationModels` system model.
There is no Linux or Intel support currently, sorry!

## Install

```
git clone https://github.com/corv89/rookmark
cd rookmark
swift build -c release
```

Check that the model is actually available before anything else:

```
swift run rookmark doctor
```

That reports model availability, the context window, and which embedding
backend is active. If it reports the model as unavailable, nothing else will
work.

## Use it

### Graphical

```
./scripts/make-app.sh      # builds build/Rookmark.app
open build/Rookmark.app
```

Or run it straight from the package during development, which skips the bundle
and therefore shows up as `RookmarkApp` rather than `Rookmark`:

```
swift run -c release RookmarkApp
```

Reads the installed [Orion](https://browser.kagi.com/) profile, classifies a sample or the whole library, and
presents the result for review: folders with counts down the side, items sorted
least-confident-first so your attention lands where the model is weakest, and an
inspector explaining why each item went where it did. Nothing is written until
you press Export.

Any other browser works too: export your bookmarks as HTML and drop the file on
the window (Safari: File ▸ Export Bookmarks). You can also press Cmd+O. The file
is only read, never modified, and the result still comes back as a new file when
you press Export.

### Command line

```
# Pull bookmarks straight out of an installed Orion profile
swift run rookmark import-orion -o mybookmarks.html

# Organize any Netscape-format bookmark export
swift run rookmark organize mybookmarks.html \
    --taxonomy-from tuning/consolidated-taxonomy-v5.json \
    --cluster --no-enrich
```

Add `--stateful` to checkpoint every classified batch to SQLite — if the run is interrupted, re-running the same command prints `resuming: N/M already classified` and picks up where it stopped.

`organize` writes a new HTML file you re-import from your browser's bookmark
manager. Other subcommands: `dedup`, `check-links`, `eval`, `worksheet`,
`import`/`export`/`list`/`search`/`undo`/`status`.

## How it works

```
bookmarks ──▶ taxonomy ──▶ classify ──▶ cluster leftovers ──▶ new HTML
              (pinned or    (batched,     (embeddings group
               generated)    constrained   the residue, the
                             decoding)     model names it)
```

Classification presents bookmarks to the model in small batches against a list
of candidate folders, each with a one-sentence rationale. A runtime
`GenerationSchema` constrains the output so the model can only emit a folder
that actually exists. Items it cannot place confidently go to `Unsorted` rather
than being guessed at, and every item gets a decision: nothing is silently
dropped.

Whatever lands in `Unsorted` can then be clustered by embedding similarity, with
the model naming each cluster, so genuinely new topics become new folders
instead of a junk drawer.

## Accuracy

On 720 hand-labeled placements from a real collection:

| Metric | |
|---|---|
| Coverage (placed / total) | 96.9% |
| Placement precision (accepted / placed) | 84.0% |
| Effective yield (accepted / total) | 81.4% |

Throughput is roughly 1.1 seconds per bookmark on an M4. The Neural Engine is
the same across the M4 line, regardless of which variant you have.

These figures come from one person's collection and are provisional. See
`docs/EVALUATION.md` for the methodology and `docs/TUNING.md` for the tuning
runbook. The `eval` subcommand reproduces all of it.

## What it will not do

- **It does not edit your existing bookmarks!** Output is always a new file that you
  choose to import manually, once you're satisfied with the proposed structure.
- **It never sends your bookmarks anywhere.** Classification and embedding both
  run on-device. Optional page-description fetching and liveness checks are the
  only features that touch the network, and they're off unless you say otherwise.

## Known limitations

- Safari's bookmarks are unreadable without Full Disk Access; export manually
  from Safari and drop the file on the window instead. Chrome, Firefox, Edge,
  and Brave work the same way: export bookmarks as HTML from the browser's
  bookmark manager, then drop the file on the window.
- The taxonomy is flat. Rookmark won't create nested folder structures.

## Contributing

If you'd like to help improve accuracy and taxonomy, open an issue, or get in
touch if you're willing to share your own bookmark collection (handled
respectfully and never redistributed).

## Credits

Shoutout to [LLMCoolJ](https://github.com/LLMCoolJ/) for the [Lazybookmarks](https://github.com/LLMCoolJ/lazybookmarks) prototype!

Special thanks to Anthropic for the Fable 5.1 Build Day hackathon which brought about this GUI.

## License

GNU General Public License v3.0. See [LICENSE](LICENSE).
