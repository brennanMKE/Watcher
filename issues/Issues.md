# Watcher

A Swift package for monitoring folders and files on Apple platforms. Wraps `FSEventStream` (folder watching, macOS) and `DispatchSource` (single-file watching, all Apple platforms) behind a single `Session` actor that exposes events as an `AsyncThrowingStream`. Issues here cover correctness bugs, API contract violations, concurrency / lifetime problems, platform-specific regressions, and gaps against the public contract documented in `PRD.md`.

This file is the local guide for managing issues in this project. The companion Mac app (Issues.app) watches the `issues/` folder and renders the current state. Markdown files are the source of truth — there is no JSON, generated artifact, or index to keep in sync.

## Folder layout

```
issues/
├── Issues.md          # this file
├── 0001.md            # one file per issue
├── 0001/              # optional sibling folder for screenshots, crash logs, etc.
│   └── screenshot.png
├── 0002.md
└── …
```

## Status values

| File value | Display name | Meaning |
|---|---|---|
| `open` | Open | Filed but not yet started |
| `in-progress` | In Progress | Actively being worked on |
| `resolved` | Resolved | Work is done; awaiting user confirmation |
| `closed` | Closed | User has confirmed the fix |
| `wontfix` | Won't Fix | Acknowledged but won't be addressed |

Use the **file value** (lowercase, hyphenated) in the issue's metadata table. The Mac app converts to the display name when rendering.

## Critical rule: never close without explicit confirmation

The most important rule of this workflow: an issue must **never** be marked `resolved`, `closed`, or `wontfix` based on inference. Only when the user has said so in plain language. Specifically, do not infer resolution from:

- a code change you (or a subagent) just made
- a commit message
- the filing of a related issue
- the user saying "thanks, that looks better"

Leave status at `open` (or `in-progress` if work has started) until the user confirms in words like "close this", "this is fixed", "mark resolved", or "won't fix". When in doubt, ask.

The deliberate exception: a subagent that finishes a fix may set `resolved` (work-is-done-but-not-confirmed). It must not set `closed` — that's the user's call. This separation is the entire reason `resolved` and `closed` are different states.

## Git tracking

`issues/` is tracked in this repo. Each lifecycle event below produces its own commit. Verify on every operation:

```bash
git rev-parse --is-inside-work-tree 2>/dev/null   # is this a git repo?
git check-ignore -q issues/                        # exit 0 = ignored, 1 = tracked
```

| Event | What's committed | Commit message |
|---|---|---|
| File a new issue | the new `NNNN.md` (and `Issues.md` if newly created) | `#NNNN <issue title>` |
| Resolve — code commit | code changes only | `#NNNN <verb> <title>` |
| Resolve — resolution commit | markdown update (status + Closed + Commit + summary) | `#NNNN Resolve: <title>` |
| Bail with notes | markdown only | `#NNNN Notes: <brief>` |
| User-confirmed close | markdown only | `#NNNN Close` |
| Won't fix | markdown only | `#NNNN Won't fix` |

**Working-copy-only changes (no commit):**

- Setting status to `in-progress` at the start of work — transient; the resolve commits supersede it. Committing every status flip would create noise.

**Why two commits to resolve, not one:** the **Commit** metadata row records the hash of the code-fix commit, and that hash isn't known until *after* the code commit lands. Splitting resolution into a code commit and a resolution commit keeps each commit single-purpose ("fix the code", "document the fix") and lets the resolution commit reference the hash cleanly.

This project's existing commits use a `M<n>: <verb> <subject>` milestone-prefix convention (see `git log`). For issue-driven commits, use the issue prefix `#NNNN` instead of the milestone tag — milestones group planned work, issues track defects and follow-ups.

## Issue file format

Each issue is `NNNN.md` (4-digit zero-padded) with this structure:

```markdown
# NNNN — Title

| | |
|---|---|
| **Status** | open |
| **Module** | <module name(s)> |
| **Platform** | iOS · macOS · iPadOS · All |
| **First seen** | YYYY-MM-DD |

## Description

What is wrong. Lead with the punchline — the first paragraph shows in the Mac app summary.

## Steps to reproduce

1. …
2. …

## Expected behavior

What should happen.

## Actual behavior

What actually happens.

## Attachments

![caption](screenshot.png)

## Notes

Any additional context, guesses at root cause, related code locations.
```

### Format details that matter

- **Title separator** is an em-dash (U+2014, `—`), not a hyphen.
- **Metadata field rows** must keep the field name in `**bold**` exactly.
- **Dates** are `YYYY-MM-DD`.
- **Module** can list multiple modules separated by ` / ` (e.g. `Session / FolderEngine`).
- **Platform** is `iOS`, `macOS`, `iPadOS`, `tvOS`, `watchOS`, `visionOS`, `All`, or any combination separated by ` / `. `All` is treated as matching every platform filter. Folder-watching bugs are macOS-only; file-watching bugs typically apply to `All`.
- When status moves to `resolved` or `closed`, add a `**Closed**` row with today's date. When the move to `resolved` is the result of a fix commit, also add a `**Commit**` row with the short hash (`git rev-parse --short HEAD`).
- Steps / Expected / Actual / Attachments / Notes are conventional but not all required — for design-refinement or feature-gap issues, Description alone is fine.

## Filing a new issue

1. Find the highest existing `NNNN.md` and increment. Start at `0001` if the folder is empty. Skip past reserved high numbers (e.g. `8888`, `9999` for test issues).
2. Create `issues/NNNN.md` from the template.
3. Set status to `open`.
4. Use today's date for First seen.
5. Phrase the title as a single declarative sentence describing the bug, not a question or a fix description.
6. Commit the new file with message `#NNNN <issue title>` so the issue enters git history with its `open` status.

## Updating an issue

Edit the file in place. The Mac app picks up changes automatically — no follow-up command. Touch only the rows or sections that changed; don't reformat the rest.

When status moves to `resolved` or `closed`, add a `**Closed**` row with the date. When the move to `resolved` was driven by a fix commit, also add a `**Commit**` row with the short hash. For any move toward `resolved`, `closed`, or `wontfix`, the "Critical rule" near the top of this file applies — those transitions require explicit user confirmation, not inference.

## Resolving an issue (the standard workflow)

Each open issue is handled by a fresh subagent. The orchestrator picks the issue; the subagent does the work in isolation and returns when done.

### Orchestrator: pick and dispatch

1. List `issues/*.md` (skip `Issues.md`). Pick the lowest-numbered file whose status is `open`.
2. Spawn a fresh subagent with the issue id and instructions to follow the resolve workflow below.
3. When the subagent returns, move on to the next open issue (or stop if only one was requested).

If the user names a specific issue ("fix 0046"), dispatch to that id directly.

### Subagent: claim → fix → build → commit → resolve

A subagent starts with fresh context, so its first job is loading the project's conventions before touching anything.

1. **Orient in the project.** Read these in order, every time:
   - **`issues/Issues.md`** (this file) — status vocabulary, module conventions, build/verify command, commit conventions, project-specific rules.
   - **`README.md`**, **`PRD.md`**, and **`Concepts.md`** at the repo root — they define the public API contract, platform matrix, lifecycle semantics, and the FSEventStream / DispatchSource mental models. The PRD is authoritative for "what the API is supposed to do"; Concepts.md is authoritative for "why the C-bridge looks the way it does".
   - **`issues/NNNN.md`** — the issue you're working on, in full, including attachments in `issues/NNNN/`.

   If guidance disagrees, prefer `PRD.md` for API contract questions and this file for issue-tracking specifics.

2. **Set status to `in-progress`** in the markdown — working copy only, no commit. The Mac app picks it up immediately.
3. **Make the code changes** required to fix the bug. Maintain Swift 6 strict concurrency: no raw pointers, no `Unmanaged`, no `FSEventStream*` in the public API; all public values stay `Sendable`.
4. **Run the project build / verification command** and confirm it passes. Fix failures caused by your changes. If the build was already failing before you started, note it on the issue and bail — don't fix unrelated breakage.

5. **Make the code commit.** Stage *only the code changes* (not the issue markdown yet). The message starts with `#NNNN` and a short, declarative title — pick the verb that actually fits (`Fix`, `Add`, `Refactor`, `Update`, `Remove`, etc.); not every issue is a bug fix. Leave a blank line after the title, then add a paragraph of details. Example:

   ```
   #0007 Fix double-release of FSEventStream on rapid stop()

   FolderEngine.stop() was invalidating the stream and then dropping the
   retained context, which double-released when teardown raced with a
   pending callback. Moved release into the finalizer and guarded with the
   SecurityScope balance check.
   ```

6. **Capture the commit hash** with `git rev-parse --short HEAD`.

7. **Update the issue markdown** to mark it resolved:
   - Change Status to `resolved`.
   - Add a `**Closed**` row with today's date.
   - Add a `**Commit**` row with the short hash from step 6.

   Then add a structured summary in this order so the issue becomes a primary-source record:

   - **`## Root cause`** — what was actually wrong (often different from the original report).
   - **`## Fix`** — the approach taken.
   - **`## Files changed`** — bulleted list, one bullet per file, with a short note describing what changed in each.
   - **`## Gotchas`** *(optional)* — surprises, dead ends, non-obvious behavior, or anything a future engineer working on similar code should know. C-bridge / FSEventStream pitfalls in particular accumulate well here.

8. **Make the resolution commit.** Stage `issues/NNNN.md` and commit with message `#NNNN Resolve: <title>`. Body briefly notes which code commit it pairs with (the hash from step 6).

Status flow: `open` → `in-progress` → `resolved`. **Never set `closed`** — the user does that after verifying the fix.

### Build / verify command for this project

This is a SwiftPM package. Default verification:

```bash
swift build
swift test
```

For platform-specific builds (folder watching is macOS-only, file watching covers all Apple platforms), use `xcodebuild` with the appropriate destination, e.g.:

```bash
xcodebuild -scheme Watcher -destination 'platform=iOS Simulator,name=iPhone 16' build test
```

Always run `swift test` before resolving — the test suite covers the public API contract, the FSEventStream integration, and the hardening invariants from milestones M2–M4.

### When the subagent can't finish

If the bug is unreproducible, out of scope, or the build won't pass after reasonable effort:

1. **Discard or stash any partial code changes** so the bail doesn't accidentally include half-done work.
2. **Revert status to `open`** in the issue markdown so the issue goes back into the queue.
3. **Add a `## Notes` section** describing what was tried, why work stopped, and what you'd try next. Be specific.
4. Commit the markdown change with message `#NNNN Notes: <one-line bail summary>`.
5. Return with a one-line summary of why work stalled.

Never use `wontfix` or `closed` to escape a stuck issue.

## Attachments

Screenshots, crash logs, console output, sample data, etc. live in a sibling folder `issues/NNNN/`. Reference them with relative paths from the issue file:

```markdown
## Attachments

![Reply button does nothing when tapped](screenshot.png)
![Crash log](crash.log)
```

### macOS screenshot filename gotcha

macOS screenshot filenames use a **narrow no-break space** (U+202F) before AM/PM, visually identical to a regular space. A literal `cp` of the quoted filename will fail with "No such file or directory". Use a glob to skip past it:

```bash
mkdir -p issues/NNNN
cp ~/Desktop/Screenshot\ YYYY-MM-DD\ at\ H.MM.SS*PM.png issues/NNNN/screenshot.png
```

The `*` matches the U+202F. Substitute the actual timestamp; if you don't know which screenshot the user means, list `~/Desktop/Screenshot*` by mtime and pick the most recent.

## Module conventions for this project

Use these canonical names in the `Module` row. Pick the most specific one that fits, or list multiple separated by ` / ` when the bug crosses boundaries.

Public API surface (`Sources/Watcher/`):

- `Session` — public actor; lifetime token; events stream
- `Event` — `Sendable`, `Hashable` enum
- `Options` — throttle / scope / depth / latency
- `WatcherError` — construction and runtime errors
- `Watcher` — caseless namespace (e.g. `logSubsystem`)

Internal engine (`Sources/Watcher/Internal/`):

- `Engine` — internal protocol shared by file and folder engines
- `FileEngine` — DispatchSource-backed single-file watching (all Apple platforms)
- `FolderEngine` — FSEventStream-backed folder watching (macOS only)
- `PathCanonicalization` — URL / path normalization helpers
- `SecurityScope` — balanced security-scoped resource access

Tests (`Tests/WatcherTests/`):

- `WatcherTests`, `FileWatchTests`, `FolderWatchTests`, `HardeningTests`

Other useful tags:

- `Concurrency` — Swift 6 strict-concurrency / actor isolation issues
- `Logging` — `os.Logger` subsystem / category / privacy issues
- `Docs` — `README.md`, `PRD.md`, `Concepts.md` corrections
- `Build` — SwiftPM / Xcode / platform matrix issues
