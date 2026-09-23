# Copilot Instructions — Flutter File Manager

> Place this file at `.github/copilot-instructions.md` in the repo root.
> VS Code Copilot Chat and Copilot agent mode load this automatically into
> every conversation for this repo — treat it as ground truth over anything
> inferred from the SRS or from older chat turns.

## 1. Current Scope (read this first, every time)

We are in **Phase 1, Android-only**. Full SRS: `docs/requirement.md`.

**Build only what Phase 1 + Android needs right now.** Do NOT write Windows
drive-letter logic, Web file-access code, iOS/macOS/Linux code, split-view,
background customization, or plugin architecture — even if the SRS describes
them. Those are Phase 2/3 and other-platform work. Instead, wherever a
platform-specific decision would be made, isolate it behind an interface
(see §4) so adding a platform later means writing one new class, not
touching existing code.

If a requirement is ambiguous or marked "future," stop and ask rather than
guessing the shape of the abstraction.

## 2. Tech Stack

- Flutter (stable channel), Material 3
- State management: **Riverpod** (hooks_riverpod + riverpod_generator)
- Navigation: **GoRouter**
- DI: Riverpod providers (no separate get_it layer — keep one DI mechanism)
- Local persistence: `shared_preferences` for simple settings, `hive` (or
  `sqflite` if relational needs grow) for structured data (Quick Access,
  Recent, open tabs)
- Android storage access: `path_provider`, `permission_handler`,
  `device_info_plus`, `disk_space_2` (or platform channel if a package is
  insufficient) — wrapped behind our own interface, never called directly
  from presentation code

## 3. Architecture — Clean Architecture + MVVM

```
lib/
  core/
    theme/            # ThemeData, color schemes, text scale
    constants/
    routing/          # GoRouter config
    utils/
    widgets/          # shared dumb widgets (cards, scroll-marquee text, etc.)
  domain/
    entities/         # StorageDevice, FileSystemEntry, QuickAccessItem, ...
    repositories/      # ABSTRACT interfaces only — no implementation
    usecases/          # one class per user action, e.g. ListDirectory,
                       # GetStorageDevices, ToggleFavourite
  data/
    models/            # DTOs + fromJson/toJson where persistence needs it
    datasources/
      android/          # concrete Android implementation
      # windows/ web/ ios/ macos/ linux/  <- added in later phases only
    repositories/       # implements domain/repositories using a datasource
  presentation/
    home/
      home_page.dart
      home_view_model.dart      # Riverpod StateNotifier/AsyncNotifier
      widgets/                  # category_card, quick_access_row, storage_card
    storage_tab/
    file_list/
    settings/
    common/
  main.dart
```

Rules:
- **Presentation never imports `data/`.** Only `domain/` entities and
  usecases are visible to the UI layer.
- **Every platform-touching capability is defined as an abstract repository
  in `domain/repositories/` first**, then implemented in
  `data/datasources/android/...`. Example:
  `abstract class StorageRepository { Future<List<StorageDevice>> getDevices(); Stream<List<FileSystemEntry>> watchDirectory(String path); }`
- ViewModels expose state via Riverpod providers; widgets are stateless where
  possible.
- No business logic in widgets. No direct `dart:io` calls in
  `presentation/`.

## 4. Responsive Layout Rule

Even though only mobile ships in Phase 1, build the layout switch now:

```dart
LayoutBuilder(
  builder: (context, constraints) {
    if (constraints.maxWidth >= 900) return DesktopShell(...); // stub OK
    return MobileShell(...);
  },
)
```

`DesktopShell` can be a minimal placeholder — the point is the branch exists
so desktop work in a later phase is additive.

## 5. Design Tokens

- Light: white background, blue primary (`#1565C0`-ish; pick one seed color
  and generate the M3 ColorScheme with `ColorScheme.fromSeed`), rounded
  corners (12–16px), soft shadows, Material 3.
- Dark: black background, same blue accent, same layout — implement as a
  second ColorScheme from the same seed with `Brightness.dark`, not a
  hand-rolled palette.
- Text size: default Medium; wire a `TextScaler` provider now even though
  Small/Large selection UI is a future setting.
- Do not hardcode colors in widgets — always pull from `Theme.of(context)`.

## 6. Persistence Keys (so future settings don't collide)

Namespace keys: `theme.mode`, `theme.textScale`, `settings.showHiddenFiles`,
`settings.defaultViewMode`, `storage.startupDrive`, `quickAccess.items`,
`recent.items`, `tabs.open`.

## 7. Testing Expectations

For each milestone, write:
- Widget tests for layout branching (mobile vs. the desktop stub) and empty
  states (no favourites, 0 open tabs).
- Unit tests for view models / usecases with a fake `StorageRepository`.

## 8. What "done" means per feature

A feature is done when: it matches the relevant SRS section, it uses only
the abstractions in §3, it has at least one test, and it does not add any
platform-specific code outside `data/datasources/android/`.

## 9. When in doubt

Prefer the smaller, more isolated change. If a requirement seems to require
touching more than one layer at once, stop and flag it instead of
refactoring broadly in the same pass.

## Settings Panel Behavior

The Settings panel is a slide-over overlay, not a full-screen route push.
This is a deliberate deviation beyond what the SRS specifies (it only says
"Opened using the Hamburger Menu") — treat these details as binding:

- Anchored left, 80% width, 100% height, ~70-75% opaque background so the
  underlying Home tab / active foreground tab is dimly visible through it
  (scrim + panel combined, not literally transparent content).
- Slides in/out with animation, not instant show/hide.
- Hamburger icon (Top App Bar, left) toggles to an X while the panel is
  open, and back to hamburger when it closes. This is a separate state from
  the Selection Mode back-arrow/more-options swap — the two icon states
  must never conflict. If both could apply at once, Selection Mode wins
  (exit Selection Mode does not need to touch the Settings panel state).
- Dismiss by: tapping the X, tapping the remaining 20% area outside the
  panel, or the Android back button (intercepted so it closes the panel
  instead of falling through to GoRouter's back stack).
- Both open/closed state and the icon must be driven from a single Riverpod
  provider (e.g. `settingsPanelOpenProvider`) read by both the app bar and
  the panel widget — never duplicate this as separate local state in two
  widgets. (This is the same bug class as the tab-header desync fixed
  earlier — one source of truth, multiple widgets read it.)
- This 80%-width-overlay approach is mobile-specific. When the desktop
  shell (§4) is built out, do not assume this same overlay pattern applies
  there without an explicit decision — desktop layouts typically favor a
  persistent settings panel/dialog rather than a slide-over.