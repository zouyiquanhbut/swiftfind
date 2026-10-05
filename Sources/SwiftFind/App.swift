import SwiftUI
import AppKit
import UniformTypeIdentifiers

let swiftFindPathType = "com.swiftfind.file-path"
let swiftFindPathsType = "com.swiftfind.file-paths"
let swiftFindTargetReorderType = "com.swiftfind.target-folder-reorder"

extension Notification.Name {
    static let swiftFindIndexDidChange = Notification.Name("SwiftFindIndexDidChange")
}

@main
struct SwiftFindApp: App {
    @StateObject private var model: SearchModel
    private let statusBarController: StatusBarController
    private let globalHotKey: GlobalHotKey

    init() {
        do {
            let database = try Database()
            _model = StateObject(wrappedValue: SearchModel(database: database))
            statusBarController = StatusBarController()
            globalHotKey = GlobalHotKey()
        } catch {
            fatalError("无法启动 SwiftFind：\(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup("SwiftFind") { SearchView(model: model) }
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("索引目录…") { model.indexer.chooseAndIndex() }
                        .keyboardShortcut("i", modifiers: [.command, .shift])
                }
            }
    }
}

@MainActor
final class SearchModel: ObservableObject {
    @Published var query = "" { didSet { search() } }
    @Published private(set) var results: [FileRecord] = []
    @Published private(set) var recentResults: [FileRecord] = []
    @Published private(set) var resultsRevision = 0
    @Published private(set) var searchError: String?
    @Published private(set) var isSearching = false
    @Published private(set) var history: [String]
    @Published var selectedID: Int64?
    @Published var selectedIDs: Set<Int64> = []
    @Published var isHistoryExpanded = false
    @Published var sort: ResultSort { didSet {
        guard sort != oldValue else { return }
        UserDefaults.standard.set(sort.rawValue, forKey: "SwiftFind.resultSort")
        search()
    } }
    @Published var ascending: Bool { didSet {
        guard ascending != oldValue else { return }
        UserDefaults.standard.set(ascending, forKey: "SwiftFind.resultSortAscending")
        search()
    } }
    @Published var searchScope: SearchScope { didSet {
        guard searchScope != oldValue else { return }
        UserDefaults.standard.set(searchScope.rawValue, forKey: "SwiftFind.searchScope")
        search()
    } }
    @Published var includeHidden: Bool { didSet {
        guard includeHidden != oldValue else { return }
        UserDefaults.standard.set(includeHidden, forKey: "SwiftFind.includeHidden")
        search()
    } }
    let indexer: Indexer
    let organizer = FileOrganizer()
    let workspace = FolderWorkspaceModel()
    private let database: Database
    private let parser = SearchQueryParser()
    private var task: Task<Void, Never>?
    private var searchGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var lastRequestedQuery: String?
    private var indexObserver: NSObjectProtocol?
    private var previewObserver: NSObjectProtocol?

    init(database: Database) {
        self.database = database
        self.sort = UserDefaults.standard.string(forKey: "SwiftFind.resultSort")
            .flatMap(ResultSort.init(rawValue:)) ?? .name
        self.ascending = UserDefaults.standard.object(forKey: "SwiftFind.resultSortAscending") as? Bool ?? true
        self.searchScope = SearchScope(rawValue: UserDefaults.standard.string(forKey: "SwiftFind.searchScope") ?? "") ?? .name
        self.includeHidden = UserDefaults.standard.object(forKey: "SwiftFind.includeHidden") as? Bool ?? false
        self.indexer = Indexer(database: database)
        self.history = UserDefaults.standard.stringArray(forKey: "SwiftFind.searchHistory") ?? []
        // First results are fetched by onAppear using the restored sort order.
        self.recentResults = []
        indexObserver = NotificationCenter.default.addObserver(forName: .swiftFindIndexDidChange, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                if let destinationPaths = notification.userInfo?["movedDestinationPaths"] as? [String] {
                    self.indexer.indexAdditional(urls: destinationPaths.map(URL.init(fileURLWithPath:)), recursive: true)
                }
                if let paths = notification.userInfo?["movedPaths"] as? [String] {
                    // Remove the old paths from the index before the delayed
                    // refresh; otherwise FSEvents may not have arrived yet and
                    // the just-moved items can briefly reappear.
                    try? self.database.removeFileRowsOnly(paths: paths)
                    let moved = Set(paths)
                    let removedIDs = Set((self.results + self.recentResults).filter { record in
                        moved.contains(record.path) || moved.contains { record.path.hasPrefix($0 + "/") }
                    }.map(\.id))
                    self.results.removeAll { record in moved.contains(record.path) || moved.contains { record.path.hasPrefix($0 + "/") } }
                    self.recentResults.removeAll { record in moved.contains(record.path) || moved.contains { record.path.hasPrefix($0 + "/") } }
                    self.resultsRevision &+= 1
                    self.selectedIDs.subtract(removedIDs)
                }
                if notification.userInfo?["indexedDestinationPaths"] != nil {
                    self.search(showProgress: false)
                } else {
                    self.scheduleIndexRefresh(delay: notification.userInfo?["movedPaths"] != nil ? .milliseconds(250) : .seconds(1))
                }
            }
        }
        // Target folders may be outside the selected index roots. Start their
        // incremental scan only after the observer is installed, so completion
        // can trigger the first fresh search.
        indexer.indexAdditional(urls: organizer.targets.map(\.url), recursive: false)
        previewObserver = NotificationCenter.default.addObserver(forName: .swiftFindPreviewSelection, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.previewSelected() }
        }
    }

    deinit {
        if let indexObserver { NotificationCenter.default.removeObserver(indexObserver) }
        if let previewObserver { NotificationCenter.default.removeObserver(previewObserver) }
    }

    private func scheduleIndexRefresh(delay: Duration = .seconds(1)) {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            while self.isSearching {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
            }
            self.refreshTask = nil
            self.search(showProgress: false)
        }
    }

    func search(showProgress: Bool = true) {
        task?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let value = query
        let isEmptyQuery = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        isSearching = showProgress && !isEmptyQuery
        searchError = nil
        if showProgress && lastRequestedQuery != value {
            results = []
            recentResults = []
            resultsRevision &+= 1
            selectedIDs.removeAll()
        }
        lastRequestedQuery = value
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, let self, generation == self.searchGeneration else { return }
            var parsed = parser.parse(value)
            parsed.scope = searchScope
            parsed.includeHidden = includeHidden
            do {
                let found = try await database.searchAsync(parsed, sort: sort, ascending: ascending)
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                if searchError != nil { searchError = nil }
                if results != found {
                    results = found
                    resultsRevision &+= 1
                }
                isSearching = false
                if isEmptyQuery && recentResults != found {
                    recentResults = found
                    resultsRevision &+= 1
                }
                if !isEmptyQuery {
                    recordHistory(value)
                }
            } catch {
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                searchError = error.localizedDescription
                results = []
                isSearching = false
            }
            if selectedID == nil { selectedID = results.first?.id }
        }
    }

    func recordHistory(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, history.first != trimmed else { return }
        history.removeAll { $0 == trimmed }
        history.insert(trimmed, at: 0)
        if history.count > 20 { history = Array(history.prefix(20)) }
        UserDefaults.standard.set(history, forKey: "SwiftFind.searchHistory")
    }

    func rebuildIndex() {
        guard let root = indexer.root else { indexer.chooseAndIndex(); return }
        indexer.index(urls: [root])
    }

    func previewSelected() {
        if workspace.currentFolder != nil {
            guard let record = workspace.items.first(where: { $0.id == workspace.selectedItemID }) else { return }
            openQuickLook(record)
            return
        }
        let visible = query.isEmpty ? recentResults : results
        guard let record = visible.first(where: { selectedIDs.contains($0.id) }) else { return }
        openQuickLook(record)
    }

    func openQuickLook(_ record: FileRecord) {
        guard !record.isDirectory else { return }
        let visible = workspace.currentFolder != nil ? workspace.items : (query.isEmpty ? recentResults : results)
        QuickLookController.shared.show(urls: visible.filter { !$0.isDirectory }.map(\.url), selected: record.url, organizer: organizer)
    }

    func open(_ record: FileRecord, reveal: Bool = false) {
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([record.url]) }
        else if record.isDirectory { workspace.open(record.url) }
        else { NSWorkspace.shared.open(record.url) }
    }

    func browseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "浏览文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.open(url)
    }

    func copyPath(_ record: FileRecord) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.path, forType: .string) }

    func selectedRecords() -> [FileRecord] {
        let visible = query.isEmpty ? recentResults : results
        return visible.filter { selectedIDs.contains($0.id) }
    }

    func moveSelected(to destination: URL) {
        organizer.move(records: selectedRecords(), to: destination)
        selectedIDs.removeAll()
    }

    func move(_ records: [FileRecord], toTargetAt index: Int) {
        guard records.isEmpty == false else { return }
        guard organizer.targets.indices.contains(index) else {
            organizer.error = "目标文件夹快捷键 ⌥\(index + 1) 尚未设置"
            return
        }
        organizer.move(records: records, to: organizer.targets[index].url)
        selectedIDs.subtract(records.map(\.id))
    }
}

struct SearchView: View {
    @ObservedObject var model: SearchModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索文件名、路径或 ext:pdf size:>1mb", text: $model.query)
                        .textFieldStyle(.plain).font(.title3).focused($focused)
                    if model.indexer.isIndexing { Text("索引中…").font(.caption).foregroundStyle(.secondary) }
                    Button { model.isHistoryExpanded.toggle() } label: {
                        Image(systemName: model.isHistoryExpanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.history.isEmpty ? .tertiary : .secondary)
                    .disabled(model.history.isEmpty)
                    .help("搜索历史")
                }.padding(14)
                if model.isHistoryExpanded && !model.history.isEmpty {
                    HistoryView(history: model.history) {
                        model.query = $0
                        model.isHistoryExpanded = false
                        focused = true
                    }
                }
                Divider()
                HStack {
                    Text("\(model.query.isEmpty ? model.recentResults.count : model.results.count) 个结果").foregroundStyle(.secondary)
                    if model.query.isEmpty { Text("桌面").foregroundStyle(.secondary) }
                    Spacer()
                    Button("浏览文件夹…") { model.browseFolder() }
                        .buttonStyle(.borderless)
                    Button {
                        model.includeHidden.toggle()
                    } label: {
                        Image(systemName: model.includeHidden ? "eye" : "eye.slash")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(model.includeHidden ? .blue : .secondary)
                    .help(model.includeHidden ? "隐藏文件已显示" : "显示隐藏文件")
                    Picker("搜索范围", selection: $model.searchScope) { ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) } }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                    Picker("排序", selection: $model.sort) { ForEach(ResultSort.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 95)
                    Button { model.ascending.toggle() } label: { Image(systemName: model.ascending ? "chevron.up" : "chevron.down") }.help(model.ascending ? "升序" : "降序")
                    if !model.selectedIDs.isEmpty { Text("已选 \(model.selectedIDs.count) 项").foregroundStyle(.blue) }
                    Text(model.indexer.status)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }.padding(.horizontal, 14).padding(.vertical, 8)
                // Keep a fixed-height status strip so the table never jumps while searching.
                Group {
                    if model.isSearching {
                        HStack(spacing: 8) {
                            Text("正在搜索…").foregroundStyle(.secondary)
                            Spacer()
                        }
                    } else if let error = model.searchError {
                        Text("搜索失败：\(error)").foregroundStyle(.red).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    } else if model.results.isEmpty && !model.query.isEmpty && !model.indexer.isIndexing {
                        Text("没有找到结果。请确认已经点击‘索引目录…’，并且该目录已获得访问权限。").foregroundStyle(.secondary).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Color.clear
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                SearchResultsArea(model: model, workspace: model.workspace)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Button("索引目录…") { model.indexer.chooseAndIndex() }
                    Button("重建索引") { model.rebuildIndex() }
                    Spacer()
                    if model.organizer.isMoving { Text("移动中…").font(.caption).foregroundStyle(.secondary) }
                    if model.organizer.message != nil { Button("撤销上次移动") { model.organizer.undoLastMove() } }
                    Text("拖到右侧目标文件夹整理").font(.caption).foregroundStyle(.secondary)
                }.padding(10)
                if let error = model.organizer.error { Text(error).font(.caption).foregroundStyle(.red).padding(.bottom, 4) }
            }
            Divider()
            TargetFoldersView(organizer: model.organizer) { folder in
                model.workspace.open(folder)
            }
        }
        .frame(minWidth: minimumWindowWidth, minHeight: 520)
        .onAppear { focused = true; model.search() }
        .onExitCommand { NSApp.keyWindow?.close() }
    }

    private var minimumWindowWidth: CGFloat {
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 1440
        return min(920, screenWidth * 0.5)
    }

    private func provider(for record: FileRecord) -> NSItemProvider {
        // Snapshot selection at drag start; never consult live selection at drop time.
        let records = model.selectedIDs.contains(record.id) ? model.selectedRecords() : [record]
        let paths = records.map { $0.url.path }
        let payload = try! JSONEncoder().encode(paths)
        let url = record.url
        let provider = NSItemProvider()
        provider.suggestedName = "\(paths.count) 个项目"
        provider.registerDataRepresentation(forTypeIdentifier: swiftFindPathsType, visibility: .ownProcess) { completion in
            completion(payload, nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: swiftFindPathType, visibility: .all) { completion in
            completion(url.path.data(using: .utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(Data(url.absoluteString.utf8), nil)
            return nil
        }
        return provider
    }
}

// Observe folder navigation where the search/table switch is made, so opening
// a folder doesn't wait for an unrelated search update to render it.
struct SearchResultsArea: View {
    @ObservedObject var model: SearchModel
    @ObservedObject var workspace: FolderWorkspaceModel

    var body: some View {
        if workspace.currentFolder != nil {
            FolderWorkspaceView(model: workspace, onPreview: model.openQuickLook)
        } else {
            ResultsTable(model: model)
        }
    }
}

struct ResultRow: View, Equatable {
    let record: FileRecord
    let query: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: record.isDirectory ? "folder.fill" : "doc").foregroundStyle(record.isDirectory ? .blue : .secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) { HighlightedText(text: record.name, query: query).lineLimit(1); HighlightedText(text: record.path, query: query).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(); Text(record.sizeText).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 3)
    }
}
