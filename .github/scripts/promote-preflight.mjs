// Evaluates Beta builds and promotes the latest eligible one to the Pre-flight external group.
//
// Groups:
//   Beta       — internal, auto-populated by release-pipeline on every push
//   Pre-flight — external, requires Apple Beta App Review
//
// Eligibility gate:
//   1. In the Beta group, not yet in the Pre-flight group
//   2. Build number > newest already in the Pre-flight group (downgrade guard)
//   3. Build age ≥ SOAK_HOURS
//   4. Build number not in BLOCKED_BUILDS (from block-promotion/build-N git tags).
//      These tags can be created manually, or automatically by the nightly UI
//      suite (swift-nightly.yml) when it fails on the code that produced the build;
//      a subsequent green nightly on the same commit removes the tag.
//   5. Sentry session count for the build's release ≥ MIN_SESSIONS
//   6. Sentry crash-free session rate ≥ MIN_CRASH_FREE_RATE
//   7. Sentry unresolved error/fatal issues for the release ≤ MAX_UNRESOLVED_ISSUES
//
// Picks the *newest* build passing all gates. Older eligible builds are skipped.
// A build failing the minimum-sessions check is considered "still soaking," not rejected.
//
// Env:
//   APP_BUNDLE_ID, SOURCE_GROUP_NAME, TARGET_GROUP_NAME
//   SOAK_HOURS, MIN_SESSIONS, MIN_CRASH_FREE_RATE
//   MAX_UNRESOLVED_ISSUES (optional; defaults to off if unset)
//   BLOCKED_BUILDS (comma-separated build numbers)
//   SENTRY_AUTH_TOKEN, SENTRY_ORG, SENTRY_PROJECT
//   DRY_RUN ('true' evaluates without promoting)
//   ASC_* (via asc-client)

import {
  required,
  getAppId,
  getGroupId,
  listBuildsInGroup,
  attachBuildToGroup,
  submitForBetaReview,
} from './asc-client.mjs';

let _sentryProjectId;
async function sentryProjectId(org, projectSlug, token) {
  if (_sentryProjectId) return _sentryProjectId;
  const res = await fetch(`https://sentry.io/api/0/projects/${encodeURIComponent(org)}/${encodeURIComponent(projectSlug)}/`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!res.ok) throw new Error(`Sentry project lookup → ${res.status}: ${await res.text()}`);
  _sentryProjectId = (await res.json()).id;
  return _sentryProjectId;
}

async function sentryCrashFreeRate(release) {
  const token = required('SENTRY_AUTH_TOKEN');
  const org = required('SENTRY_ORG');
  const project = required('SENTRY_PROJECT');
  const projectId = await sentryProjectId(org, project, token);

  const params = new URLSearchParams({
    project: projectId,
    field: 'sum(session)',
    statsPeriod: '7d',
    query: `release:${release}`,
  });
  params.append('field', 'crash_free_rate(session)');

  const res = await fetch(`https://sentry.io/api/0/organizations/${encodeURIComponent(org)}/sessions/?${params}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!res.ok) throw new Error(`Sentry sessions → ${res.status}: ${await res.text()}`);
  const data = await res.json();

  // Sessions API returns groups[0].totals when no groupBy is set.
  const totals = data.groups?.[0]?.totals || {};
  const sessions = Number(totals['sum(session)'] ?? 0);
  const rate = totals['crash_free_rate(session)'];
  // crash_free_rate returns null when there are no sessions; treat as 1.0 for gating
  // (the sessions check will independently fail and mark "still soaking").
  const crashFreeRate = rate == null ? 1 : Number(rate);
  return { sessions, crashFreeRate };
}

async function sentryUnresolvedIssueCount(release) {
  const token = required('SENTRY_AUTH_TOKEN');
  const org = required('SENTRY_ORG');
  const project = required('SENTRY_PROJECT');
  const projectId = await sentryProjectId(org, project, token);

  const params = new URLSearchParams({
    project: projectId,
    query: `release:${release} is:unresolved level:[fatal,error]`,
    statsPeriod: '14d',
    limit: '100',
  });
  const res = await fetch(`https://sentry.io/api/0/organizations/${encodeURIComponent(org)}/issues/?${params}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!res.ok) throw new Error(`Sentry issues → ${res.status}: ${await res.text()}`);
  // X-Hits exposes total without paginating; fall back to page length.
  const hits = res.headers.get('x-hits');
  if (hits != null) return Number(hits);
  const data = await res.json();
  return Array.isArray(data) ? data.length : 0;
}

function parseBlocked(csv) {
  return new Set((csv || '').split(',').map((s) => s.trim()).filter(Boolean));
}

async function main() {
  const bundleId = required('APP_BUNDLE_ID');
  const sourceName = required('SOURCE_GROUP_NAME');
  const targetName = required('TARGET_GROUP_NAME');
  const soakHours = Number(required('SOAK_HOURS'));
  const minSessions = Number(required('MIN_SESSIONS'));
  const minCrashFree = Number(required('MIN_CRASH_FREE_RATE'));
  const maxIssues = process.env.MAX_UNRESOLVED_ISSUES != null && process.env.MAX_UNRESOLVED_ISSUES !== ''
    ? Number(process.env.MAX_UNRESOLVED_ISSUES)
    : Infinity;
  const blocked = parseBlocked(process.env.BLOCKED_BUILDS);
  const dryRun = process.env.DRY_RUN === 'true';

  const appId = await getAppId(bundleId);
  const targetGroupId = await getGroupId(appId, targetName);

  const sourceBuilds = await listBuildsInGroup(appId, sourceName);
  const targetBuilds = await listBuildsInGroup(appId, targetName);
  const targetBuildIds = new Set(targetBuilds.map((b) => b.id));
  const maxTargetBuildNumber = targetBuilds.reduce(
    (max, b) => Math.max(max, Number(b.buildNumber) || 0),
    0,
  );

  sourceBuilds.sort((a, b) => new Date(b.uploadedAt) - new Date(a.uploadedAt));

  const now = Date.now();
  const results = [];

  for (const build of sourceBuilds) {
    const ageHours = (now - new Date(build.uploadedAt).getTime()) / 3_600_000;
    const reasons = [];
    if (targetBuildIds.has(build.id)) reasons.push(`already in ${targetName}`);
    if (Number(build.buildNumber) <= maxTargetBuildNumber) {
      reasons.push(`older than ${targetName}'s latest (${maxTargetBuildNumber})`);
    }
    if (ageHours < soakHours) reasons.push(`soak ${ageHours.toFixed(1)}h < ${soakHours}h`);
    if (blocked.has(String(build.buildNumber))) reasons.push('blocked by git tag');

    let health;
    if (reasons.length === 0) {
      const release = `${bundleId}@${build.version}+${build.buildNumber}`;
      health = await sentryCrashFreeRate(release);
      if (health.sessions < minSessions) reasons.push(`sessions ${health.sessions} < ${minSessions} (still soaking)`);
      else if (health.crashFreeRate < minCrashFree) reasons.push(`crash-free ${(health.crashFreeRate * 100).toFixed(2)}% < ${(minCrashFree * 100).toFixed(2)}%`);
      else if (Number.isFinite(maxIssues)) {
        const issues = await sentryUnresolvedIssueCount(release);
        health.unresolvedIssues = issues;
        if (issues > maxIssues) reasons.push(`unresolved error/fatal issues ${issues} > ${maxIssues}`);
      }
    }

    results.push({ build, ageHours, reasons, health });
    if (reasons.length === 0) break;
  }

  console.log('## Evaluation');
  for (const r of results) {
    const tag = r.reasons.length === 0 ? 'ELIGIBLE' : 'skip';
    console.log(`- [${tag}] build ${r.build.buildNumber} (${r.build.version}), age ${r.ageHours.toFixed(1)}h${r.reasons.length ? ' — ' + r.reasons.join('; ') : ''}`);
  }

  const eligible = results.find((r) => r.reasons.length === 0);
  if (!eligible) {
    console.log('No eligible build to promote.');
    return;
  }

  if (dryRun) {
    console.log(`DRY RUN: would promote build ${eligible.build.buildNumber} to ${targetName}`);
    return;
  }

  await attachBuildToGroup(eligible.build.id, targetGroupId);
  await submitForBetaReview(eligible.build.id);
  console.log(`Promoted build ${eligible.build.buildNumber} to ${targetName} and submitted for Beta App Review`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
