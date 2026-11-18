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
