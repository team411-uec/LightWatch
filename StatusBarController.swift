import AppKit
import ServiceManagement
import SwiftUI

final class StatusBarController: NSObject {
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onSettingsChanged: ((LightWatchSettings) -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let settingsStore: SettingsStore
    private let logsDirectory: URL
    private var currentSettings: LightWatchSettings
    private var settingsWindow: NSWindow?
    private let stateMenuItem = NSMenuItem(title: "現在状態: DARK", action: nil, keyEquivalent: "")
    private let pauseMenuItem = NSMenuItem(title: "一時停止", action: #selector(pause), keyEquivalent: "")
    private let resumeMenuItem = NSMenuItem(title: "再開", action: #selector(resume), keyEquivalent: "")
    private var isPaused = false
    private var currentState: LightWatchState = .dark

    init(settingsStore: SettingsStore, initialSettings: LightWatchSettings, logsDirectory: URL) {
        self.settingsStore = settingsStore
        self.currentSettings = initialSettings
        self.logsDirectory = logsDirectory
        super.init()
        configureMenu()
        update(state: .dark)
    }

    func update(state: LightWatchState) {
        currentState = state
        renderState()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        renderState()
    }

    private func configureMenu() {
        statusItem.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        stateMenuItem.isEnabled = false
        pauseMenuItem.target = self
        resumeMenuItem.target = self

        menu.addItem(stateMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(pauseMenuItem)
        menu.addItem(resumeMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "ログを開く", action: #selector(openLogs), keyEquivalent: ""))
        menu.items.last?.target = self
        menu.addItem(NSMenuItem(title: "設定を開く", action: #selector(openSettings), keyEquivalent: ""))
        menu.items.last?.target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.target = self
        statusItem.menu = menu
    }

    private func renderState() {
        let title = isPaused ? "現在状態: 一時停止中" : "現在状態: \(currentState.rawValue)"
        stateMenuItem.title = title
        pauseMenuItem.isEnabled = !isPaused
        resumeMenuItem.isEnabled = isPaused
        statusItem.button?.toolTip = isPaused ? "LightWatch: 一時停止中" : "LightWatch: \(currentState.rawValue)"
        setStatusIcon()
    }

    private func setStatusIcon() {
        let symbolName: String
        if isPaused {
            symbolName = "pause.circle"
        } else {
            switch currentState {
            case .dark:
                symbolName = "lightbulb"
            case .onCandidate, .offCandidate:
                symbolName = "clock"
            case .bright:
                symbolName = "lightbulb.fill"
            }
        }

        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "LightWatch") else {
            statusItem.button?.title = "LW"
            return
        }
        image.isTemplate = true
        statusItem.button?.title = ""
        statusItem.button?.image = image
    }

    @objc private func pause() {
        onPause?()
    }

    @objc private func resume() {
        onResume?()
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(logsDirectory)
    }

    @objc private func openSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(
            settings: currentSettings,
            onSave: { [weak self] updatedSettings in
                self?.currentSettings = updatedSettings
                self?.onSettingsChanged?(updatedSettings)
            }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "LightWatch設定"
        window.setContentSize(NSSize(width: 620, height: 520))
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension StatusBarController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        settingsWindow = nil
    }
}

private struct SettingsView: View {
    @State private var draft: LightWatchSettings
    @State private var cameraOptions: [CameraDeviceOption]
    @State private var errorMessage: String?
    let onSave: (LightWatchSettings) -> Void

    init(settings: LightWatchSettings, onSave: @escaping (LightWatchSettings) -> Void) {
        _draft = State(initialValue: settings)
        _cameraOptions = State(initialValue: CameraDeviceCatalog.availableOptions())
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Form {
                Section {
                    TextField("Discord Webhook URL", text: $draft.discordWebhookURL)
                    Picker("カメラ", selection: $draft.cameraUniqueID) {
                        Text("システム既定").tag("")
                        ForEach(cameraOptions) { camera in
                            Text(camera.name).tag(camera.id)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("カメラを再読み込み") {
                            cameraOptions = CameraDeviceCatalog.availableOptions()
                        }
                    }
                }
                Section {
                    Toggle("ログイン時に起動", isOn: $draft.launchAtLogin)
                    Stepper("取得間隔: \(Int(draft.captureIntervalSec))秒", value: $draft.captureIntervalSec, in: 1...30, step: 1)
                    Stepper("短期比較: \(Int(draft.shortDiffSec))秒", value: $draft.shortDiffSec, in: 1...30, step: 1)
                    Stepper("ノイズ計測: \(Int(draft.noiseWindowSec))秒", value: $draft.noiseWindowSec, in: 60...1800, step: 30)
                    Stepper("ON確認: \(Int(draft.onConfirmSec))秒", value: $draft.onConfirmSec, in: 30...900, step: 5)
                    Stepper("OFF確認: \(Int(draft.offConfirmSec))秒", value: $draft.offConfirmSec, in: 300...1800, step: 30)
                    Stepper("クールダウン: \(Int(draft.cooldownSec))秒", value: $draft.cooldownSec, in: 60...1800, step: 30)
                    Stepper("ON差分しきい値: \(Int(draft.minDeltaOn))", value: $draft.minDeltaOn, in: 1...80, step: 1)
                    Stepper("OFF差分しきい値: \(Int(draft.minDeltaOff))", value: $draft.minDeltaOff, in: -80 ... -1, step: 1)
                    Stepper("必要positive ROI数: \(draft.requiredPositiveROICount)", value: $draft.requiredPositiveROICount, in: 1...5)
                    Stepper("ノイズ倍率: \(draft.noiseMultiplier, specifier: "%.1f")", value: $draft.noiseMultiplier, in: 1...10, step: 0.5)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("保存") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func save() {
        do {
            try setLaunchAtLogin(draft.launchAtLogin)
            errorMessage = nil
            onSave(draft)
        } catch {
            errorMessage = "ログイン項目設定に失敗しました: \(error.localizedDescription)"
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}
