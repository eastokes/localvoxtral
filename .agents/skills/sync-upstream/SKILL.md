---
name: sync-upstream
description: >-
  Safely synchronize this personal localvoxtral fork with T0mSIlver/localvoxtral.
  Use this skill whenever fetching, reviewing, merging, testing, or analyzing new
  upstream localvoxtral changes, including requests to update the fork, sync
  upstream/main, preserve personal customizations, or resolve upstream conflicts.
compatibility: Requires git, mise, Swift 6.2, and the macOS/Xcode toolchain.
---

# Synchronize this personal fork with upstream

Update this repository from `T0mSIlver/localvoxtral` while preserving its personal customizations. Fetch and analyze upstream before modifying the current branch, merge rather than rebase, resolve conflicts deliberately, and validate the combined result.

## Repository-specific context

- `origin` is the personal fork: `https://github.com/eastokes/localvoxtral.git`.
- `upstream` must be the source project: `https://github.com/T0mSIlver/localvoxtral.git`.
- `main` is the personal, usable branch and contains changes that must remain functional.
- The project is a macOS Swift 6.2 application built and tested through `mise` tasks.
- Personal behavior may include multiple hotkeys, permission reset support, Ghostty/send-now behavior, prompt improvements, realtime dictation behavior, settings, replacement dictionary entries, and local build/release/install workflows. Treat the current branch—not this list—as the authoritative record of personal changes.
- Never push to `upstream`, open a pull request, force-push, or discard local commits.

## Preconditions and safety

1. Work only in the repository root.
2. Inspect `git status --short --branch`, the current branch, remotes, and recent graph.
3. Require the current branch to be `main` and the working tree to be clean. If either condition is false, stop and report it; do not stash, reset, clean, or switch branches automatically.
4. Verify that `origin` and `upstream` match the URLs above. Stop if they do not.
5. Record the starting `HEAD` SHA so the operation can be audited and recovered.
6. Do not run install tasks or modify files outside this repository.

## 2. Fetch the latest upstream state

Run:

```bash
git fetch --prune upstream
```

Do not merge or edit anything until the analysis below is complete.

## 3. Analyze upstream and personal changes

Establish the merge base and inspect both sides independently:

```bash
base=$(git merge-base HEAD upstream/main)
git rev-list --left-right --count HEAD...upstream/main
git log --oneline --decorate --graph --left-right HEAD...upstream/main
git diff --stat "$base"..HEAD
git diff --stat "$base"..upstream/main
git diff --name-status "$base"..HEAD
git diff --name-status "$base"..upstream/main
```

Then:

1. Summarize the upstream commits and their intended behavior.
2. Summarize the personal delta from the merge base.
3. Identify files changed on both sides as likely conflict or regression areas.
4. Read the relevant diffs and surrounding source before deciding how changes should combine.
5. Pay special attention to:
   - `Sources/localvoxtral/` behavior, settings, hotkeys, permissions, text insertion, realtime events, and resources.
   - `Tests/localvoxtralTests/` coverage affected by either side.
   - `Package.swift` and `Package.resolved` dependency changes.
   - `mise.toml`, `scripts/`, and `.github/workflows/` build, packaging, release, and installation behavior.
6. Review incoming scripts, workflow permissions, dependency changes, network endpoints, and credential handling for security implications.
7. Perform the model recommendation review below before deciding how to merge model, backend, settings, or packaging changes.

### Model recommendation review

Model changes can alter quality, latency, memory use, downloads, compatibility, and supply-chain exposure even when they merge without conflicts. Review them explicitly rather than treating catalog or pin updates as ordinary implementation details.

Inspect model-related commits and effective changes on both sides, including renamed or newly introduced equivalents of:

- `Sources/localvoxtral/Backends/SpeechModelCatalog.swift`
- `Sources/localvoxtral/Backends/PolishModelCatalog.swift`
- `Sources/localvoxtral/SettingsStore.swift`
- `SpeechHelper/Package.swift` and `SpeechHelper/Package.resolved`
- `PolishHelper/Package.swift` and `PolishHelper/Package.resolved`
- model download, backend launch, packaging, documentation, and evaluation files

For each speech or polishing model changed or introduced:

1. Record its repository/model ID, exact revision or other immutable pin, display name, quantization, estimated disk/RAM requirements, and whether it is the upstream default, an alternative, or removed.
2. Summarize upstream's stated reason for recommending it, including relevant evaluation results, performance claims, compatibility fixes, or hardware guidance. Distinguish measured evidence from comments or unverified claims.
3. Compare the upstream recommendation with the personal branch's source-controlled defaults and choices. Do not inspect or modify live `UserDefaults`, Hugging Face caches, or other state outside the repository.
4. Determine upgrade behavior from the code: whether an existing managed-model selection remains selected, whether only fresh installs adopt the new default, whether a migration rewrites persisted settings, and whether external URL/model configuration is unaffected.
5. Review dependency and model pins for immutability and provenance. Flag floating branches, tags, unpinned model revisions, changed download hosts, missing lockfile changes, or a model that requires a helper/runtime revision not included in the same merge.
6. Confirm packaging includes every helper and resource needed by the recommended models, and run model-focused tests or packaging validation when available.
7. Do not silently change a personal model selection merely because upstream changed its default. Preserve explicit personal choices unless incompatibility requires a change; report that incompatibility and the available alternatives before proceeding.

The analysis and final report must contain a **Model recommendations** section, even when no recommendation changed. State:

- previous personal/source-controlled default or choice;
- incoming upstream default and alternatives;
- exact pin changes;
- expected effect on existing versus fresh installs;
- evidence or rationale for the recommendation;
- any decision made during conflict resolution;
- remaining manual comparison worth doing on the user's Mac.

If `HEAD..upstream/main` contains no commits, report that the fork is already current and stop without creating a backup branch or merge commit.

## 4. Create a recovery point

Immediately before merging, create a uniquely named local backup branch from the recorded starting SHA:

```bash
backup_branch="backup/pre-upstream-$(date +%Y%m%d-%H%M%S)"
git branch "$backup_branch" <starting-HEAD-SHA>
```

Report the exact backup branch name. Do not push it unless explicitly requested.

## 5. Merge upstream

Merge with an explicit synchronization commit rather than rebasing:

```bash
git merge --no-ff upstream/main -m "Merge upstream/main into personal fork"
```

If conflicts occur:

1. Inspect every conflict and the relevant base, personal, and upstream versions.
2. Preserve the intent of both sides where compatible; do not resolve files wholesale with `--ours` or `--theirs` merely to finish the merge.
3. Prefer adapting personal behavior to upstream's current architecture over restoring obsolete upstream code.
4. Add or update focused tests when a resolution changes behavior or exposes an untested regression risk.
5. Stage only resolved files and finish the merge commit.
6. If a safe resolution is unclear, run `git merge --abort`, retain the backup branch, and report the ambiguity instead of guessing.

Do not mix unrelated cleanup or refactoring into this synchronization.

## 6. Validate the combined result

At minimum run:

```bash
git diff --check HEAD^ HEAD
mise run test
mise run build
```

Also:

- Run focused Swift tests for changed behavior when practical.
- Run `mise run package` if upstream or conflict resolution changed `Package.swift`, resources, `mise.toml`, packaging scripts, release scripts, or release workflows.
- Do not run `mise run install-local`; installation changes state outside the repository.
- Inspect `git status --short --branch` and the final commit graph.
- Confirm that no unresolved conflict markers remain.
- Perform a final security review of the effective merged changes, with particular attention to scripts, workflows, permissions, dependencies, secrets, and network behavior.

If a required test fails, investigate whether the failure is caused by upstream, the personal delta, or conflict resolution. Fix only integration regressions that are within scope. Do not claim success while required validation is failing.

## 7. Delivery boundary

Stop after a successful local merge and validation. Do not push by default.

Only if the task invocation explicitly authorizes pushing, push the completed `main` branch to the personal fork with:

```bash
git push origin main
```

Never push to `upstream`, never force-push, and never open a pull request to the upstream project.

## Final report

Provide a concise report containing:

- Starting SHA, fetched upstream SHA, resulting merge SHA, and backup branch.
- Upstream commits incorporated and a short impact summary.
- Files changed on both sides and how any conflicts were resolved.
- How key personal behaviors were preserved or adapted.
- A **Model recommendations** section with defaults, alternatives, exact pins, migration effects, upstream rationale, and any personal-selection decision.
- Tests and validation commands run, with outcomes.
- Security findings, remaining uncertainties, and manual checks worth performing in the macOS app.
- Final `git status` and whether anything was pushed (normally: no).
