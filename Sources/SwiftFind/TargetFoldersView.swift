import SwiftUI
import UniformTypeIdentifiers

struct TargetFoldersView: View {
    @ObservedObject var organizer: FileOrganizer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("目标文件夹").font(.headline)
                Spacer()
                Menu {
                    Button("添加已有文件夹…") { organizer.addTarget() }
                    Button("新建文件夹…") { organizer.createTarget() }
                } label: {
                    Image(systemName: "plus")
                }
                .help("添加目标文件夹")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            if organizer.targets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus").font(.title2).foregroundStyle(.secondary)
                    Text("添加常用目标文件夹")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("把搜索结果拖到这里整理")
                        .font(.caption).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(18)
                .onDrop(of: [swiftFindPathsType, swiftFindPathType, UTType.fileURL.identifier, UTType.url.identifier], isTargeted: .constant(false)) { providers in
                    organizer.addTargetFromProviders(providers)
                    return true
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(organizer.targets) { target in
                            let position = organizer.targets.firstIndex(where: { $0.id == target.id }) ?? 0
                            if organizer.targetDropIndex == position { DropInsertionIndicator() }
                            TargetFolderRow(target: target, position: position, organizer: organizer)
                        }
                        if organizer.targetDropIndex == organizer.targets.count { DropInsertionIndicator() }
                    }
                    .padding(10)
                    Spacer(minLength: 80)
                }
                .onDrop(of: [swiftFindTargetReorderType], isTargeted: Binding(
                    get: { organizer.targetDropIndex == organizer.targets.count },
                    set: { isTargeted in organizer.setTargetDropIndex(isTargeted ? organizer.targets.count : nil) }
                )) { providers in
                    organizer.handleTargetAreaDrop(providers, position: organizer.targets.count, target: nil)
                    return true
                }
            }
            if let error = organizer.error {
                ScrollView {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 140).padding(10)
            }
            if let message = organizer.message {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(message).lineLimit(2)
                    Spacer()
                    Button { organizer.undoLastMove() } label: { Image(systemName: "arrow.uturn.backward") }
                        .help("撤销上次移动")
                }
                .font(.caption)
                .padding(10)
            }
        }
        .frame(width: 235)
        .background(.quaternary.opacity(0.25))
    }
}

private struct DropInsertionIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.circle.fill")
            Text("放置到这里")
        }
        .font(.caption2)
        .foregroundStyle(Color.accentColor)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.12))
    }
}

private struct TargetFolderRow: View {
    let target: FolderTarget
    let position: Int
    @ObservedObject var organizer: FileOrganizer

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if organizer.hoveredTargetID == target.id {
                Text("松开以移动到此处")
                    .font(.caption2).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(.blue)
                Text(target.name).font(.callout).lineLimit(1)
                Spacer()
                if position < 9 { Text("⌥\(position + 1)").font(.caption2).foregroundStyle(.secondary) }
                VStack(spacing: 1) {
                    Button { organizer.moveTarget(from: position, to: position - 1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.plain).disabled(position == 0).help("上移")
                    Button { organizer.moveTarget(from: position, to: position + 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.plain).disabled(position >= organizer.targets.count - 1).help("下移")
                }
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(Color.secondary)
                    .help("拖动此图标调整目标文件夹顺序")
                    .onDrag {
                        let provider = NSItemProvider()
                        provider.registerDataRepresentation(forTypeIdentifier: swiftFindTargetReorderType, visibility: .all) { completion in
                            completion(Data("\(position)".utf8), nil)
                            return nil
                        }
                        return provider
                    }
            }
            Text(target.url.path)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(organizer.hoveredTargetID == target.id ? Color.accentColor : Color.secondary.opacity(0.08))
        .foregroundStyle(organizer.hoveredTargetID == target.id ? .white : .primary)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(organizer.hoveredTargetID == target.id ? Color.accentColor : Color.clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { FolderOpener.open(target.url) }
        // One unified drop receiver is important here. Two overlapping SwiftUI
        // onDrop modifiers can cause the file drop to be claimed by the reorder
        // receiver and never reach the move logic.
        .onDrop(of: [swiftFindTargetReorderType, swiftFindPathsType, swiftFindPathType, UTType.fileURL.identifier, UTType.url.identifier, UTType.data.identifier], isTargeted: Binding(
            get: { organizer.targetDropIndex == position || organizer.hoveredTargetID == target.id },
            set: { isTargeted in
                if !isTargeted {
                    organizer.setTargetDropIndex(nil)
                    organizer.hoveredTargetID = nil
                } else if organizer.targetDropIndex != nil {
                    organizer.setTargetDropIndex(position)
                } else {
                    organizer.hoveredTargetID = target.id
                }
            }
        )) { providers in
            organizer.setTargetDropIndex(nil)
            organizer.hoveredTargetID = nil
            organizer.handleTargetAreaDrop(providers, position: position, target: target.url)
            return true
        }
        .contextMenu {
            Button("打开文件夹") { FolderOpener.open(target.url) }
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([target.url]) }
            Divider()
            Button("移除目标文件夹", role: .destructive) { organizer.removeTarget(target) }
        }
    }
}
