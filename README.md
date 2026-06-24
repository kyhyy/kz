# kz

A minimal terminal text editor written in Zig, inspired by [kilo](https://github.com/antirez/kilo).

## Build

```
zig build --prefix ~/.local
```

Requires Zig 0.16.0.

## Features

- Syntax highlighting (C, Zig, Nim)
- Incremental search with arrow key navigation
- Tab expansion
- Unsaved changes warning

## Usage

```
kz file.txt
```

| Key | Action |
|-----|--------|
| `Ctrl-S` | Save |
| `Ctrl-Q` | Quit (×3 if unsaved) |
| `Ctrl-F` | Search (arrows to navigate, Esc to cancel) |

## Acknowledgments

Inspired by the [kilo](https://github.com/antirez/kilo) text editor and the excellent [Build Your Own Text Editor](https://viewsourcecode.org/snaptoken/kilo/) tutorial together with [micro](https://github.com/micro-editor/micro) text editor.

Special thanks to [paulsmith](https://github.com/paulsmith), [Ryp](https://github.com/Ryp), [spiral-ladder](https://github.com/spiral-ladder) even thought they will probably never see this project, their own contributions to open source helped me tremendously when learning Zig and writing this project.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
