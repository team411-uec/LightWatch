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
    private let stateMenuItem = NSMenuItem(title: "状態: 消灯中", action: nil, keyEquivalent: "")
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
        let title = isPaused ? "状態: 一時停止中" : "状態: \(currentState.displayName)"
        stateMenuItem.title = title
        pauseMenuItem.isEnabled = !isPaused
        resumeMenuItem.isEnabled = isPaused
        statusItem.button?.toolTip = isPaused ? "LightWatch: 一時停止中" : "LightWatch: \(currentState.displayName)"
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
        window.setContentSize(NSSize(width: 700, height: 460))
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
        VStack(spacing: 0) {
            TabView {
                generalPane
                    .tabItem {
                        Label("一般", systemImage: "gearshape")
                    }
                detectionPane
                    .tabItem {
                        Label("判定", systemImage: "slider.horizontal.3")
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 12) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("保存") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingRow("Webhook URL") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("", text: $draft.discordWebhookURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 420)
                    hintText("保存後、次の通知から新しいURLへ送信します。")
                }
            }

            settingRow("カメラ") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Picker("", selection: $draft.cameraUniqueID) {
                            Text("システム既定").tag("")
                            ForEach(cameraOptions) { camera in
                                Text(camera.name).tag(camera.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 300)

                        Button {
                            cameraOptions = CameraDeviceCatalog.availableOptions()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("カメラ一覧を再読み込み")
                    }
                    hintText("SplitCamなどの仮想カメラは起動後に再読み込みします。")
                }
            }

            Divider()
                .padding(.vertical, 4)

            Toggle("ログイン時に起動", isOn: $draft.launchAtLogin)
                .toggleStyle(.checkbox)
                .padding(.leading, 124)
            hintText("Mac miniで常駐させる場合は有効にします。")
                .padding(.leading, 124)

            Spacer()
        }
        .padding(24)
    }

    private var detectionPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            timeStepper("取得間隔", value: $draft.captureIntervalSec, range: 1...30, step: 1, hint: "短いほど反応は早く、ログ量は増えます。")
            timeStepper("短期比較", value: $draft.shortDiffSec, range: 1...30, step: 1, hint: "何秒前の明るさと比べるかです。短いほど直近の変化を見ます。")
            timeStepper("ノイズ計測", value: $draft.noiseWindowSec, range: 60...1800, step: 30, hint: "通常の揺れ幅を測る時間です。短いほど環境変化に早く追従します。")
            timeStepper("ON確認", value: $draft.onConfirmSec, range: 30...900, step: 5, hint: "点灯判定を確定するまでの継続時間です。短いほど早く確定します。")
            timeStepper("OFF確認", value: $draft.offConfirmSec, range: 300...1800, step: 30, hint: "消灯判定を確定するまでの継続時間です。長いほど誤検出を抑えます。")
            timeStepper("クールダウン", value: $draft.cooldownSec, range: 60...1800, step: 30, hint: "通知後、次の通知を抑える時間です。短いほど再通知が早くなります。")

            Divider()
                .padding(.vertical, 4)

            numberStepper("ON差分しきい値", value: $draft.minDeltaOn, range: 1...80, step: 1, digits: 0, hint: "明るくなったと見る輝度差です。小さいほど検出します。")
            numberStepper("OFF差分しきい値", value: $draft.minDeltaOff, range: -80 ... -1, step: 1, digits: 0, hint: "暗くなったと見る輝度差です。0に近いほど検出します。")
            integerStepper("必要positive ROI数", value: $draft.requiredPositiveROICount, range: 1...5, step: 1, hint: "いくつの監視領域が変化したら候補にするかです。")
            numberStepper("ノイズ倍率", value: $draft.noiseMultiplier, range: 1...10, step: 0.5, digits: 1, hint: "通常の揺れより何倍大きい変化を採用するかです。小さいほど敏感です。")

            Spacer()
        }
        .padding(24)
    }

    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title)
                .frame(width: 132, alignment: .trailing)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func hintText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func timeStepper(
        _ title: String,
        value: Binding<TimeInterval>,
        range: ClosedRange<TimeInterval>,
        step: TimeInterval,
        hint: String
    ) -> some View {
        settingRow(title) {
            HStack(alignment: .center, spacing: 16) {
                Stepper(value: value, in: range, step: step) {
                    Text("\(Int(value.wrappedValue))秒")
                        .monospacedDigit()
                        .frame(width: 72, alignment: .leading)
                }
                .frame(width: 150, alignment: .leading)

                hintText(hint)
                    .frame(width: 330, alignment: .leading)
            }
        }
    }

    private func numberStepper(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        digits: Int,
        hint: String
    ) -> some View {
        settingRow(title) {
            HStack(alignment: .center, spacing: 16) {
                Stepper(value: value, in: range, step: step) {
                    Text(value.wrappedValue.formatted(.number.precision(.fractionLength(digits))))
                        .monospacedDigit()
                        .frame(width: 72, alignment: .leading)
                }
                .frame(width: 150, alignment: .leading)

                hintText(hint)
                    .frame(width: 330, alignment: .leading)
            }
        }
    }

    private func integerStepper(
        _ title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        hint: String
    ) -> some View {
        settingRow(title) {
            HStack(alignment: .center, spacing: 16) {
                Stepper(value: value, in: range, step: step) {
                    Text("\(value.wrappedValue)")
                        .monospacedDigit()
                        .frame(width: 72, alignment: .leading)
                }
                .frame(width: 150, alignment: .leading)

                hintText(hint)
                    .frame(width: 330, alignment: .leading)
            }
        }
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
