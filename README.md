# nare

`nare` is an experimental X11-only terminal emulator written in Odin.

## Toolchain

- Linux on x86-64
- Odin `dev-2026-10`
- GNU Make

Run the current checks with:

```sh
make check
make test
make fixtures
```

Run a shell or command with:

```sh
./build/nare
./build/nare -e sh -c 'printf "hello\\n"'
```
