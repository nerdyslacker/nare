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

- Native VT parser with Unicode, true color, alternate screens, synchronized updates, mouse, focus, and bracketed paste.
- Fontconfig, FreeType, and HarfBuzz rendering with font fallback, combining and wide characters, color glyphs, and configurable ligatures.
- Automatic OpenGL rendering with CPU fallback and a separate CPU-only build.
- Native tabs and split/stack pane layouts with configurable shortcuts and a red tab warning for root foreground sessions.
- Bounded, resize-reflowing scrollback with incremental search, smooth wheel navigation, and a draggable scrollbar.
- X11 PRIMARY and CLIPBOARD selection, bracketed paste, large INCR transfers, OSC 8 links, and keyboard URL hints.
- Kitty Graphics, Sixel, and iTerm2 inline images with scaling, transparency, clipping, scrolling, and CPU/GPU composition.
- OSC 0/2/7/8/52/133 and XTGETTCAP support, including prompt navigation and command-output copy or piping.
- Runtime configuration, bounded image and transfer resources, and bundled terminfo.

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

Run `nare /path/to/folder` to open a shell in that folder. `make install` also installs the desktop entry used by file managers for **Open with nare**.
