import AppKit
import Carbon.HIToolbox
import Darwin
import SwiftUI

extension Notification.Name {
    static let floatScopeSettingsApplied = Notification.Name("FloatScope.settingsApplied")
}

@main
struct FloatScopeApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: FloatingPanel?
    private var conversationPanel: ConversationFloatingPanel?
    private var model: FloatScopeModel?
    private var statusItem: NSStatusItem?
    private var signalSources: [DispatchSourceSignal] = []
    private let hotKeyManager = GlobalHotKeyManager()
    private var conversationFollowTarget: NSRect?
    private var conversationFollowTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = FloatScopeModel()
        self.model = model
        installSignalHandlers()
        installStatusItem()
        installHotKey()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsApplied), name: .floatScopeSettingsApplied, object: nil)

        let rootView = ContentView(model: model)
        let panel = FloatingPanel(contentRect: Self.restoredFrame())
        panel.contentView = RoundedHostingContainer(rootView: rootView, radius: 28)
        panel.onPasteAttachment = { [weak model] in
            model?.importPasteboardAttachments() ?? false
        }
        panel.delegate = self
        panel.alphaValue = model.settings.capsuleOpacity
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        let conversationPanel = ConversationFloatingPanel(contentRect: Self.conversationFrame(for: panel.frame))
        conversationPanel.contentView = RoundedHostingContainer(rootView: ConversationOverlayView(model: model), radius: 18)
        conversationPanel.alphaValue = 0
        conversationPanel.orderOut(nil)
        self.conversationPanel = conversationPanel

        model.onExpansionChanged = { [weak self] expanded in
            self?.setConversationVisible(expanded)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyManager.unregister()
        model?.stop()
    }

    func applicationDidResignActive(_ notification: Notification) {
        model?.collapse()
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.model?.stop()
                NSApplication.shared.terminate(nil)
            }
            source.resume()
        signalSources.append(source)
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill", accessibilityDescription: "FloatScope")
        item.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open FloatScope", action: #selector(openFloatScope), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reset Position", action: #selector(resetPosition), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Conversation History...", action: #selector(openHistory), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "New Conversation", action: #selector(newConversation), keyEquivalent: "n"))
        menu.addItem(NSMenuItem(title: "Toggle Screen Watch", action: #selector(toggleScreenWatch), keyEquivalent: "w"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit FloatScope", action: #selector(quitFloatScope), keyEquivalent: "q"))
        for item in menu.items {
            item.target = self
        }
        statusItem = item
        statusItem?.menu = menu
    }

    @objc private func openFloatScope() {
        if panel?.isVisible == true {
            panel?.orderOut(nil)
            conversationPanel?.orderOut(nil)
            return
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model?.expand()
    }

    @objc private func openSettings() {
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model?.showSettings = true
    }

    @objc private func openHistory() {
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model?.openHistoryPicker()
    }

    @objc private func newConversation() {
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model?.startNewConversation()
    }

    @objc private func toggleScreenWatch() {
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model?.toggleScreenWatch()
    }

    @objc private func resetPosition() {
        guard let panel else { return }
        let frame = Self.defaultFrame(width: panel.frame.width)
        panel.setFrame(frame, display: true, animate: false)
        UserDefaults.standard.set(NSStringFromRect(FloatingPanelMetrics.restingFrame(from: frame)), forKey: SettingsKeys.windowFrame)
        repositionConversationPanel(animated: false)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func settingsApplied() {
        installHotKey()
    }

    @objc private func quitFloatScope() {
        model?.stop()
        NSApp.terminate(nil)
    }

    func windowDidMove(_ notification: Notification) {
        guard let frame = panel?.frame else { return }
        UserDefaults.standard.set(NSStringFromRect(FloatingPanelMetrics.restingFrame(from: frame)), forKey: SettingsKeys.windowFrame)
        repositionConversationPanel(animated: true)
    }

    func windowDidResize(_ notification: Notification) {
        guard let frame = panel?.frame else { return }
        UserDefaults.standard.set(NSStringFromRect(FloatingPanelMetrics.restingFrame(from: frame)), forKey: SettingsKeys.windowFrame)
        repositionConversationPanel(animated: false)
    }

    func windowDidResignKey(_ notification: Notification) {
        model?.collapse()
    }

    private static func restoredFrame() -> NSRect {
        if let raw = UserDefaults.standard.string(forKey: SettingsKeys.windowFrame) {
            var frame = NSRectFromString(raw)
            if frame.width > 240, frame.height > 48 {
                frame.size.height = FloatingPanelMetrics.collapsedHeight
                return frame
            }
        }

        return defaultFrame(width: 520)
    }

    private static func defaultFrame(width: CGFloat) -> NSRect {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = FloatingPanelMetrics.collapsedHeight
        return NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.midY - height / 2 - 180,
            width: width,
            height: height
        )
    }

    private static func conversationFrame(for capsuleFrame: NSRect) -> NSRect {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let availableHeight = screenFrame.maxY - capsuleFrame.maxY - FloatingPanelMetrics.panelGap - 12
        let height = min(FloatingPanelMetrics.maxConversationHeight, max(FloatingPanelMetrics.minConversationHeight, availableHeight))
        return NSRect(
            x: capsuleFrame.minX,
            y: capsuleFrame.maxY + FloatingPanelMetrics.panelGap,
            width: capsuleFrame.width,
            height: height
        )
    }

    private func repositionConversationPanel(animated: Bool = false) {
        guard let panel, let conversationPanel else { return }
        let target = Self.conversationFrame(for: panel.frame)
        guard animated, conversationPanel.isVisible else {
            conversationFollowTimer?.invalidate()
            conversationFollowTimer = nil
            conversationFollowTarget = nil
            setConversationPanelFrame(target)
            return
        }

        conversationFollowTarget = target
        startConversationFollowTimerIfNeeded()
    }

    private func startConversationFollowTimerIfNeeded() {
        guard conversationFollowTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(conversationFollowTick(_:)), userInfo: nil, repeats: true)
        conversationFollowTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func conversationFollowTick(_ timer: Timer) {
        guard let conversationPanel, let target = conversationFollowTarget else {
            timer.invalidate()
            conversationFollowTimer = nil
            return
        }

        let current = conversationPanel.frame
        let next = Self.dampedFrame(from: current, to: target)
        setConversationPanelFrame(next)

        if Self.frameDistance(next, target) < 0.75 {
            setConversationPanelFrame(target)
            timer.invalidate()
            conversationFollowTimer = nil
            conversationFollowTarget = nil
        }
    }

    private func setConversationPanelFrame(_ frame: NSRect) {
        guard let conversationPanel else { return }
        conversationPanel.isTrackingParentMove = true
        conversationPanel.setFrame(frame, display: false, animate: false)
        conversationPanel.isTrackingParentMove = false
    }

    private static func dampedFrame(from current: NSRect, to target: NSRect) -> NSRect {
        let factor: CGFloat = 0.38
        return NSRect(
            x: current.minX + (target.minX - current.minX) * factor,
            y: current.minY + (target.minY - current.minY) * factor,
            width: current.width + (target.width - current.width) * factor,
            height: current.height + (target.height - current.height) * factor
        )
    }

    private static func frameDistance(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        max(
            abs(lhs.minX - rhs.minX),
            abs(lhs.minY - rhs.minY),
            abs(lhs.width - rhs.width),
            abs(lhs.height - rhs.height)
        )
    }

    private func installHotKey() {
        hotKeyManager.register(shortcut: model?.settings.toggleShortcut ?? FloatScopeSettings().toggleShortcut) { [weak self] in
            self?.openFloatScope()
        }
    }

    private func setConversationVisible(_ visible: Bool) {
        guard let conversationPanel else { return }
        repositionConversationPanel()
        conversationPanel.forceRoundedLayout()
        let transitionSurface = conversationPanel.contentView as? PanelTransitionSurface
        if visible {
            conversationPanel.alphaValue = 1
            transitionSurface?.prepareForAppear()
            conversationPanel.orderFrontRegardless()
            transitionSurface?.animateVisible(duration: 0.24)
        } else {
            transitionSurface?.animateHidden(duration: 0.24)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                if self.model?.isExpanded == false {
                    conversationPanel.forceRoundedLayout()
                    conversationPanel.orderOut(nil)
                }
            }
        }
    }
}

enum FloatingPanelMetrics {
    static let collapsedHeight: CGFloat = 96
    static let expandedHeight: CGFloat = 372
    static let minConversationHeight: CGFloat = 260
    static let maxConversationHeight: CGFloat = 520
    static let panelGap: CGFloat = 6

    static func restingFrame(from frame: NSRect) -> NSRect {
        NSRect(
            x: frame.minX,
            y: frame.minY,
            width: frame.width,
            height: collapsedHeight
        )
    }
}

final class ConversationFloatingPanel: NSPanel {
    var isTrackingParentMove = false

    override var contentView: NSView? {
        didSet { forceRoundedLayout() }
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        minSize = NSSize(width: 300, height: FloatingPanelMetrics.minConversationHeight)
        maxSize = NSSize(width: 760, height: FloatingPanelMetrics.maxConversationHeight)
        forceRoundedLayout()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        super.setFrame(frameRect, display: flag, animate: animateFlag)
        if !isTrackingParentMove {
            forceRoundedLayout()
        }
    }
}

final class FloatingPanel: NSPanel {
    var onPasteAttachment: (() -> Bool)?
    private var lastAnchoredFrame: NSRect = .zero
    private var anchoredAnimationTimer: Timer?

    override var contentView: NSView? {
        didSet { forceRoundedLayout() }
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        minSize = NSSize(width: 300, height: FloatingPanelMetrics.collapsedHeight)
        maxSize = NSSize(width: 760, height: FloatingPanelMetrics.expandedHeight)
        forceRoundedLayout()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        super.setFrame(frameRect, display: flag, animate: animateFlag)
        forceRoundedLayout()
    }

    func setAnchoredFrame(_ target: NSRect, animated: Bool) {
        guard abs(frame.width - target.width) > 0.5 || abs(frame.height - target.height) > 0.5 else { return }
        anchoredAnimationTimer?.invalidate()
        lastAnchoredFrame = target

        guard animated else {
            applyAnchoredFrame(target)
            return
        }

        let start = frame
        let widthDelta = target.width - start.width
        let duration: TimeInterval = 0.18
        let startTime = CACurrentMediaTime()
        let minWidth = minSize.width
        let maxWidth = maxSize.width

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            let elapsed = CACurrentMediaTime() - startTime
            let progress = min(1, elapsed / duration)
            if progress >= 1 {
                timer.invalidate()
            }

            Task { @MainActor in
                let eased = Self.dampedEaseOut(CGFloat(progress))
                let width = start.width + widthDelta * eased
                let animatedFrame = NSRect(
                    x: target.minX,
                    y: target.minY,
                    width: max(minWidth, min(maxWidth, width)),
                    height: target.height
                )
                self.applyAnchoredFrame(animatedFrame)

                if progress >= 1 {
                    if NSEqualRects(self.lastAnchoredFrame, target) {
                        self.applyAnchoredFrame(target)
                    }
                }
            }
        }
        anchoredAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func applyAnchoredFrame(_ target: NSRect) {
        super.setFrame(target, display: true, animate: false)
        forceRoundedLayout()
    }

    nonisolated private static func dampedEaseOut(_ t: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, t))
        let k: CGFloat = 5.4
        let value = 1 - (1 + k * clamped) * exp(-k * clamped)
        let endValue = 1 - (1 + k) * exp(-k)
        return min(1, value / endValue)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let character = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        switch character {
        case "x":
            return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case "c":
            return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case "v":
            if onPasteAttachment?() == true {
                return true
            }
            return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case "a":
            return NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: self)
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

private extension NSPanel {
    func forceRoundedLayout() {
        contentView?.needsLayout = true
        contentView?.layoutSubtreeIfNeeded()
        contentView?.displayIfNeeded()
        invalidateShadow()
    }
}

private final class GlobalHotKeyManager: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var action: (() -> Void)?
    private let signature = OSType(UInt32(ascii: "FSCP"))

    func register(shortcut: String, action: @escaping () -> Void) {
        unregister()
        guard let parsed = HotKeyParser.parse(shortcut) else { return }
        self.action = action

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                manager.action?()
            }
            return noErr
        }, 1, &eventSpec, selfPointer, &eventHandler)

        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        RegisterEventHotKey(parsed.keyCode, parsed.modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        hotKeyRef = nil
        eventHandler = nil
        action = nil
    }
}

private enum HotKeyParser {
    static func parse(_ shortcut: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        let parts = shortcut
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "⌥", with: "option")
            .replacingOccurrences(of: "⌘", with: "command")
            .replacingOccurrences(of: "⇧", with: "shift")
            .replacingOccurrences(of: "⌃", with: "control")
            .split(separator: "+")
            .map(String.init)
        guard let key = parts.last,
              let keyCode = keyCodes[key] else { return nil }

        var modifiers: UInt32 = 0
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "opt", "option", "alt": modifiers |= UInt32(optionKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default: break
            }
        }
        guard modifiers != 0 else { return nil }
        return (UInt32(keyCode), modifiers)
    }

    private static let keyCodes: [String: Int] = [
        "space": kVK_Space,
        "return": kVK_Return,
        "enter": kVK_Return,
        "escape": kVK_Escape,
        "esc": kVK_Escape,
        "a": kVK_ANSI_A,
        "b": kVK_ANSI_B,
        "c": kVK_ANSI_C,
        "d": kVK_ANSI_D,
        "e": kVK_ANSI_E,
        "f": kVK_ANSI_F,
        "g": kVK_ANSI_G,
        "h": kVK_ANSI_H,
        "i": kVK_ANSI_I,
        "j": kVK_ANSI_J,
        "k": kVK_ANSI_K,
        "l": kVK_ANSI_L,
        "m": kVK_ANSI_M,
        "n": kVK_ANSI_N,
        "o": kVK_ANSI_O,
        "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q,
        "r": kVK_ANSI_R,
        "s": kVK_ANSI_S,
        "t": kVK_ANSI_T,
        "u": kVK_ANSI_U,
        "v": kVK_ANSI_V,
        "w": kVK_ANSI_W,
        "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0,
        "1": kVK_ANSI_1,
        "2": kVK_ANSI_2,
        "3": kVK_ANSI_3,
        "4": kVK_ANSI_4,
        "5": kVK_ANSI_5,
        "6": kVK_ANSI_6,
        "7": kVK_ANSI_7,
        "8": kVK_ANSI_8,
        "9": kVK_ANSI_9
    ]
}

private extension UInt32 {
    init(ascii value: String) {
        self = value.utf8.reduce(0) { ($0 << 8) + UInt32($1) }
    }
}

@MainActor
private protocol PanelTransitionSurface: AnyObject {
    func prepareForAppear()
    func animateVisible(duration: TimeInterval)
    func animateHidden(duration: TimeInterval)
}

final class RoundedHostingContainer<Content: View>: NSView, PanelTransitionSurface {
    private let hostingView: NSHostingView<Content>
    private let radius: CGFloat
    private let shapeMask = CAShapeLayer()

    init(rootView: Content, radius: CGFloat) {
        self.hostingView = NSHostingView(rootView: rootView)
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        layer?.mask = shapeMask

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeMask.frame = bounds
        shapeMask.path = CGPath(
            roundedRect: bounds,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        CATransaction.commit()
    }

    func prepareForAppear() {
        applyTransition(alpha: 0, scale: 0.94, yOffset: -24, animated: false, duration: 0)
    }

    func animateVisible(duration: TimeInterval) {
        applyTransition(
            alpha: 1,
            scale: 1,
            yOffset: 0,
            animated: true,
            duration: duration,
            fromOpacity: 0,
            fromTransform: Self.hiddenTransform
        )
    }

    func animateHidden(duration: TimeInterval) {
        applyTransition(alpha: 0, scale: 0.94, yOffset: -24, animated: true, duration: duration)
    }

    private static var hiddenTransform: CATransform3D {
        CATransform3DScale(CATransform3DMakeTranslation(0, -24, 0), 0.94, 0.94, 1)
    }

    private func applyTransition(
        alpha: CGFloat,
        scale: CGFloat,
        yOffset: CGFloat,
        animated: Bool,
        duration: TimeInterval,
        fromOpacity: Float? = nil,
        fromTransform: CATransform3D? = nil
    ) {
        wantsLayer = true
        guard let layer else {
            alphaValue = alpha
            return
        }
        let transform = CATransform3DScale(CATransform3DMakeTranslation(0, yOffset, 0), scale, scale, 1)
        let startOpacity = fromOpacity ?? layer.presentation()?.opacity ?? layer.opacity
        let startTransform = fromTransform ?? layer.presentation()?.transform ?? layer.transform

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = Float(alpha)
        layer.transform = transform
        CATransaction.commit()

        guard animated else { return }

        let timing = CAMediaTimingFunction(name: alpha > 0 ? .easeOut : .easeIn)
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = startOpacity
        opacity.toValue = Float(alpha)

        let transformAnimation = CABasicAnimation(keyPath: "transform")
        transformAnimation.fromValue = startTransform
        transformAnimation.toValue = transform

        let group = CAAnimationGroup()
        group.animations = [opacity, transformAnimation]
        group.duration = duration
        group.timingFunction = timing
        group.isRemovedOnCompletion = true
        layer.add(group, forKey: "FloatScopePanelTransition")
    }
}
