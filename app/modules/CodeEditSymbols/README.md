# CodeEditSymbols Override

This local package mirrors `CodeEditApp/CodeEditSymbols` `0.2.3` with one
manifest fix: `Symbols.xcassets` is declared as a processed resource.

`CodeEditSourceEditor` `0.15.2` pins `CodeEditSymbols` `0.2.3`, but that
upstream manifest does not expose the asset catalog even though the source uses
`Bundle.module`. Keeping this package name and identity lets SwiftPM resolve
the editor's transitive dependency to the local package until the upstream
manifest is fixed.
