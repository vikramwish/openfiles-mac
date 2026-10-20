# Native macOS design

OpenFiles follows Apple's [macOS Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos), particularly [sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars), [toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), and [tables](https://developer.apple.com/design/human-interface-guidelines/tables).

- The workspace uses a resizable `NavigationSplitView` and a system sidebar `List`. Favorites, app tools, and mounted locations use standard selection and SF Symbols.
- The AppKit `NSToolbar` owns navigation, folder creation, Quick Look, actions, the versions inspector, and an `NSSearchToolbarItem`. Command-F starts search. The bridge supports the workspace's `NSHostingView` window, which is opened from the menu bar.
- Files use SwiftUI `Table`, with native selection, column resizing, and sorting by name, modification date, and kind. Double-click opens an item, Return opens the selection, and Space starts Quick Look. Context menus retain existing file actions.
- Folder breadcrumbs and one status bar keep location and indexing information visible without competing with file content. Indexing controls remain one click away.
- Use system text styles, semantic colors, native control appearance, and standard empty states. System components adapt to appearance, contrast, and transparency settings. Avoid custom glass overlays and decorative animation.
- Keep future actions in the toolbar or context menus, and use sheets for focused tasks. Preserve keyboard navigation, explicit accessibility labels on icon controls, and full-path tooltips where paths truncate.

## Checking design changes

Build with `make build`, then inspect the running workspace, narrow-window layout, sidebar selection, column sorting, toolbar enablement, Command-F, Quick Look, and sheets. Check light and dark appearances. A separate preview bundle with temporary fixture files can be used to avoid interrupting another running development session. Never run organization, restore, or vault operations on real files merely to test appearance.

Workspace and standalone preview windows use `WindowHosting` with automatic hosting-view sizing disabled. The user controls the window frame; expanding details or changing preview content must not increase its minimum size. Hosted views still follow explicit window resizing. Long organization explanations scroll within a bounded region.

Run `make test-window-sizing` for the native AppKit regression check. Its automatic-sizing control reproduces the growth, then it verifies stable frame/minimum size through eight content changes and checks that explicit resizing still works. The check creates no visible windows and uses no personal files.
