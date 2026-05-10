import AppKit
import ServiceManagement
import SwiftUI

final class StatusBarController: NSObject {
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onSettingsChanged: ((LightWatchSettings) -> Void)?
    var onReferenceCaptureRequested: ((LightScene) throws -> LightReferenceProfile)?

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
            onReferenceCaptureRequested: { [weak self] scene in
                guard let self, let onReferenceCaptureRequested else {
                    throw LightReferenceProfileError.missingFrame
                }
                return try onReferenceCaptureRequested(scene)
            },
            onSave: { [weak self] updatedSettings in
                self?.currentSettings = updatedSettings
                self?.onSettingsChanged?(updatedSettings)
            }
        )
        let windowSize = NSSize(width: 700, height: 520)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "LightWatch設定"
        window.setContentSize(windowSize)
        window.contentMinSize = windowSize
        window.contentMaxSize = windowSize
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
    private let referenceCaptureDelaySec = 10
    private let referenceCountdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var draft: LightWatchSettings
    @State private var numberFields: SettingsNumberFields
    @State private var cameraOptions: [CameraDeviceOption]
    @State private var errorMessage: String?
    @State private var selectedTab = SettingsTab.general
    @State private var selectedPresetID = DetectionPreset.standard.id
    @State private var referenceMessage: String?
    @State private var referenceCountdown: ReferenceCountdown?
    let onReferenceCaptureRequested: (LightScene) throws -> LightReferenceProfile
    let onSave: (LightWatchSettings) -> Void

    init(
        settings: LightWatchSettings,
        onReferenceCaptureRequested: @escaping (LightScene) throws -> LightReferenceProfile,
        onSave: @escaping (LightWatchSettings) -> Void
    ) {
        _draft = State(initialValue: settings)
        _numberFields = State(initialValue: SettingsNumberFields(settings: settings))
        _cameraOptions = State(initialValue: CameraDeviceCatalog.availableOptions())
        self.onReferenceCaptureRequested = onReferenceCaptureRequested
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("一般").tag(SettingsTab.general)
                Text("判定").tag(SettingsTab.detection)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 204)
            .padding(.top, 8)
            .padding(.bottom, 8)

            Divider()

            Group {
                switch selectedTab {
                case .general:
                    ScrollView {
                        generalPane
                    }
                case .detection:
                    ScrollView {
                        detectionPane
                    }
                }
            }
            .frame(width: 700, height: 390, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor))

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
        .frame(width: 700, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(referenceCountdownTimer) { _ in
            updateReferenceCountdown()
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
            hintText("常駐させる場合は有効にします。")
                .padding(.leading, 124)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var detectionPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            presetRow

            Divider()
                .padding(.vertical, 4)

            numberField("取得間隔", text: $numberFields.captureIntervalSec, suffix: "秒", hint: "短いほど反応は早く、ログ量は増えます。")
            numberField("短期比較", text: $numberFields.shortDiffSec, suffix: "秒", hint: "何秒前の明るさと比べるかです。短いほど直近の変化を見ます。")
            numberField("ON確認", text: $numberFields.onConfirmSec, suffix: "秒", hint: "点灯判定を確定するまでの継続時間です。短いほど早く確定します。")
            numberField("OFF確認", text: $numberFields.offConfirmSec, suffix: "秒", hint: "消灯判定を確定するまでの継続時間です。長いほど誤検出を抑えます。")

            Divider()
                .padding(.vertical, 4)

            numberField("ON差分しきい値", text: $numberFields.minDeltaOn, suffix: "", hint: "明るくなったと見る輝度差です。小さいほど検出します。")
            numberField("OFF差分しきい値", text: $numberFields.minDeltaOff, suffix: "", hint: "暗くなったと見る輝度差です。0に近いほど検出します。")
            numberField("必要positive ROI数", text: $numberFields.requiredPositiveROICount, suffix: "", hint: "いくつの監視領域が変化したら候補にするかです。")

            Divider()
                .padding(.vertical, 4)

            referenceProfileRow
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title)
                .frame(width: 132, alignment: .trailing)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var presetRow: some View {
        settingRow("プリセット") {
            VStack(alignment: .leading, spacing: 4) {
                Picker("", selection: $selectedPresetID) {
                    ForEach(DetectionPreset.presets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 420)
                .onChange(of: selectedPresetID) { presetID in
                    applyPreset(id: presetID)
                }

                if let preset = DetectionPreset.find(id: selectedPresetID) {
                    hintText(preset.hint)
                }
            }
        }
    }

    private var referenceProfileRow: some View {
        settingRow("基準画像") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button(referenceButtonTitle(scene: .dark)) {
                        startReferenceCountdown(scene: .dark)
                    }
                    .disabled(referenceCountdown != nil)
                    Button(referenceButtonTitle(scene: .bright)) {
                        startReferenceCountdown(scene: .bright)
                    }
                    .disabled(referenceCountdown != nil)
                }
                hintText(referenceProfileHint)
                if let referenceCountdown {
                    countdownView(referenceCountdown)
                }
                if let referenceMessage {
                    Text(referenceMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var referenceProfileHint: String {
        let darkStatus = draft.darkReferenceProfile == nil ? "未保存" : "保存済み"
        let brightStatus = draft.brightReferenceProfile == nil ? "未保存" : "保存済み"
        return "端のpositive ROIだけを使います。消灯: \(darkStatus) / 点灯: \(brightStatus)"
    }

    private func countdownView(_ countdown: ReferenceCountdown) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "camera.metering.matrix")
                    .foregroundStyle(.tint)
                Text("\(sceneName(countdown.scene))基準を\(countdown.remainingSeconds)秒後に取得します")
                    .font(.caption)
                    .foregroundStyle(.primary)
                Spacer()
                Button("中止") {
                    cancelReferenceCountdown()
                }
                .controlSize(.small)
            }
            ProgressView(
                value: Double(referenceCaptureDelaySec - countdown.remainingSeconds),
                total: Double(referenceCaptureDelaySec)
            )
            .progressViewStyle(.linear)
            .tint(.accentColor)
        }
        .padding(10)
        .frame(width: 420, alignment: .leading)
        .background(Color(nsColor: .separatorColor).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func referenceButtonTitle(scene: LightScene) -> String {
        guard let referenceCountdown else {
            return scene == .dark ? "消灯基準を保存" : "点灯基準を保存"
        }
        guard referenceCountdown.scene == scene else {
            return scene == .dark ? "消灯基準を保存" : "点灯基準を保存"
        }
        return "\(sceneName(scene))基準を準備中"
    }

    private func sceneName(_ scene: LightScene) -> String {
        switch scene {
        case .dark:
            return "消灯"
        case .bright:
            return "点灯"
        }
    }

    private func hintText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func numberField(
        _ title: String,
        text: Binding<String>,
        suffix: String,
        hint: String
    ) -> some View {
        settingRow(title) {
            HStack(alignment: .center, spacing: 16) {
                HStack(spacing: 6) {
                    TextField("", text: text)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 86)
                    if !suffix.isEmpty {
                        Text(suffix)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 150, alignment: .leading)

                hintText(hint)
                    .frame(width: 330, alignment: .leading)
            }
        }
    }

    private func applyPreset(id: String) {
        guard let preset = DetectionPreset.find(id: id) else {
            return
        }
        numberFields = preset.numberFields
        errorMessage = nil
    }

    private func startReferenceCountdown(scene: LightScene) {
        referenceCountdown = ReferenceCountdown(scene: scene, remainingSeconds: referenceCaptureDelaySec)
        referenceMessage = "カメラ前から離れてください。"
        errorMessage = nil
    }

    private func updateReferenceCountdown() {
        guard let countdown = referenceCountdown else {
            return
        }

        let remainingSeconds = countdown.remainingSeconds - 1
        guard remainingSeconds > 0 else {
            referenceCountdown = nil
            captureReferenceProfile(scene: countdown.scene)
            return
        }

        referenceCountdown = ReferenceCountdown(scene: countdown.scene, remainingSeconds: remainingSeconds)
    }

    private func cancelReferenceCountdown() {
        referenceCountdown = nil
        referenceMessage = "基準取得を中止しました。"
    }

    private func captureReferenceProfile(scene: LightScene) {
        do {
            let profile = try onReferenceCaptureRequested(scene)
            switch scene {
            case .dark:
                draft.darkReferenceProfile = profile
                referenceMessage = "消灯基準を取得しました。保存を押すと反映されます。"
            case .bright:
                draft.brightReferenceProfile = profile
                referenceMessage = "点灯基準を取得しました。保存を押すと反映されます。"
            }
            errorMessage = nil
        } catch {
            referenceMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        do {
            draft = try numberFields.applied(to: draft)
            try setLaunchAtLogin(draft.launchAtLogin)
            errorMessage = nil
            onSave(draft)
        } catch let error as SettingsValidationError {
            errorMessage = error.localizedDescription
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

private enum SettingsTab {
    case general
    case detection
}

private struct ReferenceCountdown: Equatable {
    let scene: LightScene
    let remainingSeconds: Int
}
