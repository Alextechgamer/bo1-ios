# Steam sign-in and game-file downloads

The app's **Game files** screen reuses the native Swift Steam authentication,
connection and content client from
[`Alextechgamer/bo2-ios` at `26aad790810596cf1038a5bca42bcf8789ccb54f`](https://github.com/Alextechgamer/bo2-ios/tree/26aad790810596cf1038a5bca42bcf8789ccb54f/ios).
It does not require a separate PC download service or a Steam Web API key.
Downloads install into **Documents/game** in this app's sandbox.

The diagnostics app exposes the screen directly. The eventual game host uses
the same provider when its host-services adapter does not supply a custom
downloader. Downloading an installation does not make the currently unavailable
game engine runnable.

## Sign-in flow

The reused sign-in sheet supports a Steam account name and password, Steam
Guard codes or mobile approval, and a QR code scanned with Steam Mobile on
another device. Credentials are entered in the app, not supplied to GitHub
Actions or this repository. Authentication calls go to Steam over HTTPS.

Only the saved session tokens and associated account information are retained
in an app-specific Keychain item, using
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Passwords and Guard codes are
not written to disk. Authentication networking uses an ephemeral session with
no persistent URL cache, cookie store or credential store. Sign-out checks
the Keychain deletion result and reports a failure instead of claiming that
a retained token was removed. Account changes invalidate active work.

Steam session validity and depot access are decided by Steam. A locally saved
token is not proof of a current server session or content entitlement. The
client uses its authenticated CM connection for license lists, product info,
manifest request codes and depot decryption keys. Logs omit passwords, tokens,
Guard codes and authentication payloads; the diagnostics report does not
include the Steam account or its credentials.

## BO1 packages and manifests

| Selection | Ownership AppID | Content behavior |
| --- | --- | --- |
| Campaign and Zombies files | 42700 | Required base selection |
| Multiplayer / Combat Training files | 42710 | Optional |
| First Strike | 42716 | Optional, owned DLC only |
| Escalation | 42718 | Optional, owned DLC only |
| Annihilation | 42722 | Optional, owned DLC only |
| Rezurrection | 42719 | Optional, owned DLC only |

These are **application ownership identifiers**, not a depot or manifest
table. Valve's [base-game metadata](https://store.steampowered.com/api/appdetails?appids=42700&l=english&cc=us)
lists the four DLC applications, and their individual store records identify
[First Strike](https://store.steampowered.com/app/42716/),
[Escalation](https://store.steampowered.com/app/42718/),
[Annihilation](https://store.steampowered.com/app/42722/) and
[Rezurrection](https://store.steampowered.com/app/42719/).
[Valve's multiplayer community page](https://steamcommunity.com/app/42710)
identifies the separate multiplayer application.

The original handoff conflated some application and depot identifiers. This
implementation requests current Steam product information (PICS) and resolves
public manifests and shared-depot relationships from that metadata. It selects
Windows content for the original 32-bit game, excludes shared redistributables,
and exposes matching language choices with English as the initial preference.
Steam metadata and authorization must resolve every selected package; missing
or conflicting metadata is an error, not a reason to guess a manifest ID or
silently report an incomplete selection as installed. Valve describes shared
depot behavior in its [depot documentation](https://partner.steamgames.com/doc/store/application/depots).

## Installation, cancellation and recovery

Downloads are explicit user actions. The UI presents progress and a cancel
control; downloading/repairing does not launch an engine. Backgrounding pauses
the transfer. Authentication is not cancelled merely because the application
temporarily resigns active, which is needed when approving Steam Guard.

Content is staged privately before publication into Documents/game. Completed
chunks can be reused on resume, but they are verified against the current
manifest instead of trusting a journal entry alone. Downloaded chunks are
decrypted, decompressed and checked against their manifest checksums.

File operations reject path traversal, symlinks and unsafe nonregular targets.
The content writer uses directory-descriptor-relative operations so a path
rename cannot redirect a chunk into another directory. The publication step
keeps rollback information for files it replaces and leaves unrelated user
files alone. Repairs can replace a selected manifest's game files.

While publishing, `Documents/game/.bo1-install-in-progress.json` closes the
native host's startup gate, even if `common.ff` already exists. Recovery must
complete the transaction or its rollback before removing that marker. A
damaged or dangling marker does not count as a completed install. The host's
download completion callback runs only after writing has stopped, so startup
cannot race installation work.

The app enables Files sharing. Its Documents directory appears under the app's
displayed name; the packaged diagnostics app is **BO1 Port Diagnostics**, and
the game files are in its **game** folder. Session tokens stay in Keychain and
download journals/staging stay outside that shared game directory.

## Build and verification boundaries

`cmake/ios_steam.cmake` builds the Swift client/UI in one module using Swift 5
language mode, plus the C chunk decoders and contained-file helper. It links
the system Apple frameworks, libcompression, zlib and liblzma. No BO2 runtime, translated game
memory or game-ticket adapter is needed for these downloads.

The workflow runs the real C filesystem containment tests and Swift fixtures
against the actual package-selection, content-verification and install-recovery
implementations, then compiles and links the complete
iPhone app. The package retains the imported notices, source pins and source
hashes. See [source notices](../THIRD_PARTY_NOTICES.md).

Offline fixture tests and an Apple SDK build do not establish that a real
account completed Steam Guard or a multi-gigabyte download on an iPhone.
Current observed results, including that distinction, are recorded in
[VALIDATION.md](VALIDATION.md).
