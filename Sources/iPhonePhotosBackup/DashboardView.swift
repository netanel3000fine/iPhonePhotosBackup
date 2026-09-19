import SwiftUI
import AppKit
import ImageCaptureCore
import ImageIO
import Quartz
import NetFS
import AVFoundation
import AVKit

private extension Font {
  static func dashboardText(
    size: CGFloat,
    weight: Font.Weight = .regular,
    design: Font.Design = .default
  ) -> Font {
    .system(size: size + 1, weight: weight, design: design)
  }

  static func dashboardText(_ style: Font.TextStyle, design: Font.Design = .default) -> Font {
    let size: CGFloat
    switch style {
    case .largeTitle: size = 26
    case .title: size = 22
    case .title2: size = 22
    case .title3: size = 20
    case .headline, .body: size = 13
    case .subheadline, .callout: size = 12
    case .footnote, .caption: size = 11
    case .caption2: size = 10
    @unknown default: size = 13
    }
    return dashboardText(size: size, design: design)
  }

  static var dashboardLargeTitle: Font { dashboardText(size: 26) }
  static var dashboardTitle2: Font { dashboardText(size: 22) }
  static var dashboardTitle3: Font { dashboardText(size: 20) }
  static var dashboardHeadline: Font { dashboardText(size: 13) }
  static var dashboardSubheadline: Font { dashboardText(size: 12) }
  static var dashboardBody: Font { dashboardText(size: 13) }
  static var dashboardCaption: Font { dashboardText(size: 11) }
  static var dashboardCaption2: Font { dashboardText(size: 10) }
}

// MARK: - Tab Identifiers

enum DashboardTab: String, CaseIterable {
    case status   = "Sync Status"
    case gallery  = "Phone Gallery"
    case review   = "Quick Swiping"
    case settings = "Settings"
    
    var icon: String {
        switch self {
        case .status:   return "arrow.triangle.2.circlepath"
        case .gallery:  return "photo.on.rectangle"
        case .review:   return "rectangle.portrait.and.arrow.forward"
        case .settings: return "gearshape"
        }
    }
}

/// A small bridge that lets native AppKit controls navigate the SwiftUI dashboard.
@MainActor
final class DashboardNavigation: ObservableObject {
    @Published var isSidebarVisible = false

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }
}

enum BackupDestinationKind {
    case none
    case localFolder
    case externalVolume
    case networkVolume
    case iCloudDrive
    case cloudStorage

    var systemImage: String {
        switch self {
        case .none:            return "externaldrive"
        case .localFolder:     return "folder.fill"
        case .externalVolume:  return "externaldrive.fill"
        case .networkVolume:   return "externaldrive.connected.to.line.below.fill"
        case .iCloudDrive:     return "icloud.fill"
        case .cloudStorage:    return "cloud.fill"
        }
    }

    static func detect(for url: URL?) -> BackupDestinationKind {
        guard let url else { return .none }
        let path = url.standardizedFileURL.path

        if path.contains("/Library/Mobile Documents/com~apple~CloudDocs") {
            return .iCloudDrive
        }
        if path.contains("/Library/CloudStorage/") {
            return .cloudStorage
        }

        if path.hasPrefix("/Volumes/") {
            let components = (path as NSString).pathComponents
            guard components.count > 2 else { return .externalVolume }
            let volumeRoot = URL(fileURLWithPath: "/Volumes/\(components[2])")
            if let values = try? volumeRoot.resourceValues(forKeys: [.volumeIsLocalKey]),
               values.volumeIsLocal == false {
                return .networkVolume
            }
            return .externalVolume
        }

        return .localFolder
    }
}

enum GalleryFilter: String, CaseIterable, Sendable {
    case notBackedUp = "New"
    case backedUp    = "Backed Up"
    case today       = "Today"
    case thisWeek    = "This Week"
    case thisMonth   = "This Month"

    var icon: String {
        switch self {
        case .notBackedUp: return "arrow.triangle.2.circlepath"
        case .backedUp:    return "checkmark.circle.fill"
        case .today:       return "calendar"
        case .thisWeek:    return "calendar.badge.clock"
        case .thisMonth:   return "calendar.circle"
        }
    }
}

/// The review queue deliberately has its own media filter. It never changes the
/// user's backup policy in Settings; it only controls what is shown for review.
enum ReviewMediaFilter: String, CaseIterable, Sendable {
    case all = "All"
    case photos = "Photos"
    case videos = "Videos"

    var icon: String {
        switch self {
        case .all: return "rectangle.stack"
        case .photos: return "photo"
        case .videos: return "film"
        }
    }
}

/// Date scopes mirror the gallery and intentionally default the reviewer to
/// the most useful, least overwhelming session: media captured today.
enum ReviewDateFilter: String, CaseIterable, Sendable {
    case today = "Today"
    case thisWeek = "This Week"
    case thisMonth = "This Month"

    var icon: String {
        switch self {
        case .today: return "calendar"
        case .thisWeek: return "calendar.badge.clock"
        case .thisMonth: return "calendar.circle"
        }
    }
}

private enum ReviewDecision: Equatable {
    case keep
    case delete
}

struct GalleryItem: Identifiable, Equatable {
    let id: String
    let name: String
    let file: ICCameraFile

    static func == (lhs: GalleryItem, rhs: GalleryItem) -> Bool {
        lhs.id == rhs.id
    }
}

/// A value-only camera-file snapshot. It lets gallery and review filtering run
/// away from the main actor while the original ImageCapture objects remain
/// safely owned by the UI.
private struct CameraFileFilterSnapshot: Sendable {
    var index: Int
    var id: String
    var name: String
    var isPhoto: Bool
    var isVideo: Bool
    var captureDate: Date?
    var isBackedUp: Bool
}

private struct ReviewHistoryEntry {
    let item: GalleryItem
    let decision: ReviewDecision
}

private enum PillDeviceStatus: Equatable {
    case disconnected
    case waiting(readyCount: Int, unreadyCount: Int)
    case unlockNeeded(readyCount: Int, unreadyCount: Int)
    case ready(count: Int)
    case scanning
    case syncing
    case paused

    var isCycleNeeded: Bool {
        switch self {
        case .waiting, .unlockNeeded:
            return true
        default:
            return false
        }
    }
}

private struct ConnectionStatusPill: View {
    let status: PillDeviceStatus
    @AppStorage("appLanguage") private var appLanguage: String = "en"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var phaseIndex: Int = 0
    @State private var timerTask: Task<Void, Never>? = nil
    @State private var isPulsing: Bool = false

    private var isConnected: Bool {
        switch status {
        case .ready, .scanning, .syncing, .paused:
            return true
        case .waiting(let readyCount, _), .unlockNeeded(let readyCount, _):
            return readyCount > 0
        case .disconnected:
            return false
        }
    }

    private var dotColor: Color {
        switch status {
        case .ready:
            return .green
        case .scanning, .syncing:
            return .blue
        case .paused:
            return .orange
        case .waiting, .unlockNeeded:
            return .orange
        case .disconnected:
            return Color(red: 0.9, green: 0.35, blue: 0.25)
        }
    }

    private var isBlinking: Bool {
        switch status {
        case .ready, .paused, .disconnected:
            return false
        case .scanning, .syncing, .waiting, .unlockNeeded:
            return true
        }
    }

    private var displayedText: String {
        switch status {
        case .disconnected:
            return l10n("Disconnected", lang: appLanguage)
        case .ready(let count):
            if count <= 1 {
                return l10n("Connected", lang: appLanguage)
            } else {
                return String(format: l10n("%d Devices Connected", lang: appLanguage), count)
            }
        case .scanning:
            return l10n("Scanning...", lang: appLanguage)
        case .syncing:
            return l10n("Syncing...", lang: appLanguage)
        case .paused:
            return l10n("Sync Paused", lang: appLanguage)
        case .unlockNeeded(let readyCount, let unreadyCount):
            if readyCount == 0 {
                switch phaseIndex % 3 {
                case 0:
                    return l10n("Unlock Device", lang: appLanguage)
                case 1:
                    return l10n("Try unlocking device", lang: appLanguage)
                case 2:
                    return l10n("Try reconnecting phone", lang: appLanguage)
                default:
                    return l10n("Unlock Device", lang: appLanguage)
                }
            } else {
                switch phaseIndex % 3 {
                case 0:
                    return String(format: l10n("%d Ready, %d Need Unlock", lang: appLanguage), readyCount, unreadyCount)
                case 1:
                    return l10n("Unlock 2nd Device", lang: appLanguage)
                case 2:
                    return l10n("Try unlocking device", lang: appLanguage)
                default:
                    return l10n("Unlock 2nd Device", lang: appLanguage)
                }
            }
        case .waiting(let readyCount, let unreadyCount):
            if readyCount == 0 {
                switch phaseIndex % 3 {
                case 0:
                    return l10n("Waiting", lang: appLanguage)
                case 1:
                    return l10n("Try reconnecting phone", lang: appLanguage)
                case 2:
                    return l10n("Try unlocking device", lang: appLanguage)
                default:
                    return l10n("Waiting", lang: appLanguage)
                }
            } else {
                switch phaseIndex % 3 {
                case 0:
                    return String(format: l10n("%d Ready, %d Waiting", lang: appLanguage), readyCount, unreadyCount)
                case 1:
                    return l10n("Try reconnecting phone", lang: appLanguage)
                case 2:
                    return l10n("Try unlocking device", lang: appLanguage)
                default:
                    return l10n("Waiting", lang: appLanguage)
                }
            }
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .opacity(isBlinking && !reduceMotion ? (isPulsing ? 0.35 : 1.0) : 1.0)
                .animation(
                    isBlinking && !reduceMotion
                        ? Animation.easeInOut(duration: 0.85).repeatForever(autoreverses: true)
                        : .default,
                    value: isPulsing
                )

            Text(displayedText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 8)
        .animation(.smooth(duration: 0.35), value: displayedText)
        .animation(.smooth(duration: 0.35), value: dotColor)
        .onAppear {
            isPulsing = true
            startCycleTimerIfNeeded()
        }
        .onDisappear {
            timerTask?.cancel()
            timerTask = nil
        }
        .onChange(of: status) { newStatus in
            if newStatus.isCycleNeeded {
                startCycleTimerIfNeeded()
            } else {
                timerTask?.cancel()
                timerTask = nil
                phaseIndex = 0
            }
        }
    }

    private func startCycleTimerIfNeeded() {
        guard timerTask == nil else { return }
        guard status.isCycleNeeded else { return }
        timerTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.35)) {
                    phaseIndex += 1
                }
            }
        }
    }
}


/// A small, focused visual acknowledgement for a source or destination becoming ready.
/// It deliberately runs only on a state transition and honours the system motion setting.
private struct AvailabilityHalo: View {
    let isAvailable: Bool
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false
    @State private var pulse = false

    var body: some View {
        Circle()
            .stroke(color.opacity(0.65), lineWidth: 1.5)
            .scaleEffect(pulse ? 1.65 : 1.0)
            .opacity(isAnimating ? (pulse ? 0 : 0.65) : 0)
            .onChange(of: isAvailable) { available in
                guard available, !reduceMotion else { return }
                pulse = false
                isAnimating = true
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.7)) {
                        pulse = true
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) {
                    pulse = false
                    isAnimating = false
                }
            }
    }
}

/// The connecting indicator is intentionally local to the phone glyph: it gives
/// feedback without moving the dashboard layout or competing with backup progress.
private struct SessionStatusGlyph: View {
    let icon: String
    let color: Color
    let isConnecting: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isConnecting && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    let cycle = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1.35) / 1.35
                    Circle()
                        .stroke(color.opacity(0.52 * (1 - cycle)), lineWidth: 1.25)
                        .scaleEffect(0.9 + cycle * 0.65)
                    Circle()
                        .stroke(color.opacity(0.28 * (1 - cycle)), lineWidth: 1)
                        .scaleEffect(0.9 + ((cycle + 0.5).truncatingRemainder(dividingBy: 1)) * 0.65)
                }
            }
            Circle().fill(color.opacity(0.15)).frame(width: 42, height: 42)
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .symbolEffect(
                    .variableColor.iterative.reversing,
                    options: .repeating,
                    isActive: isConnecting && !reduceMotion
                )
        }
        .frame(width: 42, height: 42)
    }
}

// MARK: - Main View

@MainActor
struct DashboardView: View {
    @ObservedObject var ssdMonitor:    SSDMonitor
    @ObservedObject var deviceMonitor: DeviceMonitor
    @ObservedObject var backupEngine:  BackupEngine
    @ObservedObject var navigation: DashboardNavigation
    
    // Reference to AppDelegate so we can call resolvedBackupDestination()
    weak var appDelegate: AppDelegate?
    
    var onClose:        () -> Void
    var onForceBackup:  (Bool) -> Void
    var onChooseFolder: () -> Void
    var onReconnect:    () -> Void
    
    @AppStorage("defaultLaunchTab") private var defaultLaunchTab: String = DashboardTab.status.rawValue
    @State private var hasAppliedInitialTab = false
    @State private var selectedTab: DashboardTab = .status
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var hoveredTab: DashboardTab? = nil
    @State private var storageInfo: String = ""
    @State private var galleryFilter: GalleryFilter = .notBackedUp
    @State private var showErrorAlert = false
    @State private var alertErrorTitle = "Notice"
    @State private var alertErrorMessage = ""
    @State private var timerTick = false       // toggled every second to refresh elapsed / ETA
    @State private var isReconnecting = false  // shows spinner briefly after Reconnect tap
    @Namespace private var tabNamespace
    @Namespace private var filterSegmentNamespace
    @Namespace private var mediaTypeSegmentNamespace
    @Namespace private var languageSegmentNamespace
    @Namespace private var reviewFilterSegmentNamespace
    @Namespace private var reviewDateFilterSegmentNamespace

    // Gallery async loading
    @State private var galleryFiles: [GalleryItem] = []
    @State private var galleryIsLoading = false
    @State private var galleryLoadTask: Task<Void, Never>? = nil
    @State private var galleryDebounceTask: Task<Void, Never>? = nil
    @State private var tabActivationTask: Task<Void, Never>? = nil
    @State private var galleryReloadToken = UUID()
    @State private var selectedGalleryDeviceID: String = ""
    @State private var selectedPreviewItem: GalleryItem? = nil
    @StateObject private var previewManager = PreviewManager()
    @State private var itemToDelete: GalleryItem? = nil
    @State private var hoveredItemID: String? = nil

    // Swipe-review queue. Decisions are local to this session: keeping an item
    // simply removes it from the deck, while delete choices collect until the
    // end-of-session confirmation instead of interrupting every swipe.
    @State private var reviewFiles: [GalleryItem] = []
    @State private var reviewIsLoading = false
    @State private var reviewLoadTask: Task<Void, Never>? = nil
    @State private var reviewReloadToken = UUID()
    @State private var reviewMediaFilter: ReviewMediaFilter = .all
    @State private var reviewDateFilter: ReviewDateFilter = .today
    @State private var dismissedReviewItemIDs = Set<String>()
    @State private var queuedReviewDeletionCandidates: [String: GalleryItem] = [:]
    @State private var pendingReviewDeletions: [String: GalleryItem] = [:]
    @State private var isReviewDeletionConfirmationPresented = false
    @State private var reviewLastDecision: ReviewDecision? = nil
    @State private var isReviewSummaryPresented = false
    @State private var reviewKeptItemCount = 0
    @State private var reviewHistory: [ReviewHistoryEntry] = []
    @State private var isReviewDiscardAlertPresented = false
    @State private var recentDeletionsToRetry: [GalleryItem] = []
    @State private var isRetryRecentDeletionsAlertPresented = false

    // New-device prompt sheet
    @State private var showNewDeviceSheet = false
    @State private var newDeviceName: String = ""

    // Path-change prompt sheet
    @State private var showPathChangeSheet = false
    @State private var pathChangeDeviceID: String = ""

    // Quick Swiping prompt sheet
    @State private var showQuickSwipePromptSheet = false
    @State private var quickSwipePromptCameraName: String = ""
    @State private var quickSwipePromptItemCount: Int = 0

    // Mirrors AppDelegate.destinationVersion — forces re-render when destination changes
    @State private var destinationVersion: Int = 0
    
    // Settings state linked to UserDefaults via AppStorage
    @AppStorage("autoBackupActive") var autoBackupActive: Bool = true
    @AppStorage("promptQuickSwipeBeforeSync") var promptQuickSwipeBeforeSync: Bool = true
    @AppStorage("backupMediaType") var backupMediaType: Int = 0 // 0 = All, 1 = Photos Only, 2 = Videos Only
    @AppStorage("openFolderAfterBackup") var openFolderAfterBackup: Bool = true
    @AppStorage("deleteAfterBackup") var deleteAfterBackup: Bool = false
    @AppStorage("organizeByYear") var organizeByYear: Bool = true
    @AppStorage("organizeByMonth") var organizeByMonth: Bool = true
    @AppStorage("skipEditedDuplicates") var skipEditedDuplicates: Bool = false
    @AppStorage("appAppearanceV2") private var appAppearanceRaw: String = AppAppearance.liquidGlass.rawValue
    @AppStorage("themeColor") private var themeColor: ThemeColor = .default
    @AppStorage("appLanguage") private var appLanguage: String = "en"
    @State private var launchAtLogin: Bool = LaunchAtLoginManager.shared.isEnabled
    @State private var unlockedDeviceIDs: Set<String> = []
    @State private var deviceToForget: SettingsDeviceItem? = nil
    @State private var showForgetDeviceAlert: Bool = false
    @State private var showDeleteAfterBackupWarning = false
    @State private var settingsGuideIsVisible = false
    @State private var settingsGuideStep = 0
    @State private var settingsGuideTask: Task<Void, Never>? = nil
    /// Latched per-device subtitle — once an error is shown it stays until the device is ready.
    @State private var stickyDeviceStatus: [String: String] = [:]
    /// Which device ID (if any) is currently showing the connection tips.
    @State private var hoveredDeviceTipsID: String? = nil
    /// Prevents Image Capture's per-device callbacks from flashing a terminal
    /// reconnect error while another connection attempt is about to begin.
    @State private var syncErrorIsConfirmed = false
    @State private var syncErrorConfirmationTask: Task<Void, Never>? = nil

    private var appAppearance: AppAppearance {
        AppAppearance(rawValue: appAppearanceRaw) ?? .liquidGlass
    }

    private let deviceHelpText = "CHECK ON YOUR PHONE\n\n🔓 Unlock your phone — the screen must be on and unlocked.\n\n👆 On iPhone, tap \"Trust\" if prompted. On Android, choose File Transfer or Photo Transfer from the USB notification.\n\n🔌 Re-plug the USB cable and wait a couple of seconds.\n\n✅ The app will reconnect automatically once access is allowed."

    private var currentTheme: AppTheme {
        AppTheme.theme(for: appAppearance)
    }

    private var activeBackupDestination: URL? {
        appDelegate?.resolvedBackupDestination(for: deviceMonitor.connectedDeviceID)
    }

    private var readyGalleryDevices: [ConnectedDevice] {
        deviceMonitor.connectedDevices.filter { $0.isReady && $0.isCatalogLoaded }
    }

    private var selectedGalleryDevice: ConnectedDevice? {
        readyGalleryDevices.first { $0.id == selectedGalleryDeviceID } ?? readyGalleryDevices.first
    }

    private var selectedGalleryDestination: URL? {
        guard let device = selectedGalleryDevice else { return nil }
        return appDelegate?.resolvedBackupDestination(for: device.id)
    }

    private var isSelectedGalleryDestinationAvailable: Bool {
        isDestinationAvailable(selectedGalleryDestination)
    }

    private var readyDevicesForManualSync: [ConnectedDevice] {
        guard let appDelegate else { return [] }
        return readyGalleryDevices.filter { device in
            let dest = appDelegate.resolvedBackupDestination(for: device.id)
            return dest != nil && isDestinationAvailable(dest)
        }
    }

    private var currentPillStatus: PillDeviceStatus {
        if deviceMonitor.connectedDevices.isEmpty {
            return .disconnected
        }

        switch backupEngine.state {
        case .scanning:
            return .scanning
        case .copying:
            return .syncing
        case .paused:
            return .paused
        default:
            break
        }

        let all = deviceMonitor.connectedDevices
        let readyCount = all.filter { $0.isReady }.count
        let unready = all.filter { !$0.isReady }

        if unready.isEmpty {
            return .ready(count: readyCount)
        }

        let hasUnlockIssue = unready.contains {
            $0.isAccessRestricted || $0.sessionError.localizedCaseInsensitiveContains("unlock")
        }

        if hasUnlockIssue {
            return .unlockNeeded(readyCount: readyCount, unreadyCount: unready.count)
        } else {
            return .waiting(readyCount: readyCount, unreadyCount: unready.count)
        }
    }

    @ViewBuilder
    private var connectionStatusPillView: some View {
        ConnectionStatusPill(status: currentPillStatus)
    }


    struct SettingsDeviceItem: Identifiable {
        let id: String
        let name: String
        let isConnected: Bool
    }

    private var settingsDevices: [SettingsDeviceItem] {
        var items: [SettingsDeviceItem] = []
        var seenNames = Set<String>()
        
        for dev in deviceMonitor.connectedDevices {
            guard !seenNames.contains(dev.name) else { continue }
            seenNames.insert(dev.name)
            items.append(SettingsDeviceItem(id: dev.id, name: dev.name, isConnected: true))
        }
        
        for entry in deviceMonitor.deviceHistory {
            guard !seenNames.contains(entry.name) else { continue }
            seenNames.insert(entry.name)
            items.append(SettingsDeviceItem(id: entry.id, name: entry.name, isConnected: false))
        }
        
        return items
    }

    private func isDestinationAvailable(_ url: URL?) -> Bool {
        guard let url else { return false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Attempts to reconnect the SMB share automatically using native macOS NetFS APIs in the background.
    private func reconnectSMBShare(for targetDeviceID: String? = nil) {
        // `connectedDeviceID` is set only after a camera session opens. A single
        // locked/unavailable phone therefore has no active ID yet, even though its
        // destination and SMB URL are already known. Use the discovered device ID
        // so the Finder reconnect action works before the phone is fully ready.
        let deviceID = targetDeviceID
            ?? deviceMonitor.connectedDevices.first?.id
            ?? deviceMonitor.connectedDeviceID
        
        // 1. If we recorded an exact SMB network URL (e.g. smb://server/share), attempt silent background mount natively
        if let smbURL = appDelegate?.resolvedSMBURL(for: deviceID), !smbURL.isEmpty, let url = URL(string: smbURL) {
            DispatchQueue.global(qos: .userInitiated).async {
                var mountPoints: Unmanaged<CFArray>?
                let status = NetFSMountURLSync(
                    url as CFURL,
                    nil, // mountPath (default /Volumes)
                    nil, // username (automatic from keychain)
                    nil, // password (automatic from keychain)
                    nil, // openOptions
                    nil, // mountOptions
                    &mountPoints
                )
                
                if status == 0 {
                    // Successfully mounted! Re-trigger check in SSD monitor
                    DispatchQueue.main.async {
                        self.appDelegate?.triggerSSDCheck()
                    }
                    return
                }
                
                // Fallback to dialog if native background mount failed
                DispatchQueue.main.async {
                    openFolderInFinder(for: deviceID)
                }
            }
        } else {
            openFolderInFinder(for: deviceID)
        }
    }

    /// Fallback: opens Finder's Connect to Server dialog so the user can pick the SMB server.
    private func openFolderInFinder(for deviceID: String) {
        let scriptSource = """
        tell application "Finder" to activate
        tell application "System Events"
            keystroke "k" using {command down}
        end tell
        """
        if let script = NSAppleScript(source: scriptSource) {
            var err: NSDictionary?
            script.executeAndReturnError(&err)
        }
    }

    var body: some View { dashboardWithSheets }

    private var dashboardBase: AnyView {
        AnyView(
            dashboardContent
                .frame(
                    minWidth: appAppearance == .liquidGlass ? 680 : 480,
                    idealWidth: appAppearance == .liquidGlass ? 760 : (appAppearance.isModernDesign ? 600 : 620),
                    maxWidth: .infinity,
                    minHeight: 600,
                    idealHeight: appAppearance == .liquidGlass ? 680 : (appAppearance.isModernDesign ? 940 : 910),
                    maxHeight: .infinity
                )
                .background(WindowTransparencyConfigurator(appearance: appAppearance))
        )
    }

    private var dashboardWithDeleteDialog: AnyView {
        let singleDeleteDialog = dashboardBase.confirmationDialog(
                "Delete \(itemToDelete?.name ?? "file")?",
                isPresented: Binding(
                    get: { itemToDelete != nil },
                    set: { if !$0 { itemToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Permanently", role: .destructive) {
                    if let item = itemToDelete {
                        deviceMonitor.deleteFileFromDevice(item.file)
                    }
                    itemToDelete = nil
                    selectedPreviewItem = nil
                }
                Button("Cancel", role: .cancel) {
                    itemToDelete = nil
                }
            } message: {
                Text(l10n("This will permanently delete this file from your phone's camera library. Note: If iCloud Photos is enabled, iOS blocks USB deletion.", lang: appLanguage))
            }

        let count = queuedReviewDeletionCandidates.count
        let dialogTitle = count == 1 ? l10n("Delete 1 item?", lang: appLanguage) : String(format: l10n("Delete %d items?", lang: appLanguage), count)
        let deleteButtonTitle = count == 1 ? l10n("Delete 1 Item", lang: appLanguage) : String(format: l10n("Delete %d Items", lang: appLanguage), count)

        return AnyView(
            singleDeleteDialog.confirmationDialog(
                dialogTitle,
                isPresented: $isReviewDeletionConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button(deleteButtonTitle, role: .destructive) {
                    deleteQueuedReviewItems()
                }
                Button(l10n("Cancel", lang: appLanguage), role: .cancel) { }
                Button(l10n("Keep All & Discard Batch", lang: appLanguage), role: .destructive) {
                    keepQueuedReviewItems()
                }
            } message: {
                Text(l10n("These items will be permanently deleted from your phone's camera library. Note: If iCloud Photos is enabled, iOS blocks USB deletion.", lang: appLanguage))
            }
        )
    }

    private var dashboardWithLifecycle: AnyView {
        let lifecycleRoot = dashboardWithDeleteDialog
            .onAppear { handleDashboardAppear() }
            .onDisappear {
                syncErrorConfirmationTask?.cancel()
                galleryLoadTask?.cancel()
                reviewLoadTask?.cancel()
                tabActivationTask?.cancel()
                settingsGuideTask?.cancel()
            }
            .onChange(of: ssdMonitor.ssdURL) { updateStorageInfo() }
            .onChange(of: ssdMonitor.isSSDConnected) { updateStorageInfo() }
            .onChange(of: selectedTab) { handleSelectedTabChange() }
            .onChange(of: appLanguage) { languageCode in
                appDelegate?.applyAppLanguagePreference(languageCode)
            }
            .onChange(of: galleryFilter) { if selectedTab == .gallery { scheduleGalleryReload() } }
            .onChange(of: deviceMonitor.activeCamera) { handleGalleryDeviceChange() }
            .onChange(of: deviceMonitor.connectedDevices.count) { handleGalleryDeviceChange() }

        let galleryEvents = lifecycleRoot
            .onReceive(deviceMonitor.$connectedDevices) { _ in updateSyncStatePresentation() }
            .onChange(of: selectedGalleryDeviceID) { handleSelectedGalleryDeviceChange() }
            .onChange(of: backupMediaType) { if selectedTab == .gallery { scheduleGalleryReload() } }
            .onChange(of: reviewMediaFilter) { if selectedTab == .review { scheduleReviewReload() } }
            .onChange(of: reviewDateFilter) { if selectedTab == .review { scheduleReviewReload() } }
            .onReceive(deviceMonitor.$failedDeletions) { restoreFailedReviewDeletions(from: $0) }

        return AnyView(
            galleryEvents
                .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                    if case .copying = backupEngine.state { timerTick.toggle() }
                }
                .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
                    // Proactively refresh mount availability so the UI stays current
                    // without needing a hover or other interaction to trigger a redraw.
                    if !isBackupActive {
                        ssdMonitor.checkConnectedVolumes()
                        destinationVersion += 1
                    }
                }
                .onChange(of: backupEngine.state) { handleBackupStateChange() }
                .alert(l10n(alertErrorTitle, lang: appLanguage), isPresented: $showErrorAlert) {
                    Button(l10n("Dismiss", lang: appLanguage), role: .cancel) { }
                    if alertErrorTitle == "Backup Error" {
                        Button(l10n("View Status", lang: appLanguage)) {
                            withAnimation { selectedTab = .status }
                        }
                    }
                } message: {
                    Text(alertErrorMessage)
                }
        )
    }

    private var dashboardWithSheets: some View {
        dashboardWithLifecycle
            .onChange(of: appDelegate?.newDeviceCamera) { handleNewDeviceCameraChange() }
            .onChange(of: appDelegate?.quickSwipePromptCamera) { handleQuickSwipePromptCameraChange() }
            .onChange(of: appDelegate?.destinationVersion) { handleDestinationVersionChange() }
            .onChange(of: appDelegate?.pathChangedDeviceID) { handlePathChangedDeviceIDChange() }
            .sheet(isPresented: $showNewDeviceSheet) {
                newDeviceSheet
            }
            .sheet(isPresented: $showQuickSwipePromptSheet) {
                quickSwipePromptSheet
            }
            .sheet(isPresented: $showPathChangeSheet) {
                pathChangeSheet
            }
            .sheet(isPresented: $isReviewSummaryPresented) {
                reviewSessionSummarySheet
            }
            .alert(l10n("Forget this device", lang: appLanguage), isPresented: $showForgetDeviceAlert) {
                Button(l10n("Cancel", lang: appLanguage), role: .cancel) { }
                Button(l10n("Remove", lang: appLanguage), role: .destructive) {
                    if let dev = deviceToForget {
                        appDelegate?.forgetDevice(id: dev.id)
                        unlockedDeviceIDs.remove(dev.id)
                        deviceToForget = nil
                    }
                }
            } message: {
                Text(l10n("Are you sure you want to remove this device profile and its saved settings?", lang: appLanguage))
            }
            .alert(l10n("Delete from iPhone after backup?", lang: appLanguage), isPresented: $showDeleteAfterBackupWarning) {
                Button(l10n("Keep Files", lang: appLanguage), role: .cancel) { }
                Button(l10n("Delete After Backup", lang: appLanguage), role: .destructive) {
                    deleteAfterBackup = true
                }
            } message: {
                Text(l10n("Each newly verified backup will be deleted from the iPhone camera roll. This cannot be undone. Keep this off unless the backup destination is reliable.", lang: appLanguage))
            }
            .alert(
                l10n("Unsaved Marked Photos", lang: appLanguage),
                isPresented: $isReviewDiscardAlertPresented
            ) {
                Button(
                    queuedReviewDeletionCandidates.count == 1
                        ? l10n("Delete 1 Item", lang: appLanguage)
                        : String(format: l10n("Delete %d Items", lang: appLanguage), queuedReviewDeletionCandidates.count),
                    role: .destructive
                ) {
                    deleteQueuedReviewItems()
                    checkForRecentDeletionsOnDevice()
                }
                Button(l10n("Discard Batch", lang: appLanguage), role: .destructive) {
                    keepQueuedReviewItems()
                    checkForRecentDeletionsOnDevice()
                }
                Button(l10n("Cancel", lang: appLanguage), role: .cancel) { }
            } message: {
                Text(String(format: l10n("You have %d photos marked for deletion. Would you like to delete them permanently from your phone or discard the batch before refreshing?", lang: appLanguage), queuedReviewDeletionCandidates.count))
            }
            .alert(
                l10n("Retry Deletion", lang: appLanguage),
                isPresented: $isRetryRecentDeletionsAlertPresented
            ) {
                Button(
                    recentDeletionsToRetry.count == 1
                        ? l10n("Delete 1 Item", lang: appLanguage)
                        : String(format: l10n("Delete %d Items", lang: appLanguage), recentDeletionsToRetry.count),
                    role: .destructive
                ) {
                    let items = recentDeletionsToRetry
                    recentDeletionsToRetry = []
                    retryDeletingRecentItems(items)
                }
                Button(l10n("Skip", lang: appLanguage), role: .cancel) {
                    recentDeletionsToRetry = []
                    resetReviewSession()
                }
            } message: {
                Text(String(format: l10n("Found %d photos previously marked for deletion still on your iPhone. Try deleting them now? (Note: If iCloud Photos is enabled on your iPhone, iOS blocks deleting photos over USB).", lang: appLanguage), recentDeletionsToRetry.count))
            }
            .environment(\.locale, Locale(identifier: appLanguage))
    }

    private func handleDashboardAppear() {
        if !hasAppliedInitialTab {
            hasAppliedInitialTab = true
            if let tab = DashboardTab(rawValue: defaultLaunchTab) {
                selectedTab = tab
            }
        }
        updateStorageInfo()
        ensureSelectedGalleryDevice()
        refreshBackupManifest()
        deviceMonitor.onCatalogChanged = {
            handleCatalogChange()
        }
        if UserDefaults.standard.object(forKey: "folderOrganization") != nil {
            let org = UserDefaults.standard.integer(forKey: "folderOrganization")
            if org == 0 {
                organizeByYear = false
                organizeByMonth = false
            }
            UserDefaults.standard.removeObject(forKey: "folderOrganization")
        }
        migrateAppearancePreferenceIfNeeded()
    }

    private func migrateAppearancePreferenceIfNeeded() {
        // Migration is complete — the swap between liquidGlass and metal keys
        // was performed once. This function is kept as a no-op to avoid
        // re-running a destructive migration.
        guard !UserDefaults.standard.bool(forKey: "migratedToAppearanceV3") else { return }
        UserDefaults.standard.set(true, forKey: "migratedToAppearanceV3")
    }

    private func handleGalleryDeviceChange() {
        ensureSelectedGalleryDevice()
        if selectedTab == .gallery { reloadGallery() }
        if selectedTab == .review { reloadReviewQueue() }
    }

    private func handleCatalogChange() {
        ensureSelectedGalleryDevice()

        // A successful Image Capture deletion removes the item from the device
        // catalog before this callback. Drop only those completed pending entries;
        // failures remain available for the failure callback to restore.
        let liveIDs = Set(
            readyGalleryDevices.flatMap { device in
                deviceMonitor.allReadyDiscoveredFiles(for: device.id)
                    .filter { $0.isPhotoFile || $0.isVideoFile }
                    .map { backupEngine.manifestKey(for: $0) }
            }
        )
        pendingReviewDeletions = pendingReviewDeletions.filter { liveIDs.contains($0.key) }

        if selectedTab == .gallery {
            reloadGalleryDebounced()
        }
        if selectedTab == .review {
            reloadReviewQueue()
        }
    }

    private func handleSelectedTabChange() {
        tabActivationTask?.cancel()
        switch selectedTab {
        case .gallery:
            scheduleGalleryReload()
        case .review:
            scheduleReviewReload()
        case .settings:
            startSettingsGuide()
        case .status:
            break
        }
    }

    /// Delays non-essential tab work by one native interaction cycle. The tab
    /// selection responds immediately; loading begins only after the click ends.
    private func scheduleGalleryReload() {
        galleryLoadTask?.cancel()
        galleryIsLoading = true
        tabActivationTask?.cancel()
        tabActivationTask = Task {
            // Let the UI finish its spring tab selection animation before doing file work
            await Task.yield()
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, selectedTab == .gallery else { return }
            reloadGallery()
        }
    }

    private func scheduleReviewReload() {
        reviewLoadTask?.cancel()
        reviewIsLoading = true
        tabActivationTask?.cancel()
        tabActivationTask = Task {
            // Let the UI finish its spring tab selection animation before doing file work
            await Task.yield()
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, selectedTab == .review else { return }
            reloadReviewQueue()
        }
    }

    private func startSettingsGuide() {
        settingsGuideTask?.cancel()
        settingsGuideStep = 0
        withAnimation(.snappy) {
            settingsGuideIsVisible = true
        }

        settingsGuideTask = Task { @MainActor in
            for step in 1..<GuideStage.allCases.count {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy) {
                    settingsGuideStep = step
                }
            }

            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) {
                settingsGuideIsVisible = false
            }
        }
    }

    private func handleSelectedGalleryDeviceChange() {
        if selectedTab == .gallery { reloadGallery() }
        if selectedTab == .review { reloadReviewQueue() }
    }

    private func handleBackupStateChange() {
        // Destination creation issues on launch (e.g. unmounted SMB) are presented in-line in the Sync State card and notification without an intrusive modal popup.
    }

    private func handleNewDeviceCameraChange() {
        if let cam = appDelegate?.newDeviceCamera {
            newDeviceName = cam.name ?? "Unknown Device"
            showNewDeviceSheet = true
        }
    }

    private func handleQuickSwipePromptCameraChange() {
        if let cam = appDelegate?.quickSwipePromptCamera {
            quickSwipePromptCameraName = cam.name ?? "iPhone"
            quickSwipePromptItemCount = appDelegate?.quickSwipePromptCount ?? 0
            showQuickSwipePromptSheet = true
        } else {
            showQuickSwipePromptSheet = false
        }
    }

    private func handleDestinationVersionChange() {
        destinationVersion = appDelegate?.destinationVersion ?? 0
        refreshBackupManifest()
        if selectedTab == .gallery { reloadGallery() }
    }

    private func handlePathChangedDeviceIDChange() {
        if let devID = appDelegate?.pathChangedDeviceID {
            pathChangeDeviceID = devID
            showPathChangeSheet = true
            appDelegate?.pathChangedDeviceID = nil
        }
    }

    private var dashboardContent: some View {
        ZStack {
            Color.clear
                .themedWindowBackground()
                .ignoresSafeArea()
            
            if appAppearance == .liquidGlass {
                // Let macOS manage the sidebar column and its collapsed state.
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    crystalSidebar
                        .navigationSplitViewColumnWidth(min: 160, ideal: 210, max: 260)
                } detail: {
                    VStack(spacing: 0) {
                        tabContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(
                                currentTheme.animatesContentChanges
                                    ? .opacity.combined(with: .move(edge: .bottom))
                                    : .identity
                            )
                        
                        crystalBottomBar
                    }
                }
                .onChange(of: navigation.isSidebarVisible) { isVisible in
                    let target: NavigationSplitViewVisibility = isVisible ? .all : .detailOnly
                    if columnVisibility != target {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                            columnVisibility = target
                        }
                    }
                }
                .onChange(of: columnVisibility) { visibility in
                    let isVisible = (visibility != .detailOnly)
                    if navigation.isSidebarVisible != isVisible {
                        navigation.isSidebarVisible = isVisible
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        if isTitleBarTabLoading {
                            titleBarTabLoadingControl
                                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        }

                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                navigation.isSidebarVisible.toggle()
                            }
                        } label: {
                            Image(systemName: "sidebar.leading")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(Color.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .help("Toggle Sidebar")
                    }
                    
                    if !navigation.isSidebarVisible {
                        ToolbarItem(placement: .principal) {
                            liquidGlassHeaderSlider
                        }
                    }
                    
                    ToolbarItem(placement: .primaryAction) {
                        connectionStatusPillView
                    }
                }
                .navigationSplitViewStyle(.balanced)
                .transition(.opacity)
            } else {
                VStack(spacing: appAppearance.isModernDesign ? 8 : 0) {
                    titleBar
                    
                    customTabBar
                    
                    if !appAppearance.isModernDesign {
                        liquidSeparator
                    }
                    
                    tabContent
                        .transition(
                            currentTheme.animatesContentChanges
                                ? .opacity.combined(with: .move(edge: .bottom))
                                : .identity
                        )
                    
                    if !appAppearance.isModernDesign {
                        liquidSeparator
                    }
                    
                    bottomActions
                }
                .themedAppFrame()
                .animation(
                    currentTheme.animatesContentChanges
                        ? .spring(response: currentTheme.tabSpringResponse, dampingFraction: currentTheme.tabSpringDamping)
                        : nil,
                    value: selectedTab
                )
            }

            if let item = selectedPreviewItem {
                quickViewOverlay(for: item)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .environment(\.appTheme, currentTheme)
        .environment(\.appAppearance, appAppearance)
        .animation(.easeInOut(duration: 0.32), value: appAppearanceRaw)
    }

    // MARK: - Sub-views

    private var crystalSidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            // App Header
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                    Text("Backup Center")
                        .font(.system(size: 13, weight: .bold))
                }
                Text("iPhone Photo Management")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 24)
            .padding(.bottom, 16)
            
            // Navigation Links / Tabs
            VStack(spacing: 4) {
                ForEach(DashboardTab.allCases, id: \.self) { tab in
                    crystalSidebarButton(for: tab)
                }
            }
            .padding(.horizontal, 8)
            
            Spacer()
            
            // Quit Button at the bottom
            Button(role: .destructive) {
                onClose()
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("Quit App")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle(role: .destructive))
            .padding(12)
        }
        .background {
            ZStack {
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                if let color = themeColor.color {
                    color.opacity(0.08)
                }
            }
            .ignoresSafeArea()
        }
    }

    private func crystalSidebarButton(for tab: DashboardTab) -> some View {
        let isSelected = selectedTab == tab

        return GeometryReader { proxy in
            // The split view's content width is smaller than its visible column
            // width because of the sidebar's horizontal inset. Collapse early so
            // labels never compete with the app's narrow-window layout.
            let isCompact = proxy.size.width < 184

            sidebarTabButtonSurface(isSelected: isSelected) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            .frame(width: 20, height: 20)

                        if !isCompact {
                            Text(l10n(tab.rawValue, lang: appLanguage))
                                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                                .foregroundStyle(isSelected ? Color.primary : .secondary)
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: isCompact ? nil : .infinity, minHeight: 44, maxHeight: 44, alignment: .leading)
                    .padding(.horizontal, isCompact ? 12 : 16)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(width: isCompact ? 44 : nil, height: 44)
                .frame(maxWidth: isCompact ? nil : .infinity, alignment: .leading)
                .help(l10n(tab.rawValue, lang: appLanguage))
                .accessibilityLabel(l10n(tab.rawValue, lang: appLanguage))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            .frame(maxWidth: isCompact ? nil : .infinity, alignment: .leading)
        }
        .frame(height: 44)
    }

    @ViewBuilder
    private func sidebarTabButtonSurface<Content: View>(
        isSelected: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if #available(macOS 26.0, *) {
            content()
                .glassEffect(
                    .regular.tint(Color.primary.opacity(isSelected ? 0.12 : 0.04)).interactive(),
                    in: .rect(cornerRadius: 14)
                )
        } else {
            content()
                .background(Color.primary.opacity(isSelected ? 0.11 : 0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isSelected ? 0.12 : 0.05), lineWidth: 0.5)
                }
        }
    }

    private var crystalHeaderBar: some View {
        HStack {
            if navigation.isSidebarVisible {
                Text(l10n(selectedTab.rawValue, lang: appLanguage))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
            } else {
                liquidGlassHeaderSlider
            }
            
            Spacer()
            
            // Connection status badge
            connectionStatusPillView
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Color.primary.opacity(0.08)
                .frame(height: 0.5)
        }
    }

    private var liquidGlassHeaderSlider: some View {
        Picker("", selection: $selectedTab) {
            ForEach(DashboardTab.allCases, id: \.self) { tab in
                Text(l10n(tab.rawValue, lang: appLanguage)).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .overlay(HoverBlockerView())
    }

    /// Shows in the title bar while a tab has deferred work pending. It gives
    /// immediate, native feedback without capturing the next click or adding
    /// work to the backup's main interaction path.
    private var isTitleBarTabLoading: Bool {
        guard isBackupActive else { return false }
        switch selectedTab {
        case .gallery:
            return galleryIsLoading
        case .review:
            return reviewIsLoading
        case .status, .settings:
            return false
        }
    }

    private var titleBarTabLoadingControl: some View {
        HStack(spacing: 0) {
            ProgressView()
                .controlSize(.small)
                .padding(7)
        }
        .background(.quaternary, in: Circle())
        .accessibilityLabel("Loading \(selectedTab.rawValue)")
        .help("Loading \(selectedTab.rawValue)")
        .allowsHitTesting(false)
    }

    private var crystalBottomBar: some View {
        Group {
            if selectedTab == .status {
                let engineIsBusy = {
                    switch backupEngine.state {
                    case .scanning, .copying: return true
                    default: return false
                    }
                }()
                let syncableDevices = readyDevicesForManualSync

                HStack {
                    // Floating "View Sync Console" pill — always visible when active
                    if engineIsBusy {
                        Button {
                            appDelegate?.openDetailWindow()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "rectangle.on.rectangle.angled")
                                    .font(.system(size: 11, weight: .bold))
                                Text(l10n("View Sync Console", lang: appLanguage))
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .overlay {
                                Capsule().strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.8)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                    if engineIsBusy {
                        HaltTaskGlassButton {
                            backupEngine.cancelBackup()
                        }
                    } else {
                        SyncNowGlassMenu(
                            syncableDevices: syncableDevices,
                            onForceBackup: onForceBackup,
                            appDelegate: appDelegate
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }
        }
    }

    private var liquidSeparator: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(currentTheme.separatorLeading),
                        Color.primary.opacity(currentTheme.separatorCenter),
                        Color.white.opacity(currentTheme.separatorTrailing)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
            .padding(.horizontal, 16)
    }
    
    private var customTabBar: some View {
        Group {
            if currentTheme.useNativeGlassTabBar, #available(macOS 26.0, *) {
                liquidGlassTabBar
            } else {
                fallbackTabBar
            }
        }
    }

    @available(macOS 26.0, *)
    private var liquidGlassTabBar: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(DashboardTab.allCases, id: \.self) { tab in
                    tabButton(for: tab, selectedEffectID: "activeTabLiquid")
                }
            }
        }
        .padding(.horizontal, appAppearance.isModernDesign ? 12 : 16)
        .padding(.vertical, 8)
    }

    private var fallbackTabBar: some View {
        HStack(spacing: 4) {
            ForEach(DashboardTab.allCases, id: \.self) { tab in
                tabButton(for: tab, selectedEffectID: "activeTabFallback")
            }
        }
        .padding(6)
        .themedTabBarBackground()
        .padding(.horizontal, appAppearance.isModernDesign ? 12 : 16)
        .padding(.vertical, 8)
    }

    private func tabButton(for tab: DashboardTab, selectedEffectID: String) -> some View {
        let isSelected = selectedTab == tab
        let isHovered  = hoveredTab == tab
        let fgColor: Color = {
            if isSelected {
                return appAppearance.isModernDesign ? .white : Color.accentColor
            }
            if appAppearance.isModernDesign {
                return isHovered ? .white : .white.opacity(0.72)
            }
            return isHovered ? Color.primary : Color.secondary
        }()
        let scaleVal = currentTheme.enablesHoverScale && isHovered && !isSelected ? 1.04 : 1.0

        return Group {
            if appAppearance.isModernDesign {
                VStack(spacing: 3) {
                    Image(systemName: tab.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                    Text(l10n(tab.rawValue, lang: appLanguage))
                        .font(.system(size: 10, weight: isSelected ? .bold : .semibold, design: .rounded))
                        .lineLimit(1)
                        .shadow(color: isSelected ? .black.opacity(0.35) : .clear, radius: 1, y: 0.5)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: tab.icon)
                        .imageScale(.medium)
                    Text(l10n(tab.rawValue, lang: appLanguage))
                }
                .font(.subheadline)
                .lineLimit(1)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity)
        .padding(.vertical, appAppearance.isModernDesign ? 8 : 8)
        .foregroundStyle(fgColor)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(
                .spring(
                    response: currentTheme.tabSpringResponse,
                    dampingFraction: currentTheme.tabSpringDamping
                )
            ) {
                selectedTab = tab
            }
        }
        .background {
            ZStack {
                if isSelected {
                    if appAppearance == .liquidGlass {
                        Color.clear
                            .background {
                                ZStack {
                                    if appAppearance == .liquidGlass {
                                        VisualEffectView(material: .selection, blendingMode: .withinWindow)
                                            .opacity(0.42)
                                        Color.white.opacity(0.08)
                                        Color.accentColor.opacity(0.15)
                                    } else {
                                        Color.accentColor.opacity(0.15)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(
                                            Color.accentColor.opacity(0.25),
                                            lineWidth: 1.0
                                        )
                                )
                                .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
                            }
                            .matchedGeometryEffect(id: selectedEffectID, in: tabNamespace)
                    } else {
                        RoundedRectangle(cornerRadius: appAppearance.isModernDesign ? 12 : 8, style: .continuous)
                            .fill(
                                appAppearance.isModernDesign
                                    ? AnyShapeStyle(
                                        LinearGradient(
                                            colors: [
                                                Color.accentColor.opacity(0.72),
                                                Color.accentColor.opacity(0.52)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    : AnyShapeStyle(Color.accentColor.opacity(0.13))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: appAppearance.isModernDesign ? 12 : 8, style: .continuous)
                                    .strokeBorder(
                                        appAppearance.isModernDesign
                                            ? Color.white.opacity(0.28)
                                            : Color.accentColor.opacity(0.28),
                                        lineWidth: 1
                                    )
                            )
                            .matchedGeometryEffect(id: selectedEffectID, in: tabNamespace)
                    }
                } else if isHovered {
                    RoundedRectangle(cornerRadius: appAppearance.isModernDesign ? 12 : 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
            }
        }
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.12)) {
                hoveredTab = inside ? tab : nil
            }
        }
        .scaleEffect(scaleVal)
        .animation(
            currentTheme.animatesTabChanges
                ? .spring(response: 0.2, dampingFraction: 0.6)
                : nil,
            value: isHovered
        )
    }
    
    @ViewBuilder
    private var tabContent: some View {
        if selectedTab == .gallery {
            galleryTab
                .padding(.horizontal, appAppearance.isModernDesign ? 16 : 20)
                .padding(.vertical, appAppearance.isModernDesign ? 12 : 16)
        } else if selectedTab == .review {
            reviewTab
                .padding(.horizontal, appAppearance.isModernDesign ? 16 : 20)
                .padding(.vertical, appAppearance.isModernDesign ? 12 : 16)
        } else if selectedTab == .status {
            ScrollView {
                statusTab
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, appAppearance.isModernDesign ? 16 : 20)
            .padding(.vertical, appAppearance.isModernDesign ? 12 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    settingsTab
                }
                .padding(.horizontal, appAppearance.isModernDesign ? 16 : 20)
                .padding(.vertical, appAppearance.isModernDesign ? 12 : 16)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var titleBar: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        appAppearance.isModernDesign
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [Color.accentColor, Color.cyan.opacity(0.85)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            : AnyShapeStyle(Color.blue.opacity(0.15))
                    )
                    .frame(width: appAppearance.isModernDesign ? 40 : 40, height: appAppearance.isModernDesign ? 40 : 40)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(appAppearance.isModernDesign ? 0.35 : 0.0), lineWidth: 1)
                    }
                    .shadow(color: Color.accentColor.opacity(appAppearance.isModernDesign ? 0.28 : 0.0), radius: 10, y: 4)

                Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                    .font(appAppearance.isModernDesign ? .body.weight(.semibold) : .title2)
                    .foregroundStyle(appAppearance.isModernDesign ? .white : .blue)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("iPhone Backup Center")
                    .font(appAppearance.isModernDesign ? .system(.headline, design: .rounded).weight(.bold) : .headline.weight(.semibold))
                Text("Keep your memories safe locally")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()

            if appAppearance.isModernDesign {
                HStack(spacing: 6) {
                    Circle()
                        .fill(deviceMonitor.isDeviceConnected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(deviceMonitor.isDeviceConnected ? "Live" : "Waiting")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                        }
                }
            }
        }
        .padding(.leading, 68)
        .padding(.trailing, appAppearance.isModernDesign ? 14 : 20)
        .padding(.vertical, appAppearance.isModernDesign ? 14 : 16)
        .themedTitleBarBackground()
    }
    
    // MARK: - Source Devices Column

    @ViewBuilder
    private var sourceDevicesColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("SOURCE DEVICES")
                .frame(maxWidth: .infinity, alignment: .leading)
            if deviceMonitor.connectedDevices.isEmpty {
                devicePill(
                    icon: "camera.slash",
                    title: "No Device",
                    subtitle: "Disconnected",
                    active: false,
                    color: .green
                )
                .overlay(alignment: .bottom) {
                    if hoveredDeviceTipsID == "__empty__" { deviceTipsOverlay }
                }
                .onHover { hoveredDeviceTipsID = $0 ? "__empty__" : nil }
            } else if deviceMonitor.connectedDevices.count == 1,
                      let dev = deviceMonitor.connectedDevices.first {
                devicePill(
                    icon: deviceIcon(for: dev.name),
                    title: dev.name,
                    subtitle: l10n(stableDeviceStatusText(for: dev), lang: appLanguage),
                    active: dev.isReady,
                    color: backupEngine.currentDeviceID == dev.id ? .blue : .green
                )
                .overlay(alignment: .bottom) {
                    if hoveredDeviceTipsID == dev.id { deviceTipsOverlay }
                }
                .onHover { isHovered in
                    guard !dev.isReady else { return }
                    hoveredDeviceTipsID = isHovered ? dev.id : nil
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(deviceMonitor.connectedDevices) { dev in
                        deviceRow(dev)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 165, maxHeight: 175)
                .padding(10)
                .themedCard()
            }
        }
    }

    @ViewBuilder
    private var deviceTipsOverlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT TO DO")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            tipRow(icon: "lock.open.fill", color: .blue, text: "Unlock your phone — screen must be on.")
            tipRow(icon: "hand.tap.fill", color: .green, text: "Tap \"Trust\" on iPhone if prompted.")
            tipRow(icon: "cable.connector", color: .orange, text: "Re-plug the USB cable and wait.")
            tipRow(icon: "checkmark.circle", color: .purple, text: "App reconnects automatically.")
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .frame(width: 220)
        .offset(y: 8)
        .allowsHitTesting(false)
        .zIndex(999)
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        .animation(.spring(response: 0.2, dampingFraction: 0.75), value: hoveredDeviceTipsID)
    }

    private func tipRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func deviceRow(_ dev: ConnectedDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: deviceIcon(for: dev.name))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(dev.isReady ? Color.green : .secondary)
                .frame(width: 26)
                .symbolEffect(.bounce.up.byLayer, value: dev.isReady)
            VStack(alignment: .leading, spacing: 2) {
                Text(dev.name)
                    .font(.dashboardSubheadline).fontWeight(.semibold)
                    .lineLimit(1)
                Text(stableDeviceStatusText(for: dev))
                    .font(.dashboardCaption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(deviceStatusColor(for: dev))
                .frame(width: 8, height: 8)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottom) {
            if hoveredDeviceTipsID == dev.id { deviceTipsOverlay }
        }
        .onHover { isHovered in
            guard !dev.isReady else { return }
            hoveredDeviceTipsID = isHovered ? dev.id : nil
        }
    }

    // MARK: - Sync Status Tab

    private var statusTab: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                sourceDevicesColumn
                    .frame(maxWidth: .infinity)

                VStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.dashboardTitle2)
                        .foregroundStyle(
                            deviceMonitor.isDeviceConnected && ssdMonitor.isSSDConnected
                                ? Color.green : Color.secondary.opacity(0.35)
                        )
                    Text(l10n("One at a time", lang: appLanguage))
                        .font(.dashboardText(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Destinations column
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("BACKUP DESTINATIONS")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    destinationArea
                }
                .frame(maxWidth: .infinity)
            }

            // Recently Connected card — visible only when no device is plugged in
            recentlyConnectedCard

            // Android USB-trust inline hint — shown for every connected non-Apple device
            // whose catalog is loaded but returned zero files (MTP not in File Transfer mode).
            androidUsbHintIfNeeded

            if shouldShowSequentialNotice {
                sequentialNotice
            }

            sectionLabel("SYNC STATE").padding(.top, 4)

            validationRecountCard

            switch backupEngine.state {
            case .idle:
                idleCard
            case .scanning:
                liveScanningCard
            case .copying(let current, let total, let progress):
                activeBackupCard(current: current, total: total, progress: progress, isPaused: false)
            case .paused(let current, let total, let progress):
                activeBackupCard(current: current, total: total, progress: progress, isPaused: true)
            case .completed(let count):
                completedCard(count: count)
            case .interrupted(let current, let total, let progress):
                interruptedCard(current: current, total: total, progress: progress)
            case .failed(let reason):
                errorCard(reason: reason)
            }

            if !isBackupActive {
                if isDestinationAvailable(activeBackupDestination) {
                    processedThumbnailStatusGrid
                }
                if activeBackupDestination != nil || backupEngine.manifestSnapshot().count > 0 {
                    liveBackupIndexCard
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: - Recently Connected Card

    @ViewBuilder
    private var recentlyConnectedCard: some View {
        let history = deviceMonitor.deviceHistory
        let liveIDs  = Set(deviceMonitor.connectedDevices.map(\.id))
        // Only show entries that aren't currently live
        let offline  = history.filter { !liveIDs.contains($0.id) }
        if !offline.isEmpty && deviceMonitor.connectedDevices.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.dashboardText(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(l10n("RECENTLY CONNECTED", lang: appLanguage))
                        .font(.dashboardText(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)
                    Spacer()
                }

                VStack(spacing: 6) {
                    ForEach(offline) { entry in
                        HStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(Color.secondary.opacity(0.12))
                                    .frame(width: 32, height: 32)
                                Image(systemName: deviceIcon(for: entry.name))
                                    .font(.dashboardText(size: 14, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .font(.dashboardText(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                Text(relativeTimeString(from: entry.lastConnected))
                                    .font(.dashboardText(size: 11))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.secondary.opacity(0.45))
                                    .frame(width: 6, height: 6)
                                Text(l10n("Offline", lang: appLanguage))
                                    .font(.dashboardText(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(Color.secondary.opacity(0.08))
                            )
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.035))
                        )
                    }
                }
            }
            .padding(14)
            .themedCard()
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Returns a human-readable relative time string (e.g. "3 hours ago", "Yesterday").
    private func relativeTimeString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private var processedThumbnailStatusGrid: some View {
        let files = recentStatusFiles
        if !files.isEmpty || isBackupActive {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(l10n("Processed Thumbnails", lang: appLanguage), systemImage: "rectangle.grid.3x2.fill")
                        .font(.dashboardHeadline)
                    Spacer()
                    Text(l10n("live", lang: appLanguage))
                        .font(.dashboardCaption2.weight(.bold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.14)))
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(files, id: \.self) { file in
                        compactProcessedTile(for: file)
                    }
                }

                if files.isEmpty {
                    Text(l10n("Thumbnails will appear here as each photo or video is processed.", lang: appLanguage))
                        .font(.dashboardCaption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .themedCard()
        }
    }

    private var isBackupActive: Bool {
        switch backupEngine.state {
        case .scanning, .copying, .paused:
            return true
        default:
            return false
        }
    }

    private var recentStatusFiles: [ICCameraFile] {
        if !backupEngine.recentlyProcessedFiles.isEmpty {
            return backupEngine.recentlyProcessedFiles
        }

        let allFiles = deviceMonitor.allDiscoveredFiles()
        let currentName = backupEngine.stats.currentFileName
        var names = backupEngine.recentlyProcessedFileNames
        if !currentName.isEmpty, !names.contains(currentName) {
            names.insert(currentName, at: 0)
        }

        return names.compactMap { name in
            allFiles.first { $0.name == name }
        }
    }

    private func compactProcessedTile(for file: ICCameraFile) -> some View {
        let isSafe = backupEngine.isAssetAlreadyBackedUp(file)
        let thumbnail = file.name.flatMap { deviceMonitor.thumbnails[$0] }
        let name = file.name ?? "IMG_0000"

        return VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.black.opacity(0.12))

                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1.0)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 78)
                            .frame(maxWidth: .infinity)
                            .clipped()
                    } else {
                        Image(systemName: file.isVideoFile ? "film" : "photo")
                            .font(.dashboardText(size: 20))
                            .foregroundStyle(.secondary.opacity(0.65))
                    }
                }
                .frame(height: 78)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                if file.isVideoFile {
                    Image(systemName: "play.fill")
                        .font(.dashboardText(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .padding(5)
                }
            }

            HStack(spacing: 4) {
                Image(systemName: isSafe ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                    .font(.dashboardText(size: 10, weight: .semibold))
                    .foregroundStyle(isSafe ? Color.green : Color.orange)
                Text(name)
                    .font(.dashboardText(size: 10, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
            }
        }
        .padding(6)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onAppear {
            let localURL = backupEngine.localURL(for: file)
            deviceMonitor.requestThumbnail(for: file, localURL: localURL)
        }
    }

    private var liveBackupIndexCard: some View {
        let s = backupEngine.stats
        let indexedCount = backupEngine.manifestSnapshot().count
        let remaining = max(s.totalFiles - s.successCount - s.failedCount, 0)
        let hasActiveRun = s.totalFiles > 0 || s.successCount > 0 || s.skippedFiles > 0 || indexedCount > 0

        return HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.14))
                    .frame(width: 48, height: 48)
                Image(systemName: "checkmark.seal.fill")
                    .font(.dashboardTitle2)
                    .foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(l10n("Live Backup Index", lang: appLanguage))
                        .font(.dashboardHeadline).fontWeight(.semibold)
                    if case .copying = backupEngine.state {
                        Text(l10n("UPDATING", lang: appLanguage))
                            .font(.dashboardText(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.18)))
                            .foregroundStyle(.green)
                    }
                }

                if hasActiveRun {
                    Text("\(indexedCount) files are safe. \(s.successCount) newly copied this run, \(s.skippedFiles) skipped (already backed up from a previous session)\(remaining > 0 ? ", \(remaining) remaining" : "").")
                        .font(.dashboardCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(l10n("The backup index will update here as thumbnails turn green during a sync.", lang: appLanguage))
                        .font(.dashboardCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(indexedCount)")
                    .font(.dashboardText(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
                Text(l10n("safe", lang: appLanguage))
                    .font(.dashboardCaption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .themedCard()
    }

    private func devicePill(icon: String, title: String, subtitle: String,
                             active: Bool, color: Color) -> some View {
        VStack(spacing: 10) {
            ZStack {
                AvailabilityHalo(isAvailable: active, color: color)
                Circle()
                    .fill(active ? color.opacity(0.12) : Color.white.opacity(0.04))
                    .frame(width: 52, height: 52)
                Image(systemName: icon)
                    .font(.dashboardText(size: 24))
                    .foregroundStyle(active ? color : Color.secondary)
                    .symbolEffect(.bounce.up.byLayer, value: active)
            }
            Text(l10n(title, lang: appLanguage))
                .font(.dashboardHeadline).fontWeight(.semibold)
                .lineLimit(1)
            Text(l10n(subtitle, lang: appLanguage))
                .font(.dashboardCaption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 165, maxHeight: 175)
        .padding(.vertical, 16).padding(.horizontal, 12)
        .themedCard()
    }

    private func deviceIcon(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("iphone") { return "iphone.gen3" }
        if lower.contains("ipad")   { return "ipad" }
        if lower.contains("ipod")   { return "ipodtouch" }
        if lower.contains("android") || lower.contains("pixel") || lower.contains("galaxy") || lower.contains("samsung") {
            return "smartphone"
        }
        return "camera"
    }

    /// Returns true when the device name strongly suggests it's an Android / non-Apple device.
    private func isAndroidLike(_ name: String) -> Bool {
        let lower = name.lowercased()
        // Explicitly Apple devices → not Android
        if lower.contains("iphone") || lower.contains("ipad") || lower.contains("ipod") { return false }
        // Known Android keywords or generic camera-like names that are definitely not iPhone
        let androidKeywords = ["android", "pixel", "galaxy", "samsung", "oneplus", "xiaomi",
                               "redmi", "oppo", "realme", "vivo", "huawei", "motorola", "lg ",
                               "sm-", "moto"]
        if androidKeywords.contains(where: { lower.contains($0) }) { return true }
        // Fallback: a ready device that has a catalog but zero discovered files is almost
        // certainly Android MTP with no File Transfer permission — treat as Android-like.
        return false
    }

    private func deviceStatusText(for device: ConnectedDevice) -> String {
        if backupEngine.currentDeviceID == device.id {
            switch backupEngine.state {
            case .scanning:
                return l10n("Scanning…", lang: appLanguage)
            case .copying:
                return l10n("Backing up…", lang: appLanguage)
            case .paused:
                return l10n("Paused", lang: appLanguage)
            default:
                break
            }
        }

        if device.isReady {
            return l10n("Connected", lang: appLanguage)
        }
        if device.isAccessRestricted {
            return l10n("Unlock to connect", lang: appLanguage)
        }
        if device.isOpeningSession {
            return l10n("Connecting…", lang: appLanguage)
        }
        if device.needsCableReconnect {
            return l10n("Unlock or re-plug", lang: appLanguage)
        }
        if !device.sessionError.isEmpty {
            let lower = device.sessionError.lowercased()
            if lower.contains("unlock") { return l10n("Unlock to connect", lang: appLanguage) }
            if lower.contains("busy")   { return l10n("Busy — retrying…", lang: appLanguage) }
            if lower.contains("trust")  { return l10n("Tap Trust on device", lang: appLanguage) }
            return l10n("Waiting", lang: appLanguage)
        }
        return l10n("Waiting", lang: appLanguage)
    }

    /// Latch transient error messages (e.g. "Connecting…") so they do not flicker
    /// back to a generic "Waiting" while a retry is already in flight.
    private func stableDeviceStatusText(for device: ConnectedDevice) -> String {
        let live = deviceStatusText(for: device)
        if device.isReady {
            if stickyDeviceStatus[device.id] != nil {
                DispatchQueue.main.async { stickyDeviceStatus[device.id] = nil }
            }
            return live
        }
        // Only replace the latched value when transitioning to a more specific error
        let current = stickyDeviceStatus[device.id]
        let isMoreSpecific = (live != "Waiting" && live != "Reconnect cable") || current == nil
        if isMoreSpecific || current == "Waiting" {
            if current != live {
                DispatchQueue.main.async { stickyDeviceStatus[device.id] = live }
            }
            return live
        }
        return current ?? live
    }

    private func deviceStatusColor(for device: ConnectedDevice) -> Color {
        if backupEngine.currentDeviceID == device.id {
            switch backupEngine.state {
            case .scanning, .copying:
                return .blue
            case .paused:
                return .orange
            default:
                break
            }
        }
        if device.isReady { return .green }
        if device.isOpeningSession || device.needsCableReconnect ||
            device.isAccessRestricted ||
            device.sessionError.localizedCaseInsensitiveContains("unlock") {
            return .orange
        }
        return .secondary
    }

    // MARK: - Destination area (single or multi-device)

    /// Top-level destination view: one pill for a single device, stacked rows for multiple.
    @ViewBuilder
    private var destinationArea: some View {
        let _version = destinationVersion  // read here so SwiftUI re-renders on changes
        let devices = deviceMonitor.connectedDevices
        if devices.count > 1 {
            multiDestinationCard(devices: devices)
        } else {
            destinationPill
        }
    }

    /// Multi-device destination card — mirrors the device list layout on the left.
    private func multiDestinationCard(devices: [ConnectedDevice]) -> some View {
        VStack(spacing: 8) {
            ForEach(devices) { dev in
                let dest    = appDelegate?.resolvedBackupDestination(for: dev.id)
                let avail   = isDestinationAvailable(dest)
                let configured = dest != nil
                // dot colour: green = ready, orange = configured but missing, grey = not configured
                let dotColor: Color = configured ? (avail ? .green : .orange) : Color.secondary.opacity(0.4)
                let pathStr: String? = dest.map {
                    $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                }

                HStack(spacing: 12) {
                    ZStack {
                        AvailabilityHalo(isAvailable: avail, color: dotColor)
                        Circle()
                            .fill(dotColor.opacity(0.14))
                            .frame(width: 32, height: 32)
                        Image(systemName: configured
                              ? (avail ? BackupDestinationKind.detect(for: dest).systemImage
                                       : "exclamationmark.triangle.fill")
                              : "questionmark.folder")
                            .font(.dashboardText(size: 15))
                            .foregroundStyle(dotColor)
                            .symbolEffect(.bounce.up.byLayer, value: avail)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(dest.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? dev.name)
                            .font(.dashboardSubheadline).fontWeight(.semibold)
                            .lineLimit(1)
                        if let p = pathStr {
                            Text(p)
                                .font(.dashboardText(size: 10, weight: .regular, design: .monospaced))
                                .foregroundStyle(avail ? Color.secondary.opacity(0.65) : Color.orange.opacity(0.75))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text(l10n("No destination set", lang: appLanguage))
                                .font(.dashboardCaption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if configured && !avail {
                        Button {
                            reconnectSMBShare(for: dev.id)
                        } label: {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.dashboardText(size: 16))
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .help("Reconnect volume via Finder")
                    }

                    Circle()
                        .fill(dotColor)
                        .frame(width: 8, height: 8)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(configured && !avail
                              ? Color.orange.opacity(0.07)
                              : Color.white.opacity(0.05))
                        .overlay {
                            if configured && !avail {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.orange.opacity(0.30), lineWidth: 0.8)
                            }
                        }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    appDelegate?.chooseBackupFolder(for: dev.id)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 165, maxHeight: 175)
        .padding(10)
        .themedCard()
    }

    private var destinationPill: some View {
        _ = destinationVersion
        let path = activeBackupDestination
        let kind = BackupDestinationKind.detect(for: path)
        let isConfigured   = path != nil
        let isAvailable    = isDestinationAvailable(path)
        let isReady        = isConfigured && isAvailable
        let isUnavailable  = isConfigured && !isAvailable

        let iconColor: Color  = isReady ? .blue : .orange
        let circleColor: Color = isReady ? Color.blue.opacity(0.12) : Color.orange.opacity(0.12)
        let statusText: String = {
            if isUnavailable { return NSLocalizedString("Unavailable", comment: "Destination unavailable") }
            if !isConfigured  { return NSLocalizedString("Not Found", comment: "Destination not configured") }
            return storageInfo.isEmpty ? NSLocalizedString("Ready", comment: "Destination ready") : storageInfo
        }()
        let statusColor: Color = isReady ? .secondary : .orange

        return VStack(spacing: isUnavailable ? 6 : 10) {
            ZStack {
                AvailabilityHalo(isAvailable: isReady, color: iconColor)
                Circle()
                    .fill(circleColor)
                    .frame(width: 52, height: 52)
                Image(systemName: isUnavailable ? "exclamationmark.triangle.fill" : kind.systemImage)
                    .font(.dashboardText(size: isUnavailable ? 22 : 24))
                    .foregroundStyle(iconColor)
                    .symbolEffect(.bounce.up.byLayer, value: isReady)
            }
            Text(ssdMonitor.targetSSDName)
                .font(.dashboardHeadline).fontWeight(.semibold)
                .lineLimit(1)

            Text(statusText)
                .font(.dashboardCaption).fontWeight(isUnavailable ? .semibold : .regular)
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.center).lineLimit(1)

            if let destPath = path?.path {
                Text(destPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.dashboardText(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(isUnavailable ? Color.orange.opacity(0.75) : Color.secondary.opacity(0.65))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
            }

            if isUnavailable {
                Text(l10n("Connect the drive or choose a new folder", lang: appLanguage))
                    .font(.dashboardCaption2)
                    .foregroundStyle(.orange.opacity(0.80))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)

                Button {
                    reconnectSMBShare()
                } label: {
                    Label(l10n("Reconnect via Finder", lang: appLanguage),
                          systemImage: "network")
                        .font(.dashboardText(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.15))
                .foregroundStyle(.orange)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.8)
                }
            }
        }
        // Keep the one-device destination card visually paired with devicePill.
        .frame(maxWidth: .infinity, minHeight: 165, maxHeight: 175)
        .padding(.vertical, 16).padding(.horizontal, 12)
        .themedCard()
        .overlay {
            if isUnavailable {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1.2)
            }
        }
        .onTapGesture {
            onChooseFolder()
        }
    }

    private var newDeviceSheet: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 64, height: 64)
                    Image(systemName: deviceIcon(for: newDeviceName))
                        .font(.dashboardText(size: 28))
                        .foregroundStyle(.blue)
                }
                Text("New Device Detected")
                    .font(.dashboardTitle2).fontWeight(.bold)
                Text("**\(newDeviceName)** is connected for the first time.")
                    .font(.dashboardSubheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 32)
            .padding(.horizontal, 24)

            Divider().padding(.vertical, 20)

            VStack(spacing: 12) {
                Button {
                    let uuid = appDelegate?.newDeviceCamera?.uuidString ?? ""
                    showNewDeviceSheet = false
                    appDelegate?.newDeviceCamera = nil
                    appDelegate?.chooseBackupFolder(for: uuid)
                } label: {
                    Label("Choose Backup Destination…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .appButton(.primary, size: .large)

                Button {
                    showNewDeviceSheet = false
                    appDelegate?.newDeviceCamera = nil
                    appDelegate?.enqueueForceBackup(isFullBackup: true)
                } label: {
                    Label("Start Full Backup Now", systemImage: "arrow.clockwise.circle")
                        .frame(maxWidth: .infinity)
                }
                .appButton(.secondary, size: .large)

                Button("Skip for Now") {
                    showNewDeviceSheet = false
                    appDelegate?.newDeviceCamera = nil
                }
                .appButton(.text)
                .padding(.top, 4)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .frame(width: 360)
        .themedSheetChrome()
    }

    private var quickSwipePromptSheet: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.purple.opacity(0.15))
                        .frame(width: 64, height: 64)
                    Image(systemName: "rectangle.portrait.and.arrow.forward")
                        .font(.dashboardText(size: 28))
                        .foregroundStyle(.purple)
                }
                Text(l10n("Quick Swiping Available", lang: appLanguage))
                    .font(.dashboardTitle2).fontWeight(.bold)

                Text(String(format: l10n("%@ has %d unreviewed items from this week ready to swipe and clean before backup starts.", lang: appLanguage), quickSwipePromptCameraName, quickSwipePromptItemCount))
                    .font(.dashboardSubheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text(l10n("You can swipe to keep what you love and mark clutter for deletion before the backup starts.", lang: appLanguage))
                    .font(.dashboardCaption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                let targetCam = appDelegate?.quickSwipePromptCamera
                let targetID = targetCam?.uuidString ?? targetCam?.name ?? ""
                let dest = appDelegate?.resolvedBackupDestination(for: targetID) ?? activeBackupDestination
                if !isDestinationAvailable(dest) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                        Text(l10n("Backup destination currently unavailable — it will retry once connected.", lang: appLanguage))
                            .font(.dashboardCaption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 2)
                }
            }
            .padding(.top, 32)
            .padding(.horizontal, 24)

            Divider().padding(.vertical, 18)

            VStack(spacing: 12) {
                Button {
                    showQuickSwipePromptSheet = false
                    let targetCam = appDelegate?.quickSwipePromptCamera
                    appDelegate?.quickSwipePromptCamera = nil
                    if let targetCam {
                        let targetID = targetCam.uuidString ?? targetCam.name ?? ""
                        selectedGalleryDeviceID = targetID
                    }
                    selectedTab = .review
                    reloadReviewQueue()
                } label: {
                    Label(l10n("Review in Quick Swiping", lang: appLanguage), systemImage: "rectangle.portrait.and.arrow.forward")
                        .frame(maxWidth: .infinity)
                }
                .appButton(.primary, size: .large)

                Button {
                    showQuickSwipePromptSheet = false
                    if let cam = appDelegate?.quickSwipePromptCamera {
                        appDelegate?.enqueueDeviceDirectly(cam)
                    }
                    appDelegate?.quickSwipePromptCamera = nil
                } label: {
                    Label(l10n("Start Backup Now", lang: appLanguage), systemImage: "arrow.clockwise.circle")
                        .frame(maxWidth: .infinity)
                }
                .appButton(.secondary, size: .large)

                Button(l10n("Skip for Now", lang: appLanguage)) {
                    showQuickSwipePromptSheet = false
                    appDelegate?.quickSwipePromptCamera = nil
                }
                .appButton(.text)
                .padding(.top, 2)
            }
            .padding(.horizontal, 28)

            Divider().padding(.vertical, 14)

            HStack {
                Toggle(isOn: $promptQuickSwipeBeforeSync) {
                    Text(l10n("Ask before automatic sync", lang: appLanguage))
                        .font(.dashboardCaption)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
            }
            .padding(.bottom, 20)
        }
        .frame(width: 380)
        .themedSheetChrome()
    }

    private var pathChangeSheet: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.questionmark")
                .font(.dashboardText(size: 42))
                .foregroundStyle(.orange)
            
            Text("Backup Path Changed")
                .font(.dashboardHeadline)
            
            Text("You updated the backup directory for this device. Would you like to launch a verification sync to match your local files?")
                .font(.dashboardSubheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            HStack(spacing: 12) {
                Button("Keep Existing State") {
                    showPathChangeSheet = false
                }
                .appButton(.secondary)

                Button("Scan & Verify Now") {
                    showPathChangeSheet = false
                    appDelegate?.enqueueForceBackup(isFullBackup: false)
                }
                .appButton(.primary)
            }
        }
        .padding(24)
        .frame(width: 380)
        .themedSheetChrome()
    }

    private var idleCard: some View {
        let s = backupEngine.stats

        return VStack(spacing: 12) {
            headerCard(icon: idleIcon, color: idleColor, headline: idleHeadline, sub: idleSub)

            if s.manifestSize > 0 || s.skippedFiles > 0 {
                HStack(spacing: 0) {
                    statCell(label: "Known Files",  value: "\(s.manifestSize)",  color: .blue)
                    Divider().frame(height: 32).opacity(0.15)
                    statCell(label: "Already Safe", value: "\(s.skippedFiles)",  color: .green)
                    Divider().frame(height: 32).opacity(0.15)
                    statCell(label: "Copied",       value: "\(s.successCount)",  color: .teal)
                    Divider().frame(height: 32).opacity(0.15)
                    statCell(label: "Failed",       value: "\(s.failedCount)", color: s.failedCount > 0 ? .red : .secondary)
                }
                .padding(.vertical, 10)
                .themedCard()
            }
        }
    }

    private func hintRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.dashboardText(size: 13))
                .foregroundStyle(color)
                .frame(width: 20)
            Text(l10n(text, lang: appLanguage))
                .font(.dashboardCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // The sync card must derive all of its state from the same device snapshot.
    // `DeviceMonitor` also publishes convenience flags, but with multiple phones
    // those flags are updated separately and can briefly describe different devices.
    private var hasOpeningSourceDevice: Bool {
        deviceMonitor.connectedDevices.contains { $0.isOpeningSession }
    }

    private var hasCatalogLoadingSourceDevice: Bool {
        deviceMonitor.connectedDevices.contains { $0.isReady && !$0.isCatalogLoaded }
    }

    private var hasReadySourceDevice: Bool {
        deviceMonitor.connectedDevices.contains { $0.isReady }
    }

    private var pendingSessionError: String? {
        guard !hasReadySourceDevice else { return nil }
        return deviceMonitor.connectedDevices
            .first(where: { !$0.isReady && !$0.sessionError.isEmpty })?
            .sessionError
    }

    /// Keep the card in its connecting presentation until an error has remained
    /// unchanged without any device opening for a short confirmation window.
    private var isPresentingConnectionAttempt: Bool {
        hasOpeningSourceDevice || (pendingSessionError != nil && !syncErrorIsConfirmed)
    }

    private var displayedSessionError: String? {
        guard !hasOpeningSourceDevice, syncErrorIsConfirmed else { return nil }
        return pendingSessionError
    }

    private func updateSyncStatePresentation() {
        guard !hasOpeningSourceDevice, pendingSessionError != nil else {
            syncErrorConfirmationTask?.cancel()
            syncErrorConfirmationTask = nil
            syncErrorIsConfirmed = false
            return
        }

        guard !syncErrorIsConfirmed, syncErrorConfirmationTask == nil else { return }
        syncErrorConfirmationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled,
                  !hasOpeningSourceDevice,
                  pendingSessionError != nil else { return }
            syncErrorIsConfirmed = true
            syncErrorConfirmationTask = nil
        }
    }

    private var idleIcon: String {
        _ = destinationVersion
        if hasCatalogLoadingSourceDevice { return "magnifyingglass" }
        if isPresentingConnectionAttempt { return "smartphone" }
        if displayedSessionError != nil { return "smartphone" }
        if !hasReadySourceDevice { return "smartphone" }
        if activeBackupDestination == nil { return "folder.badge.questionmark" }
        return "checkmark.circle"
    }
    private var idleColor: Color {
        _ = destinationVersion
        if hasCatalogLoadingSourceDevice { return .blue }
        if isPresentingConnectionAttempt { return .blue }
        if displayedSessionError != nil { return .secondary }
        if !hasReadySourceDevice { return .secondary }
        if activeBackupDestination == nil { return .orange }
        return .green
    }
    private var idleHeadline: String {
        _ = destinationVersion
        if hasCatalogLoadingSourceDevice { return "Reading Phone Gallery…" }
        if isPresentingConnectionAttempt { return "Connecting to Phone…" }
        if displayedSessionError != nil { return "Reconnect Phone" }
        if !hasReadySourceDevice { return "Waiting for Phone…" }
        if activeBackupDestination == nil { return "Choose Destination" }
        return "Ready to Sync"
    }
    private var idleSub: String {
        _ = destinationVersion
        if hasCatalogLoadingSourceDevice {
            let discoveredCount = deviceMonitor.connectedDevices.map(\.discoveredCount).max() ?? 0
            return discoveredCount > 0
                ? "Indexing photos and videos on your phone (\(discoveredCount) items found)…"
                : "Indexing photos and videos on your phone…"
        }
        if isPresentingConnectionAttempt { return "Opening device session. Please unlock your phone and allow USB photo access." }
        if let displayedSessionError { return displayedSessionError }
        if !hasReadySourceDevice {
            return "Phone not detected. Plug it in via USB, then choose File Transfer or Photo Transfer on Android."
        }
        if activeBackupDestination == nil { return "Configure a folder in Settings to start backing up." }
        let readyCount = deviceMonitor.connectedDevices.filter { $0.isReady }.count
        if readyCount > 1 {
            return "Ready devices will back up one by one."
        }
        return "Device linked. Backup will start automatically."
    }

    private var shouldShowSequentialNotice: Bool {
        deviceMonitor.connectedDevices.count > 1 || !(appDelegate?.waitingBackupDeviceNames.isEmpty ?? true)
    }

    private var sequentialNotice: some View {
        let activeName = appDelegate?.activeBackupDeviceName
        let waitingNames = appDelegate?.waitingBackupDeviceNames ?? []

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "list.bullet")
                .font(.dashboardText(size: 14, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(l10n("Sequential backup", lang: appLanguage))
                    .font(.dashboardCaption.weight(.semibold))
                Text(sequentialNoticeText(activeName: activeName, waitingNames: waitingNames))
                    .font(.dashboardCaption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .themedCard()
    }

    private func sequentialNoticeText(activeName: String?, waitingNames: [String]) -> String {
        if let activeName, !waitingNames.isEmpty {
            return "Backing up \(activeName) now. Waiting: \(waitingNames.joined(separator: ", "))."
        }
        if let activeName {
            return "Backing up \(activeName) now. Other connected devices will wait their turn."
        }
        if !waitingNames.isEmpty {
            return "Waiting devices: \(waitingNames.joined(separator: ", ")). They will run one after another."
        }
        return "When more than one device is connected, the app backs up one device, then starts the next."
    }

    private func liveConsoleOpenBanner(current: Int, total: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.dashboardText(size: 16, weight: .semibold))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n("Live Sync Console is open", lang: appLanguage))
                    .font(.dashboardSubheadline).fontWeight(.semibold)
                Text("\(current) of \(total) files • \(backupEngine.currentDeviceName)")
                    .font(.dashboardCaption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                appDelegate?.openDetailWindow()
            } label: {
                Text(l10n("Focus", lang: appLanguage))
                    .font(.dashboardCaption).fontWeight(.medium)
            }
            .appButton(.secondary, size: .small)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .themedCard()
    }

    @ViewBuilder
    private var liveScanningCard: some View {
        let vStats = backupEngine.validationStats
        let phase = vStats?.currentPhase ?? .readingCatalog
        let deviceName = backupEngine.currentDeviceName

        VStack(spacing: 10) {
            // Header row
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.blue)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(deviceName.isEmpty ? l10n("Scanning Library…", lang: appLanguage) : "\(l10n("Scanning", lang: appLanguage)) \(deviceName)…")
                        .font(.dashboardSubheadline).fontWeight(.semibold)
                    // Live phase subtitle
                    Group {
                        switch phase {
                        case .idle, .readingCatalog:
                            Text(l10n("Reading camera index from your phone…", lang: appLanguage))
                        case .buildingIndex:
                            Text(l10n("Building destination file index…", lang: appLanguage))
                        case .validatingAndReorganizing:
                            let count = vStats?.scannedCount ?? 0
                            let total = vStats?.totalToScan ?? 0
                            Text("\(l10n("Verifying files", lang: appLanguage)): \(count) / \(total)")
                        case .complete:
                            Text(l10n("Verification complete", lang: appLanguage))
                        }
                    }
                    .font(.dashboardCaption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    appDelegate?.openDetailWindow()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .help(l10n("Open Sync Console", lang: appLanguage))
            }

            // Step phase pipeline
            let mode = vStats?.scanMode ?? .incremental
            if mode == .fullRecountAndReconcile {
                HStack(spacing: 4) {
                    scanPhaseStep(
                        label: l10n("Read Catalog", lang: appLanguage),
                        isDone: phase == .buildingIndex || phase == .validatingAndReorganizing || phase == .complete,
                        isActive: phase == .readingCatalog
                    )
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                    scanPhaseStep(
                        label: l10n("Build Index", lang: appLanguage),
                        isDone: phase == .validatingAndReorganizing || phase == .complete,
                        isActive: phase == .buildingIndex
                    )
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                    scanPhaseStep(
                        label: l10n("Verify & Reorganize", lang: appLanguage),
                        isDone: phase == .complete,
                        isActive: phase == .validatingAndReorganizing
                    )
                }
                .padding(.top, 2)
            } else {
                HStack(spacing: 4) {
                    scanPhaseStep(
                        label: l10n("Read Catalog", lang: appLanguage),
                        isDone: phase == .validatingAndReorganizing || phase == .complete,
                        isActive: phase == .readingCatalog
                    )
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                    scanPhaseStep(
                        label: l10n("Verify Parity", lang: appLanguage),
                        isDone: phase == .complete,
                        isActive: phase == .validatingAndReorganizing
                    )
                }
                .padding(.top, 2)
            }

            // Live stats row during verification
            if phase == .validatingAndReorganizing, let v = vStats {
                HStack(spacing: 0) {
                    scanMiniStat(label: l10n("Verified Safe", lang: appLanguage), value: "\(v.verifiedSafeCount)", color: .green)
                    Divider().frame(height: 24).opacity(0.15)
                    scanMiniStat(label: l10n("Missing / New", lang: appLanguage), value: "\(v.missingOrCorruptCount)", color: .orange)
                    Divider().frame(height: 24).opacity(0.15)
                    scanMiniStat(label: l10n("Reorganized", lang: appLanguage), value: "\(v.reorganizedCount)", color: .teal)
                }
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .themedCard()
    }

    private func scanPhaseStep(label: String, isDone: Bool, isActive: Bool) -> some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(isDone ? Color.green : (isActive ? Color.blue : Color.primary.opacity(0.1)))
                    .frame(width: 16, height: 16)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                } else if isActive {
                    Circle()
                        .fill(.white)
                        .frame(width: 5, height: 5)
                }
            }
            Text(label)
                .font(.system(size: 8, weight: isActive ? .bold : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func scanMiniStat(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.dashboardText(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .contentTransition(.numericText())
            Text(label)
                .font(.dashboardCaption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }


    @ViewBuilder
    private var validationRecountCard: some View {
        if let v = backupEngine.validationStats {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "checklist.checked")
                        .font(.dashboardText(size: 13, weight: .semibold))
                        .foregroundStyle(.blue)
                    Text(l10n("Deep Library Recount & Validation", lang: appLanguage))
                        .font(.dashboardCaption.weight(.semibold))
                    Spacer()
                    if v.isReconciliationSkipped {
                        Text(l10n("Reconciliation Skipped", lang: appLanguage))
                            .font(.dashboardCaption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                            .foregroundStyle(.orange)
                    } else if v.isReconciliationComplete {
                        Text(l10n("Verified", lang: appLanguage))
                            .font(.dashboardCaption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                            .foregroundStyle(.green)
                    }
                }
                
                HStack(spacing: 0) {
                    statCell(label: l10n("Source Phone", lang: appLanguage), value: "\(v.sourceFileCount)", color: .blue)
                    Divider().frame(height: 28).opacity(0.15)
                    statCell(label: l10n("On Destination", lang: appLanguage), value: "\(v.destinationFileCount)", color: .teal)
                    Divider().frame(height: 28).opacity(0.15)
                    statCell(label: l10n("Missing/Diff", lang: appLanguage), value: "\(v.differenceCount)", color: v.differenceCount > 0 ? .orange : .green)
                    Divider().frame(height: 28).opacity(0.15)
                    statCell(label: l10n("Safe on Disk", lang: appLanguage), value: "\(v.verifiedSafeCount)", color: .green)
                }
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

                if case .scanning = backupEngine.state, v.isRecountComplete, !v.isReconciliationComplete {
                    HStack {
                        Text(l10n("Reconciling physical files...", lang: appLanguage))
                            .font(.dashboardCaption2).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            backupEngine.skipValidationReconciliation()
                        } label: {
                            Text(l10n("Skip Reconciliation", lang: appLanguage))
                                .font(.dashboardCaption2)
                        }
                        .appButton(.secondary, size: .small)
                    }
                }
            }
            .padding(10)
            .themedCard()
        }
    }

    private func activeBackupCard(current: Int, total: Int, progress: Double, isPaused: Bool) -> some View {
        let s = backupEngine.stats
        let pausedForLock = backupEngine.pausedByDeviceLock
        let _ = timerTick
        let remainingFiles = s.remainingFiles

        return VStack(spacing: 12) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(isPaused ? Color.orange.opacity(0.15) : Color.primary.opacity(0.12), lineWidth: 5)
                        .frame(width: 58, height: 58)
                    Circle()
                        .trim(from: 0, to: CGFloat(progress))
                        .stroke(
                            isPaused
                                ? LinearGradient(colors: [.orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing)
                                : LinearGradient(colors: [Color.accentColor.opacity(0.62), Color.accentColor], startPoint: .topLeading, endPoint: .bottomTrailing),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .frame(width: 58, height: 58)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.4), value: progress)
                    
                    if isPaused {
                        Image(systemName: pausedForLock ? "lock.fill" : "pause.fill")
                            .font(.dashboardText(size: 16, weight: .bold))
                            .foregroundStyle(.orange)
                    } else {
                        Text("\(Int(progress * 100))%")
                            .font(.dashboardText(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(isPaused
                             ? (pausedForLock ? l10n("Waiting for Unlock", lang: appLanguage) : l10n("Backup Paused", lang: appLanguage))
                             : (s.isFullBackup ? l10n("Full Backup", lang: appLanguage) : l10n("Incremental Sync", lang: appLanguage)))
                            .font(.dashboardHeadline).fontWeight(.semibold)
                            .foregroundStyle(isPaused ? .orange : .primary)
                        Text(s.isFullBackup ? "FULL" : "INCR")
                            .font(.dashboardText(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .foregroundStyle(.secondary)
                    }
                    if !backupEngine.currentDeviceName.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: deviceIcon(for: backupEngine.currentDeviceName))
                                .font(.dashboardText(size: 11))
                            Text(backupEngine.currentDeviceName)
                                .font(.dashboardSubheadline).fontWeight(.semibold)
                        }
                        .foregroundStyle(.secondary)
                    }
                    Text(isPaused ? "\(l10n("Paused", lang: appLanguage)) \(current) / \(total) \(l10n("files", lang: appLanguage))" : "\(current) / \(total) \(l10n("files transferred", lang: appLanguage))")
                        .font(.dashboardCaption).foregroundStyle(.secondary)
                    if pausedForLock {
                        Text(l10n("Unlock iPhone · check for a Trust prompt", lang: appLanguage))
                            .font(.dashboardCaption2)
                            .foregroundStyle(.orange.opacity(0.85))
                            .lineLimit(1)
                    } else if !isPaused, !s.currentFileName.isEmpty {
                        Text(s.currentFileName)
                            .font(.dashboardCaption2)
                            .foregroundStyle(.secondary.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        appDelegate?.openDetailWindow()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.dashboardText(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .help(l10n("Expand Live Sync View", lang: appLanguage))

                    if !pausedForLock {
                        Button {
                            if isPaused {
                                backupEngine.resumeBackup()
                            } else {
                                backupEngine.pauseBackup()
                            }
                        } label: {
                            Label(isPaused ? l10n("Resume", lang: appLanguage) : l10n("Pause", lang: appLanguage), systemImage: isPaused ? "play.fill" : "pause.fill")
                        }
                        .appButton(.secondary)
                    }
                }
            }

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(isPaused ? .orange : Color.accentColor)
                .animation(.linear(duration: 0.4), value: progress)

            if s.totalBatches > 1 {
                HStack {
                    Label(String(format: l10n("Batch %d of %d", lang: appLanguage), s.currentBatch, s.totalBatches), systemImage: "square.stack.3d.up")
                        .font(.dashboardCaption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(s.filesInCurrentBatch) \(l10n("files/batch", lang: appLanguage))")
                        .font(.dashboardCaption2).foregroundStyle(.secondary)
                }
            }

            activeProcessedStrip

            HStack(spacing: 0) {
                statCell(label: l10n("Done", lang: appLanguage), value: "\(s.successCount)", color: .primary)
                Divider().frame(height: 32).opacity(0.15)
                statCell(label: l10n("Failed", lang: appLanguage), value: "\(s.failedCount)", color: s.failedCount > 0 ? .red : .secondary)
                Divider().frame(height: 32).opacity(0.15)
                statCell(label: l10n("Retried", lang: appLanguage), value: "\(s.retriedCount)", color: .primary)
                Divider().frame(height: 32).opacity(0.15)
                statCell(label: l10n("Skipped", lang: appLanguage), value: "\(s.skippedFiles)", color: .primary)
                Divider().frame(height: 32).opacity(0.15)
                statCell(label: l10n("Elapsed", lang: appLanguage), value: s.elapsedFormatted, color: .primary)
                Divider().frame(height: 32).opacity(0.15)
                statCell(label: l10n("Remaining", lang: appLanguage), value: "\(remainingFiles)", color: .primary)
            }
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.15))
            .cornerRadius(8)

            if !s.failedFileNames.isEmpty {
                failedFilesCard(names: s.failedFileNames)
            }
        }
        .padding(16)
        .themedCard()
    }

    private var activeProcessedStrip: some View {
        let files = Array(recentStatusFiles.prefix(3))
        let safeCount = backupEngine.manifestSnapshot().count

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label(l10n("Processed", lang: appLanguage), systemImage: "rectangle.grid.2x2.fill")
                    .font(.dashboardCaption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("\(safeCount) \(l10n("safe", lang: appLanguage))")
                    .font(.dashboardText(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
            }
            .frame(width: 90, alignment: .leading)

            if files.isEmpty {
                Text(l10n("Thumbnails appear as files are processed.", lang: appLanguage))
                    .font(.dashboardCaption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 10) {
                    ForEach(files, id: \.self) { file in
                        miniProcessedTile(for: file)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func miniProcessedTile(for file: ICCameraFile) -> some View {
        let isSafe = backupEngine.isAssetAlreadyBackedUp(file)
        let thumbnail = file.name.flatMap { deviceMonitor.thumbnails[$0] }
        let name = file.name ?? "IMG_0000"

        return HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.16))

                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1.0)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipped()
                    } else {
                        Image(systemName: file.isVideoFile ? "film" : "photo")
                            .font(.dashboardText(size: 20))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Image(systemName: isSafe ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                    .font(.dashboardText(size: 12, weight: .semibold))
                    .foregroundStyle(isSafe ? Color.green : Color.orange)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.dashboardText(size: 10, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isSafe ? l10n("safe", lang: appLanguage) : l10n("processing", lang: appLanguage))
                    .font(.dashboardCaption2)
                    .foregroundStyle(isSafe ? Color.green : Color.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            let localURL = backupEngine.localURL(for: file)
            deviceMonitor.requestThumbnail(for: file, localURL: localURL)
        }
    }

    private func completedCard(count: Int) -> some View {
        let s = backupEngine.stats
        let hasRetries = s.failedCount > 0
        return VStack(spacing: 12) {
            headerCard(
                icon: hasRetries ? "checkmark.circle.fill" : "checkmark.circle.fill",
                color: .green,
                headline: count == 0 ? l10n("Everything was already backed up — no new files found.", lang: appLanguage) : l10n("Backup Complete", lang: appLanguage),
                sub: count == 0
                    ? l10n("Everything was already backed up — no new files found.", lang: appLanguage)
                    : "\(count) \(l10n("files transferred", lang: appLanguage)) (\(s.elapsedFormatted))."
            )

            HStack(spacing: 0) {
                statCell(label: l10n("Copied", lang: appLanguage),      value: "\(s.successCount)",  color: .green)
                Divider().frame(height: 32).opacity(0.15)
                statCell(label: l10n("Skipped", lang: appLanguage),     value: "\(s.skippedFiles)",  color: .teal)
                Divider().frame(height: 32).opacity(0.15)
                statCell(label: l10n("Will Retry", lang: appLanguage),  value: "\(s.failedCount)",   color: hasRetries ? .orange : .secondary)
                Divider().frame(height: 32).opacity(0.15)
                statCell(label: l10n("Retried", lang: appLanguage),     value: "\(s.retriedCount)",  color: s.retriedCount > 0 ? .orange : .secondary)
                Divider().frame(height: 32).opacity(0.15)
                statCell(label: l10n("Time", lang: appLanguage),        value: s.elapsedFormatted,   color: .blue)
                Divider().frame(height: 32).opacity(0.15)
                statCell(label: l10n("Manifest", lang: appLanguage),    value: "\(s.manifestSize)",  color: .secondary)
            }
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.15))
            .cornerRadius(8)

            if hasRetries {

                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                    Text("\(s.failedCount) file(s) couldn't be copied this run and will be retried automatically on the next sync.")
                        .font(.dashboardCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.orange.opacity(0.15), lineWidth: 1)
                }

                if !s.failedFileNames.isEmpty {
                    failedFilesCard(names: s.failedFileNames)
                }
            }
        }
        .themedCard()
        .padding(.bottom, 2)
    }

    private func interruptedCard(current: Int, total: Int, progress: Double) -> some View {
        VStack(spacing: 12) {
            headerCard(
                icon: "exclamationmark.triangle.fill",
                color: .orange,
                headline: "Backup Interrupted",
                sub: "Connection to phone was dropped mid-transfer. Reconnect device to resume."
            )
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.orange)

            HStack {
                Button("Cancel Running Job", role: .destructive) {
                    backupEngine.cancelInterrupted()
                }
                .appButton(.destructive)
                Spacer()
            }
        }
        .padding(14)
        .themedCard()
    }

    private func errorCard(reason: String) -> some View {
        headerCard(
            icon: "exclamationmark.triangle.fill",
            color: .orange,
            headline: "Sync Could Not Start",
            sub: reason
        )
    }

    private func headerCard(icon: String, color: Color, headline: String, sub: String) -> some View {
        HStack(spacing: 16) {
            SessionStatusGlyph(
                icon: icon,
                color: color,
                isConnecting: headline == "Connecting to Phone…"
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n(headline, lang: appLanguage)).font(.dashboardHeadline).fontWeight(.semibold)
                Text(l10n(sub, lang: appLanguage)).font(.dashboardSubheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(18)
        .themedCard()
    }

    private func failedFilesCard(names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .foregroundStyle(.orange)
                    .imageScale(.medium)
                Text("Will Retry Next Sync (\(names.count) files)")
                    .font(.dashboardSubheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
            
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(names.prefix(20), id: \.self) { name in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.dashboardCaption2)
                                .foregroundStyle(.secondary)
                            Text(name)
                                .font(.dashboardText(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if names.count > 20 {
                        Text("...and \(names.count - 20) more")
                            .font(.dashboardCaption2)
                            .italic()
                            .foregroundStyle(.secondary)
                            .padding(.leading, 18)
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(maxHeight: 120)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.red.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.red.opacity(0.15), lineWidth: 1.0)
        }
    }

    private func statCell(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.dashboardText(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .shadow(color: .black.opacity(0.55), radius: 0, x: 0, y: 0.5)
            Text(l10n(label, lang: appLanguage).uppercased())
                .font(.dashboardText(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func sectionLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            if appAppearance.isModernDesign {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor, Color.cyan.opacity(0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3.5, height: 12)
            }
            Text(l10n(text, lang: appLanguage))
                .font(.dashboardText(size: appAppearance.isModernDesign ? 11 : 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.85))
                .kerning(0.6)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Gallery Tab

    private var galleryTab: some View {
        VStack(spacing: 12) {
            galleryHeader
                .zIndex(10)

            ScrollView {
                galleryBody
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var galleryHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label(selectedGalleryDevice?.name ?? l10n("Phone Gallery", lang: appLanguage), systemImage: "photo.on.rectangle")
                    .font(.dashboardTitle3.weight(.semibold))
                Spacer()
                if galleryIsLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(galleryAssetCountText)
                    .font(.dashboardCaption)
                    .foregroundStyle(.secondary)
            }

            if readyGalleryDevices.count > 1 {
                Picker("Gallery device", selection: $selectedGalleryDeviceID) {
                    ForEach(readyGalleryDevices) { device in
                        Label(device.name, systemImage: deviceIcon(for: device.name)).tag(device.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 0) {
                ForEach(GalleryFilter.allCases, id: \.self) { filter in
                    let isSelected = galleryFilter == filter
                    Button {
                        galleryFilter = filter
                    } label: {
                        Text(l10n(filter.rawValue, lang: appLanguage))
                            .font(.dashboardText(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.13))
                                .matchedGeometryEffect(id: "galleryFilterPill", in: filterSegmentNamespace)
                        }
                    }
                }
            }
            .padding(3)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: galleryFilter)
        }
        .padding(16)
        .themedPanel(cornerRadius: 14)
    }

    @ViewBuilder
    private var galleryBody: some View {
        if !deviceMonitor.isDeviceConnected {
            VStack(spacing: 12) {
                Image(systemName: "smartphone").font(.dashboardLargeTitle).foregroundStyle(.secondary)
                Text(l10n("Connect your phone to browse its camera library. On Android, choose File Transfer or Photo Transfer from the USB notification.", lang: appLanguage)).font(.dashboardSubheadline).foregroundStyle(.secondary)
            }
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            .themedCard()
        } else if !deviceMonitor.isCatalogLoading && galleryFiles.isEmpty
                    && deviceMonitor.discoveredCount == 0
                    && selectedGalleryDevice.map({ isAndroidLike($0.name) || !$0.name.lowercased().contains("iphone") }) == true {
            // Android (or unknown non-Apple) connected, catalog finished, but zero files found.
            // Almost always means the phone is in "Charging" mode, not "File Transfer".
            androidUsbTrustBanner
        } else if deviceMonitor.isCatalogLoading && galleryFiles.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text(galleryLoadingMessage)
                    .font(.dashboardSubheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            .themedCard()
        } else if galleryFiles.isEmpty && galleryFilter == .backedUp && !isSelectedGalleryDestinationAvailable {
            // An unreachable destination means the backup index can't be checked at
            // all — an empty "Backed Up" result here would otherwise be indistinguishable
            // from genuinely having nothing backed up yet.
            galleryDestinationUnavailableNotice
        } else if galleryFiles.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: galleryFilter == .backedUp ? "checkmark.circle" : "photo.on.rectangle.angled")
                    .font(.dashboardLargeTitle)
                    .foregroundStyle(.secondary)
                Text(galleryEmptyMessage)
                    .font(.dashboardSubheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            .themedCard()
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 95, maximum: 115), spacing: 10)], spacing: 12) {
                ForEach(galleryFiles) { item in
                    galleryItemCell(for: item)
                }
            }
            .padding(8)
            .themedCard()
        }
    }

    /// Compact inline hint shown in the Sync Status tab for each non-Apple device
    /// that is connected and ready but returned zero files (not in File Transfer mode).
    @ViewBuilder
    private var androidUsbHintIfNeeded: some View {
        let affectedDevices = deviceMonitor.connectedDevices.filter { dev in
            dev.isReady &&
            dev.isCatalogLoaded &&
            dev.discoveredCount == 0 &&
            !dev.name.lowercased().contains("iphone") &&
            !dev.name.lowercased().contains("ipad") &&
            !dev.name.lowercased().contains("ipod")
        }
        if !affectedDevices.isEmpty {
            VStack(spacing: 6) {
                ForEach(affectedDevices) { dev in
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.orange.opacity(0.14))
                                .frame(width: 32, height: 32)
                            Image(systemName: "lock.open.trianglebadge.exclamationmark.fill")
                                .font(.dashboardText(size: 15))
                                .foregroundStyle(.orange)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(dev.name) — Allow USB File Access")
                                .font(.dashboardCaption).fontWeight(.semibold)
                                .lineLimit(1)
                            Text("On your phone, tap the USB notification and choose \"File Transfer\" or \"MTP\".")
                                .font(.dashboardCaption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.orange.opacity(0.07))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.orange.opacity(0.30), lineWidth: 0.8)
                            }
                    )
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Shown when an Android (or unknown) device is connected but returned zero files,
    /// which is the typical symptom of the phone not being in File Transfer / MTP mode.
    private var androidUsbTrustBanner: some View {
        VStack(spacing: 20) {
            // Icon
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: "lock.open.trianglebadge.exclamationmark.fill")
                    .font(.dashboardText(size: 28))
                    .foregroundStyle(.orange)
            }

            VStack(spacing: 6) {
                Text(l10n("Allow USB File Access", lang: appLanguage))
                    .font(.dashboardHeadline)
                Text(l10n("Your phone is connected but not sharing its files. This usually means it's set to \"Charging\" mode instead of \"File Transfer\".", lang: appLanguage))
                    .font(.dashboardSubheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Steps
            VStack(alignment: .leading, spacing: 10) {
                androidStep(number: 1, text: l10n("Unlock your phone and look for a USB notification.", lang: appLanguage))
                androidStep(number: 2, text: l10n("Tap it and choose \"File Transfer\" or \"MTP\".", lang: appLanguage))
                androidStep(number: 3, text: l10n("If prompted, tap \"Allow\" to trust this computer.", lang: appLanguage))
                androidStep(number: 4, text: l10n("The gallery will reload automatically.", lang: appLanguage))
            }
            .frame(maxWidth: 340)
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 300)
        .themedCard()
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1.0)
        }
    }

    private func androidStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.18))
                    .frame(width: 22, height: 22)
                Text("\(number)")
                    .font(.dashboardText(size: 11, weight: .bold))
                    .foregroundStyle(.orange)
            }
            Text(l10n(text, lang: appLanguage))
                .font(.dashboardSubheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var galleryAssetCountText: String {
        let count = galleryFiles.count
        let base = count == 1 ? "1 \(l10n("asset", lang: appLanguage))" : "\(count) \(l10n("assets", lang: appLanguage))"
        guard readyGalleryDevices.count > 1, let device = selectedGalleryDevice else { return base }
        return "\(base) \(l10n("on", lang: appLanguage)) \(device.name)"
    }

    private var galleryLoadingMessage: String {
        if deviceMonitor.discoveredCount > 0 {
            return String(format: l10n("Reading camera library index... %d items found so far.", lang: appLanguage), deviceMonitor.discoveredCount)
        }
        return l10n("Reading camera library index...", lang: appLanguage)
    }

    private var galleryEmptyMessage: String {
        switch galleryFilter {
        case .notBackedUp:
            return l10n("No new assets need backup.", lang: appLanguage)
        case .backedUp:
            return l10n("No backed-up assets were found in the current backup index.", lang: appLanguage)
        case .today:
            return l10n("No assets from today match the current media settings.", lang: appLanguage)
        case .thisWeek:
            return l10n("No assets from this week match the current media settings.", lang: appLanguage)
        case .thisMonth:
            return l10n("No assets from this month match the current media settings.", lang: appLanguage)
        }
    }

    /// Shown for the "Backed Up" filter when the resolved destination is configured
    /// but unreachable — otherwise the empty grid reads as "nothing has been backed
    /// up" when the real cause is that the backup index can't be checked right now.
    private var galleryDestinationUnavailableNotice: some View {
        let isConfigured = selectedGalleryDestination != nil
        return VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: isConfigured ? "exclamationmark.triangle.fill" : "questionmark.folder")
                    .font(.dashboardText(size: 26))
                    .foregroundStyle(.orange)
            }

            VStack(spacing: 6) {
                Text(isConfigured
                     ? l10n("Folder not available (unmounted volume or moved)", lang: appLanguage)
                     : l10n("No destination set", lang: appLanguage))
                    .font(.dashboardHeadline)
                    .multilineTextAlignment(.center)
                Text(l10n("Reconnect the destination to see which items have been backed up.", lang: appLanguage))
                    .font(.dashboardSubheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                if isConfigured {
                    reconnectSMBShare(for: selectedGalleryDevice?.id)
                } else {
                    onChooseFolder()
                }
            } label: {
                Label(
                    isConfigured ? l10n("Reconnect via Finder", lang: appLanguage) : l10n("Choose...", lang: appLanguage),
                    systemImage: isConfigured ? "network" : "folder.badge.plus"
                )
                .font(.dashboardText(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.15))
            .foregroundStyle(.orange)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.8)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 300)
        .themedCard()
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1.0)
        }
    }

    private func galleryItemCell(for item: GalleryItem) -> some View {
        let isBackedUp = backupEngine.isAssetAlreadyBackedUp(item.file)
        let thumbnail = item.file.name.flatMap { deviceMonitor.thumbnails[$0] }
        let thumbFailed = item.file.name.map { deviceMonitor.failedThumbnails.contains($0) } ?? false
        return VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                ZStack(alignment: .bottomTrailing) {
                    // Square thumbnail container — always 1:1 regardless of source orientation.
                    // .aspectRatio + .clipShape do all the work; no GeometryReader needed.
                    ZStack {
                        Color.black.opacity(0.12)

                        if let thumbnail {
                            Image(decorative: thumbnail, scale: 1.0)
                                .resizable()
                                .scaledToFit()
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: item.file.isVideoFile ? "film" : "photo")
                                    .font(.dashboardText(size: 22))
                                    .foregroundStyle(.secondary.opacity(0.55))
                                // Only show spinner while actively waiting.
                                // Android MTP returns nil immediately; we hide the spinner there.
                                if !thumbFailed {
                                    ProgressView()
                                        .controlSize(.small)
                                        .opacity(0.65)
                                }
                            }
                        }
                    }
                    .aspectRatio(1.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                    if item.file.isVideoFile {
                        ZStack {
                            Circle().fill(.black.opacity(0.5)).frame(width: 20, height: 20)
                            Image(systemName: "play.fill").font(.dashboardText(size: 9)).foregroundStyle(.white)
                        }
                        .padding(4)
                    }
                }

                if hoveredItemID == item.id {
                    Button {
                        itemToDelete = item
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.red.opacity(0.85))
                                .frame(width: 20, height: 20)
                            Image(systemName: "trash.fill")
                                .font(.dashboardText(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .transition(.opacity.combined(with: .scale))
                }
            }

            HStack(spacing: 2) {
                Image(systemName: isBackedUp ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                    .font(.dashboardText(size: 10))
                    .foregroundStyle(isBackedUp ? Color.green : Color.orange)
                Text(item.name)
                    .font(.dashboardText(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
        }
        .padding(4)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.12)) {
                hoveredItemID = inside ? item.id : nil
            }
        }
        .onTapGesture {
            // Both photos and videos open via native macOS Quick Look
            selectedPreviewItem = item
            previewManager.openNativePreview(for: item.file, camera: selectedGalleryDevice?.camera)
        }
        .onAppear {
            let localURL = backupEngine.localURL(for: item.file)
            deviceMonitor.requestThumbnail(for: item.file, localURL: localURL)
        }
    }

    /// Shown only while the file is being downloaded from the phone.
    /// Once the download is done, native QLPreviewPanel takes over and this overlay closes.
    private func quickViewOverlay(for item: GalleryItem) -> some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture {
                    selectedPreviewItem = nil
                    previewManager.cancelDownload()
                }

            VStack(spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.dashboardHeadline)
                        Text(item.file.isVideoFile ? "Video" : "Photo")
                            .font(.dashboardCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        selectedPreviewItem = nil
                        previewManager.cancelDownload()
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.dashboardTitle2)
                    }
                    .appButton(.plain)
                }
                .padding(.horizontal)
                .padding(.top, 16)

                // Body — loading or error
                if let error = previewManager.error {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.dashboardText(size: 32))
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.dashboardSubheadline)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                            .scaleEffect(1.3)
                        Text("Downloading from iPhone…")
                            .font(.dashboardCaption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }

                Spacer(minLength: 0)
            }
            .frame(width: 340)
            .themedPanel(cornerRadius: appAppearance.isModernDesign ? 24 : 16)
            .shadow(color: Color.black.opacity(0.24), radius: 28, y: 14)
        }
        .onReceive(previewManager.$readyURL) { url in
            guard url != nil else { return }
            // File is ready — close the loading overlay; native QL panel is now open
            selectedPreviewItem = nil
        }
    }

    private func reloadGallery() {
        ensureSelectedGalleryDevice()
        let token = UUID()
        galleryReloadToken = token
        galleryLoadTask?.cancel()
        galleryIsLoading = true
        galleryLoadTask = Task {
            defer {
                if galleryReloadToken == token {
                    galleryIsLoading = false
                }
            }

            guard deviceMonitor.isDeviceConnected,
                  let galleryDevice = selectedGalleryDevice else {
                guard galleryReloadToken == token else { return }
                galleryFiles = []
                return
            }
            let currentFilter = self.galleryFilter
            let typeFilter = self.backupMediaType
            let skipEdited = self.skipEditedDuplicates
            let galleryDeviceID = galleryDevice.id

            let destination = appDelegate?.resolvedBackupDestination(for: galleryDeviceID)
            let allFiles = deviceMonitor.allReadyDiscoveredFiles(for: galleryDeviceID)
            let now = Date()

            let backedUpKeys: Set<String>
            if let destination {
                if let activeKeys = backupEngine.activeManifestSnapshot(for: destination) {
                    backedUpKeys = activeKeys
                } else {
                    backedUpKeys = await Task.detached(priority: .utility) {
                        BackupEngine.persistedManifestSnapshot(at: destination)
                    }.value
                }
            } else {
                backedUpKeys = []
            }

            guard !Task.isCancelled, galleryReloadToken == token else { return }

            var snapshots: [CameraFileFilterSnapshot] = []
            snapshots.reserveCapacity(allFiles.count)
            for (index, file) in allFiles.enumerated() {
                if index > 0 && index % 500 == 0 {
                    await Task.yield()
                    guard !Task.isCancelled, galleryReloadToken == token else { return }
                }
                let id = backupEngine.manifestKey(for: file)
                snapshots.append(CameraFileFilterSnapshot(
                    index: index,
                    id: id,
                    name: file.name ?? "IMG_0000",
                    isPhoto: file.isPhotoFile,
                    isVideo: file.isVideoFile,
                    captureDate: file.effectiveCaptureDate,
                    isBackedUp: backedUpKeys.contains(id)
                ))
            }

            let matchingIndices = await Task.detached(priority: .userInitiated) {
                let calendar = Calendar.autoupdatingCurrent
                let startOfWeek = calendar.date(byAdding: .day, value: -7, to: now)
                return snapshots.compactMap { snapshot -> Int? in
                    guard snapshot.isPhoto || snapshot.isVideo else { return nil }
                    if typeFilter == 1 && !snapshot.isPhoto { return nil }
                    if typeFilter == 2 && !snapshot.isVideo { return nil }
                    if skipEdited,
                       (snapshot.name.localizedCaseInsensitiveContains("edited") || snapshot.name.hasPrefix("IMG_E")) {
                        return nil
                    }

                    switch currentFilter {
                    case .notBackedUp:
                        return snapshot.isBackedUp ? nil : snapshot.index
                    case .backedUp:
                        return snapshot.isBackedUp ? snapshot.index : nil
                    case .today:
                        return snapshot.captureDate.map { calendar.isDate($0, inSameDayAs: now) } == true ? snapshot.index : nil
                    case .thisWeek:
                        guard let captureDate = snapshot.captureDate, let startOfWeek else { return nil }
                        return captureDate >= startOfWeek && captureDate <= now ? snapshot.index : nil
                    case .thisMonth:
                        guard let captureDate = snapshot.captureDate else { return nil }
                        return calendar.isDate(captureDate, equalTo: now, toGranularity: .month) &&
                            calendar.isDate(captureDate, equalTo: now, toGranularity: .year) ? snapshot.index : nil
                    }
                }
            }.value

            guard !Task.isCancelled, galleryReloadToken == token else { return }
            galleryFiles = matchingIndices.compactMap { index in
                guard allFiles.indices.contains(index) else { return nil }
                let snapshot = snapshots[index]
                return GalleryItem(id: snapshot.id, name: snapshot.name, file: allFiles[index])
            }
        }
    }

    private func reloadGalleryDebounced() {
        galleryDebounceTask?.cancel()
        galleryDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            reloadGallery()
        }
    }

    private func ensureSelectedGalleryDevice() {
        let devices = readyGalleryDevices
        guard !devices.isEmpty else {
            selectedGalleryDeviceID = ""
            return
        }
        if !devices.contains(where: { $0.id == selectedGalleryDeviceID }) {
            selectedGalleryDeviceID = devices[0].id
        }
    }

    // MARK: - Photo Filter Tab

    private var reviewTab: some View {
        VStack(spacing: 16) {
            reviewHeader
            reviewBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 8)
        .onAppear { preloadReviewThumbnails() }
        .onChange(of: reviewFiles.first?.id) { _ in preloadReviewThumbnails() }
        .background {
            Button("") {
                if let item = reviewFiles.first {
                    openReviewPreview(for: item)
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .opacity(0)
        }
    }

    private func resetReviewSession() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            dismissedReviewItemIDs.removeAll()
            queuedReviewDeletionCandidates.removeAll()
            reviewHistory.removeAll()
            reviewKeptItemCount = 0
            reviewLastDecision = nil
            isReviewSummaryPresented = false
        }
        reloadReviewQueue()
    }

    private var reviewHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Label(l10n("Photo Filter", lang: appLanguage), systemImage: "rectangle.portrait.and.arrow.forward")
                    .font(.dashboardHeadline.weight(.semibold))
                if reviewIsLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                if readyGalleryDevices.count > 1 {
                    Picker(l10n("Review device", lang: appLanguage), selection: $selectedGalleryDeviceID) {
                        ForEach(readyGalleryDevices) { device in
                            Label(device.name, systemImage: deviceIcon(for: device.name)).tag(device.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                }
                Text(reviewQueueCountText)
                    .font(.dashboardCaption)
                    .foregroundStyle(.secondary)

                Button {
                    handleReviewRefreshTapped()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.dashboardText(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help(l10n("Reset review session and check for pending deletions", lang: appLanguage))
                .accessibilityLabel(l10n("Reset review session", lang: appLanguage))
            }

            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    ForEach(ReviewMediaFilter.allCases, id: \.self) { filter in
                        let isSelected = reviewMediaFilter == filter
                        Button {
                            reviewMediaFilter = filter
                        } label: {
                            Label(l10n(filter.rawValue, lang: appLanguage), systemImage: filter.icon)
                                .font(.dashboardText(size: 11, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.13))
                                    .matchedGeometryEffect(id: "reviewFilterPill", in: reviewFilterSegmentNamespace)
                            }
                        }
                    }
                }
                .padding(2)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: reviewMediaFilter)

                Spacer()

                HStack(spacing: 0) {
                    ForEach(ReviewDateFilter.allCases, id: \.self) { filter in
                        let isSelected = reviewDateFilter == filter
                        Button {
                            reviewDateFilter = filter
                        } label: {
                            Label(l10n(filter.rawValue, lang: appLanguage), systemImage: filter.icon)
                                .font(.dashboardText(size: 11, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.13))
                                    .matchedGeometryEffect(id: "reviewDateFilterPill", in: reviewDateFilterSegmentNamespace)
                            }
                        }
                    }
                }
                .padding(2)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: reviewDateFilter)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1.0)
        }
    }

    @ViewBuilder
    private var reviewBody: some View {
        if !deviceMonitor.isDeviceConnected || selectedGalleryDevice == nil {
            reviewEmptyState(
                icon: "smartphone",
                title: l10n("Connect a phone to start filtering", lang: appLanguage),
                detail: l10n("Connect and unlock your phone, then allow photo access to review its photos and videos.", lang: appLanguage)
            )
        } else if deviceMonitor.isCatalogLoading && reviewFiles.isEmpty {
            reviewEmptyState(
                icon: "photo.stack",
                title: l10n("Reading your library…", lang: appLanguage),
                detail: galleryLoadingMessage,
                showsProgress: true
            )
        } else if reviewFiles.isEmpty {
            VStack(spacing: 16) {
                reviewEmptyState(
                    icon: "checkmark.circle",
                    title: l10n("You’re all caught up", lang: appLanguage),
                    detail: reviewEmptyMessage,
                    glowColor: .green
                )
                if !queuedReviewDeletionCandidates.isEmpty {
                    let count = queuedReviewDeletionCandidates.count
                    let title = count == 1
                        ? l10n("Delete 1 Photo", lang: appLanguage)
                        : String(format: l10n("Delete %d Photos", lang: appLanguage), count)
                    Button {
                        isReviewDeletionConfirmationPresented = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash.fill")
                                .font(.dashboardText(size: 13, weight: .bold))
                            Text(title)
                                .font(.dashboardSubheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(Color.red.gradient, in: Capsule())
                        .shadow(color: .red.opacity(0.35), radius: 6, y: 3)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            VStack(spacing: 10) {
                reviewDeck
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !queuedReviewDeletionCandidates.isEmpty {
                    let count = queuedReviewDeletionCandidates.count
                    let title = count == 1
                        ? l10n("Delete 1 Photo", lang: appLanguage)
                        : String(format: l10n("Delete %d Photos", lang: appLanguage), count)
                    Button {
                        isReviewDeletionConfirmationPresented = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash.fill")
                                .font(.dashboardText(size: 13, weight: .bold))
                            Text(title)
                                .font(.dashboardSubheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .foregroundStyle(.white)
                        .background(Color.red.gradient, in: Capsule())
                        .shadow(color: .red.opacity(0.35), radius: 6, y: 3)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
                reviewActionControls
                if let reviewLastDecision {
                    Label(reviewDecisionMessage(for: reviewLastDecision), systemImage: reviewLastDecision == .keep ? "heart.fill" : "trash.fill")
                        .font(.dashboardCaption2)
                        .foregroundStyle(reviewLastDecision == .keep ? .green : .secondary)
                        .transition(.opacity)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1.0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var reviewDeck: some View {
        ZStack {
            ForEach(Array(reviewFiles.prefix(3).enumerated()), id: \.element.id) { index, item in
                if index == 0 {
                    ReviewSwipeCard(
                        item: item,
                        camera: selectedGalleryDevice?.camera,
                        thumbnail: item.file.name.flatMap { deviceMonitor.thumbnails[$0] },
                        thumbnailFailed: item.file.name.map { deviceMonitor.failedThumbnails.contains($0) } ?? false,
                        localURL: backupEngine.localURL(for: item.file),
                        remotePreview: item.file.name.flatMap { deviceMonitor.reviewPreviews[$0] },
                        onDecision: handleReviewDecision,
                        onPreview: { openReviewPreview(for: item) }
                    )
                    .id(item.id)
                    .zIndex(3)
                } else {
                    // Peeking cards behind the active one, so the next photo is
                    // already in place when the top card swipes away instead of
                    // popping in abruptly.
                    ReviewStackedCardBackground(
                        thumbnail: item.file.name.flatMap { deviceMonitor.reviewPreviews[$0] ?? deviceMonitor.thumbnails[$0] },
                        isVideo: item.file.isVideoFile
                    )
                    .scaleEffect(1 - CGFloat(index) * 0.05)
                    .offset(y: CGFloat(index) * 12)
                    .opacity(index == 1 ? 0.85 : 0.55)
                    .allowsHitTesting(false)
                    .id(item.id)
                    .zIndex(Double(3 - index))
                }
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: reviewFiles.map(\.id))
    }

    @ViewBuilder
    private var reviewActionControls: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    ReviewDecisionButton(decision: .delete) { handleReviewDecision(.delete) }
                    ReviewPreviousButton(isDisabled: reviewHistory.isEmpty) { handleReviewPrevious() }
                    ReviewSessionButton { isReviewSummaryPresented = true }
                    ReviewDecisionButton(decision: .keep) { handleReviewDecision(.keep) }
                }
            }
        } else {
            HStack(spacing: 12) {
                ReviewDecisionButton(decision: .delete) { handleReviewDecision(.delete) }
                ReviewPreviousButton(isDisabled: reviewHistory.isEmpty) { handleReviewPrevious() }
                ReviewSessionButton { isReviewSummaryPresented = true }
                ReviewDecisionButton(decision: .keep) { handleReviewDecision(.keep) }
            }
        }
    }

    private func reviewEmptyState(
        icon: String,
        title: String,
        detail: String,
        showsProgress: Bool = false,
        glowColor: Color? = nil
    ) -> some View {
        VStack(spacing: 12) {
            if showsProgress {
                ProgressView()
                    .controlSize(.regular)
            } else {
                Image(systemName: icon)
                    .font(.dashboardText(size: 34, weight: .light))
                    .foregroundStyle(glowColor ?? Color.secondary)
            }
            Text(title)
                .font(.dashboardHeadline)
            Text(detail)
                .font(.dashboardSubheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(glowColor?.opacity(0.5) ?? Color.primary.opacity(0.12), lineWidth: glowColor == nil ? 1.0 : 1.5)
        }
        .shadow(color: glowColor?.opacity(0.45) ?? .clear, radius: 20)
        .shadow(color: glowColor?.opacity(0.3) ?? .clear, radius: 40)
    }

    private var reviewQueueCountText: String {
        let count = reviewFiles.count
        let itemText = count == 1 ? "1 \(l10n("item left", lang: appLanguage))" : "\(count) \(l10n("items left", lang: appLanguage))"
        let queuedCount = queuedReviewDeletionCandidates.count
        let queueText = queuedCount == 0 ? itemText : "\(itemText) · \(queuedCount) \(l10n("marked", lang: appLanguage))"
        guard readyGalleryDevices.count > 1, let device = selectedGalleryDevice else { return queueText }
        return "\(queueText) \(l10n("on", lang: appLanguage)) \(device.name)"
    }

    private var reviewEmptyMessage: String {
        switch reviewMediaFilter {
        case .all: return l10n("There are no photos or videos left for this review session.", lang: appLanguage)
        case .photos: return l10n("There are no photos left for this review session.", lang: appLanguage)
        case .videos: return l10n("There are no videos left for this review session.", lang: appLanguage)
        }
    }

    private func reviewDecisionMessage(for decision: ReviewDecision) -> String {
        switch decision {
        case .keep: return l10n("Kept in your library", lang: appLanguage)
        case .delete: return l10n("Marked to delete at session end", lang: appLanguage)
        }
    }

    private func handleReviewDecision(_ decision: ReviewDecision) {
        guard let item = reviewFiles.first else { return }

        reviewHistory.append(ReviewHistoryEntry(item: item, decision: decision))
        // Persist to cross-session cache so this item is never shown again
        ReviewProcessedCache.shared.markProcessed(id: item.id)
        if let name = item.file.name {
            deviceMonitor.purgeReviewPreview(for: name)
        }

        switch decision {
        case .keep:
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                dismissedReviewItemIDs.insert(item.id)
                reviewFiles.removeFirst()
                reviewKeptItemCount += 1
                reviewLastDecision = .keep
            }
            presentReviewDeletionConfirmationIfNeeded()
        case .delete:
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                dismissedReviewItemIDs.insert(item.id)
                queuedReviewDeletionCandidates[item.id] = item
                reviewFiles.removeFirst()
                reviewLastDecision = .delete
            }
            presentReviewDeletionConfirmationIfNeeded()
        }
    }

    private func handleReviewPrevious() {
        guard let last = reviewHistory.popLast() else { return }
        // Undo the cache entry so the item can appear again in future sessions
        ReviewProcessedCache.shared.unmarkProcessed(id: last.item.id)
        ReviewProcessedCache.shared.removeRecentDeletions(matchingIDs: [last.item.id])
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            dismissedReviewItemIDs.remove(last.item.id)
            if last.decision == .delete {
                queuedReviewDeletionCandidates.removeValue(forKey: last.item.id)
            } else if last.decision == .keep {
                reviewKeptItemCount = max(0, reviewKeptItemCount - 1)
            }
            reviewFiles.insert(last.item, at: 0)
            reviewLastDecision = reviewHistory.last?.decision
        }
    }

    private func keepQueuedReviewItems() {
        reviewKeptItemCount += queuedReviewDeletionCandidates.count
        queuedReviewDeletionCandidates.removeAll()
        reviewLastDecision = .keep
    }

    private func openReviewPreview(for item: GalleryItem) {
        if let localURL = backupEngine.localURL(for: item.file),
           FileManager.default.fileExists(atPath: localURL.path) {
            previewManager.openLocalPreview(at: localURL)
        } else {
            selectedPreviewItem = item
            previewManager.openNativePreview(for: item.file, camera: selectedGalleryDevice?.camera)
        }
    }

    private var reviewSessionSummarySheet: some View {
        VStack(spacing: 18) {
            Image(systemName: "chart.bar.xaxis")
                .font(.dashboardText(size: 30, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 5) {
                Text(l10n("Review session", lang: appLanguage))
                    .font(.dashboardTitle3.weight(.semibold))
                Text(l10n("Your progress is saved while you take a break.", lang: appLanguage))
                    .font(.dashboardSubheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                reviewResultMetric(
                    value: reviewKeptItemCount,
                    title: l10n("Kept", lang: appLanguage),
                    icon: "heart.fill",
                    color: .green
                )
                reviewResultMetric(
                    value: queuedReviewDeletionCandidates.count,
                    title: l10n("Marked", lang: appLanguage),
                    icon: "trash.fill",
                    color: .red
                )
                reviewResultMetric(
                    value: reviewFiles.count,
                    title: l10n("Remaining", lang: appLanguage),
                    icon: "rectangle.stack",
                    color: .blue
                )
            }

            VStack(spacing: 10) {
                if !queuedReviewDeletionCandidates.isEmpty {
                    let count = queuedReviewDeletionCandidates.count
                    let title = count == 1 ? l10n("Review 1 Marked Item", lang: appLanguage) : String(format: l10n("Review %d Marked Items", lang: appLanguage), count)
                    Button(title) {
                        isReviewSummaryPresented = false
                        DispatchQueue.main.async {
                            isReviewDeletionConfirmationPresented = true
                        }
                    }
                    .appButton(.destructive)
                }

                Button(l10n("Leave for Now", lang: appLanguage)) {
                    isReviewSummaryPresented = false
                    selectedTab = .gallery
                }
                .appButton(.secondary)

                Button(role: .destructive) {
                    resetReviewSession()
                } label: {
                    Label(l10n("Reset & Start Over", lang: appLanguage), systemImage: "arrow.counterclockwise")
                        .font(.dashboardSubheadline.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        }
        .frame(width: 360)
        .themedSheetChrome()
    }

    private func reviewResultMetric(value: Int, title: String, icon: String, color: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.dashboardCaption.weight(.bold))
                .foregroundStyle(color)
            Text("\(value)")
                .font(.dashboardText(.title3, design: .rounded).weight(.bold))
            Text(title)
                .font(.dashboardCaption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func presentReviewDeletionConfirmationIfNeeded() {
        guard reviewFiles.isEmpty, !queuedReviewDeletionCandidates.isEmpty else { return }
        DispatchQueue.main.async {
            guard reviewFiles.isEmpty, !queuedReviewDeletionCandidates.isEmpty else { return }
            isReviewDeletionConfirmationPresented = true
        }
    }

    private func handleReviewRefreshTapped() {
        if !queuedReviewDeletionCandidates.isEmpty {
            isReviewDiscardAlertPresented = true
            return
        }
        checkForRecentDeletionsOnDevice()
    }

    private func checkForRecentDeletionsOnDevice() {
        guard deviceMonitor.isDeviceConnected, let reviewDevice = selectedGalleryDevice else {
            resetReviewSession()
            return
        }

        let recentRecords = ReviewProcessedCache.shared.allRecentDeletions()
        guard !recentRecords.isEmpty else {
            resetReviewSession()
            return
        }

        let rawFiles = deviceMonitor.allReadyDiscoveredFiles(for: reviewDevice.id)
        let recentIDs = Set(recentRecords.map(\.id))
        let recentNames = Set(recentRecords.map(\.name))

        var foundItems: [GalleryItem] = []
        for file in rawFiles {
            guard let name = file.name else { continue }
            let id = backupEngine.manifestKey(for: file)
            if recentIDs.contains(id) || recentNames.contains(name) {
                foundItems.append(GalleryItem(id: id, name: name, file: file))
            }
        }

        if !foundItems.isEmpty {
            recentDeletionsToRetry = foundItems
            isRetryRecentDeletionsAlertPresented = true
        } else {
            resetReviewSession()
        }
    }

    private func retryDeletingRecentItems(_ items: [GalleryItem]) {
        guard deviceMonitor.isDeviceConnected else {
            alertErrorMessage = "Your phone disconnected before the items could be deleted."
            showErrorAlert = true
            resetReviewSession()
            return
        }

        let records = items.compactMap { item -> (id: String, name: String)? in
            guard let name = item.file.name else { return nil }
            return (id: item.id, name: name)
        }
        ReviewProcessedCache.shared.recordRecentDeletions(records)

        for item in items {
            pendingReviewDeletions[item.id] = item
            deviceMonitor.deleteFileFromDevice(item.file)
        }
        resetReviewSession()
    }

    private func deleteQueuedReviewItems() {
        let items = Array(queuedReviewDeletionCandidates.values)
        guard !items.isEmpty else { return }
        guard deviceMonitor.isDeviceConnected, selectedGalleryDevice?.isReady == true else {
            alertErrorMessage = "Your phone disconnected before the marked items could be deleted."
            showErrorAlert = true
            return
        }

        let records = items.compactMap { item -> (id: String, name: String)? in
            guard let name = item.file.name else { return nil }
            return (id: item.id, name: name)
        }
        ReviewProcessedCache.shared.recordRecentDeletions(records)

        for item in items {
            pendingReviewDeletions[item.id] = item
            deviceMonitor.deleteFileFromDevice(item.file)
        }
        queuedReviewDeletionCandidates.removeAll()
        reviewLastDecision = .delete
    }

    private func restoreFailedReviewDeletions(from failedNames: Set<String>) {
        guard !failedNames.isEmpty else { return }
        let failedItems = pendingReviewDeletions.values.filter { item in
            failedNames.contains(item.name)
        }

        for item in failedItems {
            pendingReviewDeletions.removeValue(forKey: item.id)
            dismissedReviewItemIDs.remove(item.id)
            if !reviewFiles.contains(item) {
                reviewFiles.append(item)
            }
        }
        if !reviewFiles.isEmpty {
            reviewFiles.sort { ($0.file.effectiveCaptureDate ?? .distantPast) > ($1.file.effectiveCaptureDate ?? .distantPast) }
        }

        let count = failedItems.isEmpty ? failedNames.count : failedItems.count
        alertErrorTitle = "Deletion Blocked by iPhone"
        alertErrorMessage = count == 1
            ? l10n("Your iPhone could not delete 1 photo. If iCloud Photos ('Sync this iPhone') is turned on, iOS blocks deletion over USB. Please delete it directly on your iPhone.", lang: appLanguage)
            : String(format: l10n("Your iPhone could not delete %d photos. If iCloud Photos ('Sync this iPhone') is turned on, iOS blocks deletion over USB. Please delete them directly on your iPhone.", lang: appLanguage), count)
        showErrorAlert = true
    }

    private func preloadReviewThumbnails() {
        for item in reviewFiles.prefix(4) {
            let localURL = backupEngine.localURL(for: item.file)
            deviceMonitor.requestThumbnail(for: item.file, localURL: localURL)
            if let localURL, FileManager.default.fileExists(atPath: localURL.path) {
                continue
            }
            if item.file.isPhotoFile {
                deviceMonitor.requestReviewPreview(for: item.file, camera: selectedGalleryDevice?.camera)
            }
        }
    }

    private func reloadReviewQueue() {
        ensureSelectedGalleryDevice()
        let token = UUID()
        reviewReloadToken = token
        reviewLoadTask?.cancel()
        reviewIsLoading = true

        reviewLoadTask = Task {
            defer {
                if reviewReloadToken == token {
                    reviewIsLoading = false
                }
            }

            guard deviceMonitor.isDeviceConnected,
                  let reviewDevice = selectedGalleryDevice else {
                guard reviewReloadToken == token else { return }
                reviewFiles = []
                return
            }

            let typeFilter = reviewMediaFilter
            let dateFilter = reviewDateFilter
            let dismissedIDs = dismissedReviewItemIDs
            let cachedIDs = ReviewProcessedCache.shared.processedIDs
            let pendingIDs = Set(pendingReviewDeletions.keys)
            let now = Date()
            let rawFiles = deviceMonitor.allReadyDiscoveredFiles(for: reviewDevice.id)

            var snapshots: [CameraFileFilterSnapshot] = []
            snapshots.reserveCapacity(rawFiles.count)
            for (index, file) in rawFiles.enumerated() {
                if index > 0 && index % 500 == 0 {
                    await Task.yield()
                    guard !Task.isCancelled, reviewReloadToken == token else { return }
                }
                snapshots.append(CameraFileFilterSnapshot(
                    index: index,
                    id: backupEngine.manifestKey(for: file),
                    name: file.name ?? "IMG_0000",
                    isPhoto: file.isPhotoFile,
                    isVideo: file.isVideoFile,
                    captureDate: file.effectiveCaptureDate,
                    isBackedUp: false
                ))
            }

            let matchingIndices = await Task.detached(priority: .userInitiated) {
                let calendar = Calendar.autoupdatingCurrent
                let startOfWeek = calendar.date(byAdding: .day, value: -7, to: now)
                let mediaFiles = snapshots.filter { snapshot in
                    guard snapshot.isPhoto || snapshot.isVideo else { return false }
                    let extensionName = (snapshot.name as NSString).pathExtension.lowercased()
                    return !["aae", "plist", "thm", "lrv"].contains(extensionName)
                }

                let editedBaseNames = Set(mediaFiles.compactMap { snapshot -> String? in
                    guard BackupEngine.isIOSEditedDuplicate(name: snapshot.name) else { return nil }
                    let base = snapshot.name.replacingOccurrences(of: "IMG_E", with: "IMG_")
                    return (base as NSString).deletingPathExtension.uppercased()
                })

                var seenAssetKeys = Set<String>()
                let matching = mediaFiles.compactMap { snapshot -> CameraFileFilterSnapshot? in
                    let nameWithoutExtension = (snapshot.name as NSString).deletingPathExtension.uppercased()
                    if !BackupEngine.isIOSEditedDuplicate(name: snapshot.name),
                       editedBaseNames.contains(nameWithoutExtension) {
                        return nil
                    }

                    switch typeFilter {
                    case .all: break
                    case .photos where !snapshot.isPhoto: return nil
                    case .videos where !snapshot.isVideo: return nil
                    default: break
                    }

                    guard let captureDate = snapshot.captureDate else { return nil }
                    let matchesDate: Bool
                    switch dateFilter {
                    case .today:
                        matchesDate = calendar.isDate(captureDate, inSameDayAs: now)
                    case .thisWeek:
                        matchesDate = startOfWeek.map { captureDate >= $0 && captureDate <= now } ?? false
                    case .thisMonth:
                        matchesDate = calendar.isDate(captureDate, equalTo: now, toGranularity: .month) &&
                            calendar.isDate(captureDate, equalTo: now, toGranularity: .year)
                    }

                    guard matchesDate,
                          !dismissedIDs.contains(snapshot.id),
                          !pendingIDs.contains(snapshot.id),
                          !cachedIDs.contains(snapshot.id),
                          seenAssetKeys.insert(snapshot.id).inserted else {
                        return nil
                    }
                    return snapshot
                }

                return matching
                    .sorted { ($0.captureDate ?? .distantPast) > ($1.captureDate ?? .distantPast) }
                    .map(\.index)
            }.value

            guard !Task.isCancelled, reviewReloadToken == token else { return }
            reviewFiles = matchingIndices.compactMap { index in
                guard rawFiles.indices.contains(index) else { return nil }
                let snapshot = snapshots[index]
                return GalleryItem(id: snapshot.id, name: snapshot.name, file: rawFiles[index])
            }
            preloadReviewThumbnails()
        }
    }

    // MARK: - Settings Tab

    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            aboutSettingsGroup

            settingsGroup(
                title: "General",
                subtitle: l10n("System-level behaviour for this app.", lang: appLanguage),
                icon: "macmini.fill",
                color: .gray
            ) {
                settingsToggle(
                    title: l10n("Auto-launch when a device connects", lang: appLanguage),
                    detail: l10n("Automatically opens the app whenever you connect your iPhone via USB.", lang: appLanguage),
                    isOn: Binding(
                        get: { launchAtLogin },
                        set: { newValue in
                            launchAtLogin = newValue
                            LaunchAtLoginManager.shared.setEnabled(newValue)
                        }
                    )
                )
                settingsDivider
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l10n("Default tab on launch", lang: appLanguage))
                            .font(.dashboardSubheadline)
                        Text(l10n("Choose which tab opens when the app starts.", lang: appLanguage))
                            .font(.dashboardCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $defaultLaunchTab) {
                        ForEach(DashboardTab.allCases, id: \.rawValue) { tab in
                            Text(tab.rawValue).tag(tab.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }
            .onAppear { launchAtLogin = LaunchAtLoginManager.shared.isEnabled }

            settingsGroup(
                title: "Automatic Backup",
                subtitle: l10n("How connected devices are handled.", lang: appLanguage),
                icon: "bolt.circle.fill",
                color: .green
            ) {
                settingsToggle(
                    title: l10n("Back up automatically", lang: appLanguage),
                    detail: l10n("Start when a trusted device is connected by USB. If several are connected, they wait in line and back up one at a time.", lang: appLanguage),
                    isOn: $autoBackupActive
                )
                settingsDivider
                settingsToggle(
                    title: l10n("Prompt for Quick Swiping before sync", lang: appLanguage),
                    detail: l10n("If there are unreviewed photos on your device, ask to swipe and clean before automatic backup begins.", lang: appLanguage),
                    isOn: $promptQuickSwipeBeforeSync
                )
                .disabled(!autoBackupActive)
                settingsDivider
                settingsToggle(
                    title: l10n("Open folder when finished", lang: appLanguage),
                    detail: l10n("Show the destination in Finder after a successful backup.", lang: appLanguage),
                    isOn: $openFolderAfterBackup
                )
            }

            settingsGroup(
                title: l10n("Quick Swiping", lang: appLanguage),
                subtitle: l10n("Manage your swipe review history.", lang: appLanguage),
                icon: "rectangle.portrait.and.arrow.forward",
                color: .purple
            ) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l10n("Processed photos cache", lang: appLanguage))
                            .font(.dashboardSubheadline)
                        Text(l10n("Photos you've swiped are hidden from future sessions. Clear to review them again.", lang: appLanguage))
                            .font(.dashboardCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(ReviewProcessedCache.shared.processedIDs.count) \(l10n("items cached", lang: appLanguage))")
                            .font(.dashboardCaption)
                            .foregroundStyle(.secondary)
                        Button(l10n("Clear Cache", lang: appLanguage)) {
                            ReviewProcessedCache.shared.clearAll()
                            dismissedReviewItemIDs.removeAll()
                            reloadReviewQueue()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                    }
                }
            }

            // MARK: - Device Configurations
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.dashboardText(size: 17, weight: .semibold))
                        .foregroundStyle(Color.blue)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l10n("Device Settings", lang: appLanguage))
                            .font(.dashboardHeadline)
                        Text(l10n("Custom backup configurations for your devices.", lang: appLanguage))
                            .font(.dashboardCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                // Default device settings card
                deviceSettingsCard(
                    id: "",
                    name: l10n("Default for new devices", lang: appLanguage),
                    isConnected: false,
                    isDefault: true
                )

                // Remembered device cards
                ForEach(settingsDevices) { item in
                    deviceSettingsCard(
                        id: item.id,
                        name: item.name,
                        isConnected: item.isConnected,
                        isDefault: false
                    )
                }
            }

            settingsGroup(
                title: "Appearance",
                subtitle: l10n("Choose how the app looks on your Mac.", lang: appLanguage),
                icon: "paintbrush.fill",
                color: .indigo
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(l10n("Theme Color", lang: appLanguage))
                            .font(.dashboardSubheadline.weight(.semibold))
                        
                        HStack(spacing: 12) {
                            ForEach(ThemeColor.allCases) { colorOption in
                                Button {
                                    themeColor = colorOption
                                } label: {
                                    ZStack {
                                        if colorOption == .default {
                                            Image(systemName: "circle.slash")
                                                .font(.dashboardText(size: 16))
                                                .foregroundColor(themeColor == colorOption ? .primary : .secondary)
                                        } else {
                                            Circle()
                                                .fill(colorOption.color ?? .clear)
                                                .frame(width: 24, height: 24)
                                                .shadow(color: (colorOption.color ?? .clear).opacity(0.4), radius: themeColor == colorOption ? 8 : 0)
                                        }
                                    }
                                    .frame(width: 44, height: 44)
                                    .background {
                                        if themeColor == colorOption {
                                            VisualEffectView(material: .selection, blendingMode: .withinWindow)
                                                .clipShape(Circle())
                                        } else {
                                            Circle().fill(Color.primary.opacity(0.06))
                                        }
                                    }
                                    .overlay {
                                        Circle()
                                            .stroke(themeColor == colorOption ? (colorOption.color ?? .primary) : .primary.opacity(0.15), lineWidth: themeColor == colorOption ? 2.5 : 1)
                                    }
                                }
                                .buttonStyle(.plain)
                                .scaleEffect(themeColor == colorOption ? 1.1 : 1.0)
                                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: themeColor)
                            }
                        }
                    }

                    settingsDivider

                    VStack(alignment: .leading, spacing: 8) {
                        Text(l10n("Language", lang: appLanguage))
                            .font(.dashboardSubheadline.weight(.semibold))

                        HStack(spacing: 0) {
                            let options = [
                                ("en", "English"),
                                ("he", "עברית")
                            ]
                            ForEach(options, id: \.0) { option in
                                let isSelected = appLanguage == option.0
                                Button {
                                    appLanguage = option.0
                                } label: {
                                    Text(option.1)
                                        .font(.dashboardText(size: 12, weight: isSelected ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 6)
                                        .frame(maxWidth: .infinity)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background {
                                    if isSelected {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(Color.primary.opacity(0.13))
                                            .matchedGeometryEffect(id: "languagePill", in: languageSegmentNamespace)
                                    }
                                }
                            }
                        }
                        .padding(3)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: appLanguage)
                        .frame(width: 160)
                    }
                }
            }

            settingsGroup(
                title: "Advanced",
                subtitle: l10n("Use these when you want cleanup or extra options.", lang: appLanguage),
                icon: "slider.horizontal.3",
                color: .orange
            ) {
                settingsToggle(
                    title: l10n("Delete from iPhone after backup", lang: appLanguage),
                    detail: l10n("After a file is safely copied, ask iOS to remove it from the camera roll.", lang: appLanguage),
                    isOn: deleteAfterBackupBinding
                )
            }
        }
    }

    private var deleteAfterBackupBinding: Binding<Bool> {
        Binding(
            get: { deleteAfterBackup },
            set: { enabled in
                if enabled && !deleteAfterBackup {
                    showDeleteAfterBackupWarning = true
                } else if !enabled {
                    deleteAfterBackup = false
                }
            }
        )
    }

    private var aboutSettingsGroup: some View {
        settingsGroup(
            title: "About",
            subtitle: "iPhone Backup Center Engine",
            icon: "info.circle.fill",
            color: .secondary
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("iPhone Backup Center Engine")
                            .font(.dashboardSubheadline.weight(.semibold))
                        Text("Version 2.4.0 (Build 2026.6)")
                            .font(.dashboardCaption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(l10n("Replay guide", lang: appLanguage), systemImage: "arrow.counterclockwise") {
                        startSettingsGuide()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .accessibilityLabel(l10n("Replay app guide", lang: appLanguage))
                    .help(l10n("Replay the 30-second app guide", lang: appLanguage))
                }

                if settingsGuideIsVisible {
                    settingsGuideAnimation
                        .id(settingsGuideStep)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                }

                settingsDivider

                Text(l10n("Copyright © 2026 Personal Local Backup Tooling. All rights reserved.", lang: appLanguage))
                    .font(.dashboardText(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var settingsGuideAnimation: some View {
        let stage = GuideStage.allCases[settingsGuideStep]
        let totalTime = GuideStage.allCases.count * 5
        let remaining = max(0, totalTime - settingsGuideStep * 5)

        return HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(stage.title)
                        .font(.dashboardSubheadline.weight(.bold))
                        .foregroundStyle(stage.color)
                    Spacer()
                    Text("\(remaining)\(l10n(" sec", lang: appLanguage))")
                        .font(.dashboardCaption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(stage.detail)
                    .font(.dashboardCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)

                Spacer(minLength: 6)

                HStack(spacing: 5) {
                    ForEach(GuideStage.allCases.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == settingsGuideStep ? stage.color : Color.primary.opacity(0.15))
                            .frame(width: index == settingsGuideStep ? 22 : 6, height: 4)
                            .animation(.snappy, value: settingsGuideStep)
                    }
                }
                .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SettingsGuideAnimation(stage: stage)
                .frame(width: 280, height: 136)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(stage.color.opacity(0.22), lineWidth: 1)
        )
    }

    private func mediaTypeBadgeText(_ type: Int) -> String {
        switch type {
        case 1: return l10n("Photos only", lang: appLanguage)
        case 2: return l10n("Videos only", lang: appLanguage)
        default: return l10n("Photos & videos", lang: appLanguage)
        }
    }

    private func folderOrgBadgeText(year: Bool, month: Bool) -> String {
        switch (year, month) {
        case (true, true): return l10n("Year & month folders", lang: appLanguage)
        case (true, false): return l10n("Year folders only", lang: appLanguage)
        case (false, true): return l10n("Month folders only", lang: appLanguage)
        case (false, false): return l10n("Flat folder (no subfolders)", lang: appLanguage)
        }
    }

    @ViewBuilder
    private func deviceSettingsCard(
        id: String,
        name: String,
        isConnected: Bool,
        isDefault: Bool
    ) -> some View {
        let destination = isDefault ? appDelegate?.resolvedBackupDestination() : appDelegate?.resolvedBackupDestination(for: id)
        let mediaType = isDefault ? backupMediaType : (appDelegate?.mediaType(for: id) ?? backupMediaType)
        let organizeYear = isDefault ? organizeByYear : (appDelegate?.organizeByYear(for: id) ?? organizeByYear)
        let organizeMonth = isDefault ? organizeByMonth : (appDelegate?.organizeByMonth(for: id) ?? organizeByMonth)
        let skipEdited = isDefault ? skipEditedDuplicates : (appDelegate?.skipEditedDuplicates(for: id) ?? skipEditedDuplicates)
        let isUnlocked = unlockedDeviceIDs.contains(id)

        VStack(alignment: .leading, spacing: 12) {
            // Header Row
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isDefault ? "gearshape.2.fill" : deviceIcon(for: name))
                    .font(.dashboardText(size: 17, weight: .semibold))
                    .foregroundStyle(isDefault ? Color.blue : (isConnected ? Color.green : Color.secondary))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(name)
                            .font(.dashboardHeadline)

                        if !isDefault {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(isConnected ? Color.green : Color.secondary.opacity(0.6))
                                    .frame(width: 6, height: 6)
                                Text(isConnected ? l10n("Connected", lang: appLanguage) : l10n("Disconnected", lang: appLanguage))
                                    .font(.dashboardText(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                    }

                    if isDefault {
                        Text(l10n("Default settings applied when a new device connects.", lang: appLanguage))
                            .font(.dashboardCaption)
                            .foregroundStyle(.secondary)
                    } else if let destination {
                        Text(destination.path)
                            .font(.dashboardText(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(l10n("No folder selected", lang: appLanguage))
                            .font(.dashboardCaption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        if isUnlocked {
                            unlockedDeviceIDs.remove(id)
                        } else {
                            unlockedDeviceIDs.insert(id)
                        }
                    }
                } label: {
                    Label(
                        isUnlocked ? l10n("Done", lang: appLanguage) : l10n("Edit Settings", lang: appLanguage),
                        systemImage: isUnlocked ? "checkmark.circle.fill" : "lock.fill"
                    )
                    .font(.dashboardText(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(isUnlocked ? .accentColor : .secondary)
            }

            if isUnlocked {
                // EDITING (UNLOCKED) CONTROLS
                VStack(alignment: .leading, spacing: 14) {
                    settingsDivider

                    // Destination row
                    VStack(alignment: .leading, spacing: 6) {
                        Text(l10n("Destination", lang: appLanguage))
                            .font(.dashboardSubheadline.weight(.semibold))

                        HStack(alignment: .center, spacing: 10) {
                            if let destination {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(destination.path)
                                        .font(.dashboardText(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)

                                    if isDestinationAvailable(destination) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.dashboardText(size: 10))
                                                .foregroundStyle(.green)
                                            Text(l10n("Folder available", lang: appLanguage))
                                                .font(.dashboardCaption2)
                                                .foregroundStyle(.green)
                                        }
                                    } else {
                                        HStack(spacing: 4) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .font(.dashboardText(size: 10))
                                                .foregroundStyle(.orange)
                                            Text(l10n("Folder not available (unmounted volume or moved)", lang: appLanguage))
                                                .font(.dashboardCaption2)
                                                .foregroundStyle(.orange)
                                        }

                                        Button {
                                            reconnectSMBShare(for: isDefault ? nil : id)
                                        } label: {
                                            Label(l10n("Reconnect via Finder", lang: appLanguage), systemImage: "network")
                                                .font(.dashboardCaption2)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.orange.opacity(0.12))
                                        .foregroundStyle(.orange)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    }
                                }
                            } else {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder.badge.questionmark")
                                        .font(.dashboardText(size: 11))
                                        .foregroundStyle(.secondary)
                                    Text(l10n("No folder selected", lang: appLanguage))
                                        .font(.dashboardCaption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer(minLength: 8)

                            Button {
                                appDelegate?.chooseBackupFolder(for: isDefault ? "" : id)
                            } label: {
                                Label(l10n("Choose...", lang: appLanguage), systemImage: "folder")
                            }
                            .appButton(.secondary)
                        }
                    }

                    settingsDivider

                    // What to copy (Media type)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(l10n("Media type", lang: appLanguage))
                            .font(.dashboardSubheadline.weight(.semibold))

                        HStack(spacing: 0) {
                            let options = [
                                (0, l10n("Photos and videos", lang: appLanguage)),
                                (1, l10n("Photos only", lang: appLanguage)),
                                (2, l10n("Videos only", lang: appLanguage))
                            ]
                            ForEach(options, id: \.0) { option in
                                let isSelected = mediaType == option.0
                                Button {
                                    appDelegate?.setMediaType(option.0, for: isDefault ? "" : id)
                                    if isDefault { backupMediaType = option.0 }
                                    destinationVersion += 1
                                } label: {
                                    Text(option.1)
                                        .font(.dashboardText(size: 12, weight: isSelected ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 5)
                                        .frame(maxWidth: .infinity)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background {
                                    if isSelected {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(Color.primary.opacity(0.13))
                                    }
                                }
                            }
                        }
                        .padding(3)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    settingsDivider

                    // Skip edited duplicates
                    Toggle(isOn: Binding(
                        get: { isDefault ? skipEditedDuplicates : (appDelegate?.skipEditedDuplicates(for: id) ?? skipEditedDuplicates) },
                        set: { newValue in
                            appDelegate?.setSkipEditedDuplicates(newValue, for: isDefault ? "" : id)
                            if isDefault { skipEditedDuplicates = newValue }
                            destinationVersion += 1
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l10n("Skip edited duplicates", lang: appLanguage))
                                .font(.dashboardSubheadline.weight(.semibold))
                            Text(l10n("Ignore IMG_E files created by iOS edits when you only want originals.", lang: appLanguage))
                                .font(.dashboardCaption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .appToggleStyle()

                    settingsDivider

                    // Folder organization toggles
                    VStack(alignment: .leading, spacing: 8) {
                        Text(l10n("Folder Organization", lang: appLanguage))
                            .font(.dashboardSubheadline.weight(.semibold))

                        HStack(spacing: 18) {
                            Toggle(l10n("Year folders", lang: appLanguage), isOn: Binding(
                                get: { isDefault ? organizeByYear : (appDelegate?.organizeByYear(for: id) ?? organizeByYear) },
                                set: { newValue in
                                    appDelegate?.setOrganizeByYear(newValue, for: isDefault ? "" : id)
                                    if isDefault { organizeByYear = newValue }
                                    destinationVersion += 1
                                }
                            ))
                            .appToggleStyle()

                            Toggle(l10n("Month folders", lang: appLanguage), isOn: Binding(
                                get: { isDefault ? organizeByMonth : (appDelegate?.organizeByMonth(for: id) ?? organizeByMonth) },
                                set: { newValue in
                                    appDelegate?.setOrganizeByMonth(newValue, for: isDefault ? "" : id)
                                    if isDefault { organizeByMonth = newValue }
                                    destinationVersion += 1
                                }
                            ))
                            .appToggleStyle()
                        }
                    }

                    if !isDefault && !isConnected {
                        settingsDivider

                        HStack {
                            Spacer()
                            Button(role: .destructive) {
                                deviceToForget = SettingsDeviceItem(id: id, name: name, isConnected: isConnected)
                                showForgetDeviceAlert = true
                            } label: {
                                Label(l10n("Forget this device", lang: appLanguage), systemImage: "trash")
                                    .font(.dashboardCaption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }
                }
                .padding(.leading, 34)
            } else {
                // LOCKED SUMMARY VIEW
                HStack(spacing: 8) {
                    // Destination badge
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.dashboardText(size: 10))
                            .foregroundStyle(.blue)
                        Text(destination?.lastPathComponent ?? l10n("No folder selected", lang: appLanguage))
                            .font(.dashboardCaption2.weight(.medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1), in: Capsule())

                    // Media type badge
                    HStack(spacing: 4) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.dashboardText(size: 10))
                            .foregroundStyle(.purple)
                        Text(mediaTypeBadgeText(mediaType))
                            .font(.dashboardCaption2.weight(.medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.purple.opacity(0.1), in: Capsule())

                    // Folder org badge
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.stack.fill")
                            .font(.dashboardText(size: 10))
                            .foregroundStyle(.teal)
                        Text(folderOrgBadgeText(year: organizeYear, month: organizeMonth))
                            .font(.dashboardCaption2.weight(.medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.teal.opacity(0.1), in: Capsule())

                    if skipEdited {
                        HStack(spacing: 4) {
                            Image(systemName: "scissors")
                                .font(.dashboardText(size: 10))
                                .foregroundStyle(.orange)
                            Text(l10n("Skip edited duplicates", lang: appLanguage))
                                .font(.dashboardCaption2.weight(.medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.1), in: Capsule())
                    }

                    Spacer()

                    Image(systemName: "lock.fill")
                        .font(.dashboardText(size: 10))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .padding(.leading, 34)
            }
        }
        .padding(14)
        .themedCard()
    }


    private func settingsGroup<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.dashboardText(size: 17, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.dashboardHeadline)
                    Text(subtitle)
                        .font(.dashboardCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            content()
                .padding(.leading, 34)
        }
        .padding(14)
        .themedCard()
    }

    private func settingsToggle(
        title: String,
        detail: String,
        isOn: Binding<Bool>,
        isDestructive: Bool = false
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.dashboardSubheadline.weight(.semibold))
                    .foregroundStyle(isDestructive && isOn.wrappedValue ? Color.red : Color.primary)
                Text(detail)
                    .font(.dashboardCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .appToggleStyle()
    }

    private var settingsDivider: some View {
        Divider()
            .opacity(0.18)
    }

    private var mediaTypeDescription: String {
        switch backupMediaType {
        case 1: return "Only still image files will be copied."
        case 2: return "Only video files will be copied."
        default: return "Photos and videos from the camera roll will be copied."
        }
    }

    private var folderOrganizationDescription: String {
        switch (organizeByYear, organizeByMonth) {
        case (true, true):
            return "Files will be saved into year folders with month subfolders, such as 2026 / 06 - June."
        case (true, false):
            return "Files will be grouped by year."
        case (false, true):
            return "Files will be grouped into month folders."
        case (false, false):
            return "Files will be saved directly into the chosen backup folder."
        }
    }

    // MARK: - Bottom Actions Row

    private var bottomActions: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                onClose()
            } label: {
                Label("Quit App", systemImage: "power")
            }
            .appButton(.destructive, size: .large)
            
            Spacer()
            
            let engineIsBusy = {
                switch backupEngine.state {
                case .scanning, .copying: return true
                default: return false
                }
            }()
            let syncableDevices = readyDevicesForManualSync
            
            if engineIsBusy {
                if appAppearance == .liquidGlass {
                    HaltTaskGlassButton {
                        backupEngine.cancelBackup()
                    }
                } else {
                    Button(role: .destructive) {
                        backupEngine.cancelBackup()
                    } label: {
                        Label("Halt Active Task", systemImage: "xmark.circle.fill")
                    }
                    .appButton(.destructive, size: .large)
                }
            } else {
                if appAppearance == .liquidGlass {
                    SyncNowGlassMenu(
                        syncableDevices: syncableDevices,
                        onForceBackup: onForceBackup,
                        appDelegate: appDelegate
                    )
                } else {
                    Menu {
                        Button {
                            if syncableDevices.count > 1 {
                                appDelegate?.requestForceBackupChoice(scanMode: .incremental)
                            } else if let device = syncableDevices.first {
                                appDelegate?.enqueueForceBackup(for: device.id, scanMode: .incremental)
                            } else {
                                onForceBackup(false)
                            }
                        } label: {
                            Label(l10n("Sync Delta Now", lang: appLanguage), systemImage: "arrow.triangle.2.circlepath.circle.fill")
                        }
                        
                        Button {
                            if syncableDevices.count > 1 {
                                appDelegate?.requestForceBackupChoice(scanMode: .deepValidation)
                            } else if let device = syncableDevices.first {
                                appDelegate?.enqueueForceBackup(for: device.id, scanMode: .deepValidation)
                            } else {
                                onForceBackup(true)
                            }
                        } label: {
                            Label(l10n("Run Deep Validation Sync", lang: appLanguage), systemImage: "arrow.clockwise.circle")
                        }

                        Button {
                            if syncableDevices.count > 1 {
                                appDelegate?.requestForceBackupChoice(scanMode: .fullRecountAndReconcile)
                            } else if let device = syncableDevices.first {
                                appDelegate?.enqueueForceBackup(for: device.id, scanMode: .fullRecountAndReconcile)
                            } else {
                                onForceBackup(true)
                            }
                        } label: {
                            Label(l10n("Full Library Recount & Verify", lang: appLanguage), systemImage: "checklist.checked")
                        }
                    } label: {
                        Label(l10n("Sync Now...", lang: appLanguage), systemImage: "arrow.triangle.2.circlepath.circle.fill")
                    }
                    .menuStyle(.button)
                    .appButton(.primary, size: .large)
                    .disabled(syncableDevices.isEmpty)
                }
            }
        }
        .padding(.horizontal, appAppearance == .liquidGlass ? 22 : (appAppearance.isModernDesign ? 14 : 20))
        .padding(.vertical, appAppearance == .liquidGlass ? 14 : (appAppearance.isModernDesign ? 10 : 16))
        .themedBottomBarBackground()
        .padding(.horizontal, appAppearance == .liquidGlass ? 16 : (appAppearance.isModernDesign ? 12 : 0))
        .padding(.bottom, appAppearance == .liquidGlass ? 8 : (appAppearance.isModernDesign ? 2 : 0))
    }

    private func updateStorageInfo() {
        guard let url = ssdMonitor.ssdURL, ssdMonitor.isSSDConnected else {
            self.storageInfo = ""
            return
        }
        Task {
            do {
                let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
                if let avail = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity {
                    let formatter = ByteCountFormatter()
                    formatter.allowedUnits = .useGB
                    formatter.countStyle = .file
                    let availStr = formatter.string(fromByteCount: Int64(avail))
                    let totalStr = formatter.string(fromByteCount: Int64(total))
                    
                    await MainActor.run {
                        self.storageInfo = "\(availStr) free of \(totalStr)"
                    }
                }
            } catch {
                await MainActor.run { self.storageInfo = "Connected" }
            }
        }
    }

    private func refreshBackupManifest() {
        guard let destination = activeBackupDestination,
              isDestinationAvailable(destination) else { return }
        backupEngine.useManifest(at: destination)
    }
}

// MARK: - Liquid Glass Action Controls

@MainActor
private final class SyncMenuActionHelper: NSObject {
    static let shared = SyncMenuActionHelper()
    
    var syncableDevices: [ConnectedDevice] = []
    var appDelegate: AppDelegate? = nil
    var onForceBackup: ((Bool) -> Void)? = nil

    @objc func runDeltaSync() {
        triggerSync(scanMode: .incremental)
    }

    @objc func runDeepSync() {
        triggerSync(scanMode: .deepValidation)
    }

    @objc func runFullRecountSync() {
        triggerSync(scanMode: .fullRecountAndReconcile)
    }

    private func triggerSync(scanMode: BackupScanMode) {
        if syncableDevices.count > 1 {
            appDelegate?.requestForceBackupChoice(scanMode: scanMode)
        } else if let device = syncableDevices.first {
            appDelegate?.enqueueForceBackup(for: device.id, scanMode: scanMode)
        } else {
            onForceBackup?(scanMode != .incremental)
        }
    }
}

private struct SyncNowGlassMenu: View {
    let syncableDevices: [ConnectedDevice]
    let onForceBackup: (Bool) -> Void
    let appDelegate: AppDelegate?

    @AppStorage("appLanguage") private var appLanguage: String = "en"

    private var tint: Color {
        Color.accentColor
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            button
                .glassEffect(.regular.tint(tint.opacity(0.42)).interactive(), in: .rect(cornerRadius: 18))
        } else {
            button
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(tint.opacity(0.35), lineWidth: 1)
                }
        }
    }

    private var button: some View {
        Button(action: showSyncMenu) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.dashboardText(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                Text(l10n("Sync Now...", lang: appLanguage))
                    .font(.dashboardText(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
            }
            .frame(height: 48)
            .padding(.horizontal, 20)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(syncableDevices.isEmpty)
        .opacity(syncableDevices.isEmpty ? 0.45 : 1.0)
    }

    private func showSyncMenu() {
        let helper = SyncMenuActionHelper.shared
        helper.syncableDevices = syncableDevices
        helper.appDelegate = appDelegate
        helper.onForceBackup = onForceBackup

        let menu = NSMenu(title: "")
        let deltaItem = NSMenuItem(
            title: l10n("Sync Delta Now", lang: appLanguage),
            action: #selector(SyncMenuActionHelper.runDeltaSync),
            keyEquivalent: ""
        )
        deltaItem.target = helper
        deltaItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.circle.fill", accessibilityDescription: nil)

        let deepItem = NSMenuItem(
            title: l10n("Run Deep Validation Sync", lang: appLanguage),
            action: #selector(SyncMenuActionHelper.runDeepSync),
            keyEquivalent: ""
        )
        deepItem.target = helper
        deepItem.image = NSImage(systemSymbolName: "arrow.clockwise.circle", accessibilityDescription: nil)

        let recountItem = NSMenuItem(
            title: l10n("Full Library Recount & Verify", lang: appLanguage),
            action: #selector(SyncMenuActionHelper.runFullRecountSync),
            keyEquivalent: ""
        )
        recountItem.target = helper
        recountItem.image = NSImage(systemSymbolName: "checklist.checked", accessibilityDescription: nil)

        menu.addItem(deltaItem)
        menu.addItem(deepItem)
        menu.addItem(recountItem)

        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
        }
    }
}

private struct HaltTaskGlassButton: View {
    let action: () -> Void

    @AppStorage("appLanguage") private var appLanguage: String = "en"
    private var tint: Color { .red }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            button
                .glassEffect(.regular.tint(tint.opacity(0.42)).interactive(), in: .rect(cornerRadius: 18))
        } else {
            button
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(tint.opacity(0.35), lineWidth: 1)
                }
        }
    }

    private var button: some View {
        Button(role: .destructive, action: action) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .font(.dashboardText(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                Text(l10n("Halt Active Task", lang: appLanguage))
                    .font(.dashboardText(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
            }
            .frame(height: 48)
            .padding(.horizontal, 20)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Swipe Review Controls

private struct ReviewDecisionButton: View {
    let decision: ReviewDecision
    let action: () -> Void

    @AppStorage("appLanguage") private var appLanguage: String = "en"

    private var tint: Color {
        decision == .keep ? .green : .red
    }

    private var title: String {
        decision == .keep ? l10n("Keep", lang: appLanguage) : l10n("Delete", lang: appLanguage)
    }

    private var icon: String {
        decision == .keep ? "heart.fill" : "trash.fill"
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            button
                .glassEffect(.regular.tint(tint.opacity(0.42)).interactive(), in: .rect(cornerRadius: 18))
        } else {
            button
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(tint.opacity(0.35), lineWidth: 1)
                }
        }
    }

    private var button: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.dashboardText(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.dashboardCaption2.weight(.semibold))
                    .foregroundStyle(.black)
            }
            .frame(width: 82, height: 48)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(decision == .keep ? .rightArrow : .leftArrow, modifiers: [])
        .accessibilityHint(decision == .keep ? "Keeps this item and shows the next one." : "Marks this item to be deleted at the end of the session.")
    }
}

private struct ReviewPreviousButton: View {
    let isDisabled: Bool
    let action: () -> Void

    @AppStorage("appLanguage") private var appLanguage: String = "en"

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            button
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        } else {
            button
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                }
        }
    }

    private var button: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.dashboardText(size: 14, weight: .semibold))
                Text(l10n("Previous", lang: appLanguage))
                    .font(.dashboardCaption2.weight(.semibold))
            }
            .foregroundStyle(isDisabled ? Color.secondary.opacity(0.35) : Color.primary)
            .frame(width: 74, height: 48)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .keyboardShortcut("z", modifiers: [.command])
        .accessibilityLabel(l10n("Previous", lang: appLanguage))
        .accessibilityHint(l10n("Undo previous choice", lang: appLanguage))
    }
}

private struct ReviewSessionButton: View {
    let action: () -> Void

    @AppStorage("appLanguage") private var appLanguage: String = "en"

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            button
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        } else {
            button
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                }
        }
    }

    private var button: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: "pause.fill")
                    .font(.dashboardText(size: 14, weight: .semibold))
                Text(l10n("Leave", lang: appLanguage))
                    .font(.dashboardCaption2.weight(.semibold))
            }
            .foregroundStyle(.primary)
            .frame(width: 74, height: 48)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Review session summary")
        .accessibilityHint("Shows your review result and lets you leave for now.")
    }
}

@MainActor
final class ReviewVideoDownloader: NSObject, @preconcurrency ICCameraDeviceDownloadDelegate {
    static let shared = ReviewVideoDownloader()

    private var activeContinuations: [String: CheckedContinuation<URL, Error>] = [:]

    func downloadVideo(file: ICCameraFile, camera: ICCameraDevice) async throws -> URL {
        let name = file.name ?? "video_\(UUID().uuidString).mov"
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ReviewTempVideos", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let destURL = tempDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destURL)

        return try await withCheckedThrowingContinuation { continuation in
            activeContinuations[name] = continuation

            let options: [ICDownloadOption: Any] = [
                .downloadsDirectoryURL: tempDir,
                .overwrite: true,
                .sidecarFiles: false
            ]

            camera.requestDownloadFile(
                file,
                options: options,
                downloadDelegate: self,
                didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)),
                contextInfo: nil
            )
        }
    }

    @objc func didDownloadFile(
        _ file: ICCameraFile,
        error downloadError: Error?,
        options: [String: Any],
        contextInfo: UnsafeMutableRawPointer?
    ) {
        Task { @MainActor in
            let name = file.name ?? ""
            guard let cont = self.activeContinuations.removeValue(forKey: name) else { return }
            if let downloadError {
                cont.resume(throwing: downloadError)
                return
            }
            let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ReviewTempVideos", isDirectory: true)
            let destURL = tempDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destURL.path) {
                cont.resume(returning: destURL)
            } else {
                cont.resume(throwing: NSError(domain: "ReviewVideoDownloader", code: 404, userInfo: [NSLocalizedDescriptionKey: "Downloaded video file not found"]))
            }
        }
    }
}

private struct InlineVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerContainerNSView {
        let view = PlayerContainerNSView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: PlayerContainerNSView, context: Context) {
        if nsView.playerLayer.player != player {
            nsView.playerLayer.player = player
        }
    }

    final class PlayerContainerNSView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }
}

private struct ReviewVideoPreviewButton: View {
    let isPlaying: Bool
    let isDownloading: Bool
    let action: () -> Void

    @AppStorage("appLanguage") private var appLanguage: String = "en"

    var body: some View {
        if isDownloading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(l10n("Loading video…", lang: appLanguage))
                    .font(.dashboardCaption.weight(.medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.60), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        } else if !isPlaying {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.55))
                    Circle()
                        .strokeBorder(Color.white.opacity(0.50), lineWidth: 1.5)
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.white)
                        .offset(x: 2)
                }
                .frame(width: 60, height: 60)
                .contentShape(Circle())
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(l10n("Play video", lang: appLanguage))
            .accessibilityHint("Plays the video inline inside this card.")
        }
    }
}

/// A static, non-interactive peek of an upcoming review item, stacked behind
/// the active ReviewSwipeCard so the deck reads as a continuous flow rather
/// than the next photo popping in after the current one swipes away.
private struct ReviewStackedCardBackground: View {
    let thumbnail: CGImage?
    let isVideo: Bool

    private let cardShape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)

            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.30), Color.indigo.opacity(0.35), Color.black.opacity(0.65)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: isVideo ? "film" : "photo")
                    .font(.dashboardText(size: 42, weight: .light))
                    .foregroundStyle(.white.opacity(0.86))
            }

            LinearGradient(
                colors: [.black.opacity(0.20), .clear, .black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .clipShape(cardShape)
        .overlay {
            cardShape.strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 10, y: 6)
    }
}

private struct ReviewSwipeCard: View {
    let item: GalleryItem
    let camera: ICCameraDevice?
    let thumbnail: CGImage?
    let thumbnailFailed: Bool
    let localURL: URL?
    let remotePreview: CGImage?
    let onDecision: (ReviewDecision) -> Void
    let onPreview: () -> Void

    @AppStorage("appLanguage") private var appLanguage: String = "en"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0
    @State private var isCommittingDecision = false

    @State private var player: AVPlayer? = nil
    @State private var isPlayingVideo = false
    @State private var isDownloadingVideo = false
    @State private var isMuted = false
    @State private var tempVideoURL: URL? = nil
    @State private var downloadError: String? = nil
    @State private var endObserver: NSObjectProtocol? = nil

    private let cardShape = RoundedRectangle(cornerRadius: 24, style: .continuous)
    private let swipeThreshold: CGFloat = 88

    var body: some View {
        card
            .task(id: item.id) {
                if item.file.isVideoFile {
                    startAutoPlayVideo()
                }
            }
            .onDisappear {
                cleanupVideoPlayer()
            }
            .onChange(of: item.id) { _ in
                cleanupVideoPlayer()
            }
    }

    private var card: some View {
        ZStack {
            Color.black.opacity(0.32)

            if item.file.isVideoFile, let player {
                InlineVideoPlayerView(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture {
                        togglePlayVideo()
                    }
            } else {
                ReviewMediaImage(
                    localURL: item.file.isVideoFile ? nil : localURL,
                    remotePreview: remotePreview,
                    thumbnail: thumbnail
                ) {
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.30), Color.indigo.opacity(0.35), Color.black.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    VStack(spacing: 10) {
                        Image(systemName: item.file.isVideoFile ? "film" : "photo")
                            .font(.dashboardText(size: 42, weight: .light))
                        if !thumbnailFailed {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .foregroundStyle(.white.opacity(0.86))
                }
            }

            LinearGradient(
                colors: [.black.opacity(0.20), .clear, .black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            if item.file.isVideoFile {
                ReviewVideoPreviewButton(
                    isPlaying: isPlayingVideo,
                    isDownloading: isDownloadingVideo,
                    action: togglePlayVideo
                )
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            }

            VStack {
                HStack {
                    swipeStamp(title: l10n("KEEP", lang: appLanguage), icon: "heart.fill", color: .green, opacity: positiveSwipeProgress)
                    Spacer()
                    if item.file.isVideoFile, player != nil {
                        Button {
                            isMuted.toggle()
                            player?.isMuted = isMuted
                        } label: {
                            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.dashboardText(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(Color.black.opacity(0.55), in: Circle())
                                .overlay {
                                    Circle().strokeBorder(Color.white.opacity(0.30), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 8)
                        .accessibilityLabel(isMuted ? "Unmute video" : "Mute video")
                    }
                    swipeStamp(title: l10n("DELETE", lang: appLanguage), icon: "trash.fill", color: .red, opacity: negativeSwipeProgress)
                }
                Spacer()
                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.dashboardText(.headline, design: .rounded).weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Label(item.file.isVideoFile ? l10n("Video", lang: appLanguage) : l10n("Photo", lang: appLanguage), systemImage: item.file.isVideoFile ? "film" : "photo")
                            .font(.dashboardCaption)
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    Spacer()
                    Button(action: onPreview) {
                        Label(l10n("Quick Look", lang: appLanguage), systemImage: item.file.isVideoFile ? "play.circle.fill" : "eye.fill")
                            .font(.dashboardText(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.45), in: Capsule())
                            .overlay {
                                Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Quick Look Preview")
                    .accessibilityHint("Opens native macOS Quick Look preview for this photo or video.")
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .clipShape(cardShape)
        .overlay {
            cardShape
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 16, y: 10)
        .offset(x: dragOffset)
        .rotationEffect(.degrees(Double(dragOffset / 24)))
        .contentShape(cardShape)
        .gesture(swipeGesture)
        .overlay {
            TwoFingerSwipeRecognizer(
                onChange: { translation in
                    guard !isCommittingDecision else { return }
                    dragOffset = translation
                },
                onEnd: { translation in
                    guard !isCommittingDecision else { return }
                    if translation >= swipeThreshold {
                        commit(.keep)
                    } else if translation <= -swipeThreshold {
                        commit(.delete)
                    } else {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                            dragOffset = 0
                        }
                    }
                }
            )
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.file.isVideoFile ? "Video" : "Photo") \(item.name)")
        .accessibilityHint(item.file.isVideoFile
            ? "Select Play to play the video inline. Drag or use a two-finger swipe right to keep, or left to mark for deletion."
            : "Drag or use a two-finger swipe right to keep. Drag or use a two-finger swipe left to mark the item for deletion at session end.")
    }

    private func startAutoPlayVideo() {
        guard item.file.isVideoFile else { return }

        if let player {
            player.play()
            isPlayingVideo = true
            return
        }

        // 1. Check local file
        if let localURL, FileManager.default.fileExists(atPath: localURL.path) {
            startPlayback(url: localURL, isTemp: false)
            return
        }

        // 2. Download from iPhone
        guard let camera else { return }

        isDownloadingVideo = true
        downloadError = nil

        Task { @MainActor in
            do {
                let downloadedURL = try await ReviewVideoDownloader.shared.downloadVideo(file: item.file, camera: camera)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: downloadedURL)
                    return
                }
                self.isDownloadingVideo = false
                self.tempVideoURL = downloadedURL
                self.startPlayback(url: downloadedURL, isTemp: true)
            } catch {
                self.isDownloadingVideo = false
                self.downloadError = error.localizedDescription
            }
        }
    }

    private func togglePlayVideo() {
        if let player {
            if isPlayingVideo {
                player.pause()
                isPlayingVideo = false
            } else {
                player.play()
                isPlayingVideo = true
            }
            return
        }

        // 1. Check if local video file exists in backup destination
        if let localURL, FileManager.default.fileExists(atPath: localURL.path) {
            startPlayback(url: localURL, isTemp: false)
            return
        }

        // 2. Download from iPhone camera
        guard let camera else {
            downloadError = l10n("No camera connected", lang: appLanguage)
            return
        }

        isDownloadingVideo = true
        downloadError = nil

        Task { @MainActor in
            do {
                let downloadedURL = try await ReviewVideoDownloader.shared.downloadVideo(file: item.file, camera: camera)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: downloadedURL)
                    return
                }
                self.isDownloadingVideo = false
                self.tempVideoURL = downloadedURL
                self.startPlayback(url: downloadedURL, isTemp: true)
            } catch {
                self.isDownloadingVideo = false
                self.downloadError = error.localizedDescription
            }
        }
    }

    private func startPlayback(url: URL, isTemp: Bool) {
        let playerItem = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.isMuted = isMuted
        newPlayer.actionAtItemEnd = .none

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak newPlayer] _ in
            newPlayer?.seek(to: .zero)
            newPlayer?.play()
        }

        self.player = newPlayer
        self.isPlayingVideo = true
        newPlayer.play()
    }

    private func cleanupVideoPlayer() {
        player?.pause()
        player = nil
        isPlayingVideo = false
        isDownloadingVideo = false
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let tempVideoURL {
            try? FileManager.default.removeItem(at: tempVideoURL)
            self.tempVideoURL = nil
        }
    }

    private var positiveSwipeProgress: Double {
        min(max(Double(dragOffset / swipeThreshold), 0), 1)
    }

    private var negativeSwipeProgress: Double {
        min(max(Double(-dragOffset / swipeThreshold), 0), 1)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard !isCommittingDecision else { return }
                dragOffset = value.translation.width
            }
            .onEnded { value in
                guard !isCommittingDecision else { return }
                if value.translation.width >= swipeThreshold {
                    commit(.keep)
                } else if value.translation.width <= -swipeThreshold {
                    commit(.delete)
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func swipeStamp(title: String, icon: String, color: Color, opacity: Double) -> some View {
        Label(title, systemImage: icon)
            .font(.dashboardText(size: 12, weight: .heavy, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.26), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(color.opacity(0.85), lineWidth: 1.5)
            }
            .opacity(opacity)
            .scaleEffect(0.88 + opacity * 0.12)
    }

    private func commit(_ decision: ReviewDecision) {
        cleanupVideoPlayer()
        isCommittingDecision = true
        let targetOffset: CGFloat = decision == .keep ? 720 : -720
        let transitionDuration = reduceMotion ? 0.01 : 0.20

        withAnimation(.spring(response: reduceMotion ? 0.01 : 0.26, dampingFraction: 0.82)) {
            dragOffset = targetOffset
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + transitionDuration) {
            dragOffset = 0
            isCommittingDecision = false
            onDecision(decision)
        }
    }
}

/// Observes a trackpad's precise scroll events without sitting in front of the
/// SwiftUI card. That keeps buttons on the card clickable while driving the
/// card's offset live, the same way a mouse DragGesture would.
private struct TwoFingerSwipeRecognizer: NSViewRepresentable {
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        TrackpadSwipeObserver(onChange: onChange, onEnd: onEnd)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let observer = nsView as? TrackpadSwipeObserver else { return }
        observer.onChange = onChange
        observer.onEnd = onEnd
    }

    private final class TrackpadSwipeObserver: NSView {
        var onChange: (CGFloat) -> Void
        var onEnd: (CGFloat) -> Void
        private var monitor: Any?
        private var horizontalDistance: CGFloat = 0
        private var isTrackingHorizontalSwipe = false

        init(onChange: @escaping (CGFloat) -> Void, onEnd: @escaping (CGFloat) -> Void) {
            self.onChange = onChange
            self.onEnd = onEnd
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installMonitorIfNeeded()
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.observe(event)
                return event
            }
        }

        private func observe(_ event: NSEvent) {
            guard event.hasPreciseScrollingDeltas,
                  let window,
                  event.window === window else { return }

            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return }

            let horizontal = event.scrollingDeltaX
            let vertical = event.scrollingDeltaY
            let isHorizontal = abs(horizontal) > abs(vertical)

            switch event.phase {
            case .began:
                horizontalDistance = 0
                isTrackingHorizontalSwipe = isHorizontal
            case .changed:
                if isHorizontal || isTrackingHorizontalSwipe {
                    isTrackingHorizontalSwipe = true
                    horizontalDistance += horizontal
                    onChange(horizontalDistance)
                }
            case .ended, .cancelled:
                defer {
                    horizontalDistance = 0
                    isTrackingHorizontalSwipe = false
                }
                guard isTrackingHorizontalSwipe else { return }
                onEnd(horizontalDistance)
            default:
                break
            }
        }
    }
}

/// Uses the original backed-up photo whenever it is available. Camera-provided
/// thumbnails are intentionally tiny, so they remain only as a fast fallback.
private struct ReviewMediaImage<Placeholder: View>: View {
    let localURL: URL?
    let remotePreview: CGImage?
    let thumbnail: CGImage?
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var fullResolutionImage: CGImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.20)

            Group {
                if let fullResolutionImage {
                    Image(decorative: fullResolutionImage, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .transition(.opacity)
                } else if let remotePreview {
                    Image(decorative: remotePreview, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .transition(.opacity)
                } else if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .transition(.opacity)
                } else {
                    placeholder()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: localURL?.path) {
            fullResolutionImage = nil
            guard let localURL,
                  FileManager.default.fileExists(atPath: localURL.path) else { return }

            let image = await Task.detached(priority: .userInitiated) {
                Self.loadImage(at: localURL)
            }.value
            guard !Task.isCancelled else { return }
            fullResolutionImage = image
        }
    }

    nonisolated private static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_560,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

private struct WindowTransparencyConfigurator: NSViewRepresentable {
    let appearance: AppAppearance

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true

        // Sizing belongs to AppKit.  This representable is updated whenever
        // SwiftUI changes, so resizing here prevented window restoration and
        // discarded the user's chosen size.
    }
}

// MARK: - Native Quick Look Preview Manager
// Downloads the selected camera file to a temp directory, then opens macOS
// QLPreviewPanel — the same native viewer used by Finder's spacebar preview.
// This works for HEIC photos, MOV/MP4 videos, and any other format QL supports.

@MainActor
class PreviewManager: NSObject, ObservableObject {
    @Published var isDownloading = false
    @Published var error: String? = nil
    /// Set when the file is ready on disk. The SwiftUI overlay observes this
    /// to dismiss itself once native Quick Look has opened.
    @Published var readyURL: URL? = nil

    private var dataSource: QLDataSource? = nil

    func openLocalPreview(at url: URL) {
        isDownloading = false
        error = nil
        readyURL = url
        presentQuickLook(url: url)
    }

    func openNativePreview(for file: ICCameraFile, camera: ICCameraDevice?) {
        isDownloading = true
        error = nil
        readyURL = nil

        guard let camera else {
            error = "No connected camera device."
            isDownloading = false
            return
        }

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let destURL = tempDir.appendingPathComponent(file.name ?? "preview_asset")
        try? FileManager.default.removeItem(at: destURL)

        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: tempDir,
            .overwrite: true,
            .sidecarFiles: false
        ]

        camera.requestDownloadFile(
            file,
            options: options,
            downloadDelegate: self,
            didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)),
            contextInfo: nil
        )
    }

    func cancelDownload() {
        isDownloading = false
        // Close QL panel if open
        if QLPreviewPanel.sharedPreviewPanelExists() {
            QLPreviewPanel.shared().close()
        }
        dataSource = nil
    }

    private func presentQuickLook(url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        let ds = QLDataSource(url: url)
        self.dataSource = ds
        panel.dataSource = ds
        panel.delegate = ds
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

extension PreviewManager: @preconcurrency ICCameraDeviceDownloadDelegate {
    @objc func didDownloadFile(
        _ file: ICCameraFile,
        error downloadError: Error?,
        options: [String: Any],
        contextInfo: UnsafeMutableRawPointer?
    ) {
        Task { @MainActor in
            self.isDownloading = false
            if let err = downloadError {
                self.error = err.localizedDescription
                return
            }
            let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            let url = tempDir.appendingPathComponent(file.name ?? "")
            guard FileManager.default.fileExists(atPath: url.path) else {
                self.error = "Download finished but file not found on disk."
                return
            }
            self.readyURL = url
            self.presentQuickLook(url: url)
        }
    }
}

// MARK: - QL data source / delegate
// A lightweight NSObject wrapper that drives QLPreviewPanel.
// Uses @preconcurrency to satisfy the Obj-C delegate protocols without
// triggering actor-isolation errors (the methods are called on the main thread).

final class QLDataSource: NSObject {
    private let url: URL
    init(url: URL) { self.url = url }
}

extension QLDataSource: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL
    }
}

extension QLDataSource: @preconcurrency QLPreviewPanelDelegate {
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool { false }
}
