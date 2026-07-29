# JW Fusion — Post-launch feature roadmap

Feedback from closed testing, sized against a 14-day test window with
releases every 2-3 days. Each item below is rated on the same three axes:

- **Effort** — how much work, realistically, for one person
- **Risk** — technical risk, Play Store review risk, or risk of confusing/
  scaring users with something this touches their personal data
- **Value** — how much testers actually asked for it / how visible the fix is

## Quick reality check on what's already there

**Light/dark mode already exists.** `main.dart` already defines both a
light and dark `ThemeData` and sets `themeMode: ThemeMode.system` - the app
already follows the phone's system-wide dark mode setting automatically.
If testers are asking for this, it's one of two things: their phone's
dark mode wasn't on when they tried it, or (more likely) they want a
**manual override inside the app** regardless of the system setting. I've
assumed the second below, since that's the only version of this request
that's actually new work.

---

## Recommended release order

### Release 1 (next, ~2-3 days): manual theme toggle
**Effort: low. Risk: low. Value: medium-high (directly requested).**

Add a Settings option: System / Light / Dark. The persistence plumbing
already exists (`AppSettings` + `shared_preferences`, same pattern as the
conflict-resolution toggle) - this is mostly wiring `MaterialApp`'s
`themeMode` to a value that can change at runtime instead of being fixed
at startup. Half a day of work, low regression risk, easy to verify.

### Release 2 (~2-3 days later): remember last-used folder
**Effort: low-medium. Risk: low. Value: medium.**

Save the last folder a tester picked backups from or saved a merged file
to, and reopen the picker there next time.

Important caveat to set expectations on: `file_picker`'s `initialDirectory`
option is **only honored on Windows, Linux, and macOS** - confirmed
against the current package docs. On Android, the file picker is the
system's own Storage Access Storage (SAF) UI, which does not reliably
accept a starting folder from the app; most document providers ignore
it. So this will work great on the Windows build and will help Android
testers less, if at all - worth saying that plainly in the release notes
so it's not reported back as "still broken."

### Release 3 (~2-3 days later): "remembered folder" convenience, not silent background merging
**Effort: medium. Risk: low (see why below). Value: medium.**

This is a scaled-down version of the "auto-update when files are added to
a folder" request. I'd deliberately avoid building the literal ask -
here's why, and what I'd build instead.

The literal ask (watch a folder continuously, even when the app is
closed, and auto-merge new files as they appear) is both the highest-risk
and highest-effort item on this list:

- On Android, continuously watching a folder in the background requires
  either a foreground service (permanent notification, battery drain,
  extra Play Store review scrutiny on background-access declarations) or
  fights directly with Scoped Storage, which restricts background access
  to folders the app doesn't own.
- Silently merging files without the user watching it happen is a real
  trust risk for an app whose entire pitch is "we never touch your
  original backups and you always see what happened." One wrong silent
  auto-merge and testers stop trusting the app with their data.

What I'd build instead: when the user picks a folder once, remember it,
and when they open the app, automatically check that folder and offer
("Found 3 new backups in your folder, merge them?") rather than doing it
silently in the background. Same convenience, none of the background-
service complexity or the "it did something to my files without me
knowing" risk. If testers push back that they specifically wanted it
fully automatic and unattended, that's worth a real conversation before
building it - it's a materially bigger and riskier feature.

### Release 4 onward: localization infrastructure, not full translations
**Effort: high up front, low per additional language after. Risk: medium.
Value: high, but slow to pay off.**

This is the biggest item on the list, and I wouldn't try to ship it
inside the 14-day window - the honest estimate is more than a single 2-3
day cycle just for the infrastructure, before a single word is
translated. What's actually involved:

1. Every hardcoded string in the UI (`dashboard_screen.dart`,
   `settings_screen.dart`, plus the dynamic warning/summary text the merge
   engine itself generates in `merge_report.dart`) needs to move into
   Flutter's localization system (`flutter gen-l10n` + ARB files).
2. Each target language needs an actual translation, not machine
   translation dropped in unreviewed - this is a real quality bar for
   something Jehovah's Witnesses worldwide might use.
3. Some target languages (e.g. Arabic, Hebrew) are right-to-left, which
   can affect layout in ways worth testing, not just translating.

Realistic path: treat "wire up the localization infrastructure and ship
English through it" as its own release (this makes every language after
the first cheap to add), then add languages one at a time as a low-effort
backlog item post-launch, prioritized by whatever language your actual
testers or early users are asking for by name. If there's a specific
second language testers want most, that's worth confirming before this
starts, since it changes what "done" looks like for release 4.

---

## Suggested 14-day cadence

| Day | Release | Content |
|-----|---------|---------|
| 0 | Build 1 (already shipped) | Initial closed test |
| 2-3 | Build 2 | Manual light/dark toggle |
| 5-6 | Build 3 | Remember last-used folder (Windows-reliable, Android best-effort) |
| 8-9 | Build 4 | "Check remembered folder on open" convenience feature |
| 11-14 | Build 5 | Localization infrastructure + English (if time allows); otherwise bug fixes from tester feedback on builds 2-4 |

Leaves room to absorb whatever bugs testers find in each build before the
next one ships, which matters more than cramming in every requested
feature - a testing window that surfaces real problems is more valuable
than one that just adds scope.

---

## Small QoL ideas nobody's asked for yet

None of these came from tester feedback, but they're cheap, fit the
"obvious enough for a kid or an 80-year-old" mission the app was built
around, and would make it feel more polished than a typical utility app.
Ranked roughly by effort, cheapest first.

**Show which file is newest.** The merge strategy is "latest timestamp
wins," but right now nothing in the UI tells the user which of their
selected files is actually the newest one - they just have to trust the
engine. Adding the file's modified date under its name in the selection
list (already available for free via `File.statSync()`, no new
dependency) and a small "Newest" badge on whichever one wins removes
guesswork and builds confidence in a result they can't otherwise inspect.
Effort: trivial.

**Warn on likely duplicate files.** If someone picks the same backup
twice (easy mistake - same file browsed to from two different folder
shortcuts), a quick same-size-and-date check before merging can catch it
("These two look identical - merge anyway?"). Cheap safety net, no new
dependency.

**Let the user rename the output before saving.** Right now the merged
file is auto-named `JWFusion_merged_<date>.jwlibrary`. A simple editable
text field on the success screen, pre-filled with that name, is a small
personal touch that costs almost nothing to add.

**Repeat the "your originals are safe" reassurance everywhere, not just
on error.** That line already exists on the failure screen
(`dashboard_screen.dart`'s `_FailureView`). For an audience that includes
people nervous about losing irreplaceable notes and highlights, saying
it up front on the idle screen too - before they've even started - is a
free trust-builder. Text-only change, no new logic.

**Text size control in Settings.** Given the explicit design goal of
working for a child or an elderly person, a "Larger text" toggle
(scaling `MediaQuery`'s text scale factor at the app root) is a
meaningfully on-brand accessibility feature that most competing
JW-adjacent tools won't bother with. Low-to-medium effort, no new
dependency.

**A 3-screen first-open walkthrough.** Not a tour of every feature - just
"1. Pick your backups. 2. Tap Merge. 3. Save the result," shown once on
first launch, skippable immediately. For the stated audience this
probably does more for real-world usability than any single feature on
the tester-requested list above. Medium effort (needs a first-launch
flag in `AppSettings`, similar pattern to the existing preferences).

Any of these could slot into the gaps in the 14-day cadence above without
displacing the tester-requested items - most are small enough to pair
with another release rather than needing one of their own.
