---
name: release-calf
description: >-
  Bumps calf version, opens/merges the release PR, waits for CI and Release
  pipelines, fixes failures, publishes the GitHub release, then updates the
  Homebrew cask. Use when the user asks to release calf, bump version, cut a
  release, ship a version, merge a release PR, or run the full release +
  Homebrew flow.
---

# Release Calf (version → merge → CI → Homebrew)

End-to-end release for this repo (`enegalan/calf`), then publish the Homebrew
cask in the sibling tap `enegalan/calf-homebrew`.

If the personal skill `update-calf-homebrew` is available, use it for step 8;
otherwise follow the Homebrew steps below.

## Repos

| Role | Path (typical) | Remote |
|------|----------------|--------|
| App (this repo) | repo root | `enegalan/calf` |
| Tap | `../calf-homebrew` or `~/git/calf-homebrew` | `enegalan/calf-homebrew` |

Cask: `Casks/calf.rb` in the tap. Install: `brew install --cask enegalan/calf-homebrew/calf`

## Progress checklist

Copy and track until done:

```
Release calf:
- [ ] 1. Decide target version (ask user if unclear)
- [ ] 2. Bump versions + CHANGELOG on a release branch
- [ ] 3. Commit, push, open PR
- [ ] 4. Wait CI on PR; fix failures; re-push
- [ ] 5. Merge PR into main (only when user allows / asks)
- [ ] 6. Wait Release workflow on main; fix failures; re-run / follow-up PR
- [ ] 7. Publish draft GitHub release v<version> (needs DMG asset)
- [ ] 8. Update Homebrew cask, commit, and push tap
- [ ] 9. Done report
```

Do not skip ahead. Do not invent versions, sha256, or release assets.

## Version rules

- Bump **both** in the same commit:
  - `backend/version/version.go` → `const Version = "X.Y.Z"`
  - `ui/pubspec.yaml` → `version: X.Y.Z+N` (semver part must equal Go; `+N` build may increment)
- SemVer `X.Y.Z` only (Release workflow rejects other formats).
- `CHANGELOG.md`: move `## [Unreleased]` notes into `## [X.Y.Z] - YYYY-MM-DD`, leave empty `## [Unreleased]` (keep section headers that still have items).
- User-facing CHANGELOG wording only (no file paths / protocol jargon).
- Commit type: `chore(release): bump version to X.Y.Z` (or `chore: release X.Y.Z`).

Release workflow triggers on **push to `main`** that touches `backend/version/version.go` or `ui/pubspec.yaml`. It builds installers and creates a **draft** `gh release` `vX.Y.Z` with assets under `dist/*` (DMG is `calf-X.Y.Z.dmg`, lowercase).

## Step details

### 1. Decide version

From this repo root:

```bash
grep 'const Version' backend/version/version.go
grep '^version:' ui/pubspec.yaml
gh release list --limit 5
```

Ask user for next version if not given (patch/minor/major from latest published tag). Abort if working tree has unrelated dirty changes the user did not intend to ship — either include them intentionally or stash/branch cleanly.

### 2. Branch + bump

```bash
git checkout main && git pull
git checkout -b release/vX.Y.Z
# edit version.go, pubspec.yaml, CHANGELOG.md
```

### 3. PR

Push and open PR with `gh pr create`. Title/body: version bump + short summary of Unreleased notes moved into this version.

### 4. Babysit CI on the PR

Poll until green:

```bash
gh pr checks <pr> --watch
# or
gh run list --branch release/vX.Y.Z --limit 5
gh run watch <run-id>
```

On failure:

1. `gh run view <run-id> --log-failed` (read failing job only).
2. Fix root cause in code (do not weaken CI / skip checks).
3. Commit + push; watch again.
4. Repeat until CI green.

Use babysit patterns for conflicts/comments if present. Never change workflows only to force a green check.

### 5. Merge

Merge only when the user asks (or explicitly authorized this full release run including merge):

```bash
gh pr merge <pr> --merge   # or --squash if that is the repo default; prefer matching recent merges
git checkout main && git pull
```

Confirm `main` has the version bump:

```bash
grep 'const Version' backend/version/version.go
grep '^version:' ui/pubspec.yaml
```

### 6. Babysit Release workflow on main

```bash
gh run list --workflow=release.yml --branch main --limit 5
gh run watch <run-id>
```

Also keep an eye on CI on `main` if it runs.

On Release failure: same fix loop — diagnose logs, patch on a fix branch or main (user preference), push, re-trigger if needed:

```bash
gh workflow run release.yml --ref main
# prefer fixing the real failure and re-running failed jobs:
gh run rerun <run-id> --failed
```

Wait until the draft release exists with macOS DMG:

```bash
gh release view "vX.Y.Z" --json isDraft,assets,tagName
```

Asset required for Homebrew: `calf-X.Y.Z.dmg`.

### 7. Publish the draft release

Draft assets are not reliably public for Homebrew. Publish when build is good:

```bash
gh release edit "vX.Y.Z" --draft=false
```

Only after user confirmation if the release notes or assets look wrong. If guest disk assets are missing and user cares, note they are attached manually (`make guest-disk`) — do not block Homebrew on guest disk unless user says so.

### 8. Homebrew (generate + commit + push)

Preconditions: published `vX.Y.Z` with `calf-X.Y.Z.dmg`; versions already match in this repo.

```bash
VERSION=$(grep 'const Version' backend/version/version.go | sed 's/.*"\(.*\)".*/\1/')
mkdir -p dist
# if DMG missing locally:
curl -fsSL -o "dist/calf-${VERSION}.dmg" \
  "https://github.com/enegalan/calf/releases/download/v${VERSION}/calf-${VERSION}.dmg"

# resolve tap path (sibling clone preferred)
TAP="${CALF_HOMEBREW_TAP:-../calf-homebrew}"
./scripts/update-homebrew.sh "$TAP"
```

Verify, then commit and push immediately:

```bash
cd "$TAP"
git diff Casks/calf.rb
# version, sha256 (from real DMG), url v#{version}/calf-#{version}.dmg

git add Casks/calf.rb
git commit -m "$(cat <<EOF
chore: update calf cask to version ${VERSION} with new sha256 checksum

EOF
)"
git push origin HEAD
```

Never guess sha256. If `update-calf-homebrew` is used for this step, treat commit+push as required (same as above) — do not stop after generating the cask.

### 9. Done report

Tell user:

- Version shipped
- PR URL + merge status
- Release URL (`https://github.com/enegalan/calf/releases/tag/vX.Y.Z`)
- Homebrew tap status (committed and pushed; include tap commit / remote URL if useful)
- Any remaining manual steps (e.g. guest disk attach)

## Rules

- Commit / merge / push for the **calf** app repo only per user git rules (explicit ask, or this skill invoked as a full release that already includes those steps — still confirm before destructive/irreversible ops if ambiguous).
- For the **Homebrew tap** during a full release: always commit and push after a successful cask update — no extra confirmation.
- Never bump Homebrew before the GitHub release DMG URL returns 200.
- Never guess sha256.
- Keep backend/UI versions identical.
- English only in commits, CHANGELOG, PR text.
- Fix root causes of CI/Release failures; no band-aids.
- Prefer `gh` for all GitHub Actions / PR / release operations.

## Quick commands

```bash
# Current versions
grep 'const Version' backend/version/version.go
grep '^version:' ui/pubspec.yaml

# Watch PR CI
gh pr checks --watch

# Watch latest Release run on main
gh run list --workflow=release.yml --branch main --limit 1
gh run watch $(gh run list --workflow=release.yml --branch main --limit 1 --json databaseId -q '.[0].databaseId')

# Publish draft
gh release edit "vX.Y.Z" --draft=false

# Homebrew into tap
./scripts/update-homebrew.sh ../calf-homebrew
```
