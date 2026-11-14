# Release preflight checklist

Run this before every TestFlight or App Store upload. The script does the mechanical part; the rest is a short manual list.

```bash
scripts/heavy.sh --task <ID> -- env CONFIG=Release scripts/build.sh      # an unsigned Release simulator build for the script to inspect
scripts/heavy.sh --task <ID> -- env CONFIG=Release scripts/build-mac.sh  # same for the Mac app
STORE=1 scripts/preflight.sh                                # the store gate: needs your own bundle ID prefix and a built app
PREFLIGHT_PLATFORMS=ios STORE=1 scripts/preflight.sh        # store gate for the iPhone and watch apps only (what validate-archive.sh runs)
scripts/preflight.sh --self-test                            # checks the checker, no Xcode needed
scripts/validate-archive.sh                                 # after scripts/archive.sh: preflight on the archive, then altool
```

`STORE=1` fails on purpose in a fresh clone: `Config/Local.xcconfig` is missing, so the bundle ID prefix is still `com.example`.
Without `STORE=1` the script reports that as a skip, because a self-build is allowed to use it.

## Which builds it inspects

Only Release-type products: `Release` and `Store Release` under `build/DerivedData/Build/Products`, the archive, or a path you give in
`PREFLIGHT_IOS_APP` or `PREFLIGHT_MAC_APP`. Debug builds always embed home paths, so they are never scanned. If the only app on disk
is a Debug one, the script prints a warning that names it and skips the binary checks (it does not report a pass for them).
Test bundles (`*.xctest`) and `*.debug.dylib` files are never scanned.

## What the script checks

| Check | Fails when |
|---|---|
| Versions | `MARKETING_VERSION` or `CURRENT_PROJECT_VERSION` is set more than once, an app does not read them, or a built app shows a different number |
| Export compliance | `ITSAppUsesNonExemptEncryption` is missing or not false in any of the three apps, or the sources hold third-party crypto |
| Privacy manifests | a manifest does not parse, tracking is on, or a reason code is not one Apple lists for that category |
| Required-reason APIs | the sources or a built binary use an API in one of the five categories and the manifest does not declare it |
| Usage strings | the code can trigger a permission prompt (microphone, speech, camera, local network and others) with no purpose string, or a string reads like a placeholder |
| App icons | the phone or watch icon has an alpha channel, or there is no 1024 by 1024 file |
| Private denylist | a term from the denylist `scripts/check-public.sh` uses appears inside a built app. Terms print as their first 3 letters |
| Bundle ID prefix | `STORE=1` and the prefix, or a built bundle ID, starts with `com.example` |

A warning never fails the run. The Mac app has no privacy manifest yet, so it warns normally and fails under `STORE=1`.

## Export compliance: why `ITSAppUsesNonExemptEncryption` stays false

The key tells App Store Connect that the app uses no encryption beyond what Apple's operating system provides, which is exempt.
That holds only while every piece of crypto in the app is Apple's own. Today that is:

- **CommonCrypto**: PBKDF2 for the pairing key.
- **CryptoKit**: HKDF for the sync keys.
- **Network framework**: TLS 1.2 with a pre-shared key for Mac and iPhone sync.
- **CloudKit** (when iCloud sync ships): Apple's transport and storage encryption. The app holds no keys of its own.
- **StoreKit** (when the one-time purchase ships): Apple's signed transactions. The app only checks what StoreKit returns.

Before each upload, re-read Apple's export compliance page to confirm this still holds. Change the key to true, and answer the
questions in App Store Connect, if the app ever adds:

- a crypto library (OpenSSL, libsodium, CryptoSwift and similar),
- its own cipher, or a cipher Apple's frameworks do not provide,
- encrypted data sent to a server that is not Apple's.

The script looks for the first kind in the sources and lists the Apple crypto frameworks it sees. It cannot judge the other two, so a person decides.

## Privacy manifests

- The phone app declares UserDefaults (`CA92.1`) and system boot time (`35F9.1`). The watch app declares system boot time (`35F9.1`).
- Adding code that reads file dates, free disk space, or the active keyboards needs a manifest entry first. The script tells you which category.
- Third-party SDKs would need their own manifests. There are none.

## Manual items the script cannot check

1. Xcode is a release build, not a beta (`xcode-select -p`, Xcode > About Xcode).
2. Agreements are accepted in App Store Connect.
3. The build number is new for this version (`scripts/bump-build.sh`).
4. The privacy answers in App Store Connect still say "Data Not Collected".
5. For the iCloud build, the container and the StoreKit product exist in App Store Connect with the same IDs the app uses.
6. After upload, no ITMS email arrives within 30 minutes, and the privacy report in App Store Connect lists what you expect.

The longer first-upload steps are in `docs/testflight-checklist.md`.
