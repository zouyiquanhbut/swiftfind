import Foundation
import CoreServices

final class FSEventsWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "swiftfind.fsevents", qos: .utility)
    private let handler: (String, FSEventStreamEventFlags) -> Void

    init(paths: [String], handler: @escaping (String, FSEventStreamEventFlags) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            for index in 0..<count {
                watcher.handler(String(cString: paths[index]), rawFlags[index])
            }
        }
        stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
