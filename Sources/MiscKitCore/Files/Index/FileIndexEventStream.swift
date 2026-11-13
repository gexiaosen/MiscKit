import CoreServices
import Darwin
import Foundation

struct FileIndexEvent: Sendable {
    let path: String
    let flags: FSEventStreamEventFlags
    let id: FSEventStreamEventId
}

/// FSEvents 文件级监听。回调在私有串行队列上执行，生命周期由 watcher 持有。
final class FileIndexEventStream: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.misckit.fileindex.fsevents", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let box: CallbackBox
    private var stream: FSEventStreamRef?

    init?(paths: [String], since: FSEventStreamEventId,
          handler: @escaping @Sendable ([FileIndexEvent]) -> Void) {
        guard !paths.isEmpty else { return nil }
        box = CallbackBox(handler: handler)
        queue.setSpecific(key: queueKey, value: 1)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagIgnoreSelf
            | kFSEventStreamCreateFlagWatchRoot)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, fileIndexFSEventsCallback, &context,
            paths as CFArray, since, 0.35, flags
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        // deinit 不能在回调队列上等待自己；正常销毁都发生在主线程。
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            queue.sync {}
        }
    }
}

private final class CallbackBox: @unchecked Sendable {
    let handler: @Sendable ([FileIndexEvent]) -> Void

    init(handler: @escaping @Sendable ([FileIndexEvent]) -> Void) {
        self.handler = handler
    }
}

private let fileIndexFSEventsCallback: FSEventStreamCallback = {
    _, info, count, eventPaths, eventFlags, eventIds in
    guard let info, count > 0 else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
    let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()

    var events: [FileIndexEvent] = []
    events.reserveCapacity(count)
    for index in 0..<count {
        guard let raw = CFArrayGetValueAtIndex(array, index) else { continue }
        let string = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        events.append(FileIndexEvent(path: string,
                                     flags: eventFlags[index],
                                     id: eventIds[index]))
    }
    if !events.isEmpty {
        box.handler(events)
    }
}

// MARK: - 事件归类

/// FSEvents 回传的是解析过符号链接的规范路径（例如 `/tmp/x` → `/private/tmp/x`），
/// 而索引里存的是用户配置的根路径。这里把事件路径映射回索引使用的写法。
struct FileIndexRootMap: Sendable {
    private let pairs: [(canonical: String, display: String)]

    init(roots: [URL]) {
        var pairs: [(canonical: String, display: String)] = []
        for url in roots {
            let display = url.standardizedFileURL.path
            let canonical = Self.canonicalPath(for: url)
            pairs.append((canonical, display))
            if canonical != display {
                // 事件有时回传解析后的路径，有时回传原写法；两种都要能落到索引写法。
                pairs.append((display, display))
            }
        }
        self.pairs = pairs.sorted { $0.canonical.count > $1.canonical.count }
    }

    static func canonicalPath(for url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer, let resolved = realpath(pointer, nil) else {
                return url.standardizedFileURL.path
            }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    func displayPath(for path: String) -> String {
        for pair in pairs {
            if path == pair.canonical { return pair.display }
            if path.hasPrefix(pair.canonical + "/") {
                return pair.display + path.dropFirst(pair.canonical.count)
            }
        }
        return path
    }
}

struct FileIndexEventPlan: Equatable, Sendable {
    var deletions: Set<String> = []
    var fileRefreshes: Set<String> = []
    var dirRefreshes: Set<String> = []
    var rescans: Set<String> = []
    var needsFullRescan = false
    var maxEventID: FSEventStreamEventId = 0
}

/// 把一批文件级事件折叠成“删哪些、刷哪些、重扫哪些”；路径以磁盘当前状态为准。
enum FileIndexEventPlanner {
    static func makePlan(events: [FileIndexEvent], policy: FileIndexPolicy,
                         roots: FileIndexRootMap) -> FileIndexEventPlan {
        let structural: FSEventStreamEventFlags =
            FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        let dropped: FSEventStreamEventFlags =
            FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
        let historyDone = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)

        var plan = FileIndexEventPlan()
        for event in events {
            plan.maxEventID = max(plan.maxEventID, event.id)
            let path = roots.displayPath(
                for: URL(fileURLWithPath: event.path).standardizedFileURL.path)
            guard path != "/" else {
                plan.needsFullRescan = true
                continue
            }
            if event.flags & dropped != 0 {
                plan.needsFullRescan = true
                continue
            }
            if event.flags & historyDone != 0 { continue }

            if policy.shouldSkip(path: path) {
                plan.deletions.insert(path)
                continue
            }

            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
            guard FileManager.default.fileExists(atPath: path), let values else {
                plan.deletions.insert(path)
                continue
            }

            let isDirectory = (values.isDirectory ?? false) && !(values.isSymbolicLink ?? false)
            let isPackage = values.isPackage ?? false
            if isDirectory && !isPackage {
                if event.flags & structural != 0 {
                    plan.rescans.insert(path)
                } else {
                    plan.dirRefreshes.insert(path)
                }
            } else {
                plan.fileRefreshes.insert(path)
            }
        }
        return plan
    }

    /// 去掉被上层重扫覆盖的事件，避免同一批里重复扫同一棵树。
    static func prune(_ plan: inout FileIndexEventPlan) {
        let rescans = plan.rescans.sorted { $0.count < $1.count }
        var kept: [String] = []
        for path in rescans where
            !kept.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            kept.append(path)
        }
        plan.rescans = Set(kept)

        func covered(_ path: String) -> Bool {
            kept.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        plan.fileRefreshes = plan.fileRefreshes.filter { !covered($0) }
        plan.dirRefreshes = plan.dirRefreshes.filter { !covered($0) }
        plan.deletions = plan.deletions.filter { !covered($0) }
    }
}
