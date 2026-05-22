---
name: release
description: Run the LiftMark release process for TestFlight alpha builds. Use when the user asks to release, deploy, ship, or push a build to TestFlight. Executes pre-release checks (tests, git state), then triggers the TestFlight workflow. Also use when asked to "cut a build" or "release alpha".
---

# Release to TestFlight

## Pre-Release Checklist

Run these checks in order. Stop and report on the first failure — do not attempt automatic repair. The calling agent is responsible for fixing issues and retrying.

### 1. Verify Clean Working Tree

Ensure no uncommitted or unstaged changes exist:

```bash
git status --porcelain
```

If output is non-empty, **stop and report** the uncommitted changes. All code must be committed before release.

### 2. Run Tests

Run from the repo root. Both must pass.

```bash
make test-unit
make test-ui
```

If any test fails, **stop and report** the failure output. Do not proceed to release.

### 2.5 Check CloudKit Schema Drift

```bash
python tools/check_ckrecord_drift.py
```

If the script exits non-zero, new `record["..."]` fields have been added to `CKRecordMapper.swift` since the last `deploy/*` tag. **Stop and report.** Promote the CloudKit Production schema via CloudKit Dashboard (container `iCloud.com.eff3.liftmark.v2`) before releasing, or saves against the affected record types will fail in production with CKError 12 / 2006.

### 3. Push to Remote

Ensure main is pushed. `make release-alpha` does NOT push commits — it triggers a GitHub Actions workflow against whatever is on remote main.

```bash
git push origin main
```

### 4. Trigger TestFlight Build

```bash
make release-alpha
```

This runs `gh workflow run "Deploy Swift to TestFlight" --ref main --field bump=build`.

After triggering, report that the build has been submitted and suggest the user monitor it with:

```bash
gh run list --workflow="Deploy Swift to TestFlight" --limit 1
```
