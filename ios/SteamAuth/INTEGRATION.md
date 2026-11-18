# Steam client integration

The reusable client is pinned to the BO2 source revision recorded in
[UPSTREAM.md](UPSTREAM.md) and [IMPORT.json](IMPORT.json). It signs in to Valve
and downloads depots that Valve authorizes for that account. It does not launch
the game, provide a Steam game ticket, or supply game assets in the app bundle.

## Build inputs

`cmake/steam-sources.cmake` supplies `BO1_STEAM_CORE_SWIFT_SOURCES` and
`BO1_STEAM_CONTENT_C_SOURCES`. The Swift client and BO1 installer UI must be
compiled in the same Swift module because the imported interfaces are internal.
Use Swift language version 5 with the iOS 16 deployment target.

`ios/SteamSwiftBridge.h` exposes the real zip, LZMA, Zstandard and contained-file
C helpers. It deliberately imports no BO2 engine provider. The UIKit entry point
is declared in `ios/SteamAuth/BO1SteamSignIn.h`:

```objc
[BO1SteamSignIn presentFromViewController:presenter];
```

Link Foundation, UIKit, SwiftUI, Security, CoreImage, Compression, `libz` and
`liblzma`. CommonCrypto comes from the Apple SDK. There is no Swift Package
Manager package, Steam Web API developer key, embedded Valve credential or
third-party sign-in service. The final app embeds the Swift runtime as required
by its Xcode toolchain.

## API contract

| Operation | Interface |
| --- | --- |
| Password, QR, Steam Guard UI | `SteamSignInView`, backed by `SteamSignInModel.shared` |
| Current account | `SteamSignIn.accountName`, `SteamSignIn.isSignedIn` |
| Account changes | `SteamSignIn.didChange`, `SteamSignIn.revision` |
| Sign out | `SteamSignIn.signOut() -> Bool`; false preserves the existing session and reports Keychain deletion failure |
| CM session | `SteamSession()`, using the stored refresh token |
| All owned apps, including DLC | `SteamLibraryFetcher.ownedAppIDs()` |
| Owned depot IDs | `SteamLibraryFetcher.ownedDepotIDs()` |
| Current manifests and shared metadata | `fetchInstallInfo(appID:language:includeDLC:)` |
| Download exact selection | `DepotDownloader.install(_:into:journals:selectedDepotIDs:reusing:ownedDepots:progress:)` |
| Result | `SteamInstallResult.relativeFiles`, the validated regular paths in the selected current manifests |

The coordinator supplies a nonempty `selectedDepotIDs` set selected from current
PICS metadata. Every explicitly selected depot must return a usable depot key;
a denied depot fails the job. Metadata, depot lists and local caches do not grant
access. Steam still decides depot-key, manifest and content authorization.

Use a private staging directory for `into` and the existing `Documents/game`
directory for optional `reusing`. Existing bytes are read through contained file
descriptors and copied only when their SHA-1 matches the current manifest.
`relativeFiles` excludes stale files left in staging by previous selections.
The coordinator publishes only that result after the download succeeds. Do not
recursively copy the staging directory or treat downloaded bytes as a playable
engine.

The caller permits one install at a time, cancels and drains it before starting
another, and invalidates the session/fetcher/downloader after account changes.
Cancel the calling task to stop; parsing/preparation receives cancellation and
structured chunk workers drain before the async operation returns. Suspend a
download when the app actually enters the background. A transient inactive
state during a Steam Guard approval or system dialog must not cancel sign-in.

## Integrity and containment

Manifest paths are validated before file creation. A root descriptor and
`openat`/`O_NOFOLLOW` walks reject symbolic links, hard-linked files, nonregular
files, traversal and absolute paths. Offset and size checks prevent writing
outside each manifest file. Two selected depots claiming conflicting contents
for the same case-folded path fail explicitly; ordering an unordered metadata
dictionary is not used to resolve content conflicts.

Every downloaded chunk checks its size, supplied Adler-32 and manifest SHA-1.
Resume journals are hints: recorded chunks must still match the bytes on disk.
Journal names include the depot and manifest IDs. A changed manifest cannot
silently reuse a previous manifest's completion keys.

Authentication uses ephemeral URL sessions without persistent cookies, URL
caches or credential stores. The explicit saved session uses the app's Keychain
service with `WhenUnlockedThisDeviceOnly`. No credentials or content URLs with
authorization tokens are logged. `BO1_STEAM_TRACE=1` enables sanitized protocol
diagnostics; it is off by default.

The portable file-helper tests exercise the actual C implementation. The macOS
host fixture tests cover selected metadata and content behavior; the iOS build
verifies the real Apple SDK and link inputs. None substitutes for an authorized
on-device Steam sign-in/download test, which requires the user's account and
Steam Guard approval.
