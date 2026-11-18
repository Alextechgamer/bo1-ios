# Source provenance

The UIKit host, platform bridge, portable helpers and Metal WSI provider in
this project were written for this initial implementation. No BO1 engine,
commercial game data, BO2 HUD or Steam service source is vendored here.
The pinned upstreams are recorded in `docs/ENGINE_PORT_GATES.md`.

The DXVK patch modifies upstream DXVK v2.6.1. Its license notice is preserved
at `graphics/DXVK-LICENSE`; retain it with redistributed altered code. The
patch/provider are additional or altered work, not upstream DXVK releases.

Dependency checkouts are fetched separately. Preserve their own license and
notice files when integrating or redistributing them. No project-wide license
is selected for the newly authored source in this initial project.

`scripts/ios_dependencies.json` additionally pins SDL2 (zlib license), FFmpeg
(LGPL 2.1-or-later for the enabled configuration; GPL/nonfree components are
not enabled), and MoltenVK (Apache 2.0). Their source and license notices remain
part of the fetched distributions. The optional audio target compiles native
audio source directly from the pinned BO1 upstream checkout. Any eventual
binary distribution must include the applicable dependency notices and source
/relinking materials; this repository currently distributes integration source.
