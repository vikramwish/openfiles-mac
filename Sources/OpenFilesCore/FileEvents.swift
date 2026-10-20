import Foundation
import CoreServices

/// File-level events feed a debounced queue. Overflow and wake require a reconciliation pass.
public final class FileEventWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let callback: FileEventCallback
    public init(receive: @escaping @Sendable ([URL], Bool) -> Void) { callback = FileEventCallback(receive) }
    public func start(roots: [URL]) -> Bool {
        stop()
        let paths = Array(Set(roots.map { $0.standardizedFileURL.path })).sorted()
        guard !paths.isEmpty else { return false }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(callback).toOpaque(), retain: { info in
            guard let info else { return nil }; _ = Unmanaged<FileEventCallback>.fromOpaque(info).retain(); return info
        }, release: { info in
            if let info { Unmanaged<FileEventCallback>.fromOpaque(info).release() }
        }, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let callback = Unmanaged<FileEventCallback>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            let overflow = (0..<count).contains { index in
                flags[index] & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped) != 0
            }
            let urls = paths.enumerated().compactMap { index, path -> URL? in
                let value = flags[index]
                if value & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 && value & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) == 0 { return nil }
                let url = URL(fileURLWithPath: path)
                return FileSearchQuery.allows(url) ? url : nil
            }
            if !urls.isEmpty || overflow { callback.receive(urls, overflow) }
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
        UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        guard let stream else { return false }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        if !FSEventStreamStart(stream) { stop(); return false }
        return true
    }
    public func stop() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil
    }
    deinit { stop() }
}

private final class FileEventCallback: @unchecked Sendable {
    let receive: @Sendable ([URL], Bool) -> Void
    init(_ receive: @escaping @Sendable ([URL], Bool) -> Void) { self.receive = receive }
}
