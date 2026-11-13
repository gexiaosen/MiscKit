import CoreServices
import Foundation

/// 递归目录变更监听（FSEvents）。回调只通知，去抖与扫描由调用方统一调度。
/// 回调上下文用独立的 `CallbackBox` 而不是 `self`：`deinit` 先在串行队列上排空在途回调，
/// 再让 `box` 随实例释放，避免 `FSEventStreamRelease` 后回调再解引用已销毁对象。
public final class FSEventsDirectoryWatcher: @unchecked Sendable {
    private let box: CallbackBox
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var stream: FSEventStreamRef?

    public init(paths: [String],
                queueLabel: String = "app.misckit.dirwatcher",
                latency: CFTimeInterval = 0.5,
                onChange: @escaping @Sendable () -> Void) {
        self.box = CallbackBox(handler: onChange)
        self.queue = DispatchQueue(label: queueLabel, qos: .utility)
        self.queue.setSpecific(key: queueKey, value: 1)
        start(paths: paths, latency: latency)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        // deinit 不能在回调队列上同步等待自己。
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            queue.sync {}
        }
    }

    private func start(paths: [String], latency: CFTimeInterval) {
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagIgnoreSelf)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, directoryWatcherCallback, &context,
                                               paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               latency, flags)
        else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}

private final class CallbackBox: @unchecked Sendable {
    let handler: @Sendable () -> Void

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }
}

private let directoryWatcherCallback: FSEventStreamCallback = { _, info, _, _, _, _ in
    guard let info else { return }
    Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue().handler()
}
