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

`nare` pronounced nah-reh (/nɑːrɛ/) is an experimental X11-only terminal emulator written in Odin.

## Features

- Native VT parser with Unicode, true color, alternate screens, synchronized updates, mouse, focus, and bracketed paste.
- Fontconfig, FreeType, and HarfBuzz rendering with font fallback, combining and wide characters, color glyphs, and configurable ligatures.
- Automatic OpenGL rendering with CPU fallback and a separate CPU-only build.
- Native tabs and split/stack pane layouts with configurable shortcuts and a red tab warning for root foreground sessions.
- Automatic tmux `-CC` detection with native window tabs and split-pane views, local/SSH profiles, bounded reconnect, external-state reconciliation, and detach/restoration.
- Bounded, resize-reflowing scrollback with incremental search, smooth wheel navigation, and a draggable scrollbar.
- X11 PRIMARY and CLIPBOARD selection, bracketed paste, large INCR transfers, OSC 8 links, and keyboard URL hints.
- Kitty Graphics, Sixel, and iTerm2 inline images with scaling, transparency, clipping, scrolling, and CPU/GPU composition.
- OSC 0/2/7/8/52/133 and XTGETTCAP support, including prompt navigation and command-output copy or piping.
- Runtime configuration, bounded image and transfer resources, and bundled terminfo.
- Optional local server/client mode with isolated windows, bounded authenticated IPC, and waiting or detached client launches.

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

## Server mode

Server mode is optional; ordinary `nare` launches remain standalone and never contact a daemon.

```sh
nare --server
nare --client
nare --client -e htop
nare --client --no-wait /path/to/project
```

By default the private socket is `$XDG_RUNTIME_DIR/nare.sock`. Both endpoints verify same-user peer credentials. `--server-socket=PATH` selects an explicit path for supervised or test setups.

The server owns all X11 windows, PTYs, terminal state, and rendering. A waiting client exits with its terminal child's status; disconnecting that client closes its associated window. `--no-wait` transfers the window lifetime to the server after creation. A server crash or shutdown closes every server-owned window and session; this mode does not promise persistence or reconnection.

An explicitly launched server stays alive when its last window closes. Stop it with `SIGINT` or `SIGTERM`; service managers may impose a different lifetime policy.

The server's configuration controls window appearance. Client requests currently transfer the command and working directory; per-client rendering overrides are not implemented yet. Panes and simultaneous server windows at the same font size share font faces, shaping resources, and the bounded glyph cache, while each pane keeps independent CPU/GPU and X11 renderer state.
