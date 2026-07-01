// Generates TestFlight "What to Test" notes from the commits since the previous
// release and writes them to the just-uploaded build's betaBuildLocalizations.
//
// Note formatting (conventional-commit parsing, scope/pattern filtering, char
// limit) lives in changelog.mjs and is shared with the Pre-flight promotion
// rollup so both surfaces read identically.
//
// Non-fatal by design: "What to Test" is cosmetic, so any failure (ASC hiccup,
// build slow to process) logs a warning and exits 0 — it never blocks a deploy.
//
// Env:
//   APP_BUNDLE_ID     — bundle id of the app (e.g. com.eff3.liftmark.native-ios)
//   APP_VERSION       — marketing version of the build just uploaded (e.g. 1.1.200)
//   APP_BUILD         — build number (CFBundleVersion) of that build
//   PREVIOUS_VERSION  — marketing version of the previous release; lower bound for
//                       the changelog range. Empty on the very first release.
//   MAX_WAIT_SECONDS  — optional; how long to poll for the build to appear (default 1200)
//   EXCLUDE_SCOPES    — optional; see changelog.mjs
//   EXCLUDE_PATTERN   — optional; see changelog.mjs
//   ASC_*             — via asc-client

import { required, getAppId, getBuild, setBetaBuildNotes } from './asc-client.mjs';
import { resolveVersionRef, generateNotes } from './changelog.mjs';

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function pollForBuild(appId, version, buildNumber, maxWaitSeconds) {
  const deadline = Date.now() + maxWaitSeconds * 1000;
  let attempt = 0;
  for (;;) {
    const build = await getBuild(appId, { version, buildNumber });
    if (build) return build;
    if (Date.now() >= deadline) return null;
    attempt += 1;
    console.log(`Build ${version} (${buildNumber}) not yet visible in App Store Connect; retry ${attempt} in 30s…`);
    await sleep(30_000);
  }
}

async function main() {
  const bundleId = required('APP_BUNDLE_ID');
  const version = required('APP_VERSION');
  const buildNumber = required('APP_BUILD');
  const previous = process.env.PREVIOUS_VERSION || '';
  const maxWait = Number(process.env.MAX_WAIT_SECONDS || '1200');

  const lowerRef = resolveVersionRef(previous);
  console.log(`Changelog range: ${lowerRef ? `${lowerRef}..HEAD` : 'entire history (no previous release tag found)'}`);

  const notes = generateNotes(lowerRef);
  if (!notes) {
    console.log('No feat/fix commits in range; leaving "What to Test" unset.');
    return;
  }
  console.log(`Generated "What to Test":\n${notes}`);

  const appId = await getAppId(bundleId);
  const build = await pollForBuild(appId, version, buildNumber, maxWait);
  if (!build) {
    console.warn(`::warning::Build ${version} (${buildNumber}) never appeared in App Store Connect within ${maxWait}s; skipping notes.`);
    return;
  }

  await setBetaBuildNotes(build.id, notes);
  console.log(`Set "What to Test" on build ${version} (${buildNumber}).`);
}

main().catch((err) => {
  // Non-fatal: never fail a deploy over cosmetic release notes.
  console.warn(`::warning::Failed to set "What to Test" notes: ${err.message}`);
  process.exit(0);
});
