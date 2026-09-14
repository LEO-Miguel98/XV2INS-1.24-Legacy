# XV2INS 1.24 Legacy Build

This repository builds an **unofficial legacy-compatible XV2 Mods Installer** for Dragon Ball Xenoverse 2 **1.24.x**.

The build is intentionally based on the 1.24-era source line instead of bypassing the modern XV2INS 4.7 version check. XV2INS 4.7 targets newer 1.25/1.26 data formats, so simply changing the minimum version would risk writing incompatible game data.

## Target

- Game: Dragon Ball Xenoverse 2 1.24.x (including 1.24.1)
- Installer source: HAWGT/xv2ins 4.5-era commit
- Common GUI source: HAWGT/xv2ins_common 4.5-era commit
- Common format source: HAWGT/eternity_common 4.5-era commit
- Windows x64 / Qt 6

## Safety

- No Roblox, Steam, game, GitHub, or other credentials are used.
- GitHub Actions receives read-only repository permissions.
- Upstream source revisions are pinned by full commit SHA.
- The workflow builds a separate executable; it does not patch your original XV2INS 4.7 executable.

## Status

Initial legacy build pipeline setup in progress.
