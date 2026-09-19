# iPhone Photos Backup 📸⚡

<p align="center">
  <strong>The ultra-fast, privacy-first local backup and photo management utility for macOS.</strong><br>
  Back up your iPhone photos directly to your Mac, external SSD, or Network Drive (SMB/NAS) without cloud subscriptions, compression, or lock-in.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2015.0%2B-blue?logo=apple&style=flat-square" alt="Platform" />
  <img src="https://img.shields.io/badge/Swift-5.10%20%7C%20SwiftUI-orange?logo=swift&style=flat-square" alt="Swift / SwiftUI" />
  <img src="https://img.shields.io/badge/Architecture-Apple%20Silicon%20(arm64)-black?style=flat-square" alt="Architecture" />
  <img src="https://img.shields.io/badge/Localization-English%20%7C%20Hebrew%20(RTL)-brightgreen?style=flat-square" alt="Localization" />
  <img src="https://img.shields.io/badge/License-MIT-lightgrey?style=flat-square" alt="License" />
</p>

---

## 🌟 Overview

**iPhonePhotosBackup** is a high-performance native macOS desktop application designed to give you complete control over your photo and video libraries. Instead of relying on expensive cloud storage or clunky sync software, **iPhonePhotosBackup** talks directly to your iPhone via Apple's low-level `ImageCaptureCore` framework.

Connect your iPhone via USB, and it automatically organizes and backs up your original, uncompressed media to any destination of your choice — whether that's your Mac's internal storage, a high-speed external SSD, or your home NAS.

---

## ✨ Key Features

### ⚡ Blazing Fast Auto-Backup
- **Plug & Play Detection**: Instantly detects your iPhone upon connection via USB or Wi-Fi.
- **Smart Delta Sync**: Only transfers new photos and videos captured since your last backup session, finishing routine backups in seconds.
- **Deep Validation Sync**: Scans destination volumes against the device library to verify file integrity, size consistency, and detect missing items.
- **Live Transfer Console**: Real-time progress monitoring displaying live transfer speed (MB/s), remaining items, estimated time to completion, and individual photo status.

### 🧹 Quick Swiping (Declutter & Clean)
- **Tinder-Style Curation**: Review newly captured photos before backing them up with intuitive swipe gestures:
  - 👉 **Swipe Right / Keep**: Retain the photo in your library.
  - 👈 **Swipe Left / Delete**: Mark unwanted photos, bursts, or blurry shots for permanent deletion.
  - ↩️ **Undo**: Instantly revert mistaken swipes with full state history.
- **Batch Deletion**: Review all marked photos and delete them in one permanent batch operation.
- **Recent Deletion Cache & Retry**: Keeps a robust JSON cache of deleted asset IDs. If Apple's ImageCapture service is interrupted or blocked by iCloud sync, the Refresh button detects unremoved assets and prompts you to retry with one click.
- **iCloud Photos Awareness**: Clear contextual alerts if iCloud "Optimize iPhone Storage" prevents direct USB deletions.

### 🖼️ Phone Gallery & Live Index
- **Device Gallery Browser**: Browse your iPhone's camera roll directly inside the Mac app with cached high-speed thumbnails.
- **QuickLook Support**: Hit <kbd>Space</kbd> on any asset for instantaneous full-resolution image or video previews.
- **Smart Temporal Filters**: View media filtered by **New / Not Backed Up**, **Backed Up**, **Today**, **This Week**, or **This Month**.

### 💾 Flexible Storage & External SSD Resilience
- **Any Storage Target**: Save to local folders, external SSDs/HDDs, network volumes (SMB / NFS / NAS), or Cloud mirrors (iCloud Drive, Google Drive, Dropbox).
- **SSD Auto-Monitor**: Monitors external drives in real time. If a drive is unplugged or runs low on disk space, backups safely pause and notify you.
- **Per-Device Custom Paths**: Assign individual destination folders for different family iPhones or iPads.

### 📂 Automated Organization
- **Hierarchical Folders**: Automatically sorts media into `YYYY/` or `YYYY/MM - MonthName/` subdirectories.
- **Media Type Filtering**: Choose to back up **All Media**, **Photos Only**, or **Videos Only**.
- **Duplicate Suppression**: Intelligently ignores duplicate modified/edited versions if configured.

### 🎨 Native macOS Liquid Glass Experience
- **Liquid Glass Aesthetics**: Designed for macOS Sequoia with frosted glass materials, fluid spring animations, and native sidebar navigation.
- **Theme Color Customization**: Personalize your interface with accent themes (Default, Blue, Light Blue, Purple, Green, Yellow, Orange, Red, Grey).
- **Menu Bar Companion**: Quiet background status item in your macOS menu bar with real-time transfer animations and quick actions.
- **Full Internationalization (RTL)**: Complete localization for **English** and **Hebrew (עברית)**, featuring automatic Right-to-Left layout mirroring.
- **Launch at Login**: Seamlessly monitor for device connections in the background without needing to manually launch the app.

---

## 🛠️ Architecture & Tech Stack

- **UI Framework**: SwiftUI + AppKit integration (Liquid Glass design system, native split views, QuickLook UI).
- **Device Communication**: `ImageCaptureCore` (`ICDeviceBrowser`, `ICCameraDevice`, `ICCameraFile`) for driver-level camera connection and file streaming.
- **File System & Storage**: Native POSIX file system APIs, security-scoped bookmarks, volume mount monitoring via `NSWorkspace` notifications.
- **Concurrency**: Swift modern structured concurrency (`async`/`await`, `Task`, `@MainActor`).
- **No Heavy Third-Party Dependencies**: Zero CocoaPods or external package dependencies. Compiles directly using the native macOS SDK.

---

## 🚀 Getting Started

### Prerequisites
- Mac running **macOS 15.0 (Sequoia)** or later.
- Apple Silicon (M1/M2/M3/M4) or Intel Mac with macOS SDK installed.
- Xcode Command Line Tools (`xcode-select --install`).

### 1. Clone the Repository
```bash
git clone https://github.com/netanel3000fine/iPhonePhotosBackup.git
cd iPhonePhotosBackup
```

### 2. Build and Run
Use the provided build script to compile the Swift sources, bundle resources and localizations, sign with local entitlements, and launch:

```bash
chmod +x Build-iPhonePhotosBackup.sh
./Build-iPhonePhotosBackup.sh
```

To build without launching immediately:
```bash
./Build-iPhonePhotosBackup.sh --no-launch
```

### 3. Package as a Distributable DMG
To package a standalone, drag-and-drop installer `.dmg`:
```bash
chmod +x Create-DMG-Package.sh
./Create-DMG-Package.sh
```
The resulting `.dmg` will be created in the project root (e.g. `iPhonePhotosBackup-YYYY.MM.DD.dmg`).

---

## 📱 iPhone Setup & Permissions

1. **Connect via USB**: Connect your iPhone to your Mac with a Lightning or USB-C cable.
2. **Unlock iPhone**: Ensure your iPhone screen is unlocked.
3. **Trust This Computer**: If prompted on your iPhone, tap **Trust** and enter your passcode.
4. **iCloud Photos Note**:
   - If your iPhone has **iCloud Photos** enabled with **"Optimize iPhone Storage"**, some full-resolution photos may reside in iCloud rather than local flash memory.
   - Deletions via USB are restricted by iOS while photos are actively syncing with iCloud. For complete USB management, download full originals or disable "Optimize Storage" in *Settings > Photos*.

---

## 📁 Project Structure

```
iPhonePhotosBackup/
├── Sources/
│   └── iPhonePhotosBackup/
│       ├── main.swift                   # Application entry point
│       ├── AppDelegate.swift            # Lifecycle, menu bar status item, window management
│       ├── DashboardView.swift          # Main dashboard (Status, Gallery, Quick Swipe, Settings)
│       ├── BackupEngine.swift           # File transfer, validation sync, folder organization
│       ├── DeviceMonitor.swift          # ImageCaptureCore device discovery & connection
│       ├── LiveBackupDetailView.swift   # Detailed transfer console & live speed metrics
│       ├── ReviewProcessedCache.swift   # Cache for swiped items & recent deletion tracking
│       ├── SSDMonitor.swift             # External volume and disk space monitoring
│       ├── AppAppearance.swift          # Liquid Glass theme engine & color styling
│       ├── SettingsGuideAnimation.swift # Animated onboarding & guide visuals
│       ├── LaunchAtLoginManager.swift   # SMAppService launch-at-login manager
│       └── Resources/
│           ├── en.lproj/                # English strings & localization
│           └── he.lproj/                # Hebrew strings & RTL localization
├── AppIcon.icns                         # High-resolution macOS application icon
├── Info.plist                           # Bundle metadata & camera access permissions
├── app.entitlements                     # USB and file access entitlements
├── Build-iPhonePhotosBackup.sh          # Swift compilation and bundling script
├── Create-DMG-Package.sh                # Distributable DMG packaging script
└── README.md
```

---

## 🤝 Contributing

Contributions, feature suggestions, and bug reports are welcome!
1. Fork the project.
2. Create your feature branch (`git checkout -b feature/AmazingFeature`).
3. Commit your changes (`git commit -m 'feat: Add AmazingFeature'`).
4. Push to the branch (`git push origin feature/AmazingFeature`).
5. Open a Pull Request.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

<p align="center">
  Crafted with ❤️ for effortless, independent photo management.
</p>
