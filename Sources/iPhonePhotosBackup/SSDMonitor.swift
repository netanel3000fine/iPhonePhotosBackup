import Cocoa
import Combine

@MainActor
class SSDMonitor: ObservableObject {
    @Published var isSSDConnected = false
    @Published var ssdURL: URL? = nil
    
    var onStatusChanged: (() -> Void)?
    
    init() {
        checkConnectedVolumes()
        setupNotifications()
    }
    
    var targetSSDName: String {
        UserDefaults.standard.string(forKey: "targetSSDName") ?? "BackupSSD"
    }
    
    func checkConnectedVolumes() {
        let target = targetSSDName.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty {
            updateStatus(connected: false, url: nil)
            return
        }
        
        let keys: [URLResourceKey] = [.volumeNameKey]
        guard let volumeURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) else {
            updateStatus(connected: false, url: nil)
            return
        }
        
        for url in volumeURLs {
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                if let volumeName = values.volumeName, volumeName == target {
                    updateStatus(connected: true, url: url)
                    return
                }
            } catch {
                continue
            }
        }
        updateStatus(connected: false, url: nil)
    }
    
    private func updateStatus(connected: Bool, url: URL?) {
        DispatchQueue.main.async {
            if self.isSSDConnected != connected || self.ssdURL != url {
                self.isSSDConnected = connected
                self.ssdURL = url
                self.onStatusChanged?()
            }
        }
    }
    
    private func setupNotifications() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(volumeMounted(_:)), name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumeUnmounted(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
    }
    
    @objc private func volumeMounted(_ notification: Notification) {
        checkConnectedVolumes()
    }
    
    @objc private func volumeUnmounted(_ notification: Notification) {
        checkConnectedVolumes()
    }
}
