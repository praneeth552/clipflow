import AppKit
import Carbon.HIToolbox

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var overlayWindow: OverlayWindow?
    var historyManager = ClipboardHistoryManager()
    var hotkeyMonitor: Any?
    var flagsMonitor: Any?
    var clipboardTimer: Timer?
    var lastClipboardChangeCount: Int = 0  // Track clipboard changes
    var statusItem: NSStatusItem?
    var eventTap: CFMachPort?
    
    var isNavigating = false
    var currentIndex = 0
    
    // Store reference to self for event tap callback
    static var shared: AppDelegate?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        
        // Hide dock icon - we're a menu bar app
        NSApp.setActivationPolicy(.accessory)
        
        // Setup menu bar icon
        setupMenuBar()
        
        // Setup event tap (intercepts keys globally)
        setupEventTap()
        
        // Start clipboard monitoring
        startClipboardMonitoring()
        
        print("✅ ClipFlow started! Press Cmd+Shift+V to open history.")
        print("   NOTE: Grant Accessibility permissions if hotkeys don't work.")
    }
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            // Try to load custom icon
            let executablePath = ProcessInfo.processInfo.arguments[0]
            let executableDir = (executablePath as NSString).deletingLastPathComponent
            let customIconPath = executableDir + "/icon.png"
            
            if let image = NSImage(contentsOfFile: customIconPath) {
                // Resize for menu bar (18x18)
                let resized = NSImage(size: NSSize(width: 18, height: 18))
                resized.lockFocus()
                image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
                resized.unlockFocus()
                resized.isTemplate = false // Keep colors
                button.image = resized
            } else {
                // Fallback to system symbol
                button.image = NSImage(systemSymbolName: "clipboard.fill", accessibilityDescription: "ClipFlow")
            }
            button.imagePosition = .imageOnly
        }
        
        let menu = NSMenu()
        menu.delegate = self  // Enable dynamic updates
        menu.addItem(NSMenuItem(title: "📋 ClipFlow", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        // History count placeholder - will be updated dynamically
        let historyItem = NSMenuItem(title: "History: 0 items", action: nil, keyEquivalent: "")
        historyItem.tag = 100  // Tag to find it later
        menu.addItem(historyItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
    }
    
    @objc func quitApp() {
        // Remove event tap
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        NSApp.terminate(nil)
    }
    
    // MARK: - NSMenuDelegate - Update history count when menu opens
    func menuWillOpen(_ menu: NSMenu) {
        if let historyItem = menu.item(withTag: 100) {
            let count = historyManager.items.count
            historyItem.title = "History: \(count) item\(count == 1 ? "" : "s")"
        }
    }
    
    func setupEventTap() {
        // Create event tap that can intercept and consume key events
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap, // Can modify/consume events
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                return AppDelegate.shared?.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: nil
        ) else {
            print("⚠️  Could not create event tap. Please grant Accessibility permissions.")
            print("   System Settings → Privacy & Security → Accessibility → Add this app")
            
            // Fallback to non-intercepting monitor
            setupFallbackHotkey()
            return
        }
        
        eventTap = tap
        
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        
        print("   ✓ Event tap created - arrow keys will be intercepted during navigation")
    }
    
    func setupFallbackHotkey() {
        // Fallback: use global monitor (keys will pass through)
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 9 {
                if !self.isNavigating {
                    self.activateNavigation()
                }
            }
            
            if self.isNavigating {
                switch event.keyCode {
                case 126: self.navigateUp()
                case 125: self.navigateDown()
                case 36: self.selectAndPaste()
                case 53: self.cancelNavigation()
                default: break
                }
            }
        }
        
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return }
            if self.isNavigating && !event.modifierFlags.contains(.command) {
                self.selectAndPaste()
            }
        }
    }
    
    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            
            // Cmd+Shift+V to activate
            if flags.contains([.maskCommand, .maskShift]) && keyCode == 9 {
                if !isNavigating {
                    DispatchQueue.main.async { self.activateNavigation() }
                }
                return nil // Consume the event
            }
            
            // If navigating, handle and consume navigation keys
            if isNavigating {
                switch keyCode {
                case 126: // Up arrow
                    DispatchQueue.main.async { self.navigateUp() }
                    return nil // Consume - don't pass to app!
                case 125: // Down arrow
                    DispatchQueue.main.async { self.navigateDown() }
                    return nil // Consume
                case 36: // Enter
                    DispatchQueue.main.async { self.selectAndPaste() }
                    return nil // Consume
                case 53: // Escape
                    DispatchQueue.main.async { self.cancelNavigation() }
                    return nil // Consume
                case 51: // Delete/Backspace - delete current item if Cmd+Shift held
                    if flags.contains([.maskCommand, .maskShift]) {
                        DispatchQueue.main.async { self.deleteCurrentItem() }
                        return nil // Consume
                    }
                default:
                    break
                }
            }
        }
        
        if type == .flagsChanged {
            let flags = event.flags
            // If Cmd was released while navigating, paste
            if isNavigating && !flags.contains(.maskCommand) {
                DispatchQueue.main.async { self.selectAndPaste() }
            }
        }
        
        // Pass through other events
        return Unmanaged.passRetained(event)
    }
    
    func startClipboardMonitoring() {
        // Initialize change count
        lastClipboardChangeCount = NSPasteboard.general.changeCount
        
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            let pasteboard = NSPasteboard.general
            let currentChangeCount = pasteboard.changeCount
            
            // Only process if clipboard changed
            guard currentChangeCount != self.lastClipboardChangeCount else { return }
            self.lastClipboardChangeCount = currentChangeCount
            
            // Check for IMAGE first (higher priority)
            if let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
                if let image = NSImage(data: imageData) {
                    let item = ClipboardItem.image(image)
                    self.historyManager.add(item)
                    print("🖼️ Copied: Image (\(Int(image.size.width))x\(Int(image.size.height)))")
                    return
                }
            }
            
            // Check for TEXT
            if let content = pasteboard.string(forType: .string), !content.isEmpty {
                let item = ClipboardItem.text(content)
                self.historyManager.add(item)
                print("📋 Copied: \(String(content.prefix(50)))...")
            }
        }
    }
    
    func activateNavigation() {
        guard !historyManager.items.isEmpty else {
            print("⚠️ No clipboard history yet. Copy something first!")
            return
        }
        
        isNavigating = true
        currentIndex = 0
        
        // Create overlay if needed
        if overlayWindow == nil {
            overlayWindow = OverlayWindow()
        }
        
        overlayWindow?.show(
            item: historyManager.items[currentIndex],
            position: currentIndex + 1,
            total: historyManager.items.count
        )
        
        print("📋 Navigation [\(currentIndex + 1)/\(historyManager.items.count)]")
    }
    
    func navigateUp() {
        // Go to OLDER item (like terminal history: up = older)
        guard currentIndex < historyManager.items.count - 1 else { return }
        currentIndex += 1
        updateOverlay()
    }
    
    func navigateDown() {
        // Go to NEWER item (like terminal history: down = newer)
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        updateOverlay()
    }
    
    func updateOverlay() {
        overlayWindow?.update(
            item: historyManager.items[currentIndex],
            position: currentIndex + 1,
            total: historyManager.items.count
        )
        print("   [\(currentIndex + 1)/\(historyManager.items.count)]")
    }
    
    func selectAndPaste() {
        guard isNavigating, currentIndex < historyManager.items.count else { return }
        
        let item = historyManager.items[currentIndex]
        
        // Promote selected item to the front of history (recently used first)
        historyManager.promoteToRecent(index: currentIndex)
        
        // Set clipboard based on type
        NSPasteboard.general.clearContents()
        
        switch item {
        case .text(let content):
            NSPasteboard.general.setString(content, forType: .string)
            print("✅ Pasting text: \(String(content.prefix(50)))...")
        case .image(let image):
            if let tiffData = image.tiffRepresentation {
                NSPasteboard.general.setData(tiffData, forType: .tiff)
            }
            print("✅ Pasting image")
        }
        
        // Update change count to avoid re-capturing our own paste
        lastClipboardChangeCount = NSPasteboard.general.changeCount
        
        // Hide overlay
        overlayWindow?.hide()
        isNavigating = false
        
        // Simulate Cmd+V after a small delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.simulatePaste()
        }
    }
    
    func cancelNavigation() {
        isNavigating = false
        overlayWindow?.hide()
        print("❌ Cancelled")
    }
    
    func deleteCurrentItem() {
        guard isNavigating, currentIndex < historyManager.items.count else { return }
        
        print("🗑️ Deleting item at index \(currentIndex)")
        
        // Show delete animation first
        overlayWindow?.showDeleteAnimation { [weak self] in
            guard let self = self else { return }
            
            // Remove item from history
            self.historyManager.delete(at: self.currentIndex)
            
            // Handle empty history
            if self.historyManager.items.isEmpty {
                self.isNavigating = false
                self.overlayWindow?.hide()
                print("📋 History is now empty")
                return
            }
            
            // Adjust index if needed (if we deleted the last item)
            if self.currentIndex >= self.historyManager.items.count {
                self.currentIndex = self.historyManager.items.count - 1
            }
            
            // Show next item with animation
            self.overlayWindow?.showAfterDelete(
                item: self.historyManager.items[self.currentIndex],
                position: self.currentIndex + 1,
                total: self.historyManager.items.count
            )
            
            print("   Now showing [\(self.currentIndex + 1)/\(self.historyManager.items.count)]")
        }
    }
    
    func simulatePaste() {
        // Simulate Cmd+V using CGEvent
        let source = CGEventSource(stateID: .hidSystemState)
        
        // V key = 9
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }
        
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Clipboard Item
enum ClipboardItem: Equatable {
    case text(String)
    case image(NSImage)
    
    var displayText: String {
        switch self {
        case .text(let content):
            var display = content.replacingOccurrences(of: "\n", with: "  ↵  ")
            display = display.replacingOccurrences(of: "\t", with: "  ")
            if display.count > 350 {
                display = String(display.prefix(350)) + "..."
            }
            return display
        case .image(let img):
            return "🖼️ Image (\(Int(img.size.width)) × \(Int(img.size.height)) px)"
        }
    }
    
    var isImage: Bool {
        if case .image = self { return true }
        return false
    }
    
    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)): return a == b
        case (.image, .image): return false // Images are never duplicates
        default: return false
        }
    }
}

// MARK: - Clipboard History Manager
class ClipboardHistoryManager {
    var items: [ClipboardItem] = []
    let maxItems = 50
    
    func add(_ item: ClipboardItem) {
        // Remove duplicate if exists (only for text)
        if case .text = item {
            items.removeAll { $0 == item }
        }
        // Add to front
        items.insert(item, at: 0)
        // Trim to max
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }
    }
    
    /// Promotes the item at the given index to the front of the list.
    /// This implements "recently used" behavior - the last pasted item appears first.
    func promoteToRecent(index: Int) {
        guard index > 0 && index < items.count else { return }
        let item = items.remove(at: index)
        items.insert(item, at: 0)
    }
    
    /// Deletes the item at the given index.
    /// Returns true if successful, false if index is out of bounds.
    @discardableResult
    func delete(at index: Int) -> Bool {
        guard index >= 0 && index < items.count else { return false }
        items.remove(at: index)
        return true
    }
}

// MARK: - Overlay Window
class OverlayWindow {
    var panel: NSPanel?
    var bgView: NSVisualEffectView?
    var titleLabel: NSTextField?
    var positionLabel: NSTextField?
    var contentLabel: NSTextField?
    var imageView: NSImageView?
    var hintLabel: NSTextField?
    var separator: NSBox?
    
    let minWidth: CGFloat = 420
    let maxWidth: CGFloat = 520
    let headerHeight: CGFloat = 48
    let footerHeight: CGFloat = 38
    let padding: CGFloat = 20
    let imageSize: CGFloat = 110
    
    init() {
        setupPanel()
    }
    
    func setupPanel() {
        // Initial size - will be resized dynamically
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: maxWidth, height: 180),
            styleMask: [.borderless, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        
        guard let panel = panel else { return }
        
        // Panel settings
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = NSColor.clear
        panel.isOpaque = false
        panel.hasShadow = true
        
        // Create background with refined blur effect
        bgView = NSVisualEffectView(frame: panel.frame)
        bgView?.material = .hudWindow
        bgView?.blendingMode = .behindWindow
        bgView?.state = .active
        bgView?.wantsLayer = true
        bgView?.layer?.cornerRadius = 16
        bgView?.layer?.masksToBounds = true
        // Softer, warmer dark background - easier on eyes
        bgView?.layer?.backgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.13, alpha: 0.92).cgColor
        bgView?.layer?.borderWidth = 0.5
        bgView?.layer?.borderColor = NSColor(white: 0.25, alpha: 0.4).cgColor
        panel.contentView = bgView
        
        // Title - refined typography
        titleLabel = NSTextField(labelWithString: "ClipFlow")
        titleLabel?.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        // Softer blue accent - easier on eyes
        titleLabel?.textColor = NSColor(red: 0.55, green: 0.68, blue: 0.90, alpha: 1.0)
        bgView?.addSubview(titleLabel!)
        
        // Position label - monospaced for clean alignment
        positionLabel = NSTextField(labelWithString: "1 / 1")
        positionLabel?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        positionLabel?.textColor = NSColor(red: 0.55, green: 0.55, blue: 0.62, alpha: 1.0)
        positionLabel?.alignment = .right
        bgView?.addSubview(positionLabel!)
        
        // Separator - subtle divider
        separator = NSBox()
        separator?.boxType = .separator
        separator?.alphaValue = 0.15
        bgView?.addSubview(separator!)
        
        // Image view (for image previews)
        imageView = NSImageView()
        imageView?.imageScaling = .scaleProportionallyUpOrDown
        imageView?.wantsLayer = true
        imageView?.layer?.cornerRadius = 8
        imageView?.layer?.masksToBounds = true
        imageView?.layer?.borderWidth = 1
        imageView?.layer?.borderColor = NSColor(white: 0.3, alpha: 0.4).cgColor
        imageView?.isHidden = true
        bgView?.addSubview(imageView!)
        
        // Content label - optimized for readability
        contentLabel = NSTextField(labelWithString: "")
        contentLabel?.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        // Slightly off-white for reduced eye strain
        contentLabel?.textColor = NSColor(white: 0.92, alpha: 1.0)
        contentLabel?.lineBreakMode = .byWordWrapping
        contentLabel?.maximumNumberOfLines = 6
        contentLabel?.cell?.wraps = true
        contentLabel?.cell?.truncatesLastVisibleLine = true
        bgView?.addSubview(contentLabel!)
        
        // Hint label - subtle guidance
        hintLabel = NSTextField(labelWithString: "  ↑↓ Navigate   ·   ⏎ Paste   ·   ⌘⇧⌫ Delete   ·   Esc Cancel  ")
        hintLabel?.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        hintLabel?.textColor = NSColor(red: 0.45, green: 0.45, blue: 0.52, alpha: 1.0)
        hintLabel?.alignment = .center
        bgView?.addSubview(hintLabel!)
    }
    
    func calculateSize(for item: ClipboardItem) -> NSSize {
        switch item {
        case .text(let content):
            // Calculate height based on text length
            let lineCount = min(5, max(1, content.count / 60 + 1))
            let textHeight = CGFloat(lineCount) * 20
            let totalHeight = headerHeight + textHeight + footerHeight + 30
            return NSSize(width: maxWidth, height: min(250, max(120, totalHeight)))
            
        case .image:
            // Fixed size for image preview
            return NSSize(width: maxWidth, height: headerHeight + imageSize + footerHeight + 25)
        }
    }
    
    func layoutSubviews(for size: NSSize, isImage: Bool) {
        let width = size.width
        let height = size.height
        
        bgView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        
        // Title (top left)
        titleLabel?.frame = NSRect(x: padding, y: height - 32, width: 200, height: 24)
        
        // Position (top right)
        positionLabel?.frame = NSRect(x: width - 100, y: height - 32, width: 85, height: 24)
        
        // Separator
        separator?.frame = NSRect(x: padding, y: height - 42, width: width - padding * 2, height: 1)
        
        // Content area
        let contentTop = height - headerHeight
        let contentBottom = footerHeight
        let contentHeight = contentTop - contentBottom
        
        if isImage {
            // Image centered
            imageView?.frame = NSRect(
                x: (width - imageSize) / 2,
                y: contentBottom + (contentHeight - imageSize) / 2,
                width: imageSize,
                height: imageSize
            )
            imageView?.isHidden = false
            contentLabel?.isHidden = true
        } else {
            // Text
            contentLabel?.frame = NSRect(
                x: padding,
                y: contentBottom + 5,
                width: width - padding * 2,
                height: contentHeight - 10
            )
            contentLabel?.isHidden = false
            imageView?.isHidden = true
        }
        
        // Hint (bottom)
        hintLabel?.frame = NSRect(x: padding, y: 10, width: width - padding * 2, height: 18)
    }
    
    func show(item: ClipboardItem, position: Int, total: Int) {
        guard let panel = panel else { return }

        let newSize = calculateSize(for: item)
        layoutSubviews(for: newSize, isImage: item.isImage)
        updateContent(item: item, position: position, total: total)
        
        // Panel size and gap
        let panelWidth = newSize.width
        let panelHeight = newSize.height
        let gap: CGFloat = 5.0

        // Get global mouse location (origin = bottom-left of main display)
        let mouseLocation = NSEvent.mouseLocation

        // Find the screen which contains the mouse pointer
        let screenContainingMouse = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main!

        let screenFrame = screenContainingMouse.frame

        // Default: place panel centered horizontally ABOVE the cursor
        var originX = mouseLocation.x - (panelWidth / 2)
        var originY = mouseLocation.y + gap // above cursor (preferred)

        // If not enough space above the cursor, flip below the cursor
        if originY + panelHeight > screenFrame.maxY - gap {
            originY = mouseLocation.y - panelHeight - gap // below cursor
        }

        // Horizontal clamping so panel stays fully on screen
        originX = max(screenFrame.minX + gap, min(originX, screenFrame.maxX - panelWidth - gap))

        // Vertical clamping (in case flipping still collides)
        originY = max(screenFrame.minY + gap, min(originY, screenFrame.maxY - panelHeight - gap))

        panel.setFrame(NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight), display: true)

        // Fade in with content
        panel.alphaValue = 0
        contentLabel?.alphaValue = 0
        imageView?.alphaValue = 0
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
            contentLabel?.animator().alphaValue = 1.0
            imageView?.animator().alphaValue = 1.0
        })
    }
    
    func update(item: ClipboardItem, position: Int, total: Int) {
        guard let panel = panel else { return }
        
        let newSize = calculateSize(for: item)
        let currentFrame = panel.frame
        
        // Calculate new frame (keep centered at same position)
        let newFrame = NSRect(
            x: currentFrame.origin.x + (currentFrame.width - newSize.width) / 2,
            y: currentFrame.origin.y + (currentFrame.height - newSize.height) / 2,
            width: newSize.width,
            height: newSize.height
        )
        
        // Step 1: Fade out content
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            contentLabel?.animator().alphaValue = 0
            imageView?.animator().alphaValue = 0
        }) {
            // Step 2: Update content and resize panel
            self.updateContent(item: item, position: position, total: total)
            
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(newFrame, display: true)
            }) {
                // Step 3: Layout and fade in
                self.layoutSubviews(for: newSize, isImage: item.isImage)
                
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.12
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.contentLabel?.animator().alphaValue = 1.0
                    self.imageView?.animator().alphaValue = 1.0
                })
            }
        }
    }
    
    func updateContent(item: ClipboardItem, position: Int, total: Int) {
        positionLabel?.stringValue = "\(position) / \(total)"
        
        switch item {
        case .text(let content):
            var display = content.replacingOccurrences(of: "\n", with: "  ↵  ")
            display = display.replacingOccurrences(of: "\t", with: "  ")
            if display.count > 400 {
                display = String(display.prefix(400)) + "..."
            }
            contentLabel?.stringValue = display
            
        case .image(let image):
            imageView?.image = image
        }
    }
    
    func hide() {
        guard let panel = panel else { return }
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }) {
            panel.orderOut(nil)
            panel.alphaValue = 1.0
        }
    }
    
    /// Shows delete animation: content slides left while turning red
    func showDeleteAnimation(completion: @escaping () -> Void) {
        guard let bgView = bgView else {
            completion()
            return
        }
        
        // Create a red overlay layer for the delete effect
        let redOverlay = CALayer()
        redOverlay.backgroundColor = NSColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 0.0).cgColor
        redOverlay.frame = bgView.bounds
        redOverlay.cornerRadius = 14
        bgView.layer?.addSublayer(redOverlay)
        
        // Animate: slide left + fade to red + fade out
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            
            // Slide content left
            contentLabel?.animator().frame.origin.x -= 50
            imageView?.animator().frame.origin.x -= 50
            
            // Fade out content
            contentLabel?.animator().alphaValue = 0
            imageView?.animator().alphaValue = 0
        }) {
            // Flash red briefly
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            redOverlay.backgroundColor = NSColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 0.3).cgColor
            CATransaction.commit()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                // Fade red overlay out
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.1)
                redOverlay.backgroundColor = NSColor.clear.cgColor
                CATransaction.setCompletionBlock {
                    redOverlay.removeFromSuperlayer()
                    completion()
                }
                CATransaction.commit()
            }
        }
    }
    
    /// Shows new content after delete: slides in from right
    func showAfterDelete(item: ClipboardItem, position: Int, total: Int) {
        guard let panel = panel else { return }
        
        let newSize = calculateSize(for: item)
        let currentFrame = panel.frame
        
        // Resize panel to fit new content (keep same position)
        let newFrame = NSRect(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y + (currentFrame.height - newSize.height) / 2,
            width: newSize.width,
            height: newSize.height
        )
        panel.setFrame(newFrame, display: true)
        
        // Update internal layout
        layoutSubviews(for: newSize, isImage: item.isImage)
        updateContent(item: item, position: position, total: total)
        
        // Start content off-screen to the right
        let originalX = contentLabel?.frame.origin.x ?? 0
        let originalImageX = imageView?.frame.origin.x ?? 0
        
        contentLabel?.frame.origin.x = originalX + 50
        imageView?.frame.origin.x = originalImageX + 50
        contentLabel?.alphaValue = 0
        imageView?.alphaValue = 0
        
        // Animate: slide in from right
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            
            contentLabel?.animator().frame.origin.x = originalX
            imageView?.animator().frame.origin.x = originalImageX
            contentLabel?.animator().alphaValue = 1.0
            imageView?.animator().alphaValue = 1.0
        })
    }
}

// MARK: - Main Entry Point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
