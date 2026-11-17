# Helm design kit

## Feel

Terminal craft (D-13a, look B): a monospaced, neutral grey near-black look. SF Mono for every role, flat fills, 1 pt dividers, 3 pt corners, no shadows and no blur, source-case labels (title case for buttons, see "Capitalisation rule"), and a lime accent. Colour is rare, so a cyan dot (waits on you) is seen at once.

Dark only (D-07). There is no light mode. The terminal keeps the user's own terminal colours.

## Capitalisation rule

Replaces D-13a's lower-case labels (phase 2, D-02). Buttons show their source case, so the string in code is the string on screen.

- Title case for buttons, menu titles and items, tab names, screen names and sheet titles. Capitalise the first word, the last word and each word between, except articles, coordinating conjunctions and prepositions of 4 letters or fewer ("Remove from List", "Initialize and Start"). A word after a colon is capitalised ("Next: Plan").
- Sentence case for everything else: headers, notes, reasons and help text.
- Leave tokens that are identifiers (digits, `-`, `/`, interpolation), acronyms and product names as they are ("OK", "VS Code"). Accessibility labels are spoken text and are out of the rule.
- `CapitalisationRuleTests` scans the source for literal button, menu and title strings and fails on a break. Strings built in code (tab arrays, primary titles) are checked by hand.

## Tokens

Three layers. Only the meaning layer reads the palette. Parts read the meaning layer and the scales. All of it lives in `Sources/OrchestratorGUI/DesignKit/Tokens.swift`.

### Palette

Raw colours, named by hue and step. Nothing outside `Tokens.swift` reads these names.

| Name | Hex | Used as |
| --- | --- | --- |
| black | 0x000000 | terminal background |
| white | 0xFFFFFF | terminal text |
| gray950 | 0x0E0E0F | ground, text on a light accent fill |
| gray900 | 0x121213 | sidebar, header and bars |
| gray850 | 0x161617 | node and card fill |
| gray825 | 0x1C1C1E | selected row |
| gray800 | 0x212123 | dot grid |
| gray750 | 0x2A2A2C | border |
| gray700 | 0x48484C | borderStrong, tree lines |
| gray500 | 0x9A9A9E | muted (D-13 "secondary text") |
| gray300 | 0xC9C9CC | textSecondary (D-13 "muted text") |
| gray100 | 0xE6E6E8 | text |
| gray600 | 0x6B727B | stalled |
| gray400 | 0x9AA3AD | merged |
| cyan400 | 0x3CC8D8 | waiting |
| blue400 | 0x5AA2FF | running |
| blueFill | 0x111825 | running node card fill |
| cyanFill | 0x101C21 | waiting node card fill |
| lime400 | 0xC5E478 | the default accent fill and text |
| blue600 | 0x2F6CC0 | the blue accent fill |
| ansi0 to ansi15 | 0x14191E 0xB43C2A 0x00C200 0xC7C400 0x2744C7 0xC040BE 0x00C5C7 0xC7C7C7 0x686868 0xDD7975 0x58E790 0xECE100 0xA7ABF2 0xE17EE1 0x60FDFF 0xFFFFFF | terminal palette (iTerm Default profile) |

Accent shades (D-08) are also in the palette. Each accent has a fill shade (step 600), a text shade for dark mode (step 300) and a flag that says if text on the fill is dark. The list: lime (default), blue, indigo, purple, pink, red, yellow, green, mint, graphite. Lime has one shade, because it is already light: its fill and its text are both lime400. Lime, yellow and mint use dark text (gray950) on the fill. The other accents keep white text, because their 600 fills reach less than 4.5:1 with dark text. Orange is not in the list, because D-07 keeps it free. Cyan is not in the list, because cyan means "waits on you".

### Meaning

| Token | Palette | Used for |
| --- | --- | --- |
| Ink.background | gray950 | window background, tree canvas |
| Ink.sidebar, Ink.header | gray900 | sidebar, header bar |
| Ink.panel | gray850 | cards, buttons at rest, notices |
| Ink.selectedRow | gray825 | the selected sidebar row |
| Ink.dotGrid | gray800 | the dots behind the tree |
| Ink.runningFill | blueFill | running node card fill |
| Ink.waitingFill | cyanFill | waiting node card fill |
| Ink.terminal | black | terminal background |
| Ink.border | gray750 | hairlines, card borders |
| Ink.borderStrong | gray700 | tree lines, button pressed |
| Ink.text | gray100 | main text |
| Ink.textSecondary | gray300 | button text, secondary text |
| Ink.muted | gray500 | meta text, notes |
| Ink.waiting | cyan400 | only what waits on the user |
| Ink.running | blue400 | a running node |
| Ink.merged | gray400 | a merged node |
| Ink.stalled | gray600 | a stalled node |
| Ink.syntaxKeyword | purple300 | editor keywords |
| Ink.syntaxString | green300 | editor strings and code spans |
| Ink.syntaxComment | gray500 | editor comments |
| Ink.syntaxNumber | yellow300 | editor numbers |
| Ink.syntaxKey | blue300 | editor keys (JSON, YAML) |
| Ink.syntaxHeading | pink300 | editor Markdown headings |
| Ink.accent.fill | accent fill shade | primary button, active state |
| Ink.accent.text | accent text shade | accent-coloured text |
| Ink.accent.onAccent | white or gray950 | text and symbols on an accent fill, never fixed white |

Parts read the accent from the environment value `kitAccent`, which `.kitAccentRoot()` sets on the root view of each scene from the stored choice. `Ink.accent` is the default lime. The choice is stored in UserDefaults under `accentChoice`, and `Ink.swatch(for:)` is the only place that turns a choice into colours.

The accent choice changes only the three accent tokens. Status colours, text, surfaces and borders never change with it.

### Metric

| Token | Value | Why |
| --- | --- | --- |
| corner | 3 | every card, button and row |
| selectedEdge | 2 | accent left edge of the selected sidebar row |
| dotPitch, dotSize | 16, 2 | the dot grid behind the tree |
| splitter | 5 | width of the sidebar splitter, inherited from v1 |
| headerBar | 36 | header bar height, inherited from v1 |
| dispatchBar | 30 | Dispatch bar height, inherited from v1 |
| hairline | 1 | borders and dividers |
| statusDot | 8 | status dot and alert dot |
| windowMinWidth, windowMinHeight | 760, 480 | minimum size of the main window |

### Spacing

Scale from the layout grid: 4, 8, 12, 16, 20, 24, 32 (names xs, sm, md, lg, xl, xxl, xxxl). `Space.none` is 0, for a stack with no gap: the design gate flags a bare number in `spacing:` or a size. Allowed raw numbers in views: 0, 1, 2 and multiples of 4 only through these names. Sheet widths: 360, 480, 640.

### Motion

| Intent | Curve | Used for |
| --- | --- | --- |
| hover | ease out 0.12 s | hover fills |
| press | ease out 0.08 s | pressed fills |
| reveal | ease in out 0.2 s | a panel or banner that appears |
| flow | linear, repeating | the dash flow on a line that touches an active node: dashes of 4 and gaps of 4, one cycle per second |

Every intent except flow resolves to no animation when Reduce Motion is on. Active tree lines flow under Reduce Motion too (user decision 2026-11-03).

## Type

Roles, never sizes. Every role is SF Mono (the `.monospaced` design), at 12 or 13 pt (D-13).

Exception (D-13a): conversation text (transcript rows, Markdown in replies and code blocks, the message box, the editor text and its line numbers) follows the family and size a person picks in Settings (default SF Mono 13 pt). A role there is the setting plus its offset from 13 pt, so label and meta stay 1 pt under body. All other roles stay SF Mono at 12 or 13 pt.

| Role | Size | Weight | Used for |
| --- | --- | --- | --- |
| title | 13 | semibold | sheet and window titles, node titles |
| body | 13 | regular | row titles, empty states |
| label | 12 | regular | buttons, notes, notices |
| section | 12 | semibold | group headings inside a screen |
| meta | 12 | regular | ids, status text, footer line, hold card state line |

Views set fonts only through `.kitType(...)`.

## Icons

Source: SF Symbols, wrapped in `KitIcon` (one case per symbol the app uses). Views name a `KitIcon`, never an SF Symbol string. Size 12, one weight (regular), filled form for a selected row only. The icon sits beside its label with `Space.xs` between.

## Window

Title bar: transparent, native traffic lights (D-09). Sheets, alerts, the Settings window, popovers and the menu bar stay native. Minimum window size 760 by 480. The sidebar stays a custom column with a splitter, not a `NavigationSplitView`.

## Liquid Glass

Probe, macOS 27.2 SDK, `SwiftUICore.framework/.../SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface` (the SwiftUI interface re-exports it): `glassEffect(_:in:)` exists (line 3085), `GlassEffectContainer` exists (line 11708), `glassEffectID(_:in:)` exists (line 22766).

Which parts use glass: none. The sidebar rows, node cards, hold cards and notices are content, so they get no glass. The header bar and the Dispatch bar are flat custom chrome in the app's own identity (D-09). If a later part needs glass, it goes only on the navigation and control layer, and never on glass.

## Accessibility and system behaviour

- Reduce Motion: every motion intent except flow resolves to no animation.
- Reduce Transparency: the kit uses opaque fills only, so nothing changes.
- Inactive window: the selected row of the sidebar dims its fill and border when the window is inactive (`appearsActive`).
- Every part is a real control (`Button` with a `ButtonStyle`), so keyboard focus and VoiceOver work. The focus ring is a 2 pt accent outline.

## Parts

States use vocabulary: default, hover, pressed, selected, inactive (selected row in an inactive window), disabled, focus. A part lists only those that apply. Every part takes an optional forced state, so the gallery (`screenshots/kit-gallery.png`) and `KitGalleryRenderTests` can draw states an offscreen view cannot reach. The test requires each listed state to draw differently from default.

The focus ring is 2 pt wide, in accent.text, drawn just outside the edge so it also shows on an accent fill.

### Standard button

Anatomy: label (label role, one line, never wraps, shown as written, so a call site writes "Dispatch" and the button shows "Dispatch"; the capitalisation rule applies to the string, and a text transform no longer changes it; this replaces D-13a's lower-case rule), optional `KitIcon` before it. Size: height 24, horizontal padding 8, radius 3, border 1. Native alerts, `NSAlert` and the title bar are not kit buttons and keep their own text (D-09).
Fill: panel at default, border colour on hover, borderStrong when pressed. Text: textSecondary. Border: border.
States: default, hover, pressed, disabled (40% opacity, built in), focus.
There is no selected form. The selected form of `FlatButtonStyle` exists only for `DockSegments`, which Plan 3 deletes.

### Primary button

Anatomy and size: as the standard button, with labels shown as written. Fill: accent.fill (lime by default). Text: accent.onAccent (dark on lime). No border.
Hover lightens the fill to 90%, pressed to 80%.
States: default, hover, pressed, disabled (40% opacity, built in), focus.

The top band (the Dispatch bar) holds an accent "❯" glyph (body role, accent.text, hidden from VoiceOver), Back and Close. At the right edge it shows "<n> waiting" in the waiting colour and "<n> running" in the running colour (label role, 8 apart, waiting first). A count of 0 is left out. The counts come from the same tree data as the node cards. Dispatch lives in the prompt bar under the tree or terminal: it sends typed text to the orchestrator and opens the Dispatch sheet when the field is empty. Back reads "Back" (a chevron and the label); its accessibility label stays "Back". The New Project button in the sidebar reads "+ New Project".

### Header bar

Anatomy: one content slot (leading content, a Spacer, trailing content). Size: height 36, horizontal padding 12, hairline at the bottom. Fill: header. Text: body role in text colour.
States: default, inactive (the content dims to 60% while the window is not active). Secondary text (a waiting cue) uses waiting.

### Prompt bar

Anatomy: the accent "❯" (body role, accent.text, hidden from VoiceOver), a one-line plain text field that fills the free width (hint "dispatch a task to a new worker" in muted, typed text in text colour, body role, accessibility label "Task to dispatch") and a primary button with the send icon that reads "dispatch". Size: height 36 (`Metric.headerBar`), horizontal padding 12, spacing 8, full width, hairline at the top. Fill: header.
States: default, inactive (the content dims to 60% while the window is not active). It reads the disabled state from the environment, so the host turns the whole bar off with `.disabled`.
The part only reports the action: the button and Return in the field both call one closure. It does not open a sheet, send anything or clear the text. The host does those.

### Footer line

Anatomy: lines of meta text in monospaced form, one child view per line. Size: padding 8, hairline at the top, full width. Colour: textSecondary.
States: default.

### Note

Anatomy: one muted label (label role) in a small box. Size: padding 8 across and 4 down, radius 3, border 1. Fill: panel. Colour: muted.
States: default.

### Notice

Anatomy: centred muted body text that fills the space of a screen with nothing to show. No fill, no border. An optional action (a button) sits under the text, 8 below it (Session ended with Reconnect).
States: default.

### Dot grid

Anatomy: `KitDotGrid`, one `Canvas` that fills its space with square dots (`Metric.dotSize` 2) every `Metric.dotPitch` (16) in `Ink.dotGrid`. It has no fill of its own: the worker tree draws it over `Ink.background`. No timeline and no animation. Hidden from VoiceOver.
Tree lines: a line that does not flow draws in `Ink.borderStrong` (#48484C), for both hierarchy and dependency edges. A line that touches an active node flows as 4/4 dashes in `Ink.running`. Stroke width is `Metric.edgeWidth`.
States: default.

### Sidebar row

Anatomy: title (body role, monospaced) over id (meta role, monospaced), optional alert dot at the trailing edge. It is a `Button` with its own style. Size: horizontal padding 8, vertical padding 4, radius 3, full width.
Fill: none at default, border colour on hover, borderStrong when pressed, selectedRow (#1C1C1E) when selected, with a 2 pt left edge in accent.fill (`Metric.selectedEdge`) and no outline. The selected title turns semibold.
States: default, hover, pressed, selected, inactive (selected in an inactive window: fill and edge dim to 60%), disabled (40% opacity), focus.

### Dormant sidebar row

Anatomy: title (body role, monospaced) over id (meta role, monospaced), then one trailing Restore button (kit button style). The row is a plain view, not a `Button`, so it cannot be selected. The caller attaches a context menu ("Remove from list"). Size: horizontal padding 8, vertical padding 4, radius 3, full width, the same as the sidebar row.
Fill: none. The title and id draw at disabled opacity (40%) to say the project has no live session. The button does not dim.
States: default, restoring (the button is disabled and reads "Restoring").

### Splitter

Anatomy: a vertical line, the drag handle between the sidebar and the main area. `KitSplitter` binds the width of the pane before it and a range to clamp it. Size: width 5 (the splitter metric), full height.
Fill: border colour at default, borderStrong on hover. Hover also shows the resize cursor.
States: default, hover.

### Alert dot

A filled circle, size 8, waiting colour. VoiceOver reads "Needs attention". It shows when the project has an alert.
States: default.

### Status dot

A filled circle, size 8. Colour by status: waiting is cyan, running is blue, finished is merged gray, stalled is stalled gray. VoiceOver skips it, because the status text carries the word.
States: default.

### Status text

The status word, meta role, monospaced. Colour matches the status dot.
States: default.

### Node card

Anatomy: title (title role, monospaced, up to 2 lines, centred), optional task title (meta role, muted), the status word in its status colour, optional info lines (meta role, muted, middle truncation). Size: radius 3, border 1, horizontal padding 8; the card size comes from the caller (`TreeLayout`). The card carries no gesture: the tree puts its own tap and drag on it and passes the pressed state while the press is down. The resize handle belongs to the tree.
Fill: a running card is `Ink.runningFill` and a waiting card is `Ink.waitingFill`; a card with no status, a finished card and a stalled card are plain panel; border colour when pressed. No shadow. Border: `Ink.running` on a running card and `Ink.waiting` on a waiting card, at default, hover and pressed (the colour is the signal); border at default and borderStrong on hover and pressed for every other card.
States: default, hover, pressed, focus. No selected state: a selected node does not exist in the tree after Plan 3.

### Hold card shell

Anatomy: a command slot, a state line (meta role, monospaced), a decision slot and an outcome line (up to 3 lines). The decision slot holds the Approve and Deny buttons in a `KitButtonPair`: side by side when the width allows, stacked when not. Size: radius 3, padding 8, spacing 4 between parts. Fill: panel. Border: waiting.
The shell has no state of its own. Deciding is the shell with the buttons disabled, and decided is the shell with the outcome line and no buttons. The gallery shows both.

### Sheet frame

Anatomy: title (title role), content slot, optional failure line (meta role, monospaced, selectable), optional progress row (small spinner and meta text), and a trailing row with Cancel before the primary action. Escape runs Cancel and Return runs the primary action. Size: width 360, 480 or 640, page margin 20, spacing 12 between blocks. Fill: panel. Controls in the content take their height from `.controlSize`. Sheets are native (D-09), so the frame only fills and pads their content. A sheet whose rows carry their own action has no primary button: the trailing row then holds the cancel button alone, titled "Close". The cancel button is disabled while a run cannot be abandoned (Merge, Teardown). Notes inside a sheet (pull request or review text) use the footer line part. The Dispatch sheet uses width 640, because a row holds a title of up to 2 lines, the status, the priority and the Pick button.
States: default.
The Root session alert and the "Initialize a git repository?" confirmation dialog of the New project screen are drawn by the system outside any hosting view, so they have no offscreen render.

### Stage tab bar

Anatomy: a row of text tabs (label role) at the left, a gap, then a second group set apart at the right end (Run record, Milestone). One tab is selected. Size: bar height 36 (`Metric.headerBar`), tab height 24, horizontal padding 8, radius 3, hairline at the bottom. Fill: none at default, border colour on hover, borderStrong when pressed, selectedRow when selected with a 2 pt accent.fill underline and semibold text. Text: textSecondary, text when selected. Border: none.
States: default, hover, pressed, selected, disabled (40% opacity), focus.

### Phase picker

Anatomy: one standard button (`KitButtonStyle`, label as written) showing "phase <n>  <name>  ▾" that opens a menu listing the phases. Size, fill, border: as the standard button.
States: default, hover, pressed, disabled, focus.

### Stage action row

Anatomy: one primary button, an optional reason line (meta role, textSecondary) while the primary is off, secondary standard buttons, a gap, then one menu button whose title the caller sets ("Suggested" or an overflow title). Size: horizontal padding 12, vertical padding 8. Fill and border: those of the primary and standard buttons.
States: default, hover, pressed, disabled (primary off with its reason), focus.

## Alerts

The 2 SwiftUI `.alert` modifiers in `ContentView` ("Close <title>?" and "Could not close <title>") are system alerts (D-09). The kit sets no colour, font or size on them: they take only wording and button roles. A SwiftUI `.alert` is drawn by the system outside any hosting view, so it has no offscreen render. The live check in the phase review is the evidence (Task 7 of Plan 6 captures the Close confirm alert from a test copy of the app).

Audit against `~/.claude/skills/mac-design/design-rules.md` and `SKILL.md`. No code change was needed.

- Rule 22, Escape cancels: the Cancel button has `role: .cancel`, so the system binds Escape to it. Pass.
- Rule 22, Return is the default action: the system picks the default button. A destructive button is not made the default by the system. Unverified here: the live check shows which button is highlighted.
- Rule 69, Command-Period cancels an alert: the system alert handles it. Pass by construction, not tested.
- Rules 25 and 43, Undo instead of a confirmation: not met on purpose. Close stops the tmux session and its live workers, and a stopped process cannot be brought back, so no Undo exists. The alert names the effect in its message (`CloseRequest.message`: the session and the live workers stop, worktrees and branches stay).
- Destructive role: "Close" has `role: .destructive`. Pass.
- Button set: "Close" and "Cancel" on the confirm alert, and a single "OK" on the failure alert (nothing to choose, so no role). Pass.
- Plain message text: both messages are `Text` of a model string with no font, colour or style modifier. Pass.
- Rules 13 and 28, tint and colour: no tint or fixed colour is set on either alert. Pass.
- Rule 51, nothing focused when a window opens: not applicable to a system alert.

### Evidence for the SwiftUI alerts and dialogs

- Close confirm alert: `screenshots/screen-10-close-confirm.png`, captured live from a scratch test copy of the app (bundle id `io.github.whoreallyknowsanything.helm.capture`, a private tmux socket, a fixture project) with the agent-desktop skill. It shows the system alert "Close proj-a?" with the Cancel and Close buttons. Only Cancel was pressed.
- No PNG for "Could not close <title>": `closer.failure` is set only after `CloseModel.confirm` fails, and that call runs only after the destructive Close button, which the capture rules forbid.
- No PNG for the Root session alert: it shows `rootError`, set after `NewProjectModel.startRoot()` runs `ProjectLauncher.launchRoot`. That runs the orchestrator repo's real `launch-claude.sh` (`ProjectLauncher.launcherPath`, a fixed path) in `NSHomeDirectory()`, which starts a real session in the home folder and cannot be isolated.
- No PNG for the "Initialize a git repository?" confirmation dialog: it needs `folder` set, which only `NewProjectView.choose()` does through an `NSOpenPanel`, and the confirming button of that panel is not Cancel.
- The 3 parts without a PNG are human live checks in the phase-end review (user decision 2026-11-02).

### Quit alerts

The Quit prompt and the "Some projects could not be stopped" alert are `NSAlert` (native, D-09). `QuitDialog.makeAskAlert` and `QuitDialog.makeFailureAlert` build them without showing them, so a test can read them. The only SwiftUI part is the accessory list `QuitChoices`: kit spacing (`Space.sm` between rows, `Space.xs` around), the body type role and the native `Toggle` tinted by the accent (`.kitAccentRoot()` on the hosting view). It sets no text colour, so the toggles follow the system alert appearance.

Audit of the two `NSAlert` setups. No change to wording, buttons or style was needed.

- Button titles and order: Quit prompt "Quit", "Cancel"; failure alert "OK". The render test asserts both lists.
- First button is the default (Return): "Quit" for the prompt, "OK" for the failure alert. AppKit gives Escape to a button titled "Cancel".
- Alert style: both `.warning`. The prompt uses the `NSAlert` default and the failure alert sets it. The render test asserts both.
- Undo (rules 25 and 43): not offered on purpose. Stopping a project cannot be undone. The prompt lists each project with its own checkbox, and an unchecked project keeps running in tmux.

Evidence: `screenshots/screen-11-quit-alert.png` is the 2 alerts laid out in their own windows (`NSAlert.layout()`, then `cacheDisplay` of the window content view), stacked in one image. The text and controls draw. The window backdrop (vibrancy) draws black offscreen, so judge colour in the live app, not in the PNG.

## Settings window

Layout chosen from `~/.claude/skills/mac-design/settings.md`: one pane, no tabs. The skill adds a tab only for a topic with more than about 3 rows. The terminal topic has 9 rows, and the accent topic has 1, so a second tab would break that rule. The window is a `Settings` scene with `.windowResizability(.contentSize)`. Its content is a grouped `Form` (`.formStyle(.grouped)`) of `Metric.settingsWidth` (520) points, with the height of its content (`fixedSize` vertically).

- Section "Terminal": Font `Picker`, Size `Stepper`, the 16 ANSI colour wells (the index label takes the meta type role), Background, Foreground and Cursor `ColorPicker`, Cursor shape `Picker`, Blink `Toggle`, the 2 preset buttons (kit buttons) and the preset failure line. All native controls and all labels as before. They are tinted by the accent.
- Section "Accent": one swatch per accent, in `AccentChoice` order (lime first, the default). The current one has a 2 pt ring in the text colour, the others a hairline border. Each swatch has its name as help text and accessibility label, and the current one has the selected trait. A click writes the choice through `AccentStore`, and `@AppStorage` redraws every window that has `.kitAccentRoot()`, so the main window changes at once. The `Settings` scene has `.kitAccentRoot()` of its own.
- The window keeps `.preferredColorScheme(.dark)` and the `Ink.background` fill behind the form.
- Not done: the template modifiers `.fitsContent()` and `.noInitialFocus()` of settings.md do not exist in this app.
- Evidence: `screenshots/screen-12-settings.png`, rendered offscreen from a throwaway `UserDefaults` suite.
