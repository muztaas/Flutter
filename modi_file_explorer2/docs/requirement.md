# Flutter File Manager Application - Software Requirements Specification (SRS)

## Project Overview

Develop a modern cross-platform File Manager application using **Flutter**.

### Current Target Platforms

* Android
* Windows
* Web

### Future Platforms

* iOS
* macOS
* Linux

The project must be designed with scalability in mind so future platform support requires minimal code changes.

---

# General Design Requirements

## Theme

### Light Theme (Default)

* White background
* Blue primary color
* Modern Material 3 design
* Rounded corners
* Soft shadows
* Clean spacing

### Dark Theme

* Black background
* Blue accent color
* Same layout as Light Theme

### Future Features

Users will later be able to:

* Choose custom accent colors
* Choose custom background colors
* Choose custom background images

---

# Text Size

Default:

* Medium

Future options:

* Small
* Medium
* Large

---

# UI Guidelines

Use:

* Material Design 3
* Consistent padding
* Consistent margins
* Rounded cards
* Smooth animations
* Responsive layouts
* Scrollbars where appropriate

The application must adapt automatically based on screen size.

---

# Responsive Layout

---

## Mobile Layout

Default tabs:

Tab 1

* Home Page

Tab 2

* Internal Storage

If additional internal storage exists:

Tab 3

* Second Internal Storage

If SD cards exist:

Next tabs

* SD Card 1
* SD Card 2

External devices (USB, OTG, Network Storage, etc.) should **NOT** open automatically.

They can only be opened manually from Home Page.

Maximum open tabs:

22

---

## Desktop / Large Screen Layout

Desktop uses three panels.

```
+------------+----------------------+-------------+
|            |                      |             |
| Home       | Active Storage Tab   | Open Tabs   |
| Panel      |                      | Panel       |
|            |                      |             |
+------------+----------------------+-------------+
```

---

### Left Panel

Always displays Home Page.

---

### Center Panel

Shows the currently selected storage.

Default:

* D Drive

If D does not exist:

* C Drive

Otherwise:

* First available drive.

---

### Right Panel

Displays all opened tabs.

Each tab displays:

* Storage name
* Current path
* Optional metadata

Future configurable metadata:

* Folder size
* Last modified
* Access permissions
* Thumbnail preview

---

# Home Page

The Home Page consists of three vertically stacked sections.

```
---------------------------------------
| Category Cards                     |
---------------------------------------
| Quick Access + Recent              |
---------------------------------------
| Available Storage                  |
---------------------------------------
```

---

# Section 1 - Category Cards

Height:

20–30%

Horizontal scrolling.

Categories include:

* Downloads
* Documents
* Images
* Videos
* Audio

Future categories may be added.

Each card displays:

* Icon
* Category name
* Storage occupied

Example:

Downloads

```
4.2 GB
```

Storage units:

Automatically display:

* MB
* GB
* TB

depending on size.

Cards occupy roughly:

35–40% width

Initially show:

* 2 full cards
* Small portion of next cards

to indicate horizontal scrolling.

---

# Section 2 - Quick Access & Recent

Height:

30–40%

Contains:

1. Recent Files
2. Favourite (Quick Access) folders

Quick Access folders must persist after application restart.

---

## Empty State

If no favourites exist:

```
Recent

No favourites
```

---

## Filled State

Display:

Recent

Favourite Folder 1

Favourite Folder 2

...

If items exceed available height:

* Vertical scrolling
* Visible scrollbar

---

Each item displays:

Left

* Folder name

Center

* Full path

Right

Configurable metadata

Default:

* Modified date

Future options:

* Folder size
* Modified date
* Both

---

Long text

Folder names and paths should automatically scroll horizontally inside their own area without affecting other rows.

---

Edit Mode

Allow:

* Reorder Recent
* Reorder Quick Access
* Move items up/down

---

# Section 3 - Available Storage

Height:

30–35%

Displays all detected storage devices.

Examples:

Android

* Internal Storage
* SD Card

Windows

* C
* D
* E
* USB Drive

Each storage is displayed as a card.

Card displays:

* Storage name
* Used space
* Total space

Example:

```
Internal Storage

125 GB / 256 GB
```

Layout:

* 1-2 cards per row for small devices, for larger screen, 3-8 if present
* One card occupies only required width if it is the only item
* Vertical scrolling if necessary
* in larger screen, if only 2 storage, then only show the 2 from left side and leave right side empty

Clicking a storage opens a new Storage Tab.

---

# Storage Tab

Every storage is shown inside its own tab.

---

## Default Tabs

Mobile

Automatically open:

Internal Storage

Desktop

Automatically open:

Each internal drive

Example:

C

D

E

External storage is opened only when selected by the user.

---

Maximum tabs:

22

Tabs can be closed and can also have 0 open tab, showing empty space. 
---

# Storage Usage Indicator

Top of page.

Height:

5%

Displays a horizontal usage bar.

Example:

```
████████████░░░░░░░░

60% Used
40% Free
```

Theme color indicates used space.

Unused space is grey.

---

# Top App Bar

Height:

10%

Contains:

Left

Navigation icon

Center

Current path

Right

Search icon

---

## Path Display

If path exceeds available width:

Automatically scroll horizontally.

---

## Default Icons

Left

Hamburger menu

Right

Search

---

# Selection Mode

Triggered by:

Desktop

Right-click

Mobile

Long press (1.5 seconds)

---

After selection:

Left icon becomes

Back Arrow

Right icon becomes

More Options

---

Search icon disappears.

---

Selection supports:

Single selection

Multiple selection

Checkbox appears beside each item.

Selected items are checked.

---

Leaving selection mode restores:

Hamburger

Search

---

# File List

Default Mobile View

Vertical list.

Each row:

* Icon
* Name
* Modified date
* Approximate size

Supported icons:

Folder

PDF

Image

Video

Audio

Archive

Unknown

---

Desktop Default View

Grid

Approximately:

3–6 items per row

depending on screen width.

---

Future View Modes

* Compact List
* Detailed List
* Grid (2 columns)
* Grid (3 columns)
* Grid (Large Icons)

These will be configurable later.

---

# Storage Navigation

Storage tabs can be switched by swiping or scrolling horizontally on the top tab/header area.

Order:

Home

↓

Storage Tabs

Example

Home

C

D

USB

---

The same folder/path may be opened in multiple tabs.

Only one selected folder may be opened in a new tab at a time.

---

# File Context Menu

Available in selection mode.

Current actions:

* Rename
* Delete
* Copy
* Properties / Details

Additional actions will be added later.

---

# Settings

Opened using the Hamburger Menu.

Organize settings into expandable sections.

Examples:

Appearance

* Theme
* Accent Color
* Background

Files

* Show Hidden Files
* Default View Mode

Storage

* Default Startup Drive and Drives to open/not-open at startup

Future settings will be added without changing current structure.

---

# Future Features

## Multi-Path Storage Tab

Desktop and Tablet only.

One storage tab can display:

* Two folders
* Three folders

simultaneously using split view.

---

## Custom Background

Allow users to choose:

* Solid color
* Local image

as application background.

---

# Technical Requirements

## Flutter Architecture

Use:

* Clean Architecture
* MVVM (recommended)
* Repository Pattern
* Dependency Injection

---

## State Management

Recommended:

Riverpod

(or another scalable state management solution)

---

## Navigation

Use:

Navigator 2.0 or GoRouter

Tab management must support dynamic creation and removal of tabs.

---

## Persistence

Persist using local storage:

* Theme
* Settings
* Quick Access
* Startup drive
* Open tabs 

---

## Platform Support

Implement platform abstraction for:

* Android Storage
* Windows Drives
* Web File Access

Future implementations:

* iOS
* macOS
* Linux

should require only platform-specific service implementations.

---

# Non-Functional Requirements

* Responsive UI
* Fast scrolling
* Smooth animations
* Lazy loading for directories
* Efficient handling of folders containing thousands of files
* Modular architecture
* Easy to extend
* Minimal platform-specific code
* Material 3 compliance
* Accessibility support
* Future localization support

---

# Development Priority

## Phase 1

* Responsive layouts
* Home Page
* Storage Tabs
* File browsing
* Search
* Quick Access
* Recent Files
* Settings
* Theme support

## Phase 2

* Multiple layouts
* File operations
* Split view
* Multi-tab improvements
* Persistent open tabs

## Phase 3

* Background customization
* Advanced settings
* Plugin architecture
* Additional platform support
* Performance optimizations
