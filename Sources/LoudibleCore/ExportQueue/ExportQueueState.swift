import Foundation

/// Actor-owned application state; workflows and the generic scheduler never mutate it.
struct ExportQueueState {
    var snapshot = ExportQueue.Snapshot() {
        didSet {
            guard snapshot != oldValue else { return }
            for observer in observers.values { observer.yield(snapshot) }
        }
    }
    private var observers: [UUID: AsyncStream<ExportQueue.Snapshot>.Continuation] = [:]
    private var transfers: [UUID: (invocation: UUID, attempt: Int)] = [:]

    mutating func updates(
        id: UUID, onTermination: @escaping @Sendable () -> Void) -> AsyncStream<ExportQueue.Snapshot> {
        let (stream, continuation) = AsyncStream<ExportQueue.Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(snapshot)
        continuation.onTermination = { _ in onTermination() }
        observers[id] = continuation
        return stream
    }

    mutating func removeObserver(_ id: UUID) { observers[id] = nil }

    func index(of id: UUID) -> Int? { snapshot.jobs.firstIndex { $0.id == id } }

    mutating func update(_ id: UUID, to state: ExportJob.State) {
        guard let index = index(of: id) else { return }
        try? snapshot.jobs[index].transition(to: state)
        if state.isFinished { transfers[id] = nil }
    }

    mutating func report(_ id: UUID, event: ExportProgressEvent) {
        guard let index = index(of: id), !snapshot.jobs[index].state.isFinished else { return }
        switch event {
        case .phase(let phase):
            transfers[id] = nil
            update(id, to: .running(phase, progress: 0))
        case .beginDownload(let invocation):
            guard case .running(.downloading, _) = snapshot.jobs[index].state else { return }
            transfers[id] = (invocation, -1)
        case .endDownload(let invocation):
            if transfers[id]?.invocation == invocation { transfers[id] = nil }
        case .download(let invocation, let progress):
            guard let transfer = transfers[id], transfer.invocation == invocation,
                  progress.attempt >= transfer.attempt,
                  case .running(.downloading, _) = snapshot.jobs[index].state else { return }
            if progress.attempt > transfer.attempt {
                transfers[id] = (invocation, progress.attempt)
                snapshot.jobs[index].restartDownload()
            }
            reportProgress(index, phase: .downloading, progress: progress.transferred.fraction,
                           transferred: progress.transferred)
        case .conversion(let progress):
            reportProgress(index, phase: .converting, progress: progress)
        }
    }

    private mutating func reportProgress(
        _ index: Int, phase: ExportJob.Phase, progress: Double, transferred: TransferProgress? = nil
    ) {
        guard case .running(let currentPhase, let current) = snapshot.jobs[index].state,
              currentPhase == phase, progress >= 1 || progress - current >= 0.005 || transferred != nil && current == 0
        else { return }
        try? snapshot.jobs[index].transition(to: .running(phase, progress: min(max(progress, 0), 1)),
                                             transferred: transferred)
    }
}
