# ``CodeEditSymbols``

A package containing all custom assets for CodeEdit. These are mostly custom [SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols/overview/#creating-custom-symbols).

## How to use

### NSImage:

```swift
import CodeEditSymbols

let nsImage = NSImage.symbol(named: "name_of_the_symbol")

// or using the static property:

let nsImage1 = NSImage.name_of_the_symbol
```

### Image:

```swift
import CodeEditSymbols

let image = Image(symbol: "name_of_the_symbol")

// or using the static property:

let image1 = Image.name_of_the_symbol
```
