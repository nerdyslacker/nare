<div align="center">
<a href="https://github.com/nerdyslacker/nare"><img src="assets/nare.png" width="120"/></a>
</div>
<h1 align="center">nare terminal</h1>
<div align="center">

[![License](https://img.shields.io/github/license/nerdyslacker/nare)](https://github.com/nerdyslacker/nare/blob/main/LICENSE)
[![GitHub release](https://img.shields.io/github/release/nerdyslacker/nare)](https://github.com/nerdyslacker/nare/releases)
<a href="https://app.commanddash.io/agent?github=https://github.com/nerdyslacker/nare"><img src="https://img.shields.io/badge/AI-Code%20Assist-EB9FDA"></a>
[![GitHub stars](https://img.shields.io/github/stars/nerdyslacker/nare)](https://github.com/nerdyslacker/nare/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/nerdyslacker/nare)](https://github.com/nerdyslacker/nare/fork)

</div>

`nare` is an experimental X11-only terminal emulator written in Odin.

## Features

- Native VT parser with Unicode, true color, mouse, focus, and bracketed-paste support.
- Fontconfig, FreeType, and HarfBuzz text rendering with configurable ligatures.
- Automatic OpenGL rendering with CPU fallback and a separate CPU-only build.
- Bounded scrollback with search, a scrollbar, text selection, clipboard support, and URL hints.
- Kitty Graphics, Sixel, and iTerm2 inline images with scaling, transparency, and scrolling.
- OSC title, working-directory, hyperlink, clipboard, and shell-integration sequences plus bundled terminfo.

## Dependencies

Void Linux and LazyLinux use the same XBPS packages:

```sh
sudo xbps-install -S base-devel libX11-devel fontconfig-devel freetype-devel harfbuzz-devel libglvnd-devel ncurses
```

Install Odin `dev-2026-10` separately and make sure `odin` is in `PATH`.

The binary requires `libX11 fontconfig freetype libharfbuzz libglvnd`. A usable font is required (`dejavu-fonts-ttf` is a small default), and `xdg-utils` enables the default URL opener.

Build and run:

```sh
make
./build/nare
```

`nare` uses OpenGL when available and falls back to CPU rendering. `make cpu` builds the optional no-OpenGL `build/nare-cpu` binary.

Configuration is loaded from `$XDG_CONFIG_HOME/nare/nare.conf`, or `~/.config/nare/nare.conf`. Copy [nare.conf](nare.conf) as a starting point; command-line options override it.
