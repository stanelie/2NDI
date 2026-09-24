import Cocoa
import Metal

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSUserNotificationCenterDelegate {

    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var device: MTLDevice!
    private var pipeline: Pipeline!

    // Controls
    private let sourcePopup = NSPopUpButton()
    private let namePopupField = NSTextField()
    private let codecPopup = NSPopUpButton()
    private let resolutionPopup = NSPopUpButton()
    private let fpsCapPopup = NSPopUpButton()
    private let orientationPopup = NSPopUpButton()
    private let profilePopup = NSPopUpButton()
    private let encoderPopup = NSPopUpButton()
    private let bitrateField = NSTextField()
    private let alphaCheckbox = NSButton(checkboxWithTitle: "Ignore alpha (send BGRX)", target: nil, action: nil)
    private let autostartCheckbox = NSButton(checkboxWithTitle: "Start automatically on launch", target: nil, action: nil)
    private let startButton = NSButton(title: "Start", target: nil, action: nil)
    /// Which NDI library is loaded. Reported in About rather than occupying a line above
    /// the source picker, where it was the first thing read and the least often needed.
    private var backendDescription = ""
    private let statusLabel = NSTextField(labelWithString: "Idle")
    private let statsLabel = NSTextField(wrappingLabelWithString: "")
    private var previewView: PreviewView!

    private var sources: [InputSource] = []
    private var statsTimer: Timer?
    private var bannerView: NSView!
    private var bannerTitle: NSTextField!
    private var bannerDetail: NSTextField!
    private var trialExpiryReported = false
    /// Set at launch from the one-shot flag a library switch leaves behind. Held in
    /// memory rather than re-read, because the first source refresh happens before the
    /// Syphon directory has populated — clearing the flag there would lose the resume.
    /// Set from SYPHONNDI_SNAPSHOT: the next frame sent is written here, once.
    private var snapshotPath: URL?
    private var lastOrientationKey: String?
    private var pendingResume = false
    private var deliveryFailureReported = false
    private var deliveredPerSecond = 0
    private var bannerZeroHeight: NSLayoutConstraint!
    private var streamStarted: Date?
    private var lastSnapshot = StatsSnapshot()

    // The only way to set a rate. Includes the broadcast fractional rates, which used to
    // need a separate "declared frame rate" field — the declaration now follows this, or
    // the measured source rate when it is None.
    private let fpsCapChoices: [Double] = [0, 120, 60, 59.94, 50, 48, 30, 29.97, 25, 24, 23.976, 15]

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatal("No Metal device is available on this Mac.")
            return
        }
        self.device = device

        loadNDIBackend()

        guard let pipeline = Pipeline(device: device, config: loadConfig()) else {
            fatal("Could not create the capture pipeline.")
            return
        }
        self.pipeline = pipeline
        pipeline.onError = { [weak self] message in self?.presentError(message) }
        pipeline.onPreviewFrame = { [weak self] texture in self?.previewView.present(texture) }
        // No button: the snapshot exists for diagnosing what is actually on the wire,
        // which is a thing to reach for when something looks wrong, not a control.
        if let path = ProcessInfo.processInfo.environment["SYPHONNDI_SNAPSHOT"] {
            snapshotPath = URL(fileURLWithPath: path)
        }
        pipeline.onSnapshot = { [weak self] url in
            self?.statusLabel.stringValue = url.map { "Saved the sent frame to \($0.path)" }
                ?? "Could not write the snapshot."
        }

        pendingResume = UserDefaults.standard.bool(forKey: "resumeOnLaunch")
        if pendingResume { UserDefaults.standard.set(false, forKey: "resumeOnLaunch") }

        NSUserNotificationCenter.default.delegate = self

        buildMenu()
        buildWindow()
        buildStatusItem()
        applyConfigToControls(pipeline.config)
        refreshSources()

        // The directory is push-based; these fire whenever an app starts or stops publishing.
        for name in [NSNotification.Name.SyphonServerAnnounce,
                     NSNotification.Name.SyphonServerUpdate,
                     NSNotification.Name.SyphonServerRetire] {
            NotificationCenter.default.addObserver(self, selector: #selector(refreshSources),
                                                  name: name, object: nil)
        }

        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pipeline?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Without this macOS suppresses the banner whenever the app happens to be frontmost,
    // which is exactly when someone is testing it.
    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                shouldPresent notification: NSUserNotification) -> Bool { true }

    private func loadNDIBackend() {
        // Derived from the saved codec, not just the saved library preference. Otherwise a
        // session saved on HX but with the base library preferred would come back loading
        // base, and every compressed send would silently do nothing.
        let savedCodec = NDICodec(rawValue: UserDefaults.standard.integer(forKey: "codec")) ?? .speedHQ
        let preferred: NDIBackend = UserDefaults.standard.bool(forKey: "useBaseNDI") ? .base : .advanced
        let backend = requiredBackend(for: savedCodec) ?? preferred

        var error: NSString?
        if NDISender.load(backend, error: &error) {
            describeBackend(backend)
            return
        }

        // A missing Advanced library is recoverable: fall back to base and to SpeedHQ,
        // rather than refusing to start at all.
        if backend == .advanced {
            var fallbackError: NSString?
            if NDISender.load(.base, error: &fallbackError) {
                UserDefaults.standard.set(0, forKey: "codec")
                describeBackend(.base)
                statusLabel.stringValue = "The Advanced SDK could not be loaded; using the base SDK, SpeedHQ only."
                return
            }
        }
        fatal((error as String?) ?? "The NDI library could not be loaded.")
    }

    private func describeBackend(_ backend: NDIBackend) {
        let name = backend == .advanced ? "Advanced" : "Base"
        let hx = NDISender.supportsCompressedSend() ? "HX available" : "SpeedHQ only"
        backendDescription = "NDI \(NDISender.libraryVersion()) · \(name) SDK · \(hx)"
    }

    // MARK: - Window

    private func buildWindow() {
        previewView = PreviewView(device: device)
        previewView.translatesAutoresizingMaskIntoConstraints = false

        let controls = buildControls()
        controls.translatesAutoresizingMaskIntoConstraints = false

        statsLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statsLabel.translatesAutoresizingMaskIntoConstraints = false

        let banner = buildBanner()

        // Plain view with explicit constraints rather than a stack view: the banner has to
        // take zero height when hidden without disturbing anything below it, and a vertical
        // NSStackView sized the rest by its fitting height instead, which collapsed the
        // preview to nothing (MTKView then logs "nextDrawable returning nil" 30×/s).
        let content = NSView()
        content.addSubview(banner)
        content.addSubview(controls)
        content.addSubview(previewView)
        content.addSubview(statsLabel)

        bannerZeroHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        bannerZeroHeight.isActive = true

        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            banner.topAnchor.constraint(equalTo: content.topAnchor),

            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            controls.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 16),
            controls.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            controls.widthAnchor.constraint(equalToConstant: 300),

            previewView.leadingAnchor.constraint(equalTo: controls.trailingAnchor, constant: 16),
            previewView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            previewView.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 16),
            previewView.heightAnchor.constraint(equalTo: previewView.widthAnchor, multiplier: 9.0 / 16.0),

            statsLabel.leadingAnchor.constraint(equalTo: previewView.leadingAnchor),
            statsLabel.trailingAnchor.constraint(equalTo: previewView.trailingAnchor),
            statsLabel.topAnchor.constraint(equalTo: previewView.bottomAnchor, constant: 12),
            statsLabel.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
        ])

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "2NDI"
        window.contentView = content
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A wide, unmissable strip across the top of the window. The failure it reports is
    /// silent — the stream simply stops reaching receivers — so a line in the status label
    /// would not be enough.
    private func buildBanner() -> NSView {
        let banner = NSView()
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.90).cgColor
        banner.isHidden = true
        bannerView = banner

        bannerTitle = NSTextField(labelWithString: "")
        bannerTitle.font = NSFont.boldSystemFont(ofSize: 14)
        bannerTitle.textColor = .white

        bannerDetail = NSTextField(wrappingLabelWithString: "")
        bannerDetail.font = NSFont.systemFont(ofSize: 12)
        bannerDetail.textColor = .white
        bannerDetail.preferredMaxLayoutWidth = 900

        let useBase = NSButton(title: "Switch to the base SDK…", target: self,
                               action: #selector(chooseBaseBackend))
        let dismiss = NSButton(title: "Dismiss", target: self, action: #selector(dismissBanner))
        let buttons = NSStackView(views: [useBase, dismiss])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [bannerTitle, bannerDetail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: banner.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: banner.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -12),
        ])
        return banner
    }

    /// Consecutive seconds during which we were sending and the local receiver got nothing.
    private var deliveryDeadSeconds = 0
    /// How long delivery must be dead before the banner. A couple of seconds of nothing is
    /// normal at startup or across a codec change; five is well past any of that and still
    /// fast enough to catch it live.
    private static let deliveryDeadThreshold = 5

    /// The certain check. Not "how long has this been running" but "is anything actually
    /// arriving": we are sending, a receiver of our own is attached, and it is being given
    /// no frames at all. Nothing on the sender side reports this — `no_connections` still
    /// said 1 receiver for minutes after delivery stopped dead, and every send call kept
    /// returning normally.
    private func checkDelivery(sentFPS: Double) {
        let delivered = pipeline.takeDeliveredFrameCount()
        deliveredPerSecond = delivered

        guard pipeline.isDeliveryMonitored else {
            deliveryDeadSeconds = 0
            return
        }

        if sentFPS >= 1, delivered == 0 {
            deliveryDeadSeconds += 1
            if deliveryDeadSeconds >= Self.deliveryDeadThreshold { showDeliveryFailureBanner() }
        } else {
            deliveryDeadSeconds = 0
        }
    }

    private func showDeliveryFailureBanner() {
        guard !deliveryFailureReported else { return }
        deliveryFailureReported = true

        let ran = streamStarted.map { " after \(Int(Date().timeIntervalSince($0) / 60)) min" } ?? ""
        let title = "Nothing is being delivered\(ran) — receivers are getting no video"
        var detail = "This app is still sending and NDI still reports its receivers connected, "
            + "but a receiver attached to this very stream has been given no frames for "
            + "\(Self.deliveryDeadThreshold) seconds. The picture downstream is frozen or black."
        if NDISender.loadedBackend() == .advanced {
            detail += " The usual cause is the Advanced SDK's development licence, which stops "
                + "delivering after 30 minutes without announcing it. Stop and start the stream "
                + "to reset that, or switch to the base SDK for SpeedHQ with no time limit."
        }

        showBanner(colour: NSColor.systemRed.withAlphaComponent(0.92), title: title, detail: detail)
        FileHandle.standardError.write(Data("2NDI: \(title)\n".utf8))
        postAlertNotification(title: title,
                               body: "Stop and start the stream to recover, or switch to the base SDK for SpeedHQ with no time limit.")
        statusItem.button?.title = "2NDI ⚠"
        statusLabel.stringValue = "Nothing is reaching receivers."
    }

    private func showBanner(colour: NSColor, title: String, detail: String) {
        bannerView.layer?.backgroundColor = colour.cgColor
        bannerTitle.stringValue = title
        bannerDetail.stringValue = detail
        bannerZeroHeight.isActive = false
        bannerView.isHidden = false
    }

    /// Posts a system notification so a failure is visible when the window is closed to the
    /// menu bar, which is how this app is meant to be left running.
    ///
    /// NSUserNotification rather than UNUserNotificationCenter: the modern API needs an
    /// authorisation round-trip and a properly signed, Launch-Services-registered bundle,
    /// neither of which an ad-hoc build run out of .build reliably has. This one is
    /// deprecated but delivers. Marking the wrapper deprecated too silences the warning
    /// without hiding it project-wide.
    @available(macOS, deprecated: 11.0)
    private func postAlertNotification(title: String, body: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    @objc private func dismissBanner() {
        bannerView.isHidden = true
        bannerZeroHeight.isActive = true
    }

    private func buildControls() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        func heading(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }

        func row(_ title: String, _ control: NSView) -> NSView {
            let container = NSStackView(views: [heading(title), control])
            container.orientation = .vertical
            container.alignment = .leading
            container.spacing = 2
            control.widthAnchor.constraint(equalToConstant: 300).isActive = true
            return container
        }

        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        stack.addArrangedSubview(row("Input source", sourcePopup))

        namePopupField.placeholderString = "NDI source name"
        namePopupField.target = self
        namePopupField.action = #selector(controlChanged)
        stack.addArrangedSubview(row("NDI name", namePopupField))

        codecPopup.addItems(withTitles: ["SpeedHQ (full bandwidth)", "H.264 (NDI HX)", "HEVC (NDI HX)"])
        codecPopup.target = self
        codecPopup.action = #selector(controlChanged)
        stack.addArrangedSubview(row("Codec", codecPopup))

        resolutionPopup.addItem(withTitle: "Match source")
        resolutionPopup.target = self
        resolutionPopup.action = #selector(controlChanged)
        resolutionPopup.toolTip = "The top entry is the source's own resolution; everything below it "
            + "reduces, keeping the aspect ratio. A smaller setting costs less GPU and less bandwidth."
        stack.addArrangedSubview(row("Output resolution", resolutionPopup))

        orientationPopup.addItems(withTitles: FrameOrientation.allCases.map(\.label))
        orientationPopup.target = self
        orientationPopup.action = #selector(controlChanged)
        orientationPopup.toolTip = "Syphon does not say which way up a source is. OpenGL servers such as Millumin 2 publish upside down."
        stack.addArrangedSubview(row("Image orientation", orientationPopup))

        profilePopup.addItems(withTitles: Encoder.Profile.allCases.map(\.label))
        profilePopup.target = self
        profilePopup.action = #selector(controlChanged)
        profilePopup.toolTip = "H.264 only. Baseline has no CABAC and no B-frames, so it is the cheapest for a receiver to decode."
        stack.addArrangedSubview(row("H.264 profile", profilePopup))

        encoderPopup.addItems(withTitles: ["Hardware (preferred)", "Software (force)"])
        encoderPopup.target = self
        encoderPopup.action = #selector(controlChanged)
        encoderPopup.toolTip = "VideoToolbox picks hardware when it can. Forcing software is for diagnosis — measured at 4K it managed 3.9 fps against hardware's 26.6."
        stack.addArrangedSubview(row("Encoder", encoderPopup))

        fpsCapPopup.addItems(withTitles: fpsCapChoices.map { $0 == 0 ? "None (follow the source)" : formatted($0) })
        fpsCapPopup.toolTip = "Caps the send rate, and is what receivers are told the stream runs at. "
            + "With None, the declared rate is measured from the source instead, so it always "
            + "matches what is really being sent."
        fpsCapPopup.target = self
        fpsCapPopup.action = #selector(controlChanged)
        stack.addArrangedSubview(row("Frame rate", fpsCapPopup))

        bitrateField.placeholderString = "0 = SDK target"
        bitrateField.target = self
        bitrateField.action = #selector(controlChanged)
        stack.addArrangedSubview(row("Bit rate (Mbps, HX only)", bitrateField))

        alphaCheckbox.target = self
        alphaCheckbox.action = #selector(controlChanged)
        stack.addArrangedSubview(alphaCheckbox)


        autostartCheckbox.target = self
        autostartCheckbox.action = #selector(autostartToggled)
        autostartCheckbox.state = UserDefaults.standard.bool(forKey: "autostart") ? .on : .off
        autostartCheckbox.toolTip = "Reconnects to the saved input as soon as it appears, so the app can be left in Login Items."
        stack.addArrangedSubview(autostartCheckbox)

        startButton.target = self
        startButton.action = #selector(toggleStreaming)
        startButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [startButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.preferredMaxLayoutWidth = 300
        stack.addArrangedSubview(statusLabel)

        return stack
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About 2NDI", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())

        let libraryItem = NSMenuItem(title: "NDI Library", action: nil, keyEquivalent: "")
        let libraryMenu = NSMenu()
        let usingBase = UserDefaults.standard.bool(forKey: "useBaseNDI")
        let advanced = NSMenuItem(title: "Advanced SDK — HX, 30-minute trial limit",
                                  action: #selector(chooseAdvancedBackend), keyEquivalent: "")
        advanced.state = usingBase ? .off : .on
        let base = NSMenuItem(title: "Base SDK — SpeedHQ only, no time limit",
                              action: #selector(chooseBaseBackend), keyEquivalent: "")
        base.state = usingBase ? .on : .off
        libraryMenu.addItem(advanced)
        libraryMenu.addItem(base)
        libraryItem.submenu = libraryMenu
        appMenu.addItem(libraryItem)

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "2NDI"
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Window", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Start / Stop", action: #selector(toggleStreaming), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
    }

    // Closing the window leaves the app running as a menu-bar item, which is how it is
    // meant to sit on a show machine once it is configured.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    @objc private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Sources

    @objc private func refreshSources() {
        let selectedID = currentSource()?.id
        sources = InputSource.available()

        sourcePopup.removeAllItems()
        if sources.isEmpty {
            sourcePopup.addItem(withTitle: "No input sources found")
            sourcePopup.isEnabled = false
        } else {
            sourcePopup.isEnabled = true
            sourcePopup.addItems(withTitles: sources.map(\.displayName))
            if let selectedID, let index = sources.firstIndex(where: { $0.id == selectedID }) {
                sourcePopup.selectItem(at: index)
            } else if let saved = UserDefaults.standard.string(forKey: "sourceUUID"),
                      let index = sources.firstIndex(where: { $0.id == saved }) {
                sourcePopup.selectItem(at: index)
            }
        }
        applyRememberedOrientation()
        startButton.isEnabled = !sources.isEmpty || pipeline.isRunning

        // With autostart on, the app waits for its saved source rather than requiring a
        // click — the host app is often launched after this one.
        if !pipeline.isRunning, pendingResume || UserDefaults.standard.bool(forKey: "autostart") {
            // SYPHONNDI_SOURCE picks the source by name for a scripted or login-item
            // launch, where the saved UUID from a previous session may no longer exist
            // (Syphon UUIDs are per-run, not per-output).
            if let wanted = ProcessInfo.processInfo.environment["SYPHONNDI_SOURCE"],
               let index = sources.firstIndex(where: { $0.displayName.localizedCaseInsensitiveContains(wanted) }) {
                sourcePopup.selectItem(at: index)
                startStreaming()
            } else if let saved = UserDefaults.standard.string(forKey: "sourceUUID"),
                      let index = sources.firstIndex(where: { $0.id == saved }) {
                sourcePopup.selectItem(at: index)
                startStreaming()
            }
            // Only spend the resume once it has actually found its source.
            if pipeline.isRunning { pendingResume = false }
        }

        // A source that disappears mid-stream (the host app quit) leaves a dead sender.
        if pipeline.isRunning, let uuid = UserDefaults.standard.string(forKey: "sourceUUID"),
           !sources.contains(where: { $0.id == uuid }) {
            stopStreaming()
            statusLabel.stringValue = "Stopped — the input went away."
        }
    }

    private func currentSource() -> InputSource? {
        guard !sources.isEmpty, sourcePopup.indexOfSelectedItem >= 0,
              sourcePopup.indexOfSelectedItem < sources.count else { return nil }
        return sources[sourcePopup.indexOfSelectedItem]
    }

    // MARK: - Configuration

    private func loadConfig() -> PipelineConfig {
        let defaults = UserDefaults.standard
        var config = PipelineConfig()
        if let name = defaults.string(forKey: "ndiName"), !name.isEmpty { config.ndiName = name }
        config.codec = NDICodec(rawValue: defaults.integer(forKey: "codec")) ?? .speedHQ
        selectedMaxHeight = defaults.integer(forKey: "resolutionMaxHeight")
        config.resolution = selectedMaxHeight > 0 ? .maxHeight(selectedMaxHeight) : .native
        config.fpsCap = defaults.double(forKey: "fpsCap")
        config.bitrateMbps = defaults.double(forKey: "bitrateMbps")
        config.ignoreAlpha = defaults.object(forKey: "ignoreAlpha") != nil
            ? defaults.bool(forKey: "ignoreAlpha") : true
        config.orientation = FrameOrientation(rawValue: defaults.integer(forKey: "orientation")) ?? .none
        config.allowHardwareEncoder = defaults.object(forKey: "allowHardwareEncoder") != nil
            ? defaults.bool(forKey: "allowHardwareEncoder") : true
        config.h264Profile = Encoder.Profile(rawValue: defaults.integer(forKey: "h264Profile")) ?? .high
        return config
    }

    private func applyConfigToControls(_ config: PipelineConfig) {
        namePopupField.stringValue = config.ndiName
        codecPopup.selectItem(at: config.codec.rawValue)
        if case .maxHeight(let height) = config.resolution { selectedMaxHeight = height } else { selectedMaxHeight = 0 }
        updateResolutionChoices()
        // Nearest, not exact: a rate that has been through a 32-bit float comes back as
        // 29.969999…, and an exact match then silently falls through to "None", which
        // quietly changes both the send rate and what receivers are told.
        if let index = fpsCapChoices.enumerated().min(by: {
            abs($0.element - config.fpsCap) < abs($1.element - config.fpsCap)
        })?.offset {
            fpsCapPopup.selectItem(at: index)
        }
        bitrateField.stringValue = config.bitrateMbps > 0 ? formatted(config.bitrateMbps) : ""
        alphaCheckbox.state = config.ignoreAlpha ? .on : .off
        orientationPopup.selectItem(at: config.orientation.rawValue)
        profilePopup.selectItem(at: config.h264Profile.rawValue)
        encoderPopup.selectItem(at: config.allowHardwareEncoder ? 0 : 1)
    }

    private func configFromControls() -> PipelineConfig {
        var config = PipelineConfig()
        let name = namePopupField.stringValue.trimmingCharacters(in: .whitespaces)
        config.ndiName = name.isEmpty ? "Syphon" : name
        config.codec = NDICodec(rawValue: codecPopup.indexOfSelectedItem) ?? .speedHQ
        let index = max(resolutionPopup.indexOfSelectedItem, 0)
        selectedMaxHeight = index < resolutionHeights.count ? resolutionHeights[index] : 0
        config.resolution = selectedMaxHeight > 0 ? .maxHeight(selectedMaxHeight) : .native
        config.fpsCap = fpsCapChoices[max(fpsCapPopup.indexOfSelectedItem, 0)]
        config.bitrateMbps = max(0, Double(bitrateField.stringValue) ?? 0)
        config.ignoreAlpha = alphaCheckbox.state == .on
        config.orientation = FrameOrientation(rawValue: max(orientationPopup.indexOfSelectedItem, 0)) ?? .none
        config.allowHardwareEncoder = encoderPopup.indexOfSelectedItem == 0
        config.h264Profile = Encoder.Profile(rawValue: max(profilePopup.indexOfSelectedItem, 0)) ?? .high
        return config
    }

    private func saveConfig(_ config: PipelineConfig) {
        let defaults = UserDefaults.standard
        defaults.set(config.ndiName, forKey: "ndiName")
        defaults.set(config.codec.rawValue, forKey: "codec")
        defaults.set(selectedMaxHeight, forKey: "resolutionMaxHeight")
        defaults.set(config.fpsCap, forKey: "fpsCap")
        defaults.set(config.bitrateMbps, forKey: "bitrateMbps")
        defaults.set(config.ignoreAlpha, forKey: "ignoreAlpha")
        defaults.set(config.orientation.rawValue, forKey: "orientation")
        defaults.set(config.allowHardwareEncoder, forKey: "allowHardwareEncoder")
        defaults.set(config.h264Profile.rawValue, forKey: "h264Profile")
        defaults.set(currentSource()?.id, forKey: "sourceUUID")
    }

    /// The library a codec needs, or nil when either will do.
    ///
    /// Only HX constrains the choice: it exists solely in the Advanced SDK. The Advanced
    /// library also sends SpeedHQ perfectly well, so selecting SpeedHQ deliberately does
    /// *not* force a switch back to base — that would mean a relaunch on every step of an
    /// A/B comparison, which is the main thing this app is for. Base stays a explicit
    /// choice in the menu, for long SpeedHQ runs that must outlast the 30-minute trial.
    private func requiredBackend(for codec: NDICodec) -> NDIBackend? {
        codec == .speedHQ ? nil : .advanced
    }

    /// Restarts into the other NDI library, carrying the settings and the running stream
    /// across. Both dylibs export the same C symbols, so only one can be loaded per
    /// process and switching means a new process.
    private func relaunch(into backend: NDIBackend, reason: String) {
        UserDefaults.standard.set(backend == .base, forKey: "useBaseNDI")
        // Consumed once on the next launch, so a relaunch resumes what was interrupted
        // without turning on the persistent autostart setting.
        UserDefaults.standard.set(pipeline.isRunning, forKey: "resumeOnLaunch")
        UserDefaults.standard.synchronize()

        statusLabel.stringValue = reason
        pipeline.stop()

        // Launch after this process has gone, so the new instance does not briefly race
        // the old one for the same NDI source name.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open -n '\(Bundle.main.bundlePath)'"]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Orientation is remembered per source: an OpenGL Syphon publisher needs a flip and a
    /// camera does not, and nothing in the Syphon protocol says which is which. Setting it
    /// once per source is the most that can honestly be automated.
    private func rememberedOrientation(for source: InputSource) -> FrameOrientation? {
        let stored = UserDefaults.standard.dictionary(forKey: "orientationBySource") as? [String: Int]
        return stored?[source.orientationKey].flatMap(FrameOrientation.init(rawValue:))
    }

    private func rememberOrientation(_ orientation: FrameOrientation, for source: InputSource) {
        var stored = UserDefaults.standard.dictionary(forKey: "orientationBySource") as? [String: Int] ?? [:]
        stored[source.orientationKey] = orientation.rawValue
        UserDefaults.standard.set(stored, forKey: "orientationBySource")
    }

    @objc private func sourceChanged() {
        applyRememberedOrientation()
        controlChanged()
    }

    /// Applies the orientation remembered for the currently selected source, once per
    /// change of source. It has to run before anything can start streaming, or autostart
    /// records the previous source's orientation against the new one.
    private func applyRememberedOrientation() {
        guard let source = currentSource(), source.orientationKey != lastOrientationKey else { return }
        lastOrientationKey = source.orientationKey
        guard let remembered = rememberedOrientation(for: source) else { return }
        orientationPopup.selectItem(at: remembered.rawValue)
        statusLabel.stringValue = "Using the orientation last set for \(source.displayName)."
        if pipeline.isRunning { pipeline.update(config: configFromControls()) }
    }

    @objc private func controlChanged() {
        let config = configFromControls()
        saveConfig(config)
        if let source = currentSource() { rememberOrientation(config.orientation, for: source) }

        // Selecting HX on the base library switches libraries by itself rather than
        // telling the user to go and do it.
        if let needed = requiredBackend(for: config.codec), needed != NDISender.loadedBackend() {
            let name = config.codec == .hevc ? "HEVC" : "H.264"
            relaunch(into: needed, reason: "Switching to the Advanced SDK for \(name) HX…")
            return
        }

        // Changing source is the one edit that has to restart the stream.
        if pipeline.isRunning, let source = currentSource(),
           source.id != UserDefaults.standard.string(forKey: "runningSourceUUID") {
            startStreaming()
            return
        }

        pipeline.update(config: config)
        if pipeline.isRunning { pipeline.stats.reset() }
    }

    @objc private func autostartToggled() {
        UserDefaults.standard.set(autostartCheckbox.state == .on, forKey: "autostart")
    }

    // MARK: - Streaming

    @objc private func toggleStreaming() {
        pipeline.isRunning ? stopStreaming() : startStreaming()
    }

    private func startStreaming() {
        guard let source = currentSource() else {
            presentError("No input is available. Start a Syphon output in Millumin or QLab, or connect a camera.")
            return
        }

        // A camera needs consent the first time. Ask, then come back through here.
        if source.kind == .camera {
            switch CameraInput.authorization {
            case .notDetermined:
                // Asking for camera access terminates the process when the *responsible*
                // process has no camera usage description. TCC enforces that with SIGABRT
                // from its own thread, so it cannot be caught; it has to be avoided.
                //
                // That happens whenever the binary is started from a terminal instead of
                // by LaunchServices: the process inherits the launching application's
                // `__CFBundleIdentifier`, which is the identity TCC then holds responsible,
                // and that application has no reason to declare a camera usage string.
                // Comparing it with our own is the reliable test — `getppid()` is not,
                // because a backgrounded process is reparented to launchd either way.
                guard ProcessInfo.processInfo.environment["__CFBundleIdentifier"] == Bundle.main.bundleIdentifier else {
                    let owner = ProcessInfo.processInfo.environment["__CFBundleIdentifier"] ?? "another process"
                    presentError("Camera access cannot be requested: macOS is attributing this app to “\(owner)”, which happens when it is started from a terminal, and it would terminate the app. Quit, open 2NDI normally, and select the camera again.")
                    return
                }
                // Logged because this blocks on a system dialog, which is invisible when
                // the app is running headless or as a menu-bar item.
                FileHandle.standardError.write(Data("2NDI: requesting camera access — a system dialog is waiting for an answer\n".utf8))
                statusLabel.stringValue = "Waiting for camera permission…"
                CameraInput.requestAccess { [weak self] granted in
                    FileHandle.standardError.write(Data("2NDI: camera access \(granted ? "granted" : "denied")\n".utf8))
                    if granted { self?.startStreaming() }
                    else { self?.presentError("Camera access was denied. Grant it in System Preferences ▸ Security & Privacy ▸ Camera.") }
                }
                return
            case .denied, .restricted:
                presentError("Camera access is turned off for this app. Enable it in System Preferences ▸ Security & Privacy ▸ Camera.")
                return
            default:
                break
            }
        }
        let config = configFromControls()
        saveConfig(config)
        // Capture the pairing even if the user never touched the orientation control, so
        // starting a source once is enough for it to be remembered.
        rememberOrientation(config.orientation, for: source)
        pipeline.update(config: config)

        do {
            try pipeline.start(source: source)
            UserDefaults.standard.set(source.id, forKey: "runningSourceUUID")
            if let snapshotPath {
                pipeline.requestSnapshot(to: snapshotPath)
                self.snapshotPath = nil
            }
            streamStarted = Date()
            trialExpiryReported = false
            deliveryFailureReported = false
            deliveryDeadSeconds = 0
            bannerView.isHidden = true
            bannerZeroHeight.isActive = true
            startButton.title = "Stop"
            statusItem.button?.title = "2NDI ●"
            statusLabel.stringValue = "Sending “\(config.ndiName)” from \(source.displayName)."
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func stopStreaming() {
        pipeline.stop()
        updateFrameRateChoices()
        previewView.clear()
        startButton.title = "Start"
        statusItem.button?.title = "2NDI"
        statusLabel.stringValue = "Idle"
        statsLabel.stringValue = ""
    }

    // MARK: - Stats

    /// Grey out rates the source cannot supply. Selecting one would be clamped anyway, so
    /// offering it only invites the question of why picking 60 yields 30.
    /// Heights offered below the source's own. Only those smaller than the source appear,
    /// so the list can never ask for more pixels than exist.
    /// 360p is the floor: at 16:9 that is 640 wide, exactly the minimum the hardware
    /// encoder accepts. Anything smaller gets scaled back up to 640 and the setting stops
    /// meaning what it says.
    private static let reducedHeights = [2160, 1440, 1080, 900, 720, 540, 480, 360]

    /// Currently offered heights, 0 meaning "match the source". Rebuilt as the source
    /// becomes known or changes.
    private var resolutionHeights: [Int] = [0]

    /// The height the user has chosen, 0 for native. Held separately from the popup so a
    /// rebuild of the list cannot silently change the setting.
    private var selectedMaxHeight = 0

    private func updateResolutionChoices() {
        let size = pipeline.sourceSize
        var heights = [0]
        heights += Self.reducedHeights.filter { size == nil || $0 < size!.height }
        guard heights != resolutionHeights || resolutionPopup.numberOfItems != heights.count else { return }
        resolutionHeights = heights

        resolutionPopup.removeAllItems()
        for height in heights {
            resolutionPopup.addItem(withTitle: resolutionLabel(height, sourceSize: size))
        }
        // Keep the user's choice across a rebuild; fall back to the nearest still offered.
        if let exact = heights.firstIndex(of: selectedMaxHeight) {
            resolutionPopup.selectItem(at: exact)
        } else if let nearest = heights.enumerated().dropFirst().min(by: {
            abs($0.element - selectedMaxHeight) < abs($1.element - selectedMaxHeight)
        })?.offset {
            resolutionPopup.selectItem(at: nearest)
            selectedMaxHeight = heights[nearest]
        }
    }

    private func resolutionLabel(_ height: Int, sourceSize: (width: Int, height: Int)?) -> String {
        guard let sourceSize, sourceSize.height > 0 else {
            return height == 0 ? "Match source" : "\(height)p"
        }
        if height == 0 {
            return "Match source — \(sourceSize.width) × \(sourceSize.height)"
        }
        // Aspect is preserved, so show what the output will actually be.
        let width = Int((Double(sourceSize.width) * Double(height) / Double(sourceSize.height)).rounded()) & ~1
        return "\(height)p — \(width) × \(height)"
    }

    private func updateFrameRateChoices() {
        let source = pipeline.isRunning ? pipeline.measuredSourceFPS : nil
        for (index, choice) in fpsCapChoices.enumerated() {
            guard let item = fpsCapPopup.item(at: index) else { continue }
            // "None" always stays available; it means "follow the source" whatever that is.
            item.isEnabled = choice == 0 || source == nil || choice <= source! + 0.01
        }
    }

    private func updateStats() {
        updateFrameRateChoices()
        updateResolutionChoices()
        guard pipeline.isRunning else { return }
        pipeline.pollConnections()
        let snapshot = pipeline.stats.sample()
        checkDelivery(sentFPS: snapshot.sentFPS)
        lastSnapshot = snapshot
        statsLabel.stringValue = report(snapshot)
    }

    private func report(_ s: StatsSnapshot) -> String {
        let config = pipeline.config
        let codecName: String
        switch config.codec {
        case .h264: codecName = "H.264 (HX)"
        case .hevc: codecName = "HEVC (HX)"
        default:    codecName = "SpeedHQ"
        }

        var lines: [String] = []
        lines.append("codec            \(codecName)\(config.codec != .speedHQ ? (pipeline.isHardwareEncoding ? "  hardware" : "  SOFTWARE") : "")")
        lines.append("source           \(s.sourceWidth) × \(s.sourceHeight) @ \(String(format: "%.1f", s.sourceFPS)) fps")
        lines.append("output           \(s.outputWidth) × \(s.outputHeight) @ \(String(format: "%.1f", s.sentFPS)) fps")
        let declared = pipeline.nominalFPS
        let origin: String
        if pipeline.frameRateLimitedBySource {
            origin = "(setting asks \(formatted(pipeline.config.fpsCap)); the source only gives \(formatted(declared)))"
        } else if pipeline.config.fpsCap > 0 {
            origin = "(from the frame rate setting)"
        } else {
            origin = "(measured from the source)"
        }
        lines.append("declared         \(formatted(declared)) fps \(origin)")
        if s.sentFPS > 1, s.sentFPS < declared * 0.9 {
            lines.append("                 receivers are told \(formatted(declared)) and are getting \(String(format: "%.1f", s.sentFPS));")
            lines.append("                 lower Frame rate to something this machine can hold")
        }
        if pipeline.didRaiseResolutionForEncoder {
            lines.append("                 (scaled up to 640 wide — below that VideoToolbox")
            lines.append("                  drops to a software encoder on this Mac)")
        }
        // The delivery monitor is itself a receiver on this stream, so it shows up in the
        // SDK's count. Reporting that raw made one attached Millumin read as two.
        let ourOwn = pipeline.isDeliveryMonitored ? 1 : 0
        lines.append("receivers        \(max(0, s.connections - ourOwn))\(ourOwn > 0 ? "   (plus this app's own delivery check)" : "")")
        if pipeline.isDeliveryMonitored {
            lines.append("delivered        \(deliveredPerSecond) fps  (verified at a local receiver)")
        } else {
            lines.append("delivered        attaching a local receiver…")
        }
        lines.append("")
        lines.append("dropped          \(String(format: "%.1f", s.droppedPerSecond))/s   (\(s.droppedTotal) total, could not keep up)")
        if s.rateLimitedPerSecond > 0.05 {
            lines.append("rate limited     \(String(format: "%.1f", s.rateLimitedPerSecond))/s   (skipped on purpose by the frame rate setting)")
        }
        if s.measuredMbps > 0 {
            lines.append("wire bit rate    \(String(format: "%.1f", s.measuredMbps)) Mbps measured")
        } else {
            lines.append("wire bit rate    not observable for SpeedHQ (NDI encodes internally)")
        }
        if s.targetMbps > 0 {
            lines.append("SDK target       \(String(format: "%.1f", s.targetMbps)) Mbps")
        }
        if config.codec != .speedHQ {
            lines.append("keyframes        \(String(format: "%.2f", s.keyframesPerSecond))/s")
        }
        lines.append("")
        lines.append("gpu copy/scale   \(String(format: "%6.2f", s.gpuMillisecondsAvg)) ms")
        if s.encodeMillisecondsAvg > 0 {
            lines.append("encode           \(String(format: "%6.2f", s.encodeMillisecondsAvg)) ms")
        }
        lines.append("ndi send         \(String(format: "%6.2f", s.sendMillisecondsAvg)) ms")
        lines.append("total in-app     \(String(format: "%6.2f", s.totalMillisecondsAvg)) ms avg, \(String(format: "%.2f", s.totalMillisecondsPeak)) ms peak")
        lines.append("")
        lines.append("This measures Syphon callback to NDI send returning. Glass-to-glass")
        lines.append("latency also includes the network and the receiver's own decode.")
        return lines.joined(separator: "\n")
    }



    // MARK: - Backend switching

    @objc private func chooseAdvancedBackend() { switchBackend(toBase: false) }
    @objc private func chooseBaseBackend() { switchBackend(toBase: true) }

    private func switchBackend(toBase: Bool) {
        let backend: NDIBackend = toBase ? .base : .advanced
        guard backend != NDISender.loadedBackend() else { return }

        if toBase, let codec = NDICodec(rawValue: codecPopup.indexOfSelectedItem), codec != .speedHQ {
            presentError("The base SDK cannot send HX. Choose SpeedHQ first.")
            return
        }
        relaunch(into: backend,
                 reason: toBase ? "Switching to the base SDK (SpeedHQ, no time limit)…"
                                : "Switching to the Advanced SDK…")
    }

    // MARK: - Misc

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "2NDI"
        alert.informativeText = """
        Publishes a Syphon output, a camera or a test pattern to the network as NDI, in \
        SpeedHQ or HX, with per-frame \
        timings for comparing the two.

        \(backendDescription)
        """
        alert.runModal()
    }

    private func presentError(_ message: String) {
        statusLabel.stringValue = message
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "2NDI"
        alert.informativeText = message
        alert.runModal()
    }

    private func fatal(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "2NDI cannot start"
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}
