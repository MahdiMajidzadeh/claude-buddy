# Claude Usage

A tiny native macOS **menu bar app** that shows your local Claude Code token usage — session, daily, and weekly — with per-category breakdowns and progress against limits you set.

It works **entirely offline**: it reads the transcript files Claude Code already writes to `~/.claude/projects/`, parses the token counts, and never makes a network request or touches a credential.

---

## What it shows

Click the gauge icon in the menu bar to open the panel.

- **Menu bar label** — your session usage as a percent of your session limit (e.g. `47%`).
- **Session (5h window)** — usage in the current rolling 5-hour block (the way Claude's session limit actually resets), with a live countdown to reset.
- **This week** — rolling 7-day usage.
- **Today** — usage since local midnight.

Each window breaks usage into **Input / Output / Cache write / Cache read**, shown as labeled token counts plus a proportional stacked bar. The Session and Week rows also show a **percent badge and progress bar** (green → orange at 70% → red at 90%) against the limits you configure.

### Settings

Expand **Settings** in the panel to control:

- **Percent of** — whether percentages are based on **Input+Output** (real consumption) or **All tokens** (includes cache reads).
- **Session limit (5h)** and **Weekly limit** — your own ceilings, in **millions of tokens**.

Settings persist across launches. There's also a **Launch at login** toggle.

---

## Requirements

- macOS 13 (Ventura) or later
- The Swift toolchain (`swiftc`) — install with the Xcode Command Line Tools:
  ```sh
  xcode-select --install
  ```
- Claude Code, which populates `~/.claude/projects/**/*.jsonl`

---

## Build & install

```sh
./build.sh
```

This compiles [Sources/main.swift](Sources/main.swift) into `build/Claude Usage.app` (targeting your machine's architecture) and ad-hoc signs it so macOS will launch it locally.

To install it permanently:

```sh
cp -R "build/Claude Usage.app" /Applications/
open "/Applications/Claude Usage.app"
```

Then open the panel and flip on **Launch at login** if you want it to start automatically. The first time you enable it, macOS may ask you to approve the login item in **System Settings → General → Login Items**.

---

## How it works

- **Data source** — on a 60-second timer, the app scans `~/.claude/projects/**/*.jsonl` (only files modified in the last 8 days, for speed), decodes each `assistant` message's `usage` block, and dedupes by message ID.
- **5-hour blocks** — entries are grouped into 5-hour blocks anchored to the first activity, mirroring how Claude's session limit resets. The active block is the one containing the current time.
- **Daily / weekly** — simple rolling sums since local midnight and over the last 7 days.

Everything runs on your machine. No API key, no login, no outbound connection.

---

## Important: this is not your plan's official usage

The percentage shown here is measured against **limits you type in** — it is **not** the "% of plan" figure the Claude app shows. That official number is computed server-side from a weighted measure and is **not available anywhere on your machine**, so this app can't reproduce it.

Two things to keep in mind:

- **Cache reads dominate raw totals.** Your conversation context is re-read every turn, so `Cache read` can be ~100× your actual input+output. The **Input+Output** metric is the more meaningful "real work" number; **All tokens** is the raw throughput.
- **Set your limits to match your chosen metric.** Defaults (1M session / 5M weekly) suit **Input+Output**. If you switch to **All tokens**, raise the limits substantially or the bars will peg at 100%.

Treat this as a **local token-activity monitor**, not a mirror of your subscription limits.

---

## Project layout

```
.
├── Sources/main.swift   # the entire app (SwiftUI MenuBarExtra)
├── build.sh             # compiles + bundles + ad-hoc signs Claude Usage.app
├── .gitignore
└── README.md
```

There's no Xcode project — the app is a single Swift file compiled directly with `swiftc`. To make changes, edit [Sources/main.swift](Sources/main.swift) and re-run `./build.sh`.
