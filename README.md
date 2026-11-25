<p align="center">
  <img src="assets/readme/icon.svg" alt="" width="160">
</p>

<h1 align="center">Swipterm</h1>

<p align="center">A Linux environment and Ghostty-based terminal for iOS.</p>

<p align="center">
  <a href="https://testflight.apple.com/join/Sqgw9nc5"><img src="assets/readme/testflight-badge.svg" alt="Join the beta on TestFlight" height="40"></a>
  <a href="https://github.com/swipt-automation/Swipterm/releases/tag/nightly"><img src="assets/readme/github-releases-badge.svg" alt="Get it on GitHub Releases" height="40"></a>
</p>

## Features

- **Any distribution, any Linux kernel**: Boots unmodified ARM64 Linux kernels from built-in distros or your own rootfs.
- **Fast out of the box**: Powered by a custom ARM64 emulator in [SwiptermKit](https://github.com/swipt-automation/SwiptermKit) that stays fast even without JIT.
- **Optional automatic JIT**: Automatically enables native ARM64 JIT via Swipt on sideloaded builds.
- **Native Ghostty terminal**: Built on `libghostty` with native iOS host integration.

## Installation

Join the [Swipterm public beta](https://testflight.apple.com/join/Sqgw9nc5) on TestFlight.

Add the [Nightly](https://github.com/swipt-automation/Swipterm/releases/tag/nightly) source to SideStore or AltStore:

```text
https://github.com/swipt-automation/Swipterm/releases/download/nightly/altstore.json
```

Or download [Swipterm.ipa](https://github.com/swipt-automation/Swipterm/releases/download/nightly/Swipterm.ipa) and sideload it.

## Run in the background

To run in the background using low-precision location (which does not actually activate your GPS or drain your battery), run `swipterm caffeinate` in the terminal. This turns on background execution and shows a toggle in Settings.

## Benchmarks

| Benchmark                                     | Swipterm (with JIT) | Swipterm | iSH-arm64           | iSH                 |
|-----------------------------------------------|---------------------|----------|---------------------|---------------------|
| Lua 5.4.9 (`make -j6`)                        | **25.57s**          | 41.04s   | 39.86s              | 88.21s              |
| Git 2.52.0 (`tar -xf` + `git add`)            | **7.63s**           | 14.41s   | 19.52s              | 48.38s              |
| sing-box 1.14.4 (`go build -p 6`, cold cache) | **292.68s**         | 411.90s  | Crashed (`SIGSEGV`) | Crashed (`SIGSEGV`) |

## License

```text
Copyright (C) 2026 by nekohasekai <i@sekai.icu>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <http://www.gnu.org/licenses/>.

In addition, no derivative work may use the name or imply association
with this application without prior consent.
```
