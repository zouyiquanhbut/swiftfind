import AppKit
import Foundation

@MainActor
enum FileActions {
    static func rename(_ record: FileRecord, completion: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "重命名"
        alert.informativeText = record.isDirectory ? "输入文件夹的新名称：" : "输入文件的新名称："
        let field = NSTextField(string: record.name)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != record.name, !newName.contains("/") else { return }
        let destination = record.url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: record.url, to: destination)
            NotificationCenter.default.post(name: .swiftFindIndexDidChange, object: nil, userInfo: [
                "movedPaths": [record.path],
                "movedDestinationPaths": [destination.path]
            ])
            completion()
        } catch {
            showError("无法重命名", error.localizedDescription)
        }
    }

    static func trash(_ records: [FileRecord], confirm: Bool = true, completion: @escaping () -> Void) {
        guard !records.isEmpty else { return }
        if confirm {
            let alert = NSAlert()
            alert.messageText = "移到废纸篓？"
            alert.informativeText = "将把选中的 \(records.count) 个项目移到废纸篓。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "移到废纸篓")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var movedPaths: [String] = []
        var firstError: Error?
        for record in records {
            do {
                try FileManager.default.trashItem(at: record.url, resultingItemURL: nil)
                movedPaths.append(record.path)
            } catch { if firstError == nil { firstError = error } }
        }
        if !movedPaths.isEmpty {
            NotificationCenter.default.post(name: .swiftFindIndexDidChange, object: nil, userInfo: ["movedPaths": movedPaths])
            completion()
        }
        if let firstError { showError("部分项目无法移到废纸篓", firstError.localizedDescription) }
    }

    private static func showError(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}
