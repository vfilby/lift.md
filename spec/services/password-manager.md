# Password-Manager Association Service Specification

## Purpose

Enable iCloud Keychain and third-party password managers (1Password, Bitwarden,
etc.) to offer the user's saved `liftmark.app` credentials when the native iOS
app shows its account sign-in form. This is Apple's
[Shared Web Credentials / Associated Domains `webcredentials`](https://developer.apple.com/documentation/xcode/supporting-associated-domains)
mechanism.

The association is bidirectional and only works when **both** halves agree:

1. The **app** declares the domain it trusts via the
   `com.apple.developer.associated-domains` entitlement (`webcredentials:liftmark.app`).
2. The **domain** declares the app(s) it trusts via an
   `apple-app-site-association` (AASA) file served at
   `https://liftmark.app/.well-known/apple-app-site-association`.

Apple's CDN fetches the AASA and matches the app's Team ID + bundle ID against
the `webcredentials.apps` list. Only on a match does autofill light up.

## Identity facts

| Field | Value |
| --- | --- |
| Apple Team ID | `43DNX2P3T6` |
| Prod app bundle ID | `com.eff3.liftmark.native-ios` |
| Dev/debug app bundle ID | `com.eff3.liftmark.native-ios.dev` |
| Associated domain | `liftmark.app` (apex) |

The `.dev` bundle ID is included so debug/TestFlight-from-Xcode builds can be
tested against the same AASA. Both fully-qualified app identifiers are
`<TeamID>.<bundleID>`.

Scope is **webcredentials only**. No `applinks` / universal-links entry is
declared — the app has a custom `liftmark://` URL scheme but no universal-link
handling, so adding `applinks` would be unused surface area.

## Piece 1 — App entitlement

The app target declares the associated domain in two mirrored locations
(XcodeGen `project.yml` regenerates the `.entitlements` plist, so both must
stay in sync):

- `mobile-apps/ios/LiftMark/LiftMark.entitlements`
- `mobile-apps/ios/project.yml` → `targets.LiftMark.entitlements.properties`

Required key/value (added alongside the existing HealthKit / CloudKit / iCloud
entitlements, none of which are disturbed):

```
com.apple.developer.associated-domains = [ "webcredentials:liftmark.app" ]
```

### Login form requirements

The account sign-in form (`mobile-apps/ios/LiftMark/Views/Auth/LoginView.swift`)
must mark its fields so managers recognise them:

- Email field → `.textContentType(.username)`
- Password field → `.textContentType(.password)`

There is **no native account-creation / new-password field** — signup and
password reset are deferred to the web (`beta.liftmark.app`). If a native
signup field is ever added, its password field must use
`.textContentType(.newPassword)` so managers offer to generate and save a
credential. (The Anthropic API-key `SecureField` in Settings is **not** an
account credential and must keep `.password` without a paired `.username`.)

## Piece 2 — apple-app-site-association (AASA) file

### Location

Served at the apex by the validator CDK stack, which uploads the Astro build
output (`website/dist`) to the prod S3 bucket via a **single**
`BucketDeployment` (the whole site, including the `.well-known/` subtree). Astro
copies `website/public/**` verbatim into `website/dist/**`, so the source file
lives at:

```
website/public/.well-known/apple-app-site-association
```

and is published at:

```
https://liftmark.app/.well-known/apple-app-site-association
```

The file has **no extension** (Apple requires the exact filename).

### Content (strict JSON, no comments)

```json
{
  "webcredentials": {
    "apps": [
      "43DNX2P3T6.com.eff3.liftmark.native-ios",
      "43DNX2P3T6.com.eff3.liftmark.native-ios.dev"
    ]
  }
}
```

### Serving requirements

The AASA must be reachable with:

- **HTTP 200**, no redirect.
- **`Content-Type: application/json`.**

Two stack behaviours would otherwise break this and are explicitly handled in
`validator/cdk/stack.ts`:

1. **CloudFront URL-rewrite function.** The viewer-request function rewrites any
   path whose last segment contains no `.` to `…/index.html` (pretty URLs for
   the Astro site). `apple-app-site-association` has no dot, so it would be
   rewritten to `/.well-known/apple-app-site-association/index.html` → 404. The
   function MUST short-circuit (pass the request through untouched) for any URI
   beginning with `/.well-known/`.

2. **Content-Type.** S3/`BucketDeployment` infers content type from the file
   extension; an extensionless object defaults to `application/octet-stream`.
   A small CloudFront **viewer-response** Function (`AasaContentTypeFn`),
   associated with the default behaviour, overrides the response
   `content-type` to `application/json` for the exact URI
   `/.well-known/apple-app-site-association`. This is CloudFront-native — it
   needs no Lambda layer and no extra IAM.

   A **second `BucketDeployment`** is deliberately **NOT** used for this. Each
   `BucketDeployment` provisions its own AWS-CLI Lambda layer, and publishing
   that layer requires `lambda:PublishLayerVersion`, which the scoped
   `cdk-lmwf-cfn-exec-role` is not permitted to call. A second deployment for
   `.well-known/*` (the original PR #183 approach) therefore fails the deploy
   with a 403 on `lambda:PublishLayerVersion`. The single site
   `BucketDeployment` uploads the whole site (no `.well-known` exclude), and
   the viewer-response function handles the Content-Type.

   Note: Apple's `webcredentials` fetch does not strictly require
   `application/json` (octet-stream also works for password autofill), so the
   viewer-response override is a correctness nicety rather than a hard
   requirement — but it is cheap and CloudFront-native, so it is kept.

The default CloudFront behaviour serves S3, so `/.well-known/*` is **not**
routed to the `/validate`, `/v1/*`, or `/version` API origins.

### Canonical domain & redirects

The canonical website domain is **`getlift.md`** (see "Domains & Hosting
Topology" in `lmwf-validator.md`). `liftmark.app` now 302-redirects its **site
pages** to `getlift.md`, but the AASA is the load-bearing exception: Apple's
`webcredentials` fetcher does **not** follow redirects, so
`https://liftmark.app/.well-known/apple-app-site-association` MUST keep returning
the file directly (HTTP 200, no redirect). The same exclusion applies to the
app's API paths (`/validate`, `/v1/*`, `/version`). The associated-domains
entitlement still targets `webcredentials:liftmark.app`, so AASA hosting stays on
`liftmark.app` even though the marketing site has moved. (`liftmd.app` redirects
everything, including `/.well-known/*`, because it never hosted the app's
entitlement.)

## Deploy / order-of-operations

`website/dist` is **gitignored** and rebuilt fresh (`npm run build`) by the
`website-build` Make target before every `cdk deploy` (`validator/Makefile`).
Committing the file under `website/public/` is therefore sufficient — it will
be present in `website/dist` at deploy time.

**Order matters.** The AASA must be LIVE on `liftmark.app` *before* (or at the
same time as) an app build carrying the `webcredentials` entitlement reaches
users. If the entitlement ships first, Apple's CDN caches a missing/old AASA and
autofill stays silent until the AASA deploys and the CDN re-fetches.

Recommended sequence:

1. Deploy the validator/website change first (publishes the AASA):
   `cd validator && make deploy-prod`.
2. Verify:
   `curl -sI https://liftmark.app/.well-known/apple-app-site-association`
   → `200` + `content-type: application/json`, no redirect.
3. Then ship the app build carrying the entitlement.

## Verification

- `website` build produces `website/dist/.well-known/apple-app-site-association`
  byte-for-byte identical to the source, and it is valid JSON
  (`jq . website/dist/.well-known/apple-app-site-association`).
- The CDK stack synthesises (`cd validator/cdk && npx cdk synth`) with the
  viewer-request rewrite-function `.well-known` short-circuit and the
  viewer-response `AasaContentTypeFn`, served from the single site
  `BucketDeployment` (no second `.well-known` deployment / AwsCliLayer).
- `cd mobile-apps/ios && make generate && make build` regenerates the project
  with the entitlement and compiles cleanly.
- Post-deploy, on device: invoke the sign-in form; iCloud Keychain / the
  installed password manager offers saved `liftmark.app` credentials in the
  QuickType bar.
