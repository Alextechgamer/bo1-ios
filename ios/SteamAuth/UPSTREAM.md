# BO1 Steam client provenance

This port imports the reusable Steam authentication, CM transport, license/PICS,
metadata and content sources from
[Alextechgamer/bo2-ios](https://github.com/Alextechgamer/bo2-ios/tree/26aad790810596cf1038a5bca42bcf8789ccb54f/ios)
at commit `26aad790810596cf1038a5bca42bcf8789ccb54f`. `IMPORT.json` records the
original paths and SHA-256 hashes. Per-file notices, `COPYING`,
`LICENSE-EXCEPTION.md`, the upstream sign-in document and `ZSTD-LICENSE` are
retained. The license exception is reproduced as supplied by upstream; this
record does not extend its scope or assign a license to the BO1 engine or game.

The BO1 adaptation uses a BO1 UIKit bridge, app-specific Keychain service and
notification/environment names. Password/RSA, QR, Steam Guard, CM login and
Valve-controlled depot authorization are retained. Authentication and CM HTTP
sessions use ephemeral storage; sign-out checks the Keychain deletion result.
No BO2 game runtime, ticket adapter, player storage, converted executable,
account credential or game asset was imported. Unused played-game and encrypted
ticket protobuf wrappers were removed. The original BO2 provenance below also
mentions those excluded BO2 components and is preserved for attribution only.

Installer changes add explicit live-metadata depot selection, all owned app IDs
(including DLC), inherited shared-depot restrictions, checked package KeyValues
parsing, no-follow descriptor-based file access, current-manifest file results,
read-only reuse of an existing install, SHA-1 checks on downloaded and resumed
chunks, malformed-size/range checks and cancellation forwarding to worker tasks.
The caller stages files privately before publishing them to `Documents/game`.
Files from conflicting depot manifests fail instead of selecting arbitrary
unordered contents. `INTEGRATION.md` describes the APIs and build inputs.

The binary package header and type rules were checked against
[SteamKit SteamApps callbacks](https://github.com/SteamRE/SteamKit/blob/7c6e2f0309aa2d33c0769d18cf799450c0d02f91/SteamKit2/SteamKit2/Steam/Handlers/SteamApps/Callbacks.cs)
and
[SteamKit KeyValue](https://github.com/SteamRE/SteamKit/blob/7c6e2f0309aa2d33c0769d18cf799450c0d02f91/SteamKit2/SteamKit2/Types/KeyValue.cs).
Those implementations were used as protocol references; no SteamKit source is
included in this Swift port.

## Retained BO2 upstream provenance

# Steam authentication source

The Swift sign-in files were adapted from [kuscholar/iDeck](https://github.com/kuscholar/iDeck/tree/2ac39beff91251d36f3ad6331d3f8402b3c10e18/app/Madeira/SwiftSteam) at commit `2ac39beff91251d36f3ad6331d3f8402b3c10e18`.

Copyright 2026 Jfishin and 125hz, as identified in each source file. The iDeck-authored additions use GPL-3.0-or-later with the Madeira Converter Exception. See COPYING, LICENSE-EXCEPTION.md and the retained upstream provenance in docs/STEAM_SIGNIN.md. The upstream document describes iDeck's integration.

The BO2 adaptation adds a UIKit bridge, uses an app-specific Keychain service, replaces Madeira configuration and logging dependencies, supports the port's iOS 16 deployment target, checks cancellation at authentication network boundaries and updates existing Keychain sessions without deleting them first. The launcher exposes account sign-in and sign-out.

The original transport, protobuf, RSA and Steam Guard code retains its upstream notices. No account credentials, Steam executables or game data are included in these sources.

The same pinned revision supplies the CM WebSocket/session, license/PICS and metadata files under ../SteamServices/. Their per-file authorship and license notices are retained. The BO2 coordinator uses iOS 16-compatible state, shared refresh operations and account-generation invalidation. These files use the license and exception provided here.

The same pinned revision supplies the content download files under ../SteamServices/Content/: the depot downloader, manifest parser, chunk decryption and the LZMA, zip and Zstandard chunk decoders. The BO2 adaptation installs into the app's own game folder, writes no Steam install record and keeps no manifest cache; the manifest path check comes from the same revision's `SteamInstall.swift`. `zstd_edu.c` is Meta's Zstandard educational decoder under its own licence.

The BO2 encrypted-ticket adapter follows the [CM request/response schema](https://github.com/SteamDatabase/Protobufs/blob/master/steam/steammessages_clientserver.proto) and [encrypted envelope schema](https://github.com/SteamDatabase/Protobufs/blob/master/steam/encrypted_app_ticket.proto). It preserves the full nested encoding, consistent with [node-steam-user's encrypted-ticket API](https://github.com/DoctorMcKay/node-steam-user/blob/master/components/appauth.js). Duplicate requests and the one-minute interval follow [Valve's RequestEncryptedAppTicket documentation](https://partner.steamgames.com/doc/api/ISteamUser#RequestEncryptedAppTicket). Ticket contents are never logged.

The same CM schema supplies played-game notifications. Their local state records an announcement, not game-service acceptance. The adaptation also corrects the imported CM control-message numbers to LogOnResponse 751, LogOff 706 and LoggedOff 757, checked against the [protocol message enum](https://github.com/DoctorMcKay/node-steam-user/blob/master/enums/EMsg.js). An explicit server logoff clears identity and pending work without an automatic reconnect.
