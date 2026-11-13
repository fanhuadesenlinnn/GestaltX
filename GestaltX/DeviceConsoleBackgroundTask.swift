// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

/// Keeps pairing / capture running and shown in the Dynamic Island via a
/// `BGContinuedProcessingTask` (iOS 26+). It is *only* submitted after the user
/// explicitly starts pairing or capture — never on launch — and it degrades to a
/// plain foreground session when the system declines or the device has no
/// Dynamic Island. No silent-audio keep-alive is used.
///
/// Identifiers derive from the runtime bundle id so a self-signed bundle-id
/// rewrite does not break registration. The matching wildcard must be listed in
/// `BGTaskSchedulerPermittedIdentifiers` (see Configuration/App-Info.plist).
@MainActor
final class DeviceConsoleBackgroundTask {
    static let shared = DeviceConsoleBackgroundTask()
    private init() {}

    /// Fixed identifier: BGTaskScheduler requires the exact submitted
    /// identifier to have been registered at launch. Pairing and capture are
    /// mutually exclusive, so one continued-processing slot is enough.
    static var identifier: String { DeviceConsolePaths.runtimeBundleID + ".console.continued" }

    private var registered = false
    private var registrationSucceeded = false
    private var onExpire: (() -> Void)?
    /// Identifier of the submitted request, kept so an early `end()` can
    /// cancel a task that the system has not launched into yet.
    private var requestIdentifier: String?
    /// Updates can arrive before the system hands us the task. Remember the
    /// latest values and apply them when `attach` runs.
    private var pendingSubtitle: String?
    private var pendingFraction: Double?

    #if canImport(BackgroundTasks)
    private var activeTask: BGContinuedProcessingTask?
    #endif

    var isRunning: Bool {
        if activeTask != nil { return true }
        return requestIdentifier != nil
    }

    /// Register the launch handler once, at app startup.
    func registerIfNeeded() {
        #if canImport(BackgroundTasks)
        guard !registered else { return }
        registered = true
        if #available(iOS 26.0, *) {
            registrationSucceeded = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: Self.identifier,
                using: .main
            ) { [weak self] task in
                guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                self?.attach(task)
            }
            if !registrationSucceeded {
                // Identifier not permitted (Info.plist / signing). Foreground only.
                NSLog("GestaltX: BGContinuedProcessingTask registration failed for \(Self.identifier)")
            }
        }
        #endif
    }

    /// Returns whether a continued-processing task was accepted. When false, the
    /// caller must keep the app in the foreground.
    @discardableResult
    func begin(title: String, subtitle: String, fraction: Double? = 0.05,
               onExpire: @escaping () -> Void) -> Bool {
        #if canImport(BackgroundTasks)
        guard #available(iOS 26.0, *) else { return false }
        guard registrationSucceeded else {
            NSLog("GestaltX: refusing to submit unregistered BG task \(Self.identifier)")
            return false
        }
        if isRunning {
            self.onExpire = onExpire
            update(subtitle: subtitle)
            return true
        }
        self.onExpire = onExpire
        pendingSubtitle = subtitle
        pendingFraction = fraction
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.identifier,
            title: title,
            subtitle: subtitle)
        request.strategy = .fail   // if resources are unavailable now, fail fast rather than queue
        do {
            try BGTaskScheduler.shared.submit(request)
            requestIdentifier = Self.identifier
            return true
        } catch {
            self.onExpire = nil
            requestIdentifier = nil
            return false
        }
        #else
        _ = (title, subtitle, fraction, onExpire)
        return false
        #endif
    }

    /// Update the Dynamic Island subtitle / progress. `fraction` nil leaves it
    /// indeterminate. The subtitle may carry a phase or pairing code — it is
    /// shown, never written to disk.
    func update(subtitle: String, fraction: Double? = nil) {
        #if canImport(BackgroundTasks)
        pendingSubtitle = subtitle
        pendingFraction = fraction
        guard #available(iOS 26.0, *), let task = activeTask else { return }
        task.updateTitle(task.title, subtitle: subtitle)
        if let fraction {
            task.progress.totalUnitCount = 100
            task.progress.completedUnitCount = Int64((fraction * 100).rounded())
        }
        #else
        _ = (subtitle, fraction)
        #endif
    }

    /// Mark the task finished (pairing/capture ended normally or by the user).
    func end(success: Bool = true) {
        #if canImport(BackgroundTasks)
        guard #available(iOS 26.0, *) else {
            onExpire = nil
            return
        }
        if let activeTask {
            activeTask.setTaskCompleted(success: success)
        } else if let requestIdentifier {
            // The system has not launched the task yet; cancel the pending
            // request so a stale continued-processing card does not linger.
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestIdentifier)
        }
        activeTask = nil
        requestIdentifier = nil
        pendingSubtitle = nil
        pendingFraction = nil
        onExpire = nil
        #endif
    }

    #if canImport(BackgroundTasks)
    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask) {
        activeTask = task
        if let subtitle = pendingSubtitle {
            task.updateTitle(task.title, subtitle: subtitle)
            if let fraction = pendingFraction {
                task.progress.totalUnitCount = 100
                task.progress.completedUnitCount = Int64((fraction * 100).rounded())
            }
        }
        task.expirationHandler = { [weak self] in
            // The system is ending the task: stop native work and release it.
            self?.onExpire?()
            self?.activeTask?.setTaskCompleted(success: false)
            self?.activeTask = nil
            self?.requestIdentifier = nil
        }
    }
    #endif
}
