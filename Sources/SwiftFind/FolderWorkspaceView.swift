import SwiftUI
import UniformTypeIdentifiers

struct FolderWorkspaceView: View {
    @ObservedObject var model: FolderWorkspaceModel
    let onPreview: (FileRecord) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isLoading && model.items.isEmpty {
                ProgressView("读取文件夹…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.error, model.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
                    Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("重试") { model.refresh() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            } else if model.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder").font(.title2).foregroundStyle(.secondary)
                    Text("此文件夹为空").foregroundStyle(.secondary)
                    Text("可以拖入文件，或点击右上角新建文件夹").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onDrop(of: FileOperationService.dropTypes, isTargeted: .constant(false)) { providers in
                        guard let folder = model.currentFolder else { return false }
                        model.moveDroppedProviders(providers, to: folder)
                        return true
                    }
            } else {
                FolderTable(model: model, onPreview: onPreview)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))

    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).disabled(!model.canGoBack).help("返回上一级")
            Image(systemName: "folder.fill").foregroundStyle(.blue)
            Text(model.folderName).font(.headline).lineLimit(1)
            Text(model.currentFolder?.path ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button { model.showHidden.toggle(); model.refresh() } label: {
                Image(systemName: model.showHidden ? "eye" : "eye.slash")
            }.buttonStyle(.borderless).help(model.showHidden ? "隐藏隐藏文件" : "显示隐藏文件")
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("刷新")
            Button { model.createFolder() } label: { Image(systemName: "folder.badge.plus") }
                .buttonStyle(.borderless).help("新建文件夹")
            Button { model.close() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("关闭文件夹视图")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

