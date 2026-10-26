// CatCursorLock — keep mouse/trackpad cursor movement, block other input.
// Control+Option+Command+L toggles lock/unlock, one toggle per physical L press.
// No automatic unlock timer and no display-sleep prevention assertion.
//
// This is a convenience lock, not a macOS security boundary: the event tap
// disappears if the process exits, and some system/multitouch gestures bypass it.

import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import Darwin

let agentLabel = "local.catcursorlock"

func stderrLine(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

struct OperationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func posixError(_ operation: String, code: Int32 = errno) -> OperationError {
    OperationError(message: "\(operation): \(String(cString: strerror(code))) (\(code))")
}

// The file must remain in place: unlinking it would let another process lock a
// different inode. The OS releases flock automatically when the process exits.
func acquireLock(_ name: String, wait: Bool) throws -> Int32? {
    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CatCursorLock", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent(name + ".lock").path
    let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else { throw posixError("Open lock file \(path)") }
    let operation = wait ? LOCK_EX : LOCK_EX | LOCK_NB
    while flock(fd, operation) != 0 {
        let code = errno
        if code == EINTR { continue }
        close(fd)
        if !wait && code == EWOULDBLOCK { return nil }
        throw posixError("Lock \(path)", code: code)
    }
    return fd
}

struct LaunchctlResult {
    let status: Int32
    let diagnostics: String
}

func runLaunchctl(_ args: [String], quiet: Bool = false) throws -> LaunchctlResult {
    let p = Process()
    let errorPipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardError = errorPipe
    if quiet { p.standardOutput = FileHandle.nullDevice }
    try p.run()
    // Drain before waiting so a full pipe cannot deadlock the child process.
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationReason == .exit else {
        throw OperationError(message: "launchctl \(args.joined(separator: " ")) terminated by signal \(p.terminationStatus)")
    }
    return LaunchctlResult(status: p.terminationStatus,
                           diagnostics: String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

func launchctlError(_ args: [String], result: LaunchctlResult) -> OperationError {
    let details = result.diagnostics.isEmpty ? "" : ": \(result.diagnostics)"
    return OperationError(message: "launchctl \(args.joined(separator: " ")) failed (code \(result.status))\(details)")
}

func requireLaunchctl(_ args: [String], quiet: Bool = false) throws {
    let result = try runLaunchctl(args, quiet: quiet)
    guard result.status == 0 else {
        throw launchctlError(args, result: result)
    }
}

func stopAgent() throws {
    let domain = "gui/\(getuid())"
    // Distinguish an absent service from an unavailable GUI login domain.
    try requireLaunchctl(["print", domain], quiet: true)
    let target = "\(domain)/\(agentLabel)"
    let args = ["bootout", target]
    let result = try runLaunchctl(args)
    // ESRCH means the service is already absent. Other failures must propagate.
    guard result.status == 0 || result.status == ESRCH else {
        throw launchctlError(args, result: result)
    }
}

func agentPlistPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return home + "/Library/LaunchAgents/\(agentLabel).plist"
}

func selfExecutablePath() -> String {
    // Use the executable inside the app bundle when available.
    return Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
}

func installAgent() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let exec = selfExecutablePath()
    let logPath = home + "/Library/Logs/catcursorlock.log"
    let plistPath = agentPlistPath()
    let plist: [String: Any] = [
        "Label": agentLabel,
        "ProgramArguments": [exec, "--agent"],
        "RunAtLoad": true,
        "KeepAlive": true,
        "StandardOutPath": logPath,
        "StandardErrorPath": logPath
    ]
    let fm = FileManager.default
    try fm.createDirectory(atPath: home + "/Library/LaunchAgents", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: home + "/Library/Logs", withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
    let uid = getuid()
    try stopAgent()
    try requireLaunchctl(["bootstrap", "gui/\(uid)", plistPath])
    try requireLaunchctl(["print", "gui/\(uid)/\(agentLabel)"], quiet: true)
    stderrLine("""
    [catcursorlock] LaunchAgent installed: \(plistPath)
    Toggle: Control+Option+Command+L. Log: \(logPath)
    Ensure Accessibility permission is enabled for the .app.
    If another instance is running, the agent waits for it to exit.
    """)
}

func uninstallAgent() throws {
    try stopAgent()
    let plistPath = agentPlistPath()
    do {
        try FileManager.default.removeItem(atPath: plistPath)
    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
        // Removing an already absent plist is successful and idempotent.
    }
    stderrLine("[catcursorlock] LaunchAgent uninstalled (plist removed: \(plistPath))")
}

func manageAgent(install: Bool) -> Int32 {
    do {
        guard let fd = try acquireLock("management", wait: false) else {
            throw OperationError(message: "Another install/uninstall operation is in progress; retry after it finishes.")
        }
        defer { close(fd) }
        if install { try installAgent() } else { try uninstallAgent() }
        return 0
    } catch {
        stderrLine("[catcursorlock] \(install ? "Install" : "Uninstall") failed: \(error.localizedDescription)")
        return 1
    }
}

func printHelp() {
    stderrLine("""
    CatCursorLock — keyboard/click/scroll lock with free pointer movement.

    Usage:
      catcursorlock                   Run in foreground; ⌃⌥⌘L toggles input lock.
      catcursorlock --install-agent   Install optional login LaunchAgent.
      catcursorlock --uninstall-agent Remove LaunchAgent.
      catcursorlock --help            Show help.

    Emergency exit: terminate the catcursorlock process or restart macOS.
    No unlock timer; on process exit the OS releases the event tap.
    """)
}

// MARK: - Command line switches
var runningAsAgent = false
if CommandLine.arguments.count > 1 {
    guard CommandLine.arguments.count == 2 else {
        stderrLine("[catcursorlock] Expected a single option (see --help)")
        exit(2)
    }
    switch CommandLine.arguments[1] {
    case "--install-agent":   exit(manageAgent(install: true))
    case "--uninstall-agent": exit(manageAgent(install: false))
    case "--agent":           runningAsAgent = true
    case "--help", "-h":      printHelp();      exit(0)
    default:
        stderrLine("[catcursorlock] Unknown option: \(CommandLine.arguments[1]) (see --help)")
        exit(2)
    }
}

// Acquire before checking permissions or creating a tap. Agent mode waits
// without intercepting input; ordinary duplicate launches exit immediately.
let instanceLockFD: Int32
do {
    if runningAsAgent {
        stderrLine("[catcursorlock] Waiting for the input-lock instance slot.")
    }
    guard let fd = try acquireLock("instance", wait: runningAsAgent) else {
        stderrLine("[catcursorlock] Another instance is already running.")
        exit(0)
    }
    instanceLockFD = fd // Keep the descriptor open for the lifetime of the tap.
} catch {
    stderrLine("[catcursorlock] Cannot acquire instance lock: \(error.localizedDescription)")
    exit(1)
}

// kVK_ANSI_L = 0x25 (37)
let toggleKeyCode: Int64 = 0x25

var locked = false
var eventTap: CFMachPort?
var statusItem: NSStatusItem?

// AppKit updates stay on the main thread and outside the event-tap callback.
@MainActor
func updateStatusIcon(locked: Bool) {
    guard let button = statusItem?.button else { return }
    let description = "CatCursorLock — \(locked ? "Locked" : "Unlocked")"
    let image = NSImage(systemSymbolName: locked ? "lock.fill" : "lock.open",
                        accessibilityDescription: description)
    image?.isTemplate = true
    button.image = image
    button.title = image == nil ? (locked ? "🔒" : "🔓") : ""
    button.toolTip = description + " (⌃⌥⌘L)"
    button.setAccessibilityLabel(description)
}

// No IOPMAssertion: allow macOS to sleep the display normally.
// Ignore repeated key-downs until the L key is actually released.
var toggleKeyHeld = false

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

// MARK: - Detect Control+Option+Command+L
func isToggleCombo(_ event: CGEvent) -> Bool {
    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    let f = event.flags
    return keycode == toggleKeyCode
        && f.contains(.maskControl)
        && f.contains(.maskAlternate)
        && f.contains(.maskCommand)
}

// MARK: - Input event callback
let eventCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // This can lose a key-up; reset the latch so the next physical press works.
        toggleKeyHeld = false
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return nil
    }

    // Re-arm only after physical key release, even if modifier keys were released first.
    if type == .keyUp && event.getIntegerValueField(.keyboardEventKeycode) == toggleKeyCode {
        if toggleKeyHeld {
            toggleKeyHeld = false
            return nil // Don't leak the matching hotkey key-up to the focused app.
        }
    }

    if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == toggleKeyCode {
        // If modifiers are released before L, its autorepeats must not type text.
        if toggleKeyHeld { return nil }
        if isToggleCombo(event) {
            // Autorepeat events are not new physical presses.
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat {
                toggleKeyHeld = true
                locked.toggle()
                let newState = locked
                DispatchQueue.main.async { updateStatusIcon(locked: newState) }
                log("[catcursorlock] \(locked ? "LOCKED" : "UNLOCKED")")
            }
            return nil // Consume the hotkey, including any repeats.
        }
    }

    if locked {
        // Simple pointer movement passes without interception (not in the event tap mask).
        // A pressed button produces dragged events rather than mouseMoved. Convert
        // those events to movement, preserving pointer motion without app drag actions.
        switch type {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            event.type = .mouseMoved
            return Unmanaged.passUnretained(event)
        default:
            return nil // Block keys, modifiers, mouse buttons and scrolling.
        }
    }

    return Unmanaged.passUnretained(event)
}

// Accessory mode provides a menu-bar indicator without a Dock icon or window.
// Command-line management and waiting agents never reach this initialization.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// MARK: - Check Accessibility permission
let promptOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
if !AXIsProcessTrustedWithOptions(promptOpts) {
    log("""
    [catcursorlock] Accessibility permission is required.
    System Settings > Privacy & Security > Accessibility:
    authorize this app, then relaunch it.
    """)
    // The permission prompt may be open; try creating the tap below.
}

// MARK: - Event tap configuration
let types: [CGEventType] = [
    .keyDown, .keyUp, .flagsChanged,
    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
    .leftMouseDragged, .rightMouseDragged,
    .scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged
]
var mask: CGEventMask = 0
for t in types { mask |= (CGEventMask(1) << CGEventMask(t.rawValue)) }

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,            // Allows suppressing events
    eventsOfInterest: mask,
    callback: eventCallback,
    userInfo: nil
) else {
    log("""
    [catcursorlock] Failed to create an event tap.
    Enable Accessibility permission in System Settings, then relaunch.
    """)
    exit(1)
}
eventTap = tap

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)

// Keep the item for the lifetime of the active instance. It is an indicator;
// the keyboard shortcut remains the control for changing lock state.
// Explicitly enter the main actor even with synchronous top-level code.
DispatchQueue.main.async {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    updateStatusIcon(locked: locked)
}
CGEvent.tapEnable(tap: tap, enable: true)

// MARK: - Cleanup on exit
func cleanup() {
    if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
}
signal(SIGINT)  { _ in cleanup(); exit(0) }
signal(SIGTERM) { _ in cleanup(); exit(0) }

log("""
[catcursorlock] Running. Toggle input lock with Control+Option+Command+L.
    Cursor movement allowed; buttons, scrolling and keyboard blocked while locked.
    No automatic unlock timer. The display follows ordinary macOS sleep settings.
    Emergency exit: Ctrl+C in foreground, or terminate the catcursorlock process.
""")

app.run()
