# Terminal output and diffs

A pasted build log keeps its colours:

```
[32m✔[0m  17 tests passed
[33m⚠[0m  2 warnings in [36mSources/MarkioRender/Theme.swift[0m
[31m✖[0m  1 failure: [1;31mexpected 3, got 4[0m
[90m…quiet trailing note…[0m
[44;97m INFO [0m background works too
[38;5;208m256-colour orange[0m and [38;2;120;190;255mtrue colour blue[0m
```

A diff block reads as bands:

```diff
@@ -12,7 +12,7 @@ struct Palette {
 let base = theme.palette.codeText
-let spans = SyntaxHighlighter.spans(code: content)
+let code = CodeText.build(content: content, language: language)
 return code.attributed
```

Ordinary code is still highlighted:

```swift
let answer = 42  // unchanged
```
