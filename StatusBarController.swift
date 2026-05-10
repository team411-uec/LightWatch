import AppKit
import ServiceManagement
import SwiftUI

final class StatusBarController: NSObject {
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onSettingsChanged: ((LightWatchSettings) -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
        statusItem.button?.title = "LightWatch"

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
        statusItem.button?.title = isPaused ? "LightWatch Paused" : "LightWatch \(currentState.rawValue)"
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
        window.setContentSize(NSSize(width: 520, height: 360))
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
    @State private var errorMessage: String?
    let onSave: (LightWatchSettings) -> Void

    init(settings: LightWatchSettings, onSave: @escaping (LightWatchSettings) -> Void) {
        _draft = State(initialValue: settings)
        self.onSave = onSave
    }

    var body: some View {
        Form {
            TextField("Discord Webhook URL", text: $draft.discordWebhookURL)
            Toggle("ログイン時に起動", isOn: $draft.launchAtLogin)
            Stepper("ON確認秒数: \(draft.onConfirmSec)", value: $draft.onConfirmSec, in: 30...900, step: 5)
            Stepper("OFF確認秒数: \(draft.offConfirmSec)", value: $draft.offConfirmSec, in: 300...1800, step: 30)
            Stepper("クールダウン秒数: \(draft.cooldownSec)", value: $draft.cooldownSec, in: 60...1800, step: 30)
            Stepper("必要positive ROI数: \(draft.requiredPositiveROICount)", value: $draft.requiredPositiveROICount, in: 1...5)
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
