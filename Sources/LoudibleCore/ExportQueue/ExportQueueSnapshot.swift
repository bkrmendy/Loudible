import Foundation

extension ExportQueue {
    public struct Snapshot: Sendable, Equatable {
        public var jobs: [ExportJob]
        public var isRunning: Bool
        public var isWaitingForAuthentication: Bool

        public init(jobs: [ExportJob] = [], isRunning: Bool = false, isWaitingForAuthentication: Bool = false) {
            self.jobs = jobs
            self.isRunning = isRunning
            self.isWaitingForAuthentication = isWaitingForAuthentication
        }

        /// Completion across all jobs (0...1).
        public var fractionCompleted: Double {
            guard !jobs.isEmpty else { return 0 }
            return jobs.map(\.fractionCompleted).reduce(0, +) / Double(jobs.count)
        }
    }

}
