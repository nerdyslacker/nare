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

`nare`, pronounced nah-reh (/nɑːrɛ/), is an experimental X11-only terminal emulator written in Odin.

<div align="center">
    <img src="assets/screenshot.png"/>
</div>

## Features

- Nare parses VT/ANSI sequences, Unicode, true color, alternate screens, synchronized updates, mouse input, focus events, and bracketed paste.
- Fontconfig, FreeType, and HarfBuzz provide fallback fonts, wide and combining characters, color glyphs, and ligatures.
- The OpenGL renderer falls back to the CPU renderer after initialization or drawing errors. `nare-lite` provides a CPU-only build.
- Native tabs support split and stacked panes, font zoom, named command rules, close confirmation, and root-session warnings.
- Bounded scrollback reflows after resize and supports search, prompt navigation, wheel scrolling, and a draggable scrollbar.
- Nare handles X11 PRIMARY and CLIPBOARD, OSC 8 links, URL hints, command-output copy, and output pipes.
- Kitty direct graphics, Sixel, and iTerm2 inline images share bounded CPU and GPU image paths.
- tmux control mode maps tmux windows and panes to native Nare views across local or SSH sessions.
- The status bar can show shell metadata, jobs, system resources, Git state, and zoom. Server and Quake modes remain optional.

## Install

### Dependencies

| Component | Use | Required |
|---|---|---|
| Odin `dev-2026-10` | Compiler and core library | Yes |
| libX11, libXext, libXrandr | Windows, input, selections, and monitor geometry | Yes |
| Fontconfig, FreeType, HarfBuzz | Font discovery, rasterization, and shaping | Yes |
| zlib | Kitty raw-pixel and PNG decompression | Yes |
| OpenGL and GLX | GPU renderer in `nare` | Full build only |
| `tic` from ncurses | Bundled `nare` terminfo entry | Install only |
| tmux | Native control-mode integration | Optional |
| `xdg-open` and Git | URL opening and complete status-bar Git data | Optional |

Install the build tools and native libraries for your distribution.

#### Void Linux/LazyLinux

```sh
sudo xbps-install -S base-devel libX11-devel libXext-devel libXrandr-devel \
  fontconfig-devel freetype-devel harfbuzz-devel libglvnd-devel zlib-devel ncurses
```

#### Arch Linux

```sh
sudo pacman -S --needed base-devel libx11 libxext libxrandr fontconfig \
  freetype2 harfbuzz libglvnd zlib ncurses
```

#### Debian/Ubuntu

```sh
sudo apt install build-essential libx11-dev libxext-dev libxrandr-dev \
  libfontconfig1-dev libfreetype-dev libharfbuzz-dev libgl-dev zlib1g-dev ncurses-bin
```

#### Fedora

```sh
sudo dnf install make libX11-devel libXext-devel libXrandr-devel \
  fontconfig-devel freetype-devel harfbuzz-devel libglvnd-devel zlib-devel ncurses
```

#### openSUSE

```sh
sudo zypper install make libX11-devel libXext-devel libXrandr-devel \
  fontconfig-devel freetype2-devel harfbuzz-devel libglvnd-devel zlib-devel ncurses-utils
```

#### Gentoo

```sh
sudo emerge --ask dev-build/make x11-libs/libX11 x11-libs/libXext \
  x11-libs/libXrandr media-libs/fontconfig media-libs/freetype \
  media-libs/harfbuzz media-libs/libglvnd sys-libs/zlib sys-libs/ncurses
```

#### Alpine Linux

```sh
sudo apk add build-base libx11-dev libxext-dev libxrandr-dev fontconfig-dev \
  freetype-dev harfbuzz-dev libglvnd-dev zlib-dev ncurses
```

#### Solus

```sh
sudo eopkg install -c system.devel
sudo eopkg install libx11-devel libxext-devel libxrandr-devel fontconfig-devel \
  freetype2-devel harfbuzz-devel libglvnd-devel zlib-devel ncurses-devel
```

#### NixOS

```sh
nix-shell -p odin gnumake xorg.libX11 xorg.libXext xorg.libXrandr \
  fontconfig freetype harfbuzz libglvnd zlib ncurses
```

Run Nare from `build/` on NixOS or package it as a derivation. NixOS keeps `/usr` read-only, so `sudo make install` cannot write there.

Use Odin `dev-2026-10` and place `odin` in `PATH`. A usable font must exist on the system. `dejavu-fonts-ttf` supplies a small default set; `noto-fonts-emoji` adds color emoji.

### Build

`make` builds a development `nare` binary with OpenGL support. The release target builds optimized GPU and CPU-only binaries.

```sh
make
./build/nare

make build-lite
./build/nare-lite

make release
```

Run `sudo make install` to build and install both release binaries, desktop entries, icons, example configuration, and terminfo. Set `PREFIX` or `DESTDIR` for package builds.

## Configuration

Nare reads `$XDG_CONFIG_HOME/nare/nare.conf` or `~/.config/nare/nare.conf`. Copy [nare.conf](nare.conf) as a starting point. Command-line flags override file settings.

Use repeatable `include=` directives to split the file. Nare resolves relative paths from the file that contains the directive. Later values win.

```ini
include=bindings.conf
include=themes/catppuccin-mocha.conf
```

The `themes/` directory contains Catppuccin Mocha and Latte. Include a theme before local `[colors]` overrides.

`nare-lite` keeps an independent profile under `$XDG_CONFIG_HOME/nare-lite/nare.conf`, or `~/.config/nare-lite/nare.conf`.

Press `Alt+Shift+R` to reload the file. Nare keeps the current settings after a parse error. Set `[shell] startup-command=/usr/bin/fish --login` to replace `$SHELL` for local tabs and panes.

Pass a directory to open the first shell there:

```sh
nare ~/Projects/nare
```

### Named commands

Bind a command to a tab, pane, or window. `reuse=focus` selects the existing instance before Nare creates another one.

```ini
[bindings]
tab.editor=alt+1

[tab.editor]
command=nvim .
working-directory=~/Projects
title=Editor
target=new-tab
reuse=focus
```

## Shell integration

Nare defaults to `TERM=xterm-256color`. Install the bundled entry and select it when you want Nare's exact keyboard, mouse, color, focus, and paste capabilities.

System installs place the entry through `make install`. For a user install:

```sh
tic -x -o ~/.terminfo terminfo/nare.terminfo
```

```ini
[shell]
term=nare
```

Use a custom database by passing its path to `tic`, then export the same path as `TERMINFO` before starting Nare.

OSC 7 reports the shell's working directory. OSC 133 marks prompts, commands, output, and exit status so Nare can navigate prompts or copy command output. Add the matching snippet to your shell configuration.

| Action | Shortcut |
|---|---|
| Previous or next prompt | `Ctrl+Shift+Up` or `Ctrl+Shift+Down` |
| Copy the selected command's output | `Ctrl+Shift+O` |
| Send the output to `[shell] output-pipe` | `Ctrl+Shift+P` |

<details>
<summary>zsh</summary>

```zsh
autoload -Uz add-zsh-hook
typeset -g _nare_command_started=0

_nare_precmd() {
  local status=$?
  (( _nare_command_started )) && printf '\e]133;D;%d\e\\' "$status"
  printf '\e]7;file://%s%s\e\\\e]133;A\e\\' "$HOST" "${PWD// /%20}"
  _nare_command_started=0
}

_nare_preexec() {
  printf '\e]133;B\e\\\e]133;C\e\\'
  _nare_command_started=1
}

add-zsh-hook precmd _nare_precmd
add-zsh-hook preexec _nare_preexec
```

</details>

<details>
<summary>bash</summary>

```bash
_nare_prompt_command() {
  local status=$?
  printf '\e]133;D;%d\e\\\e]7;file://%s%s\e\\\e]133;A\e\\' \
    "$status" "$HOSTNAME" "${PWD// /%20}"
}
PROMPT_COMMAND="_nare_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
PS0=$'\e]133;B\e\\\e]133;C\e\\'"$PS0"
```

</details>

<details>
<summary>fish</summary>

```fish
function _nare_prompt --on-event fish_prompt
    set -l status_code $status
    if set -q _nare_command_started
        printf '\e]133;D;%d\e\\' $status_code
        set -e _nare_command_started
    end
    set -l uri_path (string replace -a ' ' '%20' $PWD)
    printf '\e]7;file://%s%s\e\\\e]133;A\e\\' (hostname) $uri_path
end

function _nare_preexec --on-event fish_preexec
    printf '\e]133;B\e\\\e]133;C\e\\'
    set -g _nare_command_started 1
end
```

</details>

Nare treats OSC metadata as text and does not execute it.

## tmux control mode

Run `tmux -CC` inside Nare to activate control mode. Nare turns tmux windows into native tabs and tmux panes into native panes. Each pane keeps its own renderer, scrollback, selection, and search state.

You can launch local and SSH sessions without opening a shell first:

```sh
nare --tmux
nare --tmux main
nare --tmux --ssh dev --session main
```

Named profiles keep host and session settings in `nare.conf`:

```ini
[tmux]
enabled=yes
auto-detect=yes
auto-reconnect=yes

[tmux.profile.dev]
ssh-host=dev
session=main
target=new-tab

[bindings]
tmux-profile.dev=alt+control+1
```

`tmux-new-tab`, `tmux-new-window`, and `tmux-attach-last` start explicit control-mode sessions. The default bindings also provide detach and reconnect actions:

| Action | Default binding |
|---|---|
| New tmux tab | `Alt+Ctrl+T` |
| New tmux window | `Alt+Ctrl+N` |
| Attach last session | `Alt+Ctrl+A` |
| Detach | `Alt+Ctrl+D` |
| Reconnect or refresh | `Alt+Ctrl+R` |

Nare routes tab, split, close, focus, swap, paste, and mouse actions through tmux while a tmux tab is active. A transport failure keeps the native views on screen; `auto-reconnect=yes` retries the original local or SSH command. Restarting the tmux server loses the processes it owns.

Initial and reconnect captures restore visible pane contents. They do not import the full tmux history.

## Background jobs

Install the `+` helper in your shell:

```sh
# bash (.bashrc)
eval "$(nare job init bash)"

# zsh (.zshrc)
eval "$(nare job init zsh)"

# fish (config.fish)
nare job init fish | source
```

Use `+ make` to track a background command, or `+ +build make` to name it `build`. Open the jobs popup from the status bar or press `Alt+Shift+J`. The popup can focus the source pane or interrupt the command.

The direct form is `nare job run build -- make`. Scripts can report progress with `nare status job start|progress|finish|fail`. Each Nare window tracks its own jobs.

## Optional modes

### Server

Server mode lets one Nare process own several windows:

```sh
nare --server
nare --client
nare --client -e htop
nare --client --no-wait /path/to/project
nare --client --font-size=18 --ligatures=false --title=work
```

The socket lives at `$XDG_RUNTIME_DIR/nare.sock` and accepts same-user clients. A waiting client returns its terminal child's exit status. `--no-wait` gives the server ownership of the window. Stopping the server closes its windows and terminal children.

### Quake

Quake mode wraps a normal workspace in a drop-down window. Hiding it keeps PTYs, tabs, scrollback, and tmux sessions alive.

```sh
nare --quake          # toggle an existing instance, or start one visible
```

Configure monitor selection, size, animation, and focus behavior under `[quake]`. Bind `nare --quake` through an X11 hotkey daemon such as sxhkd:

```text
alt + grave
    nare --quake
```

## Security

Nare treats terminal output as untrusted input. Parsers cap control strings, replies, clipboard transfers, scrollback, decoded images, image placements, and GPU textures. Oversized or malformed data produces a bounded failure path.

OSC 52 clipboard access starts disabled. Enable copy, paste, or both under `[security]`. Kitty accepts direct image data and rejects file, temporary-file, and shared-memory transports so terminal output cannot ask Nare to read local files.

Nare invokes URL openers and output-pipe programs without shell interpolation. Server and Quake sockets verify peer credentials from the same user.
