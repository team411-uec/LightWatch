import AppKit
import AVFoundation
import IOKit.pwr_mgt

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore()
    private var settings: LightWatchSettings = .default
    private var logger: EventLogger?
    private var analyzer: LightAnalyzer?
    private var stateMachine: StateMachine?
    private var webhookClient: DiscordWebhookClient?
    private var cameraManager: CameraManager?
    private var statusBarController: StatusBarController?
    private var powerAssertionID = IOPMAssertionID(0)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            settings = try settingsStore.load()
            logger = try EventLogger(applicationSupportDirectory: settingsStore.applicationSupportDirectory)
            analyzer = LightAnalyzer(settings: settings)
            stateMachine = StateMachine(settings: settings, initialState: settingsStore.loadState())
            webhookClient = DiscordWebhookClient(settingsProvider: { [weak self] in
                self?.settings ?? .default
            })

            let statusBarController = StatusBarController(
                settingsStore: settingsStore,
                initialSettings: settings,
                logsDirectory: settingsStore.logsDirectory
            )
            statusBarController.onPause = { [weak self] in self?.pauseMonitoring() }
            statusBarController.onResume = { [weak self] in self?.resumeMonitoring() }
            statusBarController.onSettingsChanged = { [weak self] updatedSettings in
                self?.applySettings(updatedSettings)
            }
            self.statusBarController = statusBarController

            logWebhookConfigurationIfNeeded(settings)
            startPowerAssertion()
            startCamera()
        } catch {
            logger?.logError("起動初期化に失敗しました: \(error.localizedDescription)")
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cameraManager?.stop()
        stopPowerAssertion()
        if let stateMachine {
            settingsStore.saveState(stateMachine.currentState)
        }
    }

    private func startCamera() {
        let cameraManager = CameraManager(captureInterval: settings.captureIntervalSec)
        cameraManager.onSampleBuffer = { [weak self] sampleBuffer in
            self?.handleSampleBuffer(sampleBuffer)
        }
        cameraManager.onError = { [weak self] message in
            self?.logger?.logError(message)
        }
        self.cameraManager = cameraManager
        cameraManager.start()
    }

    private func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let analyzer, let stateMachine, let logger else { return }

        do {
            let snapshot = try analyzer.analyze(sampleBuffer: sampleBuffer, state: stateMachine.currentState)
            logger.logSample(snapshot)

            let transitionEvents = stateMachine.handle(snapshot: snapshot)
            settingsStore.saveState(stateMachine.currentState)
            DispatchQueue.main.async { [weak self] in
                self?.statusBarController?.update(state: stateMachine.currentState)
            }

            for event in transitionEvents {
                logger.logEvent(event)
                if let notification = event.notification {
                    webhookClient?.send(notification: notification) { [weak self] result in
                        switch result {
                        case .success:
                            break
                        case .failure(let error):
                            self?.logger?.logError("Discord Webhook送信に失敗しました: \(error.localizedDescription)")
                        }
                    }
                }
            }
        } catch {
            logger.logError("フレーム解析に失敗しました: \(error.localizedDescription)")
        }
    }

    private func pauseMonitoring() {
        cameraManager?.stop()
        stopPowerAssertion()
        DispatchQueue.main.async { [weak self] in
            self?.statusBarController?.setPaused(true)
        }
        logger?.logEvent(LightEvent(event: "paused", state: nil, reason: "user_menu", values: [:]))
    }

    private func resumeMonitoring() {
        startPowerAssertion()
        startCamera()
        DispatchQueue.main.async { [weak self] in
            self?.statusBarController?.setPaused(false)
        }
        logger?.logEvent(LightEvent(event: "resumed", state: nil, reason: "user_menu", values: [:]))
    }

    private func applySettings(_ updatedSettings: LightWatchSettings) {
        settings = updatedSettings
        settingsStore.save(settings)
        logWebhookConfigurationIfNeeded(updatedSettings)
        analyzer = LightAnalyzer(settings: updatedSettings)
        stateMachine?.update(settings: updatedSettings)
        cameraManager?.update(captureInterval: updatedSettings.captureIntervalSec)
    }

    private func logWebhookConfigurationIfNeeded(_ settings: LightWatchSettings) {
        guard settings.discordWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        logger?.logError("Discord Webhook URLが未設定です。通知は送信されません。")
    }

    private func startPowerAssertion() {
        guard powerAssertionID == 0 else { return }
        let reason = "LightWatch monitoring" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &powerAssertionID
        )
        if result != kIOReturnSuccess {
            logger?.logError("アイドルスリープ抑止の開始に失敗しました: \(result)")
            powerAssertionID = 0
        }
    }

    private func stopPowerAssertion() {
        guard powerAssertionID != 0 else { return }
        IOPMAssertionRelease(powerAssertionID)
        powerAssertionID = 0
    }
}
