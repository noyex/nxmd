# nxmd

A tiny, native Markdown viewer for macOS. Double-click a `.md` file and read it, nicely rendered.

- Clean typography, follows light and dark mode
- GitHub-flavored Markdown: tables, task lists, strikethrough, autolinks
- Syntax highlighting for code blocks
- Live reload: the page updates the moment the file changes on disk, scroll position kept
- Relative images and links to other `.md` files work
- Find (⌘F), zoom (⌘+ / ⌘- / ⌘0), print and export to PDF (⌘P)
- Safe: scripts inside Markdown never run
- Under 1 MB, no Electron

## Install

Requires macOS 13+ and Xcode (or the Command Line Tools with Swift).

```sh
git clone https://github.com/noyex/nxmd.git
cd nxmd
brew install duti        # optional, lets the script set nxmd as the default app
./scripts/install.sh
```

The script builds the app, copies it to `/Applications` and makes it the default app for Markdown files. Without `duti`, set it once in Finder: Get Info on any `.md` file, Open with: nxmd, Change All.

## Build only

```sh
./scripts/build.sh       # outputs build/nxmd.app
```

## How it works

An AppKit document app with a `WKWebView`. Markdown is converted to HTML by [marked](https://github.com/markedjs/marked) and [highlight.js](https://github.com/highlightjs/highlight.js) inside JavaScriptCore, so the rendered page runs with JavaScript disabled.

## License

MIT. Bundles marked (MIT) and highlight.js (BSD-3-Clause).
