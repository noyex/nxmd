<img src="docs/icon.png" width="128" alt="nxmd icon">

# nxmd

A tiny, native Markdown viewer for macOS. Double-click a `.md` file and read it, nicely rendered.

- Pure black, distraction-free reading with the Geist and Geist Mono typefaces
- Tabs: open more files and they join the same window as browser-style tabs. Drag to reorder, middle-click to close
- Floating toolbar: outline, find, text size, Markdown source, open in your editor. It hides while you scroll down
- Smooth mouse-wheel scrolling and a thin reading-progress line under the title
- GitHub-flavored Markdown: tables, task lists, strikethrough, autolinks
- Syntax highlighting and a copy button for code blocks
- Live reload: the page updates the moment the file changes on disk, scroll position kept
- Relative images and links to other `.md` files work
- Shortcuts: find ⌘F, outline ⇧⌘O, source ⌥⌘U, open in editor ⇧⌘E, text size ⌘+ / ⌘- / ⌘0, print and PDF ⌘P, close tab ⌘W, close window ⇧⌘W, switch tabs ⌃Tab / ⌃⇧Tab, ⇧⌘] / ⇧⌘[ or ⌘1–9
- Safe: scripts inside Markdown never run
- About 1 MB, no Electron

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

MIT. Bundles marked (MIT), highlight.js (BSD-3-Clause) and the Geist fonts (SIL Open Font License, see `Resources/fonts/OFL.txt`).
