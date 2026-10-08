//
//  HUDController.swift
//  by Danny Stewart (2025)
//  MIT License
//  https://github.com/dannystewart/volumeHUD
//

import AppKit
import Combine
import CoreGraphics
import Foundation
import SwiftUI

@MainActor
class HUDController: ObservableObject {
    @Published var isShowing = false

    let logger: Logger = .init()

    private var hudWindow: NSWindow?
    /// Extra HUD windows on the other displays, used to show the muted HUD everywhere
    private var mirrorWindows: [NSWindow] = []
    private var hostingView: NSHostingView<HUDView>?
    private var hideTimer: Timer?
    private var lastShownVolume: Float?
    private var lastShownMuted: Bool?
    private var lastShownBrightness: Float?
    private var lastShownHUDType: HUDType?
    /// Whether a pinned muted HUD has shrunk down to its small badge
    private var isCompactBadge = false
    /// Bumped on every content change so an in-flight collapse can tell it went stale
    private var contentGeneration = 0
    private var isObservingDisplayChanges = false
    private let isPreviewMode: Bool

    init(isPreviewMode: Bool = false) {
        self.isPreviewMode = isPreviewMode
    }

    deinit {}

    @MainActor
    func showVolumeHUD(volume: Float, isMuted: Bool) {
        displayHUD(hudType: .volume, value: volume, isMuted: isMuted)
    }

    /// Whether the volume HUD should stay on screen while muted (defaults to on)
    private var keepHUDWhileMuted: Bool {
        UserDefaults.standard.object(forKey: "keepHUDWhileMuted") as? Bool ?? true
    }

    /// Called when the "Keep HUD While Muted" setting changes. Releases a pinned muted HUD when
    /// the setting is turned off.
    @MainActor
    func keepHUDWhileMutedDidChange() {
        guard !keepHUDWhileMuted, isShowing, lastShownHUDType == .volume, lastShownMuted == true else { return }
        scheduleHideTimer()
    }

    /// Whether the muted HUD should be mirrored on every display (defaults to off)
    private var showMutedOnAllDisplays: Bool {
        UserDefaults.standard.bool(forKey: "showMutedHUDOnAllDisplays")
    }

    /// Called when the "Muted HUD on All Displays" setting changes. Adds or removes mirrors for a
    /// muted HUD that is currently on screen.
    @MainActor
    func showMutedOnAllDisplaysDidChange() {
        guard isShowing, lastShownHUDType == .volume, lastShownMuted == true else { return }
        updateMirrorWindows(hudType: .volume, value: lastShownVolume ?? 0, isMuted: true)
    }

    /// Called on any mute state change (user-initiated or not). If the HUD is pinned on screen
    /// showing muted volume and audio gets unmuted, resume the normal auto-hide behavior.
    @MainActor
    func volumeMuteStateDidChange(isMuted: Bool) {
        guard !isMuted, isShowing, lastShownHUDType == .volume, lastShownMuted == true else { return }
        lastShownMuted = nil // Force a content rebuild on the next show
        scheduleHideTimer()
    }

    #if !SANDBOX
        @MainActor
        func showBrightnessHUD(brightness: Float) {
            // Only show brightness HUD if the feature is enabled
            guard UserDefaults.standard.bool(forKey: "brightnessEnabled") else {
                logger.debug("Brightness HUD disabled; skipping display.")
                return
            }
            displayHUD(hudType: .brightness, value: brightness, isMuted: false)
        }
    #endif // !SANDBOX

    @MainActor
    func startDisplayChangeMonitoring() {
        guard !isObservingDisplayChanges else { return }

        // Skip display monitoring in preview mode
        if isPreviewMode {
            logger.debug("Skipping display monitoring in preview mode.")
            isObservingDisplayChanges = true
            return
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayConfigurationDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil,
        )
        isObservingDisplayChanges = true

        logger.debug("Started monitoring display configuration changes.")
    }

    @MainActor
    func stopDisplayChangeMonitoring() {
        guard isObservingDisplayChanges else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil,
        )
        isObservingDisplayChanges = false

        logger.debug("Stopped monitoring display configuration changes.")
    }

    @objc
    private func displayConfigurationDidChange(_: Notification) {
        // Ensure we hop to the main actor for UI work
        Task { @MainActor in
            self.handleDisplayConfigurationChange()
        }
    }

    @MainActor
    private func handleDisplayConfigurationChange() {
        logger.debug("Display configuration changed, updating HUD position.")

        // If the HUD window exists, update its position
        if hudWindow != nil {
            updateWindowPosition()
            refreshMirrorWindows()
            // Re-apply after a short delay to handle transient frame/layout updates macOS screen
            // geometry may still be adjusting after didChangeScreenParameters fires
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.updateWindowPosition()
                self?.refreshMirrorWindows()
            }
        }
    }

    @MainActor
    private func updateWindowPosition(for hudType: HUDType? = nil) {
        guard let window = hudWindow else { return }

        let windowSize = currentWindowSize

        // Brightness HUD always shows on built-in display (since that's what it controls). Volume
        // HUD respects user preference for display location.
        let targetScreen: NSScreen
        let selectionReason: String
        #if !SANDBOX
            if hudType == .brightness {
                if let builtin = getBuiltinScreen() {
                    targetScreen = builtin
                    selectionReason = "brightness builtin"
                } else if let main = NSScreen.main {
                    targetScreen = main
                    selectionReason = "brightness builtin-missing fallback NSScreen.main"
                } else {
                    targetScreen = NSScreen.screens.first!
                    selectionReason = "brightness builtin-missing fallback firstScreen"
                }
            } else {
                // Check user preference for volume HUD location
                let followMouse = UserDefaults.standard.bool(forKey: "volumeHUDFollowsMouse")
                if followMouse {
                    if let mouse = getScreenWithMouse() {
                        targetScreen = mouse
                        selectionReason = "volume followsMouse"
                    } else if let main = NSScreen.main {
                        targetScreen = main
                        selectionReason = "volume followsMouse missing-mouse fallback NSScreen.main"
                    } else {
                        targetScreen = NSScreen.screens.first!
                        selectionReason = "volume followsMouse missing-mouse fallback firstScreen"
                    }
                } else {
                    if let primary = getPrimaryScreen() {
                        targetScreen = primary
                        selectionReason = "volume primaryDisplay"
                    } else if let main = NSScreen.main {
                        targetScreen = main
                        selectionReason = "volume primaryDisplay missing-primary fallback NSScreen.main"
                    } else {
                        targetScreen = NSScreen.screens.first!
                        selectionReason = "volume primaryDisplay missing-primary fallback firstScreen"
                    }
                }
            }
        #else
            // Check user preference for volume HUD location
            let followMouse = UserDefaults.standard.bool(forKey: "volumeHUDFollowsMouse")
            if followMouse {
                if let mouse = getScreenWithMouse() {
                    targetScreen = mouse
                    selectionReason = "volume followsMouse"
                } else if let main = NSScreen.main {
                    targetScreen = main
                    selectionReason = "volume followsMouse missing-mouse fallback NSScreen.main"
                } else {
                    targetScreen = NSScreen.screens.first!
                    selectionReason = "volume followsMouse missing-mouse fallback firstScreen"
                }
            } else {
                if let primary = getPrimaryScreen() {
                    targetScreen = primary
                    selectionReason = "volume primaryDisplay"
                } else if let main = NSScreen.main {
                    targetScreen = main
                    selectionReason = "volume primaryDisplay missing-primary fallback NSScreen.main"
                } else {
                    targetScreen = NSScreen.screens.first!
                    selectionReason = "volume primaryDisplay missing-primary fallback firstScreen"
                }
            }
        #endif // !SANDBOX

        let selectedDisplayID: CGDirectDisplayID? = {
            guard
                let screenNumber = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDirectDisplayID(screenNumber.uint32Value)
        }()
        let selectedDisplayIDText = selectedDisplayID.map { String($0) } ?? "unknown"
        logger.debug("HUD screen selection: \(selectionReason), displayID=\(selectedDisplayIDText), frame=\(targetScreen.frame)")

        let newWindowRect = hudFrame(on: targetScreen, size: windowSize)

        // Update the window frame
        window.setFrame(newWindowRect, display: true)

        logger.debug("Updated HUD window position to: \(newWindowRect)")
    }

    /// Window size for the current HUD state: full HUD, or the small muted badge.
    private var currentWindowSize: NSSize {
        let side = isCompactBadge ? HUDView.badgeSize : HUDView.hudSize
        return NSSize(width: side, height: side)
    }

    /// Returns the HUD window frame for a screen, honoring the positioning preference.
    private func hudFrame(on screen: NSScreen, size: NSSize) -> NSRect {
        // Use full screen frame to ignore Dock positioning
        let screenFrame = screen.frame

        // Check user preference for positioning
        let useRelativePositioning = UserDefaults.standard.bool(forKey: "useRelativePositioning")
        let yPosition = useRelativePositioning
            ? screenFrame.origin.y + screenFrame.height * 0.17 // 17% from bottom
            : screenFrame.origin.y + 140 // 140px from bottom

        return NSRect(
            x: screenFrame.origin.x + (screenFrame.width - size.width) / 2,
            y: yPosition,
            width: size.width,
            height: size.height,
        )
    }

    /// Returns the NSScreen that currently contains the mouse cursor
    private func getScreenWithMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation

        for screen in NSScreen.screens where screen.frame.contains(mouseLocation) {
            return screen
        }

        return nil
    }

    /// Returns the NSScreen corresponding to the built-in display, if present
    private func getBuiltinScreen() -> NSScreen? {
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let displayID = CGDirectDisplayID(screenNumber.uint32Value)
                if CGDisplayIsBuiltin(displayID) != 0 {
                    return screen
                }
            }
        }
        return nil
    }

    /// Returns the NSScreen corresponding to macOS's primary (menu bar) display, if present.
    private func getPrimaryScreen() -> NSScreen? {
        let mainDisplayID = CGMainDisplayID()
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let displayID = CGDirectDisplayID(screenNumber.uint32Value)
                if displayID == mainDisplayID {
                    return screen
                }
            }
        }
        return nil
    }

    @MainActor
    private func displayHUD(hudType: HUDType, value: Float, isMuted: Bool) {
        // Cancel any existing hide timer
        hideTimer?.invalidate()

        // Keep the volume HUD on screen for as long as audio is muted
        let keepVisible = hudType == .volume && isMuted && keepHUDWhileMuted

        // Any new event shows the full HUD again; a pinned muted HUD re-collapses afterward
        let wasCompact = isCompactBadge
        isCompactBadge = false

        // Create or update the HUD window
        if hudWindow == nil {
            createHUDWindow()
        }

        // Update the content view
        if let window = hudWindow {

            let shouldUpdateContent: Bool =
                switch hudType {
                case .volume:
                    hostingView == nil
                        || lastShownHUDType != hudType
                        || lastShownVolume == nil
                        || abs((lastShownVolume ?? -1) - value) > 0.0005
                        || (lastShownMuted ?? !isMuted) != isMuted

                case .brightness:
                    hostingView == nil
                        || lastShownHUDType != hudType
                        || lastShownBrightness == nil
                        || abs((lastShownBrightness ?? -1) - value) > 0.0005
                }

            // If nothing changed and the window is already visible, just extend the timer
            if window.isVisible, !shouldUpdateContent, !wasCompact {
                scheduleHideTimer(collapse: keepVisible)
                return
            }

            contentGeneration += 1

            // Always recreate hosting view to avoid SwiftUI state issues
            hostingView = setHUDContent(of: window, hudType: hudType, value: value, isMuted: isMuted)

            // Update position based on HUD type
            updateWindowPosition(for: hudType)

            // Show the window
            window.orderFront(nil)
            isShowing = true

            // Mirror the muted HUD to other displays (or clear stale mirrors)
            updateMirrorWindows(hudType: hudType, value: value, isMuted: isMuted)
        }

        scheduleHideTimer(collapse: keepVisible)

        // Remember last shown state to avoid redundant view rebuilds
        lastShownHUDType = hudType
        switch hudType {
        case .volume:
            lastShownVolume = value
            lastShownMuted = isMuted

        case .brightness:
            lastShownBrightness = value
        }
    }

    /// Schedules the HUD to hide, or with `collapse` to shrink into the muted badge instead.
    @MainActor
    private func scheduleHideTimer(collapse: Bool = false) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: false) { [weak self] _ in
            Task { @MainActor in
                if collapse {
                    self?.collapseToBadge()
                } else {
                    self?.hideHUD()
                }
            }
        }
    }

    /// Cross-fades a pinned muted HUD (and its mirrors) into the small badge.
    @MainActor
    private func collapseToBadge() {
        guard let window = hudWindow, isShowing, !isCompactBadge, lastShownHUDType == .volume, lastShownMuted == true else { return }

        let generation = contentGeneration
        let oldMirrors = mirrorWindows

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.11
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0.0
            for mirror in oldMirrors {
                mirror.animator().alphaValue = 0.0
            }
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }

                // Something new was shown (or the HUD hid) during the fade; leave it alone
                guard generation == contentGeneration, isShowing, lastShownMuted == true else {
                    window.alphaValue = 1.0
                    return
                }

                isCompactBadge = true
                let volume = lastShownVolume ?? 0
                hostingView = setHUDContent(of: window, hudType: .volume, value: volume, isMuted: true)
                updateWindowPosition(for: .volume)
                updateMirrorWindows(hudType: .volume, value: volume, isMuted: true)

                let newMirrors = mirrorWindows
                for mirror in newMirrors {
                    mirror.alphaValue = 0.0
                }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    window.animator().alphaValue = 1.0
                    for mirror in newMirrors {
                        mirror.animator().alphaValue = 1.0
                    }
                }
                logger.debug("Collapsed muted HUD to badge.")
            }
        }
    }

    /// Replaces the window's content with a fresh HUDView and returns the new hosting view.
    @MainActor
    @discardableResult
    private func setHUDContent(of window: NSWindow, hudType: HUDType, value: Float, isMuted: Bool) -> NSHostingView<HUDView> {
        let newHostingView = NSHostingView(rootView: HUDView(hudType: hudType, value: value, isMuted: isMuted, isCompact: isCompactBadge))
        newHostingView.frame = window.contentView?.bounds ?? NSRect(origin: .zero, size: currentWindowSize)

        // Ensure hosting view background is clear for proper material rendering
        newHostingView.wantsLayer = true
        newHostingView.layer?.backgroundColor = NSColor.clear.cgColor

        // Remove old content view if it exists
        if let oldView = window.contentView { oldView.removeFromSuperview() }

        window.contentView = newHostingView
        return newHostingView
    }

    // MARK: Mirror Windows

    /// Shows a copy of the muted volume HUD on every display other than the main HUD's, or removes
    /// the copies when they no longer apply.
    @MainActor
    private func updateMirrorWindows(hudType: HUDType, value: Float, isMuted: Bool) {
        removeMirrorWindows()

        guard hudType == .volume, isMuted, showMutedOnAllDisplays, let mainWindow = hudWindow else { return }

        let mainCenter = NSPoint(x: mainWindow.frame.midX, y: mainWindow.frame.midY)
        for screen in NSScreen.screens where !screen.frame.contains(mainCenter) {
            let mirror = makeOverlayWindow()
            setHUDContent(of: mirror, hudType: hudType, value: value, isMuted: isMuted)
            mirror.setFrame(hudFrame(on: screen, size: currentWindowSize), display: true)
            mirror.orderFront(nil)
            mirrorWindows.append(mirror)
        }

        if !mirrorWindows.isEmpty {
            logger.debug("Showing muted HUD on \(mirrorWindows.count) additional display(s).")
        }
    }

    /// Rebuilds mirrors after a display change so they land on the current set of screens.
    @MainActor
    private func refreshMirrorWindows() {
        guard !mirrorWindows.isEmpty, isShowing, lastShownHUDType == .volume, lastShownMuted == true else { return }
        updateMirrorWindows(hudType: .volume, value: lastShownVolume ?? 0, isMuted: true)
    }

    @MainActor
    private func removeMirrorWindows() {
        for mirror in mirrorWindows {
            mirror.orderOut(nil)
        }
        mirrorWindows.removeAll()
    }

    @MainActor
    private func createHUDWindow() {
        let window = makeOverlayWindow()
        hudWindow = window

        // Set the initial position
        updateWindowPosition()

        // Start the window hidden (only show when volume changes)
        window.orderOut(nil)

        logger.debug("Created HUD window.")
    }

    /// Creates a borderless, click-through overlay window for displaying a HUD.
    @MainActor
    private func makeOverlayWindow() -> NSWindow {
        // Create the window with special properties for overlay
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false

        // Configure window properties for overlay behavior. Use `.statusBar` level to appear above
        // normal windows but not block Exposé/Show Desktop.
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Avoid .stationary: it can interact badly with Mission Control / Show Desktop.
        // `canJoinAllSpaces` is sufficient for cross-space visibility.
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]

        return window
    }

    // MARK: Hide HUD

    @MainActor
    private func hideHUD() {
        guard let window = hudWindow else { return }

        // Take ownership of the mirrors so a re-show during the fade gets fresh ones
        let mirrors = mirrorWindows
        mirrorWindows.removeAll()
        isCompactBadge = false
        contentGeneration += 1

        // Animate fade-out before hiding
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.11
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0.0
            for mirror in mirrors {
                mirror.animator().alphaValue = 0.0
            }
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                window.orderOut(nil)
                window.alphaValue = 1.0 // Reset for next show
                for mirror in mirrors {
                    mirror.orderOut(nil)
                }
                self?.isShowing = false
            }
        }
    }
}
