# Add Custom Symbols

To create a new asset, follow the guide on [Apple's developer website](https://developer.apple.com/documentation/uikit/uiimage/creating_custom_symbol_images_for_your_app).

## Overview

Add the `.svg` you exported from `SF Symbols.app` to the `Symbols.xcassets` catalog.

Also add a static property to the `Image` and `NSImage` extension like so:

```swift
// Image Extension
static let your_symbol_name: Image = .init(symbol: "your_symbol_name")

// NSImage Extension
static let your_symbol_name: NSImage = .symbol(named: "your_symbol_name")
```

> **Important:** Make sure your symbol looks great in every font weight.


## Tests

Also include snapshot tests for each symbol for `Image` as well as `NSImage`:

### NSImage:

```swift
// MARK: YOUR_SYMBOL_NAME

func testCreateNSImageYourSymbolName() {
    let image = NSImage.your_symbol_name
    let view = NSImageView(image: image)
    view.appearance = .init(named: .aqua)
    assertSnapshot(matching: view, as: .image, record: record)
}
```

### Image:

```swift
// MARK: YOUR_SYMBOL_NAME

func testCreateImageYourSymbolName() {
    let image = Image.your_symbol_name
    let view: NSView = NSHostingController(rootView: image).view
    view.appearance = .init(named: .aqua)
    assertSnapshot(matching: view, as: .image(size: view.intrinsicContentSize))
}
```

## Variants

Keep different variants of a symbol in the same parent folder and name them appropriately (see Apple's own symbols for reference).

You might have a symbol called `lock` and one where the symbol is inside a square where you would call that file `lock.square`. Also keep in mind to also provide a `.fill` variant if appropriate (`lock.fill`, `lock.square.fill`)

### Example of a `.fill` Variant

![Fill Variant](fill_variant.png)

## Annotate the Symbol

As of version 3 of `SF Symbols` it is possible to create `multi-color`, `hierarchical` and `palette` annotations inside the `SF Symbols.app`. Be sure to annotate it accordingly if appropriate.

![Annotating](annotating.png)
