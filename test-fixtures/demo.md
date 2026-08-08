---
title: Markio 2
status: draft
---

# Markio 2

A native macOS Markdown viewer with **no web view**, no HTML and no JavaScript.
Everything on this page was typeset by CoreText from a parser that reads the
file's bytes directly.

## What it renders

Ordinary prose with *emphasis*, **strong emphasis**, ***both at once***,
~~struck-through text~~, `inline code`, a [link](https://example.com), and an
entity or two — a dash &mdash; and a non-breaking space.

Press <kbd>⌘F</kbd> to search, <kbd>⌥⌘S</kbd> for the outline.

### Lists

- A bullet with **bold** inside
- Another one
  - Nested a level deeper
  - And a second nested item
- [x] A finished task
- [ ] An unfinished one

1. Ordered lists count properly
2. Even when they are long
3. And the numbers come from the source

### Quotes

> A block quote holds ordinary blocks.
>
> > Including another quote, one level deeper.

### Code

```swift
struct HeightIndex {
    private var tree: [Double]

    func index(atOffset y: CGFloat) -> Int {
        // Descend the Fenwick tree by powers of two.
        var target = Double(max(0, y))
        var position = 0
        return position
    }
}
```

```json
{ "blocks": 341868, "structure": "38% of the file", "parse": "69 ms" }
```

### Tables

| Document | Parse | Structure | Viewport inline |
| --- | ---: | ---: | :---: |
| 1 MB | 1.9 ms | 0.4 MB | 0.4 ms |
| 8 MB | 14.7 ms | 3.0 MB | 0.3 ms |
| 32 MB | 69.3 ms | 12.2 MB | 0.3 ms |

---

### Math and long words

Inline math such as $e^{i\pi} + 1 = 0$ is kept as its source in a distinct
style. A very long path like
`/Users/someone/Library/Application Support/SomeApp/really/deep/path.json`
wraps instead of pushing the column sideways.
