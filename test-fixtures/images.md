# Images

An image on its own line is drawn:

![A generated gradient with a checkerboard](sample.png)

An image mentioned ![inline](sample.png) in a sentence is drawn on the line, at
most a little taller than the text, and its alt text gives way to it.

A missing file leaves an empty frame where it belongs, so Find and the drawing
agree on every character:

![this file does not exist](nowhere.png)

A remote address is not fetched; it keeps its marker and alt text:

![a remote picture](https://example.com/picture.png)
