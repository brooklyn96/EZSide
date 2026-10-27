# iPASideCertImport.dylib

A ~10 KB dylib injected into LiveContainer at sign time. It reads a certificate import
request that iPASide leaves in LiveContainer's `Documents` directory and writes the
signing certificate into LiveContainer's app group preferences, so JIT-less mode works
without the user picking a `.p12` out of a file browser by hand.

## Why it is needed

LiveContainer reads its signing certificate from the app group's `UserDefaults` suite:

```objc
NSUserDefaults* nud = [[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]];
if(!nud) { nud = NSUserDefaults.standardUserDefaults; }
return [nud objectForKey:@"LCCertificateData"];
```

That suite is a plist inside the shared app group container, and iPASide cannot write it
from Windows. `house_arrest` starts an AFC server in the target app's sandbox and vends
the app's own container; directory listings traverse `..` happily, but `GET_FILE_INFO`
and `FILE_OPEN` both fail with status 7 for any path outside the vended container. So the
group container can be *enumerated* from a PC but not read or written - verified on
iOS 16 hardware.

The `standardUserDefaults` fallback above is not a way around it either: it only triggers
when the suite cannot be created, which never happens once the app group entitlement is
granted - and that entitlement is precisely what JIT-less mode requires.

That leaves one option: run the write inside LiveContainer. iPASide writes the request
into `Documents` (reachable, because LiveContainer declares `UIFileSharingEnabled`) and
injects this dylib, whose constructor performs the same writes LiveContainer's own
`importCertificate()` performs.

## The request

`Documents/iPASide-cert-import.plist`:

| Key | Type | Meaning |
| --- | --- | --- |
| `AppGroupID` | string | `group.com.SideStore.SideStore.<TEAM>` |
| `CertificateData` | data | the PKCS#12 iPASide signs with |
| `CertificatePassword` | string | its password |

On success the dylib removes both the request and the loose `iPASide-certificate.p12`,
since that file is the signing identity and `Documents` is exposed by the Files app. On
any failure it leaves both in place and logs the reason to the device console, so the
manual import through LiveContainer's Settings remains available as a fallback.

## Building

Only builds on macOS - it needs Xcode's iPhoneOS SDK, which is why the binary is
committed rather than built during packaging:

```bash
bash tools/lc-cert-import/build.sh
```

CI does this on a `macos-latest` runner (`.github/workflows/build-lc-helper.yml`) and
uploads the result as an artifact; commit that artifact to
`src/iPASide.Engine/ipaside_engine/vendor/`.

LiveContainer and all three of its bundled dylibs are arm64-only, so this is built as a
single arm64 slice.
