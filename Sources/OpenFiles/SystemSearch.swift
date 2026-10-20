import Foundation

/// Spotlight searches all indexed local volumes without importing folders into OpenFiles.
@MainActor
final class SystemSearch {
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var generation = UUID()
    var onUpdate: (([URL], Bool, Int) -> Void)?
    func stop() {
        generation = UUID(); query?.stop(); query = nil
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers = []
    }
    func search(_ text: String, folder: URL? = nil) {
        stop()
        let query = NSMetadataQuery(), token = generation
        query.searchScopes = folder.map { [$0] as [Any] } ?? [NSMetadataQueryLocalComputerScope]
        query.predicate = NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@ OR kMDItemTextContent CONTAINS[cd] %@", text, text)
        query.notificationBatchingInterval = 0.2
        self.query = query
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, NSNotification.Name.NSMetadataQueryDidUpdate, NSNotification.Name.NSMetadataQueryGatheringProgress] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token, let activeQuery = self.query else { return }
                    activeQuery.disableUpdates()
                    let urls = (0..<min(activeQuery.resultCount, 1000)).compactMap { index -> URL? in
                        guard let item = activeQuery.result(at: index) as? NSMetadataItem, let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
                        return URL(fileURLWithPath: path)
                    }
                    activeQuery.enableUpdates()
                    self.onUpdate?(urls, activeQuery.isGathering, activeQuery.resultCount)
                }
            })
        }
        if !query.start() { onUpdate?([], false, 0) }
    }
}
