import AppKit
import Combine

/// Two persistent AppKit menu-bar status items — microphone mute and caffeination.
/// Reflects the live state of `MicrophoneController` and `CaffeinationController` plus `AppSettings`
/// preferences without owning any of them.
@MainActor
final class SystemStatusItems {
    private weak var microphone: MicrophoneController?
    private weak var caffeination: CaffeinationController?
    
    private var micItem: NSStatusItem?
    private var coffeeItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    
    // Direct getters to the observed shared settings. 
    // AppCore holds `SystemStatusItems`, so `AppCore.shared.settings` is always available.
    private var settings: AppSettings { AppCore.shared.settings }
    
    init(microphone: MicrophoneController, caffeination: CaffeinationController) {
        self.microphone = microphone
        self.caffeination = caffeination
    }
    
    // MARK: - Lifecycle
    
    /// Builds both status items, subscribes to controller/settings `@Published` state, and renders the initial icons/menus.
    func start() {
        if micItem != nil || coffeeItem != nil { stop() }
        
        guard let mic = microphone, let coffee = caffeination else { return }
        
        let bar = NSStatusBar.system
        
        // Microphone item setup + combine
        if settings.showMicrophoneMenuBar {
            micItem = bar.statusItem(withLength: NSStatusItem.squareLength)
        }
        
        // Coffee item setup + combine
        if settings.showCoffeeMenuBar {
            coffeeItem = bar.statusItem(withLength: NSStatusItem.squareLength)
        }
        
        // Wire up combined observation of everything that could change visibility/icon/menu:
        // - Microphone state + settings
        Publishers.CombineLatest4(
            mic.$isMuted,
            settings.$showMicrophoneMenuBar,
            settings.$micHideIconWhenUnmuted,
            settings.$micMutedTintRed
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshMic() } }
        .store(in: &cancellables)
        
        // - Coffee state + settings
        Publishers.CombineLatest3(
            coffee.$mode,
            settings.$showCoffeeMenuBar,
            settings.$coffeeHideWhenDecaffeinated
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshCoffee() } }
        .store(in: &cancellables)
        
        // Timer for remaining-time subtitle only when caffeinating in bounded mode
        coffee.$remaining
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshCoffeeMenuOnly() } }
            .store(in: &cancellables)
            
        refreshMic()
        refreshCoffee()
    }
    
    func stop() {
        cancellables.removeAll()
        if let micItem { NSStatusBar.system.removeStatusItem(micItem) }
        if let coffeeItem { NSStatusBar.system.removeStatusItem(coffeeItem) }
        micItem = nil
        coffeeItem = nil
    }
    
    // MARK: - Refreshes
    
    private func refreshMic() {
        let isMuted = microphone?.isMuted ?? true
        let shouldShow = settings.showMicrophoneMenuBar && (!settings.micHideIconWhenUnmuted || isMuted)
        
        if shouldShow {
            if micItem == nil { micItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }
            micItem?.applyMic(muted: isMuted, tintRed: settings.micMutedTintRed)
            micItem?.menu = micMenu(isMuted: isMuted)
        } else {
            if let item = micItem { NSStatusBar.system.removeStatusItem(item) }
            micItem = nil
        }
    }
    
    private func refreshCoffee() {
        let mode = caffeination?.mode ?? .inactive
        let isActive = mode != .inactive
        let shouldShow = settings.showCoffeeMenuBar && (!settings.coffeeHideWhenDecaffeinated || isActive)
        
        if shouldShow {
            if coffeeItem == nil { coffeeItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }
            coffeeItem?.applyCoffee(mode: mode)
            coffeeItem?.menu = coffeeMenu(mode: mode)
        } else {
            if let item = coffeeItem { NSStatusBar.system.removeStatusItem(item) }
            coffeeItem = nil
        }
    }
    
    private func refreshCoffeeMenuOnly() {
        guard let mode = caffeination?.mode, mode != .inactive, let item = coffeeItem else { return }
        item.menu = coffeeMenu(mode: mode)
    }

    // MARK: - Menus
    
    private func micMenu(isMuted: Bool) -> NSMenu {
        let menu = NSMenu()
        let muteItem = toggleItem(title: isMuted ? "Unmute Microphone" : "Mute Microphone", action: #selector(toggleMic))
        if isMuted { muteItem.state = .on }
        menu.addItem(muteItem)
        menu.addItem(openItem("Set Microphone Level…", selector: #selector(openSetMicLevel)))
        menu.addItem(.separator())
        menu.addItem(openItem("Microphone Settings…", selector: #selector(openMicSettings)))
        return menu
    }
    
    private func coffeeMenu(mode: CaffeinationController.Mode) -> NSMenu {
        let menu = NSMenu()
        let isActive = mode != .inactive
        
        // Primary toggle
        let decafItem = toggleItem(title: "Decaffeinate", action: #selector(decaffeinate))
        decafItem.isEnabled = isActive
        if mode == .inactive { decafItem.state = .on }
        menu.addItem(decafItem)
        
        let indefItem = toggleItem(title: "Indefinite", action: #selector(caffeinateIndefinite))
        if mode == .indefinite { indefItem.state = .on }
        menu.addItem(indefItem)
        
        menu.addItem(.separator())
        
        // Durations
        let presets: [(String, TimeInterval)] = [
            ("10 minutes", 600), ("30 minutes", 1800), ("1 hour", 3600), ("2 hours", 7200),
            ("4 hours", 14400), ("8 hours", 28800), ("12 hours", 43200)
        ]
        
        for (title, duration) in presets {
            let item = NSMenuItem(title: title, action: #selector(caffeinatePreset(_:)), keyEquivalent: "")
            item.target = self
            // Note: tag carries duration for action dispatch
            item.tag = Int(duration)
            if case .duration(let d) = mode, d == duration { item.state = .on }
            menu.addItem(item)
        }
        
        let untilItem = openItem("Until…", selector: #selector(openUntil))
        if case .until = mode { untilItem.state = .on }
        menu.addItem(untilItem)
        
        let whileAppItem = openItem("While App…", selector: #selector(openWhileApp))
        if case .whileApp = mode { whileAppItem.state = .on }
        menu.addItem(whileAppItem)
        
        // Remaining time if applicable
        if isActive, let remaining = caffeination?.remainingDescription {
            menu.addItem(.separator())
            let remainingItem = NSMenuItem(title: remaining, action: nil, keyEquivalent: "")
            remainingItem.isEnabled = false
            menu.addItem(remainingItem)
        }
        
        return menu
    }

    @objc private func toggleMic() { Task { [microphone] in await microphone?.toggleMuted() } }
    @objc private func openMicSettings() { AppCore.shared.showSettings(tab: .general) }
    @objc private func openSetMicLevel() { AppCore.shared.showPalette(mode: .setMicrophoneLevel) }
    
    @objc private func decaffeinate() { Task { [caffeination] in await caffeination?.decaffeinate() } }
    @objc private func caffeinateIndefinite() { Task { [caffeination] in await caffeination?.caffeinate() } }
    @objc private func caffeinatePreset(_ sender: NSMenuItem) {
        let duration = TimeInterval(sender.tag)
        Task { [caffeination] in await caffeination?.caffeinate(for: duration) }
    }
    
    
    @objc private func openUntil() { AppCore.shared.showPalette(mode: .caffeinateUntil) }
    @objc private func openWhileApp() { AppCore.shared.showPalette(mode: .caffeinateWhile) }
    
    // MARK: - Helpers
    
    private func toggleItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
    
    private func openItem(_ title: String, selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }
}

// MARK: - Icon application

@MainActor private extension NSStatusItem {
    func applyMic(muted: Bool, tintRed: Bool) {
        let content = Content(symbol: muted ? "microphone.slash" : "microphone", isMuted: muted && tintRed)
        applyIcon(content)
        button?.toolTip = muted ? "Microphone: Muted" : "Microphone: Active"
    }

    func applyCoffee(mode: CaffeinationController.Mode) {
        let isKey = mode != .inactive
        let content = Content(symbol: isKey ? "cup.and.saucer.fill" : "cup.and.saucer", isMuted: false)
        applyIcon(content)
        button?.toolTip = isKey ? "Caffeination: Active" : "Caffeination: Inactive"
    }

    private struct Content {
        let symbol: String
        let isMuted: Bool
    }
    
    private func applyIcon(_ content: Content) {
        let image = NSImage(systemSymbolName: content.symbol, accessibilityDescription: content.symbol)
        image?.isTemplate = true
        
        if content.isMuted {
            // Apply red tint directly for muted mic matching Raycast
            if let btn = button, let img = image {
                let tinted = NSImage(size: img.size)
                tinted.lockFocus()
                NSColor.systemRed.set()
                let rect = NSRect(origin: .zero, size: img.size)
                img.draw(in: rect, from: rect, operation: .sourceOut, fraction: 1.0)
                tinted.unlockFocus()
                tinted.isTemplate = false // Has explicit color
                btn.image = tinted
            }
        } else {
            button?.image = image
        }
    }
}
