import AppKit
import GeobraCore
import SwiftUI

struct PlacesOutlineView: NSViewRepresentable {
    @Bindable var store: WorkspaceStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = PlacesOutlineTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("place"))
        column.title = "Places"
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowHeight = 24
        outline.indentationPerLevel = 16
        outline.intercellSpacing = NSSize(width: 0, height: 1)
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.autoresizesOutlineColumn = true
        outline.backgroundColor = .clear
        outline.setAccessibilityLabel("Places")
        outline.setAccessibilityHelp("Select places. Drag them into folders. Press Return to rename a place.")
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.focusDoubleClick(_:))
        outline.onRename = { [weak coordinator = context.coordinator] in coordinator?.renameSelection() }
        outline.onDelete = { [weak store] in store?.deleteSelections() }
        outline.onWindowReady = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return }
            coordinator.update(store: coordinator.store)
        }
        outline.registerForDraggedTypes([Coordinator.dragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        context.coordinator.outline = outline
        context.coordinator.update(store: store)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(store: store)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate,
                             NSTextFieldDelegate, NSMenuDelegate {
        static let dragType = NSPasteboard.PasteboardType("com.geobra.places.drag")

        var store: WorkspaceStore
        weak var outline: PlacesOutlineTableView?
        private var nodes: [PlaceSelection: PlaceNode] = [:]
        private var roots: [PlaceNode] = []
        private var visibleRoots: [PlaceNode] = []
        private var visibleChildren: [PlaceSelection: [PlaceNode]] = [:]
        private var expandedItems = Set<PlaceSelection>()
        private var lastWorkspace: GeoWorkspace?
        private var lastSearch = ""
        private var isSynchronizing = false
        private var editingItem: PlaceSelection?
        private weak var editingField: NSTextField?
        private var handledRenameRequest: PlaceSelection?
        private var contextItem: PlaceSelection?
        private var previousSelection = Set<PlaceSelection>()

        init(store: WorkspaceStore) { self.store = store }

        func update(store: WorkspaceStore) {
            self.store = store
            guard let outline else { return }
            let searchChanged = lastSearch != store.search
            let contentChanged = lastWorkspace != store.workspace || searchChanged
            let previousParents = Dictionary(uniqueKeysWithValues: store.selections.compactMap { id in
                nodes[id]?.parent.map { (id, $0) }
            })
            if contentChanged && editingItem == nil {
                rebuild(outline)
                if searchChanged { pruneFilteredSelection() }
            }
            if store.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let moved = store.selections.filter { previousParents[$0] != nodes[$0]?.parent }
                for id in store.selections.subtracting(previousSelection).union(moved) {
                    revealAncestors(of: id)
                }
            }
            synchronizeSelection(outline)
            previousSelection = store.selections
            if let request = store.renameRequest {
                if handledRenameRequest != request {
                    handledRenameRequest = request
                    Task { @MainActor [weak self] in
                        guard let self, self.store.renameRequest == request else { return }
                        if !self.store.search.isEmpty,
                           self.nodes[request].map({ self.outline?.row(forItem: $0) ?? -1 }) ?? -1 < 0 {
                            self.store.search = ""
                            self.update(store: self.store)
                        }
                        if self.beginRename(request) { self.store.renameRequest = nil }
                        else { self.handledRenameRequest = nil }
                    }
                }
            } else {
                handledRenameRequest = nil
            }
        }

        private func rebuild(_ outline: NSOutlineView) {
            let previousIDs = Set(nodes.keys)
            let firstLoad = lastWorkspace == nil
            var alive = Set<PlaceSelection>()
            func node(for id: PlaceSelection) -> PlaceNode {
                alive.insert(id)
                if let existing = nodes[id] { return existing }
                let created = PlaceNode(id: id)
                nodes[id] = created
                return created
            }
            func folderNode(_ folder: GeoFolder, parent: PlaceSelection?, parentVisible: Bool) -> PlaceNode {
                let result = node(for: .folder(folder.id))
                result.name = folder.name
                result.isVisible = folder.isVisible
                result.isEffectivelyVisible = parentVisible && folder.isVisible
                result.parent = parent
                result.symbol = "folder"
                result.children = folder.children.map {
                    folderNode($0, parent: result.id, parentVisible: result.isEffectivelyVisible)
                } + folder.features.map { feature in
                    let child = node(for: .feature(feature.id))
                    child.name = feature.name
                    child.isVisible = feature.isVisible
                    child.isEffectivelyVisible = result.isEffectivelyVisible && feature.isVisible
                    child.parent = result.id
                    child.symbol = geometrySymbol(feature.geometry)
                    child.children = []
                    return child
                }
                return result
            }
            roots = store.workspace.folders.map { folderNode($0, parent: nil, parentVisible: true) }
            nodes = nodes.filter { alive.contains($0.key) }
            visibleChildren.removeAll(keepingCapacity: true)
            let query = store.search.trimmingCharacters(in: .whitespacesAndNewlines)
            func filtered(_ node: PlaceNode, inheritedMatch: Bool) -> PlaceNode? {
                let matches = inheritedMatch || query.isEmpty || node.name.localizedCaseInsensitiveContains(query)
                let children = node.children.compactMap { filtered($0, inheritedMatch: matches) }
                visibleChildren[node.id] = children
                return matches || !children.isEmpty ? node : nil
            }
            visibleRoots = roots.compactMap { filtered($0, inheritedMatch: false) }
            lastWorkspace = store.workspace
            lastSearch = store.search

            isSynchronizing = true
            outline.reloadData()
            outline.collapseItem(nil, collapseChildren: true)
            if !query.isEmpty || firstLoad {
                outline.expandItem(nil, expandChildren: true)
                if firstLoad { expandedItems.formUnion(alive.filter(\.isFolder)) }
            } else {
                for node in roots { restoreExpansion(node, in: outline, previousIDs: previousIDs) }
            }
            isSynchronizing = false
        }

        private func restoreExpansion(_ node: PlaceNode, in outline: NSOutlineView,
                                      previousIDs: Set<PlaceSelection>) {
            guard node.isFolder else { return }
            if expandedItems.contains(node.id) || !previousIDs.contains(node.id) {
                outline.expandItem(node)
                if !previousIDs.contains(node.id) { expandedItems.insert(node.id) }
                for child in node.children { restoreExpansion(child, in: outline, previousIDs: previousIDs) }
            }
        }

        private func synchronizeSelection(_ outline: NSOutlineView) {
            var rows = IndexSet()
            for id in store.selections {
                guard let node = nodes[id] else { continue }
                let row = outline.row(forItem: node)
                if row >= 0 { rows.insert(row) }
            }
            guard rows != outline.selectedRowIndexes else { return }
            isSynchronizing = true
            outline.selectRowIndexes(rows, byExtendingSelection: false)
            isSynchronizing = false
        }

        private func pruneFilteredSelection() {
            var included = Set<PlaceSelection>()
            func collect(_ node: PlaceNode) {
                included.insert(node.id)
                for child in visibleChildren[node.id] ?? [] { collect(child) }
            }
            for root in visibleRoots { collect(root) }
            if let request = store.renameRequest { included.insert(request) }
            let original = store.selections
            let retained = original.intersection(included)
            guard retained != original else { return }
            let query = store.search
            Task { @MainActor [weak self] in
                guard let self, self.store.search == query, self.store.selections == original else { return }
                self.store.selections = retained
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(of: item).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            children(of: item)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? PlaceNode)?.isFolder == true
        }

        private func children(of item: Any?) -> [PlaceNode] {
            guard let node = item as? PlaceNode else { return visibleRoots }
            return visibleChildren[node.id] ?? []
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? PlaceNode else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("PlaceCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? PlaceCellView ?? PlaceCellView()
            cell.identifier = identifier
            cell.configure(node)
            cell.textField?.delegate = self
            cell.onVisibilityToggle = { [weak self] in
                guard let self else { return }
                switch node.id {
                case .folder(let id): self.store.toggleFolder(id)
                case .feature(let id): self.store.toggleFeature(id)
                }
            }
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSynchronizing, let outline else { return }
            let selected = Set(outline.selectedRowIndexes.compactMap {
                (outline.item(atRow: $0) as? PlaceNode)?.id
            })
            if store.selections != selected { store.selections = selected }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isSynchronizing, store.search.isEmpty,
                  let node = notification.userInfo?["NSObject"] as? PlaceNode else { return }
            expandedItems.insert(node.id)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isSynchronizing, store.search.isEmpty,
                  let node = notification.userInfo?["NSObject"] as? PlaceNode else { return }
            expandedItems.remove(node.id)
        }

        @objc func focusDoubleClick(_ sender: NSOutlineView) {
            guard sender.clickedRow >= 0, sender.clickedRow < sender.numberOfRows,
                  let node = sender.item(atRow: sender.clickedRow) as? PlaceNode else { return }
            if let event = NSApp.currentEvent {
                let point = sender.convert(event.locationInWindow, from: nil)
                if sender.hitTest(point) is NSButton { return }
            }
            if !store.selections.contains(node.id) { store.selections = [node.id] }
            store.focusSelection()
        }

        func renameSelection() {
            guard store.selections.count == 1, let id = store.selections.first else { return }
            beginRename(id)
        }

        private func revealAncestors(of id: PlaceSelection) {
            guard let outline, let node = nodes[id] else { return }
            var parentID = node.parent
            var parents: [PlaceNode] = []
            while let id = parentID, let parent = nodes[id] {
                parents.append(parent)
                parentID = parent.parent
            }
            for parent in parents.reversed() { outline.expandItem(parent) }
        }

        @discardableResult
        private func beginRename(_ id: PlaceSelection) -> Bool {
            guard let outline, outline.window != nil, let node = nodes[id] else { return false }
            revealAncestors(of: id)
            synchronizeSelection(outline)
            let row = outline.row(forItem: node)
            guard row >= 0 else { return false }
            outline.scrollRowToVisible(row)
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? PlaceCellView,
                  let field = cell.textField else { return false }
            if editingItem != nil { outline.window?.makeFirstResponder(outline) }
            editingItem = id
            editingField = field
            field.isEditable = true
            field.isSelectable = true
            field.selectText(nil)
            return true
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finishEditing(commit: false)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, field === editingField else { return }
            finishEditing(commit: true)
        }

        private func finishEditing(commit: Bool) {
            guard let id = editingItem else { return }
            let draft = editingField?.stringValue ?? ""
            let field = editingField
            editingItem = nil
            editingField = nil
            field?.isEditable = false
            field?.isSelectable = false
            if commit { store.rename(id, to: draft) }
            field?.stringValue = modelName(for: id) ?? nodes[id]?.name ?? ""
            outline?.window?.makeFirstResponder(outline)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.update(store: self.store)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? PlaceNode else { return nil }
            guard let data = try? JSONEncoder().encode(Set([node.id])) else { return nil }
            let writer = NSPasteboardItem()
            writer.setData(data, forType: Self.dragType)
            return writer
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            let items = draggedItems(info)
            guard info.draggingSource is PlacesOutlineTableView,
                  let destination = destination(for: item, index: index),
                  representsInsertion(items, at: destination.index, in: item as? PlaceNode),
                  store.canMove(items, to: destination.folderID) else { return [] }
            return .move
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            let items = draggedItems(info)
            guard info.draggingSource is PlacesOutlineTableView,
                  let destination = destination(for: item, index: index),
                  representsInsertion(items, at: destination.index, in: item as? PlaceNode),
                  store.canMove(items, to: destination.folderID) else { return false }
            store.move(items, to: destination.folderID, at: destination.index)
            return true
        }

        private func draggedItems(_ info: NSDraggingInfo) -> Set<PlaceSelection> {
            (info.draggingPasteboard.pasteboardItems ?? []).reduce(into: Set<PlaceSelection>()) { result, item in
                guard let data = item.data(forType: Self.dragType),
                      let decoded = try? JSONDecoder().decode(Set<PlaceSelection>.self, from: data) else { return }
                result.formUnion(decoded)
            }
        }

        private func destination(for item: Any?, index: Int) -> (folderID: UUID?, index: Int?)? {
            let node = item as? PlaceNode
            let folderID: UUID?
            if let node {
                guard case .folder(let id) = node.id else { return nil }
                folderID = id
            } else { folderID = nil }
            guard index >= 0 else { return (folderID, nil) }
            let displayed = children(of: node)
            let all = node?.children ?? roots
            if index < displayed.count, let position = all.firstIndex(where: { $0.id == displayed[index].id }) {
                return (folderID, position)
            }
            return (folderID, all.count)
        }

        private func representsInsertion(_ items: Set<PlaceSelection>, at index: Int?, in parent: PlaceNode?) -> Bool {
            guard let index else { return true }
            let folderCount = (parent?.children ?? roots).prefix { $0.isFolder }.count
            let topLevel = items.filter { item in
                var ancestor = nodes[item]?.parent
                while let id = ancestor {
                    if items.contains(id) { return false }
                    ancestor = nodes[id]?.parent
                }
                return true
            }
            let hasFolders = topLevel.contains(where: \.isFolder)
            let hasFeatures = topLevel.contains { !$0.isFolder }
            if hasFolders && hasFeatures { return index == folderCount }
            if hasFolders { return index <= folderCount }
            return hasFeatures && index >= folderCount
        }

        private func modelName(for selection: PlaceSelection) -> String? {
            func find(in folder: GeoFolder) -> String? {
                if selection == .folder(folder.id) { return folder.name }
                if let feature = folder.features.first(where: { selection == .feature($0.id) }) { return feature.name }
                for child in folder.children {
                    if let name = find(in: child) { return name }
                }
                return nil
            }
            for folder in store.workspace.folders {
                if let name = find(in: folder) { return name }
            }
            return nil
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let outline else { return }
            contextItem = outline.clickedRow >= 0 && outline.clickedRow < outline.numberOfRows
                ? (outline.item(atRow: outline.clickedRow) as? PlaceNode)?.id : nil
            if let contextItem, !store.selections.contains(contextItem) {
                store.selections = [contextItem]
                synchronizeSelection(outline)
            }
            menu.removeAllItems()
            addMenuItem("New Folder", command: "newFolder", to: menu)
            guard contextItem != nil else { return }
            menu.addItem(.separator())
            addMenuItem("Rename", command: "rename", enabled: store.selections.count == 1, to: menu)
            addMenuItem("New Folder with Selection", command: "group", to: menu)
            addMenuItem("Show on Globe", command: "focus", to: menu)
            addMenuItem("Show", command: "show", to: menu)
            addMenuItem("Hide", command: "hide", to: menu)
            addMenuItem("Export GeoJSON…", command: "export", to: menu)
            menu.addItem(.separator())
            addMenuItem("Delete", command: "delete", to: menu)
        }

        private func addMenuItem(_ title: String, command: String, enabled: Bool = true, to menu: NSMenu) {
            let item = NSMenuItem(title: title, action: #selector(performMenuCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command
            item.isEnabled = enabled
            menu.addItem(item)
        }

        @objc private func performMenuCommand(_ sender: NSMenuItem) {
            switch sender.representedObject as? String {
            case "newFolder":
                store.selection = contextItem?.isFolder == true ? contextItem : nil
                store.addFolder()
            case "rename": renameSelection()
            case "group": store.groupSelection()
            case "focus": store.focusSelection()
            case "show": store.setSelectedVisibility(true)
            case "hide": store.setSelectedVisibility(false)
            case "export": store.exportGeoJSON()
            case "delete": store.deleteSelections()
            default: break
            }
        }

        private func geometrySymbol(_ geometry: GeoGeometry?) -> String {
            switch geometry {
            case .point, .multiPoint: return "mappin"
            case .lineString, .multiLineString: return "point.topleft.down.to.point.bottomright.curvepath"
            case .polygon, .multiPolygon: return "pentagon"
            case .geometryCollection: return "square.stack.3d.up"
            case nil: return "doc"
            }
        }
    }
}

private final class PlaceNode: NSObject {
    let id: PlaceSelection
    var name = ""
    var symbol = "doc"
    var isVisible = true
    var isEffectivelyVisible = true
    var parent: PlaceSelection?
    var children: [PlaceNode] = []
    var isFolder: Bool { id.isFolder }

    init(id: PlaceSelection) { self.id = id }
}

private extension PlaceSelection {
    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }
}

@MainActor
final class PlacesOutlineTableView: NSOutlineView {
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?
    var onWindowReady: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            Task { @MainActor [weak self] in self?.onWindowReady?() }
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onRename?()
        case 51, 117: onDelete?()
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
private final class PlaceCellView: NSTableCellView {
    var onVisibilityToggle: (() -> Void)?
    private let visibility = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var effectivelyVisible = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView()
        let name = NSTextField(labelWithString: "")
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.isEditable = false
        name.isSelectable = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        visibility.setContentHuggingPriority(.required, for: .horizontal)
        visibility.target = self
        visibility.action = #selector(toggleVisibility(_:))
        let stack = NSStackView(views: [icon, name, visibility])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16)
        ])
        imageView = icon
        textField = name
    }

    required init?(coder: NSCoder) { nil }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    func configure(_ node: PlaceNode) {
        textField?.stringValue = node.name
        textField?.toolTip = node.name
        imageView?.image = node.isFolder ? NSImage(named: NSImage.folderName)
            : NSImage(systemSymbolName: node.symbol, accessibilityDescription: nil)
        effectivelyVisible = node.isEffectivelyVisible
        visibility.state = node.isVisible ? .on : .off
        visibility.setAccessibilityLabel("Show \(node.name) on Globe")
        visibility.toolTip = node.isVisible ? "Hide on globe" : "Show on globe"
        textField?.setAccessibilityLabel(node.name)
        updateColors()
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        textField?.textColor = selected ? .selectedControlTextColor
            : effectivelyVisible ? .labelColor : .secondaryLabelColor
        imageView?.contentTintColor = selected ? .selectedControlTextColor : .secondaryLabelColor
    }

    @objc private func toggleVisibility(_ sender: NSButton) { onVisibilityToggle?() }
}
