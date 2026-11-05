#if os(iOS)
import BackgroundTasks
import Dispatch
import Foundation
import os

final class ContinuedTask {
    nonisolated private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Swipt", category: "background")
    private static let unitsPerStep: Int64 = 1000

    var onExpire: (() -> Void)?

    var isRunning: Bool { task != nil }

    private let identifier: String
    private var task: BGTask?
    private var heartbeat: Timer?
    private var isFinished = false
    private var succeeded = false
    private var title = ""
    private var subtitle = ""
    private var completed: Int64 = 0
    private var total: Int64 = 0

    init(kind: String) {
        // AltStore replaces CFBundleIdentifier without rewriting BGTaskSchedulerPermittedIdentifiers
        // (AltStore 56854e6, AltStore/Operations/ResignAppOperation.swift:112-152); SideStore rewrites both
        // (SideStore 0dd743f, SideStore/Core/Operations/PipelineOperations/ResignAppOperation.swift:132-141).
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        let prefix = permitted?.first { $0.hasSuffix(".\(kind).*") }?.dropLast() ?? ""
        identifier = String(prefix) + UUID().uuidString
    }

    func submit(title: String, subtitle: String) {
        guard #available(iOS 26, *) else { return }
        self.title = title
        self.subtitle = subtitle
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { @Sendable task in
            let task = UncheckedSendable(value: task)
            MainActor.assumeIsolated { self.launched(task.value) }
        }
        guard registered else {
            Self.logger.error("Couldn't register the background task \(self.identifier, privacy: .public)")
            return
        }
        let identifier = identifier
        Task.detached {
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
            request.strategy = .fail
            do {
                if #available(iOS 27, *) {
                    try await BGTaskScheduler.shared.submitTaskRequest(request)
                } else {
                    try BGTaskScheduler.shared.submit(request)
                }
            } catch {
                Self.logger.error("Couldn't submit the background task \(identifier, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    func update(title: String, subtitle: String) {
        guard title != self.title || subtitle != self.subtitle else { return }
        self.title = title
        self.subtitle = subtitle
        if #available(iOS 26, *), let task = task as? BGContinuedProcessingTask {
            task.updateTitle(title, subtitle: subtitle)
        }
    }

    func setProgress(completed: Int64, total: Int64) {
        self.completed = completed * Self.unitsPerStep
        self.total = total * Self.unitsPerStep
        reportProgress()
    }

    private func reportProgress() {
        if #available(iOS 26, *), let task = task as? BGContinuedProcessingTask {
            task.progress.totalUnitCount = total
            task.progress.completedUnitCount = completed
        }
    }

    func finish(success: Bool) {
        guard !isFinished else { return }
        isFinished = true
        succeeded = success
        onExpire = nil
        heartbeat?.invalidate()
        heartbeat = nil
        if let task {
            task.setTaskCompleted(success: success)
            self.task = nil
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
    }

    @available(iOS 26, *)
    private func launched(_ task: BGTask) {
        guard !isFinished, let task = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: succeeded)
            return
        }
        self.task = task
        task.expirationHandler = { @Sendable [weak self] in
            DispatchQueue.main.async { self?.expire() }
        }
        task.updateTitle(title, subtitle: subtitle)
        reportProgress()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.completed += 1
                self.reportProgress()
            }
        }
    }

    private func expire() {
        guard !isFinished else { return }
        onExpire?()
        finish(success: false)
    }
}
#endif
