# Releasing AnyWhere

English · [简体中文](RELEASING.zh.md) · [Back to home](../README.md)

AnyWhere ships as a **Developer ID-signed, notarized `.dmg`** with **Sparkle** auto-updates.
This document covers the one-time setup and the per-release flow.

Keychain use below belongs to developer signing and release tooling. Plugin password settings
use [local encrypted storage](pack-spec.md#settings--plugin-configuration-schemaversion-2-or-later).

> Distribution requires a paid **Apple Developer Program** membership and a **Developer ID
> Application** certificate. An "Apple Development" cert (free) is enough to build and run
> locally, but **not** to notarize for distribution.

---

## One-time setup

### 1. Developer ID certificate

In Xcode → Settings → Accounts, or the Apple Developer portal, create a **Developer ID
Application** certificate and install it in your login keychain. Find its identity string:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
# → "Developer ID Application: Your Name (TEAMID)"
```

### 2. Notarization credentials (App Store Connect API key)

App Store Connect → Users and Access → Integrations → create an **API Key** (role: Developer).
Download the `AuthKey_XXXXXX.p8`. Note the **Key ID** and **Issuer ID**.

For local runs you can instead store a notarytool profile once:

```bash
xcrun notarytool store-credentials anywhere-notary \
  --key AuthKey_XXXXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
# then run releases with NOTARY_PROFILE=anywhere-notary
```

### 3. Sparkle EdDSA keys

Generate the signing key pair once (the private key is stored in your login keychain):

```bash
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
# prints the PUBLIC key — paste it into project.yml → SUPublicEDKey (replace the placeholder)
```

Export the **private** key for CI (keep it secret):

```bash
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private_key.pem
```

After setting `SUPublicEDKey`, re-run `make gen`.

The update feed is `https://raw.githubusercontent.com/AnyWhereTools/AnyWhere/main/appcast.xml`.
Publish an AnyWhere release and its feed in this repository; the upstream project's feed
is not used. Automatic checks are enabled by default and run silently on launch. Only
available updates prompt the user; initialization errors are logged without showing an
alert. Manual checks remain unavailable until the updater is configured successfully.

### 4. GitHub Actions secrets

For the tag-triggered [`release.yml`](../.github/workflows/release.yml) workflow, add these
repository secrets (Settings → Secrets and variables → Actions):

| Secret | What |
|--------|------|
| `DEVELOPER_ID_CERT_P12_BASE64` | your Developer ID cert+key exported as `.p12`, then `base64` |
| `DEVELOPER_ID_CERT_PASSWORD` | the `.p12` export password |
| `KEYCHAIN_PASSWORD` | any string (temp CI keychain password) |
| `DEVELOPER_ID_APP` | `Developer ID Application: Your Name (TEAMID)` |
| `TEAM_ID` | your Apple Team ID |
| `NOTARY_KEY_ID` / `NOTARY_ISSUER` | from the API key above |
| `NOTARY_KEY_P8_BASE64` | the `AuthKey_XXXXXX.p8`, `base64`-encoded |
| `SPARKLE_ED_PRIVATE_KEY` | the Sparkle private key string |

Export the cert as base64: `base64 -i DeveloperID.p12 | pbcopy`.

---

## Cutting a release

### Locally

```bash
export DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)"
export TEAM_ID=TEAMID
export NOTARY_PROFILE=anywhere-notary        # from step 2
make release VERSION=1.0.0
```

This archives (Release, hardened runtime), exports a Developer ID app, builds a signed dmg,
notarizes + staples it, and prints the Sparkle signature. Artifact: `build/release/AnyWhere-1.0.0.dmg`.

### Via CI (recommended)

Commit the release changes, then create and push the version tag:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

The release script takes the version from the tag, overrides `MARKETING_VERSION`, and generates
an increasing `CURRENT_PROJECT_VERSION`. Keep the build-variable placeholders in `App/Info.plist`.

`release.yml` then builds, signs, notarizes, creates a GitHub Release with the dmg, regenerates
`appcast.xml`, and pushes it to `main`. Sparkle clients poll `SUFeedURL`
(`…/main/appcast.xml`) and offer the update.

---

## Checklist

- [ ] `SUPublicEDKey` in `project.yml` is your real Sparkle public key (not the placeholder).
- [ ] Verify the default background check (`SUEnableAutomaticChecks: true`): an available update prompts, while no update or a check failure does not. Manual checks still report their results.
- [ ] Version tag and the release script's version/build numbers are correct.
- [ ] All nine GitHub secrets set (for CI).
- [ ] `xcrun stapler validate build/release/AnyWhere-<v>.dmg` passes.
- [ ] Gatekeeper check on a clean machine: `spctl -a -vvv -t install AnyWhere-<v>.dmg`.
