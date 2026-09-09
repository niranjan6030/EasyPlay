# Third-party software

EasyPlay orchestrates other people's software; it does not include it.

| Project | Licence | Relationship |
|---|---|---|
| [Wine](https://www.winehq.org) | LGPL-2.1 | Runs the games. Invoked as an external process. |
| [Game Porting Toolkit / D3DMetal](https://developer.apple.com/games/) (Apple), packaged by [Gcenx](https://github.com/Gcenx) | Apple's terms | The Wine build EasyPlay targets, and the DirectX-to-Metal translator. |
| [DXVK](https://github.com/doitsujin/dxvk) | zlib | Optional per-preset graphics translator. |
| [MoltenVK](https://github.com/KhronosGroup/MoltenVK) | Apache-2.0 | Vulkan-to-Metal, used only by the DXVK path. |
| [Winetricks](https://github.com/Winetricks/winetricks) | LGPL-2.1 | Installs Windows runtimes into a bottle. |

All of these are installed separately by the user through Homebrew and are driven
as external processes. No part of any of them is copied into this repository,
linked against, or redistributed, so their licence terms attach to the user's own
installations rather than to this project.

[Whisky](https://github.com/Whisky-App/Whisky) (GPL-3.0, archived 2025) is cited
in the README as prior art. No code from it is used here.

The MIT licence in [LICENSE](LICENSE) covers this project's own source, presets
and documentation.
