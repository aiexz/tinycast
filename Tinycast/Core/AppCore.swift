import AppKit
import SwiftUI

enum PaletteMode: String, CaseIterable, Identifiable {
    case launcher
    case clipboard
    case calculatorHistory
    case emoji
    // System command modes that render inside the palette (Tinycast/Features/System/SystemCommandViews),
    // matching the Raycast Microphone + Coffee command surface. The no-view immediate actions
    // (Caffeinate/Decaffeinate/Toggle Microphone/Toggle Caffeination) stay plain commands; the five
    // bellow take an arg the launcher can't carry, so they switch the palette into these modes.
    case setMicrophoneLevel
    case caffeinateFor
    case caffeinateUntil
    case caffeinateWhile
    var id: String { rawValue }
    var title: String {
        switch self {
        case .launcher: return "Apps"
        case .clipboard: return "Clipboard"
        case .calculatorHistory: return "Calculator History"
        case .emoji: return "Emoji & Symbols"
        case .setMicrophoneLevel: return "Microphone"
        case .caffeinateFor: return "Caffeinate for"
        case .caffeinateUntil: return "Caffeinate Until"
        case .caffeinateWhile: return "Caffeinate While"
        }
    }
    var systemImage: String {
        switch self {
        case .launcher: return "magnifyingglass"
        case .clipboard: return "doc.on.doc"
        case .calculatorHistory: return "plus.forwardslash.minus"
        case .emoji: return "face.smiling"
        case .setMicrophoneLevel: return "microphone"
        case .caffeinateFor: return "timer"
        case .caffeinateUntil: return "clock.badge.checkmark"
        case .caffeinateWhile: return "macwindow"
        }
    }
    var placeholder: String {
        switch self {
        case .launcher: return "Search for apps and commands…"
        case .clipboard: return "Type to filter entries…"
        case .calculatorHistory: return "Do math, convert units, or search your past calculations…"
        case .emoji: return "Search emoji and symbols…"
        case .setMicrophoneLevel: return "Set the microphone input level…"
        case .caffeinateFor: return "Keep awake for a duration, e.g. 5m, 2h…"
        case .caffeinateUntil: return "Keep awake until a time or date, e.g. 9am, 5pm, april 9…"
        case .caffeinateWhile: return "Pick an app to keep the Mac awake while it's running…"
        }
    }
}

/// The app a paste will land in, resolved once per palette show so the footer pill and menu rows can name it without re-reading `NSWorkspace` on every render.
struct PasteTarget: Equatable {
    let name: String
    /// Bundle path for `IconCache` — nil for a target with no on-disk bundle.
    let iconPath: String?

    init?(app: NSRunningApplication?) {
        guard let app, let name = app.localizedName else { return nil }
        self.name = name
        iconPath = app.bundleURL?.path
    }

    var pasteTitle: String { "Paste to \(name)" }
}

/// View-model shared between the panel's SwiftUI tree and the coordinator.
@MainActor
final class PaletteViewModel: ObservableObject {
    @Published var mode: PaletteMode = .launcher
    @Published var query: String = ""
    @Published var selection: Int = 0
    /// Changes every time the palette is shown so the search field can re-focus.
    @Published var focusToken = UUID()
    /// Changes only when `prepare` resets the palette, so the lists snap their scroll to the top even when query/mode were already at their defaults (`focusToken` can't serve: it bumps on every reopen, which must preserve a within-timeout scroll).
    @Published var resetToken = UUID()
    /// Set by the compact bar's "…" overflow to expand into the full launcher without a query; cleared on every `prepare`.
    @Published var forceExpanded = false
    /// The app a paste would land in, mirrored from `PaletteWindowController.previousApp` on every show. Deliberately *not* cleared by `prepare` — pop-to-root resets the screen, not the paste target.
    @Published var pasteTarget: PasteTarget?
    /// Gates the mouse-hover highlight: true only while the pointer is physically moving (armed on `.mouseMoved`, disarmed on any `.keyDown` in `PalettePanel.sendEvent`). Plain, not `@Published` — read at hover time, never drives a re-render.
    var hoverHighlightArmed = false
    /// True while a footer popover menu (⌘K Actions or the app menu) is open, so `PalettePanel.sendEvent` swallows text-editing keystrokes the field editor would otherwise consume — the query must stay frozen while a menu owns the keyboard (matches Raycast). Plain, not `@Published` — read at event time, mirrored from the view's menu state.
    var menuOpen = false { didSet { onMenuOpenChanged?(menuOpen) } }
    /// Fired when `menuOpen` flips so `PalettePanel` can hide/show the search field's caret while it keeps first-responder status (no focus swap, so the placeholder never reflows).
    var onMenuOpenChanged: ((Bool) -> Void)?

    func prepare(mode: PaletteMode) {
        self.mode = mode
        query = ""
        selection = 0
        forceExpanded = false
        hoverHighlightArmed = false
        menuOpen = false
        focusToken = UUID()
        resetToken = UUID()
    }
}

/// Single owner of every long-lived manager. Wired up once from the app delegate.
@MainActor
final class AppCore: ObservableObject {
    static let shared = AppCore()

    let appIndex = AppIndex()
    let clipboardStore = ClipboardStore()
    let clipboardManager: ClipboardManager
    let hotKeys = HotKeyManager()
    let hyperKeyTap = HyperKeyTap()
    let settings = AppSettings()
    let favorites = FavoritesStore()
    let visibility = VisibilityStore()
    let calcHistory = CalculatorHistoryStore()
    let currencyRates = CurrencyRateStore()
    let emojiIndex = EmojiIndex()
    let frequentEmoji = FrequentEmojiStore()
    let runningApps = RunningAppsMonitor()
    let appUsage = AppUsageStore()
    let palette = PaletteViewModel()

    // System integration: microphone mute/level + caffeination assertions + the two persistent
    // menu-bar status items reflecting their state. AppCore owns the controllers; `SystemStatusItems`
    // observes them via Combine (never owns them) so a single source of truth drives both the icons
    // and Swift state. Feature behavior and palette views live together in Features/System;
    // AppCore remains their single lifecycle owner.
    let microphoneController = MicrophoneController()
    let caffeinationController = CaffeinationController()
    let systemStatusItems: SystemStatusItems

    private lazy var windowController = PaletteWindowController(core: self)
    private let auxWindows = AuxWindowController()

    private init() {
        clipboardManager = ClipboardManager(store: clipboardStore, settings: settings)
        // Status items observe the controllers, so they're constructed last; no I/O happens until `start()`.
        systemStatusItems = SystemStatusItems(microphone: microphoneController, caffeination: caffeinationController)
    }

    func start() {
        // AppKit's default tooltip delay is ~2–3s; shorten it (in ms) so the compact-bar favorite tooltips appear promptly. Registration domain — never overrides a user default.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 250])
        NSApp.setActivationPolicy(.accessory)
        // Force dark: the Liquid Glass material is tuned for a deep dark surface and renders washed-out in Light mode.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        clipboardStore.maxAge = settings.clipboardRetention.maxAge
        // Defer the initial SQLite read + stale-image prune off the synchronous launch path so the menu bar is interactive immediately; `items` is @Published, so the palette fills in when it lands.
        Task { clipboardStore.load() }
        clipboardManager.start()

        Task { await appIndex.refresh() }
        Task { await emojiIndex.load() }
        currencyRates.start()

        hotKeys.onTogglePalette = { [weak self] in self?.togglePalette() }
        hotKeys.onToggleClipboard = { [weak self] in self?.toggleClipboard() }
        hotKeys.onToggleEmoji = { [weak self] in self?.toggleEmoji() }
        hotKeys.onToggleApp = { [weak self] in self?.toggleApp(bundleID: $0) }
        hotKeys.start()
        // Deliberately keeps running while `hotKeys.recordingAction` pauses Carbon: the recorder relies on the tap's rewritten flags to capture Hyper shortcuts.
        hyperKeyTap.start(settings: settings)
        // System integration: start the caffeination tick, hydrate mic level off-main (short-lived
        // osascript reads), and build the menu-bar status items last so their Combine subscriptions
        // see settled controllers. No blocking process work here — all I/O is detached.
        caffeinationController.start()
        Task { await microphoneController.refresh() }
        systemStatusItems.start()

        // First launch has no palette hotkey bound and shows nothing but the menu-bar icon; guide the user once. Marker is written at show-time so it stays one-time even if they Cmd-Q mid-flow.
        if !OnboardingState.hasOnboarded {
            OnboardingState.markShown()
            showOnboarding()
        }
    }
    /// Tear down child processes and menu-bar artifacts before the app exits; called from `AppDelegate.applicationWillTerminate` alongside the existing `hyperKeyTap` cleanup. Order matters: terminate the caffeinate child *before* removing the status items so the menu-bar indicator never flashes a stale asserting state, and never `killall caffeinate` — only the process this app owns is touched.
    func prepareForTermination() {
        caffeinationController.prepareForTermination()
        systemStatusItems.stop()
    }


    // MARK: - Palette control

    func togglePalette() {
        if windowController.isVisible, palette.mode == .launcher {
            hidePalette()
        } else {
            showPalette(mode: .launcher, restoreAnyMode: true)
        }
    }

    func toggleApp(bundleID: String) {
        if let app = appIndex.apps.first(where: {
            $0.kind == .application && $0.bundleID == bundleID
        }) {
            appUsage.record(app)
        }
        AppLauncher.toggle(bundleID: bundleID)
    }

    func toggleClipboard() {
        recordCommand(.clipboardHistory)
        if windowController.isVisible, palette.mode == .clipboard {
            hidePalette()
        } else {
            showPalette(mode: .clipboard)
        }
    }

    func showClipboard() {
        recordCommand(.clipboardHistory)
        showPalette(mode: .clipboard)
    }
    func toggleEmoji() {
        recordCommand(.searchEmoji)
        if windowController.isVisible, palette.mode == .emoji {
            hidePalette()
        } else {
            showPalette(mode: .emoji)
        }
    }

    private func recordCommand(_ id: CommandID) {
        guard let entry = CommandRegistry.all.first(where: { $0.id == id.rawValue }) else { return }
        appUsage.record(entry)
    }
    /// Shows the palette, honoring Pop to Root Search: a reopen within the timeout restores the pre-close state — any mode for the generic summon (`restoreAnyMode`), else only when the preserved mode already matches the requested one.
    func showPalette(mode: PaletteMode, restoreAnyMode: Bool = false) {
        let preserved = windowController.consumePreservedState()
        if !(preserved && (restoreAnyMode || palette.mode == mode)) {
            palette.prepare(mode: mode)
        }
        windowController.show()
        // Re-scan on open so an app uninstalled since the last scan drops out of the launcher.
        if palette.mode == .launcher { Task { await appIndex.refresh() } }
    }

    func hidePalette(restoreFocus: Bool = true) {
        windowController.hide(restoreFocus: restoreFocus)
    }

    /// True when the palette should render as the slim compact bar: compact mode on, launcher root, empty query, and not force-expanded via the "…" overflow.
    var paletteIsCollapsed: Bool {
        settings.compactMode
            && !palette.forceExpanded
            && palette.mode == .launcher
            && palette.query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The compact bar's "…" overflow: expand into the full favorites-pinned launcher without typing.
    func expandFromCompact() {
        palette.forceExpanded = true
    }

    /// Resize the panel to match the current collapsed state; called by the view when `paletteIsCollapsed` flips while open.
    func syncPaletteSize() {
        windowController.applyCollapsed(paletteIsCollapsed)
    }

    /// Dock-icon / reopen: focus an open aux window (About/Settings/Onboarding), else summon the launcher. Decoupled from the individual show paths so activation always works.
    func handleReopen() {
        if auxWindows.focusExisting() { return }
        showPalette(mode: .launcher, restoreAnyMode: true)
    }

    /// Settings runs in its own window (the SwiftUI `Settings` scene is unreliable for accessory apps). A fresh window mounts directly on `tab` (no first-frame flicker); an already-open one is switched in place.
    func showSettings(tab: SettingsTab = .general) {
        let isNew = auxWindows.show(
            id: "settings", title: "Settings", size: CGSize(width: 720, height: 550),
            seamlessTitleBar: true
        ) {
            SettingsRootView(initialTab: tab)
                .environmentObject(self.appIndex)
                .environmentObject(self.visibility)
        }
        if !isNew {
            NotificationCenter.default.post(name: .tinycastSelectSettingsTab, object: tab)
        }
    }

    func showBackupSettings() {
        showSettings(tab: .backup)
    }

    func showAbout() {
        showSettings(tab: .about)
    }

    /// The first-run wizard: palette shortcut, Accessibility, Raycast import. Also re-runnable from Settings.
    func showOnboarding() {
        auxWindows.show(
            id: "onboarding", title: "Welcome to Tinycast",
            size: OnboardingView.windowSize, seamlessTitleBar: true
        ) {
            OnboardingView()
        }
    }

    /// Final onboarding step: close the wizard and drop straight into the launcher.
    func finishOnboarding() {
        auxWindows.close(id: "onboarding")
        showPalette(mode: .launcher)
    }

    // MARK: - Actions invoked from the palette UI

    func launch(_ app: AppEntry) {
        // Record frequency once for launcher activations only — apps and commands count,
        // system settings (and direct hotkey/system activations) do not. Recorded before
        // dispatch so a mode-switch or app quit can't race the tally.
        if app.kind != .systemSettings {
            appUsage.record(app)
        }
        // Commands dispatch before the palette hides: mode-switching commands keep it open.
        if app.kind == .command {
            runCommand(app)
            return
        }
        hidePalette(restoreFocus: false)
        switch app.kind {
        case .application:
            AppLauncher.launch(app.url)
        case .systemSettings:
            guard let bundleID = app.bundleID else { return }
            AppLauncher.openSettingsPane(bundleID: bundleID)
        case .command:
            break  // handled above
        }
    }

    /// Quits the app behind an entry; a no-op (palette stays put) when it isn't running.
    func quit(_ app: AppEntry) {
        guard app.kind == .application, let bundleID = app.bundleID else { return }
        // Unlike `launch`, nothing here takes focus on its own — hand it back to where the user was, unless that's the app now on its way out.
        let quittingPreviousApp = windowController.previousApp?.bundleIdentifier == bundleID
        guard AppLauncher.quit(bundleID: bundleID) else { return }
        hidePalette(restoreFocus: !quittingPreviousApp)
    }

    /// Quit All: the one action whose blast radius reaches outside Tinycast, so it confirms first. The target list is resolved once and both counted and terminated, so the set the user approves is the set that quits.
    private func quitAllApps() {
        let targets = AppLauncher.quitAllTargets()
        guard !targets.isEmpty, Self.confirmQuitAll(count: targets.count) else { return }
        for app in targets { app.terminate() }
    }

    private static func confirmQuitAll(count: Int) -> Bool {
        // An accessory app's alert opens behind the frontmost app unless it activates first (same as `BackupActions`).
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Quit 1 application?" : "Quit \(count) applications?"
        alert.informativeText = "Applications with unsaved changes will ask you to save."
        alert.alertStyle = .warning
        let quitButton = alert.addButton(withTitle: "Quit All")
        quitButton.hasDestructiveAction = true
        // `hasDestructiveAction` only tints the button — it stays the ↵ default. Hand ↵ to Cancel instead: this command is one ↵ away in the palette, and a second reflexive ↵ must not quit the desktop.
        quitButton.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func runCommand(_ entry: AppEntry) {
        switch CommandRegistry.command(for: entry) {
        case .calculatorHistory:
            showPalette(mode: .calculatorHistory)
        case .clipboardHistory:
            showPalette(mode: .clipboard)
        case .searchEmoji:
            showPalette(mode: .emoji)
        case .exportSettings:
            hidePalette(restoreFocus: false)
            BackupActions.exportSettings()
        case .importSettings:
            hidePalette(restoreFocus: false)
            BackupActions.importSettings()
        case .importFromRaycast:
            hidePalette(restoreFocus: false)
            showBackupSettings()
        case .settings:
            hidePalette(restoreFocus: false)
            showSettings()
        case .about:
            hidePalette(restoreFocus: false)
            showAbout()
        // Microphone + Caffeination commands. The four immediate actions (Caffeinate/
        // Decaffeinate/Toggle Microphone/Toggle Caffeination) dispatch straight to the
        // controllers (off-main, in a Task so the palette tear-down isn't delayed); the
        // four arg-bearing commands (set level, caffeinate for/until/while) need
        // input the launcher can't carry, so they switch the palette into the matching
        // `PaletteMode` where the SystemCommandViews surface collects it.
        case .toggleMicrophone:
            hidePalette(restoreFocus: false)
            Task { await microphoneController.toggleMuted() }
        case .setMicrophoneLevel:
            showPalette(mode: .setMicrophoneLevel)
        case .caffeinate:
            hidePalette(restoreFocus: false)
            Task { await caffeinationController.caffeinate() }
        case .decaffeinate:
            hidePalette(restoreFocus: false)
            Task { await caffeinationController.decaffeinate() }
        case .toggleCaffeination:
            hidePalette(restoreFocus: false)
            Task { await caffeinationController.toggle() }
        case .caffeinateFor:
            showPalette(mode: .caffeinateFor)
        case .caffeinateUntil:
            showPalette(mode: .caffeinateUntil)
        case .caffeinateWhile:
            showPalette(mode: .caffeinateWhile)
        case .quitAllApps:
            // Hide before confirming: the palette is a floating panel and would sit above the alert.
            hidePalette(restoreFocus: false)
            quitAllApps()
        case .quit:
            NSApp.terminate(nil)
        case nil:
            break
        }
    }

    /// ↵ on the inline calculator card: copy the formatted answer (`display`), remember the calculation, dismiss.
    func copyCalculatorResult(_ result: CalcResult) {
        copyCalc(result) { display, _ in display }
    }

    /// ⌘↵ on the inline calculator card: copy the unformatted answer (`copyText`), remember, dismiss.
    func copyCalculatorResultUnformatted(_ result: CalcResult) {
        copyCalc(result) { _, copyText in copyText }
    }

    /// ⌘⇧↵ on the inline calculator card: copy the question and the formatted answer together, remember, dismiss.
    func copyCalculatorResultWithExpression(_ result: CalcResult) {
        copyCalc(result) { display, _ in "\(result.expression)\n\(display)" }
    }

    /// Shared record + dismiss + copy path for the calculator card's three copy shortcuts — history always records the formatted `display` so the stored entry is identical regardless of which answer form was copied.
    private func copyCalc(_ result: CalcResult, text: (_ display: String, _ copyText: String) -> String) {
        guard case .value(let display, let copyText) = result.payload else { return }
        calcHistory.record(expression: result.expression, result: display)
        hidePalette(restoreFocus: false)
        Paster.copyPlainText(text(display, copyText))
    }

    /// Enter on a Calculator History row: re-copy the stored answer (no re-record).
    func copyHistoryEntry(_ entry: CalcHistoryEntry) {
        hidePalette(restoreFocus: false)
        Paster.copyPlainText(entry.result.replacingOccurrences(of: ",", with: ""))
    }

    func copyHistoryExpression(_ entry: CalcHistoryEntry) {
        hidePalette(restoreFocus: false)
        Paster.copyPlainText(entry.expression)
    }

    func showInFinder(_ app: AppEntry) {
        hidePalette(restoreFocus: false)
        AppLauncher.showInFinder(app.url)
    }

    func paste(_ item: ClipboardItem) {
        let previous = windowController.previousApp
        hidePalette(restoreFocus: false)
        // A successful write promotes the item to index 0; follow it so any preserved (pop-to-root) or open clipboard state highlights the row that moved.
        if Paster.paste(item, store: clipboardStore, previousApp: previous) {
            palette.selection = 0
        }
    }

    func pasteKeepingWindowOpen(_ item: ClipboardItem) {
        if windowController.pasteKeepingWindowOpen(item, store: clipboardStore) {
            palette.selection = 0
        }
    }

    func copyToClipboard(_ item: ClipboardItem) {
        hidePalette(restoreFocus: false)
        if Paster.copy(item, store: clipboardStore) {
            palette.selection = 0
        }
    }

    func revealClipboardImage(_ item: ClipboardItem) {
        guard let url = clipboardStore.imageURL(for: item) else { return }
        hidePalette(restoreFocus: false)
        AppLauncher.showInFinder(url)
    }

    // MARK: - Emoji actions (frequency is tallied on the base glyph; the configured tone is applied at copy time)

    func pasteEmoji(_ entry: EmojiEntry) {
        frequentEmoji.record(entry.glyph)
        let previous = windowController.previousApp
        hidePalette(restoreFocus: false)
        Paster.pasteString(entry.display(tone: settings.emojiSkinTone), previousApp: previous)
    }

    func copyEmoji(_ entry: EmojiEntry) {
        frequentEmoji.record(entry.glyph)
        hidePalette(restoreFocus: false)
        Paster.copyString(entry.display(tone: settings.emojiSkinTone))
    }

    func pasteEmojiKeepingWindowOpen(_ entry: EmojiEntry) {
        frequentEmoji.record(entry.glyph)
        windowController.pasteStringKeepingWindowOpen(entry.display(tone: settings.emojiSkinTone))
    }
}
