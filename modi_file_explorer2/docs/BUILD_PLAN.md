# Build Plan — Flutter File Manager (Android, Phase 1)

How to use this file:
1. Keep `.github/copilot-instructions.md` in the repo — it's loaded automatically.
2. Work through milestones **in order**, one at a time, in a fresh Copilot
   Chat / agent session per milestone (mentioning the milestone number keeps
   its context tight).
3. After each milestone: run the app, run tests, review the diff, **commit**.
   Don't start the next milestone on top of an unreviewed one — that's the
   single biggest cause of "Copilot broke something and I can't tell what."
4. If Copilot's output drifts from a checklist item, correct it in that same
   session before moving on rather than patching it three milestones later.

Each milestone below has: **Goal**, a **prompt to paste into Copilot Chat
(agent mode)**, and an **acceptance checklist**.

---

## Milestone 0 — Project Scaffold

**Goal:** Repo skeleton, dependencies, empty layered folders, lint config.

**Prompt:**
> Using `.github/copilot-instructions.md` as the source of truth, scaffold a
> new Flutter project: set up the folder structure in §3, add the
> dependencies listed in §2 to pubspec.yaml, configure `flutter_lints`, and
> create empty placeholder files (with TODO comments) for each abstract
> repository named in the SRS's "Platform Support" section. Do not implement
> any features yet — just structure. Add a trivial widget test that boots
> `MaterialApp` and confirms the app builds.

**Checklist:**
- [ ] Folder structure matches §3 exactly
- [ ] `flutter analyze` clean
- [ ] `flutter test` passes (smoke test)
- [ ] No feature code yet

---

## Milestone 1 — Theming (Light/Dark, Material 3, Text Scale)

**Goal:** §5 of instructions file, fully wired, switchable at runtime.

**Prompt:**
> Implement `core/theme/`: a light and dark ColorScheme generated from one
> seed color via `ColorScheme.fromSeed`, matching the SRS "Theme" section. Add
> a Riverpod provider for `ThemeMode` and one for text scale (Medium default,
> Small/Medium/Large enum even though only Medium is user-selectable right
> now). Wire both into `MaterialApp`. Persist theme mode to shared_preferences
> using the key from §6.

**Checklist:**
- [ ] Toggling theme mode in a debug button actually restyles the app
- [ ] Restarting the app remembers the last theme mode
- [ ] No hardcoded colors introduced elsewhere

---

## Milestone 2 — Routing + Responsive Shell

**Goal:** GoRouter skeleton, mobile shell with tab bar, desktop-stub branch.

**Prompt:**
> Set up GoRouter with routes for Home and a generic Storage Tab route
> (`/storage/:tabId`). Build `MobileShell` per the SRS "Mobile Layout"
> section: Home tab always present, dynamically add/remove storage tabs
> (cap at 22 per SRS). Add the `LayoutBuilder` split from §4 with a minimal
> `DesktopShell` placeholder (just a Text widget is fine for now). No real
> storage data yet — use a hardcoded fake list of 2 tabs to prove tab
> add/remove/swipe works.

**Checklist:**
- [ ] Tabs can be opened and closed, capped at 22
- [ ] 0 open tabs shows empty state, doesn't crash
- [ ] Swiping/scrolling between tabs works
- [ ] Desktop branch exists but is not fleshed out (that's correct for now)

---

## Milestone 3 — Domain Layer + Android Storage Repository

**Goal:** The abstraction boundary that protects future platforms.

**Prompt:**
> Define domain entities `StorageDevice`, `FileSystemEntry` per the SRS
> "Available Storage" and "File List" sections. Define abstract
> `StorageRepository` in `domain/repositories/` with methods to list storage
> devices (with used/total space), list a directory's contents, and watch a
> directory for changes. Implement `AndroidStorageDataSource` and
> `AndroidStorageRepositoryImpl` in `data/`, using permission_handler +
> path_provider + device_info_plus, handling internal storage and SD card
> detection per the SRS. Register via Riverpod provider. Write unit tests
> against a fake repository (don't require a real device for tests).

**Checklist:**
- [ ] `StorageRepository` interface has zero Android-specific types leaking through
- [ ] Presentation layer never imports `data/`
- [ ] Runs on a real/emulated Android device and lists real storage
- [ ] Unit tests pass without a device attached

---

## Milestone 4 — Home Page: Category Cards (Section 1)

**Prompt:**
> Build the horizontally-scrolling category cards section per SRS "Section 1
> — Category Cards": Downloads/Documents/Images/Videos/Audio, each showing
> icon, name, and computed storage size auto-formatted MB/GB/TB. Card sizing
> should show ~2 full cards + partial next card to hint scrollability, per
> spec. Wire size calculation through a usecase that walks the relevant
> Android directories via `StorageRepository`.

**Checklist:**
- [ ] Sizes auto-format units correctly at boundary values (e.g. 999MB vs 1GB)
- [ ] Horizontal scroll shows partial next card
- [ ] Category list is a simple list Copilot didn't hardcode into the widget (easy to extend later)

---

## Milestone 5 — Home Page: Quick Access + Recent (Section 2)

**Prompt:**
> Build SRS "Section 2": Recent Files and Favourite (Quick Access) folders.
> Empty state shows "No favourites" per spec. Persist Quick Access across
> restarts (hive, key from §6). Each row: name (left), full path (center,
> auto-marquee-scroll if it overflows, isolated per-row per spec), metadata
> (right, default Modified date). Implement Edit Mode for reordering both
> lists (up/down, drag or buttons — your call, note the choice).

**Checklist:**
- [ ] Restarting the app keeps Quick Access folders
- [ ] Empty state matches spec exactly
- [ ] Long path text scrolls without affecting sibling rows
- [ ] Reordering persists

---

## Milestone 6 — Home Page: Available Storage (Section 3)

**Prompt:**
> Build SRS "Section 3": grid of storage device cards (name, used/total
> space), 1–2 per row on phones. Tapping a card opens a new Storage Tab
> (reuse Milestone 2's tab mechanism) via `StorageRepository`. Internal
> storage/SD cards auto-open on first launch per "Default Tabs — Mobile";
> external devices only open on manual tap.

**Checklist:**
- [ ] Internal storage tab(s) open automatically on first launch, only once
- [ ] Tapping a storage card opens/focuses the right tab, doesn't duplicate needlessly
- [ ] Layout matches 1–2 cards/row on phone widths

---

## Milestone 7 — Storage Tab: File List + Top App Bar + Usage Indicator

**Prompt:**
> Implement the Storage Tab screen: top usage bar (5% height, used vs free,
> theme-colored used / grey free, per SRS "Storage Usage Indicator"), top
> app bar (hamburger left, scrolling current path center, search right, per
> SRS "Top App Bar"), and the mobile vertical file list (icon, name,
> modified date, approx size, per SRS "File List"). Use lazy loading —
> directories should not block the UI for large folders. Support icon
> mapping for folder/pdf/image/video/audio/archive/unknown.

**Checklist:**
- [ ] Opening a folder with 1000+ fake files stays smooth (test with a generated fixture)
- [ ] Path text scrolls when it overflows
- [ ] Usage bar percentage matches actual used/total from Milestone 3 data

---

## Milestone 8 — Selection Mode + Context Menu

**Prompt:**
> Implement Selection Mode per SRS: long-press (1.5s) enters it on mobile,
> app bar left icon becomes Back Arrow, right becomes More Options, search
> icon hides, checkboxes appear, supports single/multi selection. Wire the
> context menu actions Rename/Delete/Copy/Properties (Properties can just
> show a dialog with entity metadata for now — full copy/delete file ops can
> be a stub usecase if underlying platform code isn't ready, but note that
> explicitly rather than silently no-op'ing).

**Checklist:**
- [ ] Long-press timing feels correct (1.5s), doesn't trigger on scroll
- [ ] Exiting selection mode restores hamburger/search icons exactly
- [ ] Rename/Delete/Copy call real repository methods (not just UI)

---

## Milestone 9 — Search

**Prompt:**
> Implement search triggered from the Top App Bar search icon, scoped to the
> currently active Storage Tab's path, using `StorageRepository`. Debounce
> input, show empty/no-results state.

**Checklist:**
- [ ] Search doesn't block UI thread on large directories
- [ ] Clearing search returns to normal file list state

---

## Milestone 10 — Settings

**Prompt:**
> Build Settings (opened from hamburger menu) as expandable sections per SRS:
> Appearance (Theme — functional; Accent Color, Background — visible but
> disabled/"coming soon", since those are future features), Files (Show
> Hidden Files — functional; Default View Mode — functional if only List
> exists so far), Storage (Default Startup Drive / drives to auto-open —
> functional, persisted per §6). Structure the section list so adding a
> future setting doesn't require restructuring the page.

**Checklist:**
- [ ] Toggling "Show Hidden Files" actually filters the file list
- [ ] Settings persist across restart
- [ ] Disabled/future items are visibly disabled, not silently missing

---

## Milestone 11 — Persistence Pass (Open Tabs)

**Prompt:**
> Persist open tabs (which storage, current path per tab) across app
> restarts per SRS "Persistence" section, key from §6. Restore exactly the
> tabs that were open, in order, on next launch.

**Checklist:**
- [ ] Force-close app with 3 tabs open on different paths → relaunch restores all 3 correctly
- [ ] Tab cap (22) still enforced after restore

---

## Milestone 12 — Polish Pass

**Prompt:**
> Pass over all Phase 1 screens: verify empty states, animations
> (SRS "smooth animations"), scrollbars where content overflows, and
> accessibility (semantics labels on icons/buttons). Fix anything not
> matching `.github/copilot-instructions.md` §8's definition of done.

---

## Explicitly out of scope for now (don't let Copilot pull these in early)

Multi-path split view, custom background (color/image), accent color
picker, Windows/Web/iOS/macOS/Linux implementations, plugin architecture,
configurable metadata beyond what's specified above. These are Phase 2/3 or
other-platform — the abstractions above already leave room for them.
