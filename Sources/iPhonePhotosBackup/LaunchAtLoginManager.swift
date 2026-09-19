import Foundation
import ServiceManagement
import Darwin

/// Manages the automatic launch of iPhonePhotosBackup when an iPhone/device is connected via USB.
/// Uses a launchd LaunchAgent with IOKit matching (`com.apple.iokit.matching`) so macOS launches
/// the app strictly when a USB device is attached, rather than on every Mac startup/login.
@MainActor
final class LaunchAtLoginManager {

    static let shared = LaunchAtLoginManager()

    private let userDefaultsKey = "autoLaunchOnDeviceConnect"
    private let agentLabel = "com.user.iPhonePhotosBackup.usb-trigger"

    private var launchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    private var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(agentLabel).plist")
    }

    private init() {
        // Ensure any legacy SMAppService login item is cleaned up on init
        cleanupLegacyLoginItem()
    }

    /// Whether USB auto-launch is currently enabled.
    var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: userDefaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: userDefaultsKey)
        }
        // Default to enabled if the plist exists, or true by default
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Unregisters any legacy macOS Login Item previously set via SMAppService.
    func cleanupLegacyLoginItem() {
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status == .enabled {
                do {
                    try SMAppService.mainApp.unregister()
                    print("LaunchAtLoginManager: Unregistered legacy SMAppService login item.")
                } catch {
                    print("LaunchAtLoginManager: Failed to unregister legacy login item: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Configures or removes the USB trigger LaunchAgent plist and updates launchd.
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: userDefaultsKey)
        cleanupLegacyLoginItem()

        if enabled {
            installUSBLaunchAgent()
        } else {
            removeUSBLaunchAgent()
        }
    }

    // MARK: - LaunchAgent Management

    private func installUSBLaunchAgent() {
        do {
            try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)

            let bundleID = Bundle.main.bundleIdentifier ?? "com.user.iPhonePhotosBackup"
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(agentLabel)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>/usr/bin/open</string>
                    <string>-b</string>
                    <string>\(bundleID)</string>
                </array>
                <key>LaunchEvents</key>
                <dict>
                    <key>com.apple.iokit.matching</key>
                    <dict>
                        <key>com.apple.device-attach-apple</key>
                        <dict>
                            <key>idVendor</key>
                            <integer>1452</integer>
                            <key>IOProviderClass</key>
                            <string>IOUSBHostDevice</string>
                            <key>IOMatchLaunchStream</key>
                            <true/>
                        </dict>
                    </dict>
                </dict>
            </dict>
            </plist>
            """

            try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)

            let uid = getuid()
            let serviceTarget = "gui/\(uid)/\(agentLabel)"
            let domainTarget = "gui/\(uid)"

            // Unload if already loaded to ensure fresh registration
            _ = runLaunchctl(["bootout", serviceTarget])

            // Bootstrap into current user GUI domain
            let bootResult = runLaunchctl(["bootstrap", domainTarget, plistURL.path])
            if bootResult.status != 0 {
                // Fallback to legacy launchctl load
                _ = runLaunchctl(["load", "-w", plistURL.path])
            }
            print("LaunchAtLoginManager: Successfully installed USB auto-launch agent.")
        } catch {
            print("LaunchAtLoginManager: Failed to install USB launch agent: \(error.localizedDescription)")
        }
    }

    private func removeUSBLaunchAgent() {
        let uid = getuid()
        let serviceTarget = "gui/\(uid)/\(agentLabel)"

        _ = runLaunchctl(["bootout", serviceTarget])
        _ = runLaunchctl(["unload", "-w", plistURL.path])

        if FileManager.default.fileExists(atPath: plistURL.path) {
            try? FileManager.default.removeItem(at: plistURL)
        }
        print("LaunchAtLoginManager: Removed USB auto-launch agent.")
    }

    @discardableResult
    private func runLaunchctl(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, out)
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}

