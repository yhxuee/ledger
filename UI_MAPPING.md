# Web-to-iOS UI Mapping

| Web UI | Native iOS implementation |
|---|---|
| Five-page sidebar / portrait navigation | `NavigationSplitView` on regular width and system `TabView` on compact width |
| Glass circle actions | Liquid Glass button styles on iOS 26; bordered/material fallback on iOS 17–25 |
| Gradient Wallet account card | Native SwiftUI gradient card with the original 85.60 × 53.98 aspect ratio |
| Portrait Wallet account picker | Detented native sheet with stacked cards |
| Balance / Weekly / Budget+Remain dashboard | Adaptive `ViewThatFits` and `LazyVGrid` metric surfaces |
| Add/Edit transaction bottom sheet | Native detented sheet, segmented type picker, date picker, account pickers, numeric pad and category carousel |
| Ledger Search and Filter | System `.searchable` plus a toolbar `Menu` with category toggles |
| W/M/6M/Y Analytics | Swift Charts bar and donut charts computed from live transactions |
| Accounts CRUD | Native form editor with card preview, account semantics, budget participation and soft deletion |
| Settings export/import | `FileDocument`, system Files picker and validated import-preview sheet |
| Cloud backup placeholder | Working iCloud Documents backup/restore service |

The original PWA’s visual hierarchy and restrained palette are preserved, while navigation, sheets, search, menus, accessibility labels, Dynamic Type and safe-area behavior use native platform conventions.
