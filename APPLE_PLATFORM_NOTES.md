# Apple Platform Notes

- iOS 26 Liquid Glass custom surfaces use `glassEffect(_:in:)`; nearby system actions use `.buttonStyle(.glass)` or `.glassProminent`. The compatibility modifier falls back to `ultraThinMaterial` on iOS 17–25.
- Ledger search uses SwiftUI `.searchable` in the navigation toolbar. Category filters use a native toolbar `Menu` with toggles.
- External backup import/export uses SwiftUI `FileDocument`, backed by the system document picker.
- iCloud backup uses `FileManager.url(forUbiquityContainerIdentifier:)` off the main actor and writes into the configured iCloud Documents container.

Official references:

- https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
- https://developer.apple.com/documentation/swiftui/glasseffectcontainer
- https://developer.apple.com/documentation/swiftui/search
- https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller
- https://developer.apple.com/documentation/foundation/filemanager/url(forubiquitycontaineridentifier:)
