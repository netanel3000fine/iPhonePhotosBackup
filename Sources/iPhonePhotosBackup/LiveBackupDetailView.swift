import SwiftUI
import AppKit
import ImageCaptureCore

struct LiveBackupDetailView: View {
  @ObservedObject var backupEngine: BackupEngine
  @ObservedObject var deviceMonitor: DeviceMonitor
  var onClose: () -> Void

  @AppStorage("appLanguage") private var appLanguage: String = "en"
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isProgressRingActive = false
  @State private var isConsolePresented = false
  @State private var isLivePulseActive = false

  private let tileSize: CGFloat = 132

  var body: some View {
    ZStack {
      ConsoleBackdrop()

      switch backupEngine.state {
      case .completed(let count):
        completionSummary(count: count, failed: backupEngine.stats.failedCount)
      case .failed(let reason):
        errorSummary(reason: reason)
      default:
        activeConsole
      }
    }
    .frame(minWidth: 840, minHeight: 640)
    .environment(\.appTheme, AppTheme.theme(for: .liquidGlass))
    .environment(\.appAppearance, .liquidGlass)
    .task {
      guard !reduceMotion else {
        isProgressRingActive = true
        isConsolePresented = true
        return
      }
      withAnimation(.smooth(duration: 0.7)) {
        isProgressRingActive = true
        isConsolePresented = true
      }
      withAnimation(.smooth(duration: 1.35).repeatForever(autoreverses: true)) {
        isLivePulseActive = true
      }
    }
  }

  // MARK: - Active Console Layout

  @ViewBuilder
  private var activeConsole: some View {
    if #available(macOS 26.0, *) {
      GlassEffectContainer(spacing: 18) {
        consoleContent
      }
    } else {
      consoleContent
    }
  }

  private var consoleContent: some View {
    VStack(spacing: 20) {
      headerBar
      .opacity(isConsolePresented ? 1 : 0)
      .offset(y: isConsolePresented ? 0 : -10)

      HStack(alignment: .top, spacing: 18) {
        leftColumn
        .frame(width: 282)

        rightColumn
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .opacity(isConsolePresented ? 1 : 0)
      .offset(y: isConsolePresented ? 0 : 14)
    }
    .padding(28)
    .animation(.snappy(duration: 0.45), value: isConsolePresented)
  }

  // MARK: - Completion Summary

  private func completionSummary(count: Int, failed: Int) -> some View {
    let s = backupEngine.stats
    let vStats = backupEngine.validationStats
    let showAuditCard = s.reorganizedCount > 0 || vStats?.isRecountComplete == true || s.isFullBackup

    return VStack(spacing: 24) {
      Spacer()

      VStack(spacing: 14) {
        ZStack {
          Circle()
          .fill(Color.green.opacity(0.12))
          .frame(width: 90, height: 90)
          Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 48))
          .foregroundStyle(.green)
        }

        VStack(spacing: 6) {
          Text(l10n("Backup Complete", lang: appLanguage))
          .font(.system(size: 22, weight: .bold, design: .rounded))
          if count == 0 {
            Text(l10n("Everything was already backed up — no new files found.", lang: appLanguage))
            .font(.subheadline).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          } else {
            Text("\(count) \(l10n("files transferred", lang: appLanguage)) (\(s.elapsedFormatted))")
            .font(.subheadline).foregroundStyle(.secondary)
          }
        }
      }

      // Main stats row
      HStack(spacing: 0) {
        summaryStatCell(label: l10n("Copied", lang: appLanguage),    value: "\(s.successCount)",  color: .green)
        Divider().frame(height: 36).opacity(0.15)
        summaryStatCell(label: l10n("Skipped", lang: appLanguage),   value: "\(s.skippedFiles)",  color: .teal)
        Divider().frame(height: 36).opacity(0.15)
        summaryStatCell(label: l10n("Reorganized", lang: appLanguage), value: "\(s.reorganizedCount)", color: .purple)
        Divider().frame(height: 36).opacity(0.15)
        summaryStatCell(label: l10n("Will Retry", lang: appLanguage),value: "\(failed)",          color: failed > 0 ? .orange : .secondary)
        Divider().frame(height: 36).opacity(0.15)
        summaryStatCell(label: l10n("Time", lang: appLanguage),      value: s.elapsedFormatted,   color: .blue)
      }
      .padding(.vertical, 10)
      .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
      .padding(.horizontal, 36)

      // Audit Card when recount / full backup / reorganized
      if showAuditCard {
        VStack(spacing: 10) {
          HStack {
            Label(l10n("Library Parity & Recount Audit", lang: appLanguage), systemImage: "checklist.checked")
              .font(.system(size: 12, weight: .bold, design: .rounded))
              .foregroundStyle(Color.accentColor)
            Spacer()
            HStack(spacing: 4) {
              Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
              Text(l10n("100% In Sync", lang: appLanguage))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.green)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.green.opacity(0.12), in: Capsule())
          }

          HStack(spacing: 0) {
            summaryStatCell(label: l10n("iPhone Media", lang: appLanguage), value: "\(vStats?.sourceFileCount ?? s.totalFiles)", color: .purple)
            Divider().frame(height: 28).opacity(0.15)
            summaryStatCell(label: l10n("Destination Media", lang: appLanguage), value: "\(vStats?.destinationFileCount ?? (s.skippedFiles + s.successCount))", color: .blue)
            Divider().frame(height: 28).opacity(0.15)
            summaryStatCell(label: l10n("Verified Safe", lang: appLanguage), value: "\(vStats?.verifiedSafeCount ?? s.skippedFiles)", color: .green)
            Divider().frame(height: 28).opacity(0.15)
            summaryStatCell(label: l10n("Folders Reorganized", lang: appLanguage), value: "\(s.reorganizedCount)", color: .teal)
          }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
        }
        .padding(.horizontal, 36)
      }

      if failed > 0 {
        HStack(spacing: 10) {
          Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
          Text("\(failed) \(l10n("files", lang: appLanguage)) \(l10n("will be retried automatically on the next sync.", lang: appLanguage))")
          .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 36)
      } else if let missing = vStats?.missingOrCorruptCount, missing > 0, count == 0 {
        HStack(spacing: 10) {
          Image(systemName: "info.circle.fill").foregroundStyle(.blue)
          Text(l10n("Files missing from manifest will be re-downloaded on next sync", lang: appLanguage))
          .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 36)
      }

      Spacer()

      Button {
        onClose()
      } label: {
        Text(l10n("Close Console", lang: appLanguage))
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.vertical, 10)
        .padding(.horizontal, 32)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
          RoundedRectangle(cornerRadius: 9)
          .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8)
        }
      }
      .buttonStyle(.plain)

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Error Summary (true engine errors, e.g. no destination)

  private func errorSummary(reason: String) -> some View {
    VStack(spacing: 24) {
      Spacer()
      Image(systemName: "exclamationmark.triangle.fill")
      .font(.system(size: 48))
      .foregroundStyle(.orange)
      VStack(spacing: 8) {
        Text(l10n("Sync Could Not Complete", lang: appLanguage))
        .font(.system(size: 20, weight: .bold, design: .rounded))
        Text(reason)
        .font(.subheadline).foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
      }
      Spacer()
      Button {
        onClose()
      } label: {
        Text(l10n("Close Console", lang: appLanguage))
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.vertical, 10).padding(.horizontal, 32)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
      }
      .buttonStyle(.plain)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func summaryStatCell(label: String, value: String, color: Color) -> some View {
    VStack(spacing: 4) {
      Text(value)
      .font(.system(size: 18, weight: .bold, design: .rounded))
      .foregroundStyle(color)
      Text(label)
      .font(.system(size: 10))
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 6)
  }

  // MARK: - Header

  private var headerBar: some View {
    HStack(spacing: 14) {
      Image(systemName: "arrow.triangle.2.circlepath")
      .font(.system(size: 18, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 42, height: 42)
      .background(
        LinearGradient(
          colors: [Color.accentColor, Color.accentColor.opacity(0.68)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ),
        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )
      .shadow(color: Color.accentColor.opacity(0.28), radius: 12, y: 5)

      VStack(alignment: .leading, spacing: 3) {
        Text(l10n("Live Sync Console", lang: appLanguage))
        .font(.system(size: 20, weight: .bold, design: .rounded))
        if !backupEngine.currentDeviceName.isEmpty {
          HStack(spacing: 5) {
            Image(systemName: "iphone")
            .font(.system(size: 11, weight: .medium))
            Text(backupEngine.currentDeviceName)
            .font(.subheadline)
            .fontWeight(.medium)
          }
          .foregroundStyle(.secondary)
        }
      }
      Spacer()
      syncStatusBadge
    }
    .padding(16)
    .consoleSurface(cornerRadius: 22)
  }

  private var syncStatusBadge: some View {
    let isScanning: Bool = { if case .scanning = backupEngine.state { return true }; return false }()
    let isPaused: Bool = { if case .paused = backupEngine.state { return true }; return false }()
    let isInterrupted: Bool = { if case .interrupted = backupEngine.state { return true }; return false }()
    let color: Color = isInterrupted ? .orange : (isPaused ? .orange : (isScanning ? .teal : .green))
    let title: String = {
      if isInterrupted { return l10n("Interrupted", lang: appLanguage) }
      if isPaused { return l10n("Paused", lang: appLanguage) }
      if isScanning {
        let mode = backupEngine.validationStats?.scanMode ?? .incremental
        return mode == .fullRecountAndReconcile
          ? l10n("Auditing Parity", lang: appLanguage)
          : l10n("Scanning & Auditing", lang: appLanguage)
      }
      return l10n("Syncing", lang: appLanguage)
    }()

    let icon: String = {
      if isInterrupted { return "exclamationmark.triangle.fill" }
      if isPaused { return "pause.fill" }
      if isScanning { return "magnifyingglass" }
      return "waveform.path.ecg"
    }()

    return Label(title, systemImage: icon)
    .font(.system(size: 11, weight: .bold, design: .rounded))
    .foregroundStyle(color)
    .padding(.horizontal, 11)
    .padding(.vertical, 7)
    .background(color.opacity(0.12), in: Capsule())
    .overlay {
      Capsule().strokeBorder(color.opacity(0.22), lineWidth: 0.8)
    }
    .shadow(color: color.opacity(isLivePulseActive ? 0.26 : 0.08), radius: isLivePulseActive ? 8 : 2)
    .accessibilityLabel(title)
  }

  // MARK: - Left Column

  private var leftColumn: some View {
    let s = backupEngine.stats
    let vStats = backupEngine.validationStats
    let isScanning = backupEngine.state == .scanning
    let progress = isScanning ? (vStats?.scanProgress ?? 0.0) : s.overallProgress
    let isPaused: Bool = { if case .paused = backupEngine.state { return true }; return false }()
    let isInterrupted: Bool = { if case .interrupted = backupEngine.state { return true }; return false }()

    return VStack(alignment: .center, spacing: 14) {

      HStack {
        Label(isScanning ? l10n("Scan & Audit Progress", lang: appLanguage) : l10n("Sync Progress", lang: appLanguage), systemImage: isScanning ? "magnifyingglass" : "arrow.triangle.2.circlepath")
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .foregroundStyle(.secondary)
        Spacer()
        Text(l10n("LIVE", lang: appLanguage))
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .foregroundStyle(isScanning ? Color.teal : Color.accentColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background((isScanning ? Color.teal : Color.accentColor).opacity(0.12), in: Capsule())
        .scaleEffect(isLivePulseActive ? 1.04 : 0.96)
        .opacity(isLivePulseActive ? 1 : 0.72)
      }

      // Progress ring
      ZStack {
        Circle()
        .fill((isScanning ? Color.teal : Color.accentColor).opacity(0.11))
        .frame(width: 156, height: 156)
        .blur(radius: 16)
        Circle()
        .stroke(Color.primary.opacity(0.08), lineWidth: 12)
        Circle()
        .trim(from: 0, to: isProgressRingActive ? CGFloat(progress) : 0)
        .stroke(
          LinearGradient(colors: isScanning ? [Color.teal.opacity(0.75), Color.teal] : [Color.accentColor.opacity(0.75), Color.accentColor],
            startPoint: .topLeading, endPoint: .bottomTrailing),
          style: StrokeStyle(lineWidth: 12, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
        .shadow(color: (isScanning ? Color.teal : Color.accentColor).opacity(0.25), radius: 7)
        .animation(.smooth(duration: 0.55), value: progress)
        VStack(spacing: 3) {
          if isInterrupted {
            Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 28))
            .foregroundStyle(.orange)
            Text(l10n("interrupted", lang: appLanguage))
            .font(.caption)
            .foregroundStyle(.orange)
          } else {
            Text("\(Int(progress * 100))%")
            .font(.system(size: 32, weight: .bold, design: .rounded))
            Text(isPaused ? l10n("paused", lang: appLanguage) : (isScanning ? l10n("scanning", lang: appLanguage) : l10n("complete", lang: appLanguage)))
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
      }
      .frame(width: 148, height: 148)

      // Sync type badge + file count
      VStack(spacing: 5) {
        let scanMode = vStats?.scanMode ?? (s.isFullBackup ? .deepValidation : .incremental)
        HStack(spacing: 5) {
          Image(systemName: scanMode == .fullRecountAndReconcile ? "checklist.checked" : (scanMode == .deepValidation ? "arrow.clockwise.circle" : "bolt.fill"))
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(scanMode == .fullRecountAndReconcile ? .purple : (scanMode == .deepValidation ? .orange : Color.accentColor))
          Text(scanMode == .fullRecountAndReconcile
            ? l10n("Full Library Recount & Verify", lang: appLanguage)
            : (scanMode == .deepValidation ? l10n("Deep Validation Sync", lang: appLanguage) : l10n("Delta Incremental Sync", lang: appLanguage)))
          .font(.system(size: 11, weight: .semibold))
        }
        if isScanning {
          Text("\(vStats?.scannedCount ?? 0) / \(vStats?.totalToScan ?? 0) \(l10n("items verified", lang: appLanguage))")
          .font(.caption)
          .foregroundStyle(.secondary)
        } else {
          Text("\(s.successCount + s.failedCount) / \(s.totalFiles) \(l10n("files processed", lang: appLanguage))")
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      .multilineTextAlignment(.center)

      Divider().opacity(0.10)

      // Current file or Interrupted Warning or Scanning Item
      if isInterrupted {
        VStack(spacing: 6) {
          HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.system(size: 12, weight: .bold))
            Text(l10n("Backup Interrupted", lang: appLanguage))
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.orange)
          }
          Text(l10n("Device disconnected. Reconnect to resume.", lang: appLanguage))
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(Color.orange.opacity(0.20), lineWidth: 0.8)
        }
      } else {
        let activeName = isScanning ? (vStats?.currentScannedFile ?? "") : s.currentFileName
        if !activeName.isEmpty {
          VStack(spacing: 4) {
            Label(isScanning ? l10n("Now verifying", lang: appLanguage) : l10n("Now processing", lang: appLanguage), systemImage: isScanning ? "magnifyingglass" : "doc.badge.arrow.up")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary.opacity(0.7))
            Text(activeName)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .truncationMode(.middle)
          }
          .padding(8)
          .frame(maxWidth: .infinity)
          .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.primary.opacity(0.06), lineWidth: 0.8)
          }
        }
      }

      // Batch progress (only when multi-batch and copying)
      if !isScanning && s.totalBatches > 1 {
        VStack(spacing: 6) {
          HStack {
            Text("Batch \(s.currentBatch) / \(s.totalBatches)")
            .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text("\(s.filesInCurrentBatch) \(l10n("files", lang: appLanguage))")
            .font(.caption2).foregroundStyle(.secondary)
          }
          ProgressView(value: s.batchProgress)
          .progressViewStyle(.linear)
          .tint(Color.accentColor)
        }
        .padding(8)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      }

      // Speed & manifest info
      if isScanning {
        infoRow(icon: "checkmark.shield",
          label: l10n("Verified Safe", lang: appLanguage),
          value: "\(vStats?.verifiedSafeCount ?? 0)",
          color: .green)
        infoRow(icon: "arrow.triangle.swap",
          label: l10n("Reorganized", lang: appLanguage),
          value: "\(vStats?.reorganizedCount ?? 0)",
          color: .teal)
        infoRow(icon: "arrow.down.circle",
          label: l10n("Missing / New", lang: appLanguage),
          value: "\(vStats?.missingOrCorruptCount ?? 0)",
          color: .orange)
      } else {
        infoRow(icon: "speedometer",
          label: l10n("Rate", lang: appLanguage),
          value: s.averageSecondsPerFile > 0
          ? String(format: "%.1f s/file", s.averageSecondsPerFile)
          : "—",
          color: .cyan)
        infoRow(icon: "archivebox",
          label: l10n("Manifest", lang: appLanguage),
          value: "\(s.manifestSize) \(l10n("total known", lang: appLanguage))",
          color: .teal)
        if s.reorganizedCount > 0 {
          infoRow(icon: "arrow.triangle.swap",
            label: l10n("Reorganized", lang: appLanguage),
            value: "\(s.reorganizedCount) \(l10n("files", lang: appLanguage))",
            color: .purple)
        }
      }

      Spacer(minLength: 0)

      // Controls
      controlButtons(isPaused: isPaused, isInterrupted: isInterrupted)
    }
    .padding(18)
    .consoleSurface(cornerRadius: 24)
  }

  // MARK: - Right Column

  private var rightColumn: some View {
    VStack(alignment: .leading, spacing: 14) {
      if backupEngine.state == .scanning {
        scanningRightColumn
      } else {
        statsGrid
        thumbnailSection
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
  }

  // MARK: - Scanning Right Column Pipeline & Parity Grid

  private var scanningRightColumn: some View {
    let vStats = backupEngine.validationStats
    let phase = vStats?.currentPhase ?? .readingCatalog
    let mode = vStats?.scanMode ?? .incremental
    let isRecount = mode == .fullRecountAndReconcile

    return VStack(alignment: .leading, spacing: 14) {
      // Step-by-Step Pipeline
      scanningPipeline(currentPhase: phase, scanMode: mode)

      // Parity Grid
      LazyVGrid(
        columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
        spacing: 8
      ) {
        statBox(label: l10n("Verified Safe", lang: appLanguage), value: "\(vStats?.verifiedSafeCount ?? 0)", icon: "checkmark.shield.fill", color: .green)
        if isRecount {
          statBox(label: l10n("Reorganized", lang: appLanguage), value: "\(vStats?.reorganizedCount ?? 0)", icon: "arrow.triangle.swap", color: .teal)
        } else {
          statBox(label: l10n("Skipped", lang: appLanguage), value: "\(vStats?.verifiedSafeCount ?? 0)", icon: "forward.end.fill", color: .teal)
        }
        statBox(label: l10n("Missing / New", lang: appLanguage), value: "\(vStats?.missingOrCorruptCount ?? 0)", icon: "arrow.down.circle.fill", color: .orange)
        statBox(label: l10n("iPhone Catalog", lang: appLanguage), value: "\(vStats?.sourceFileCount ?? 0)", icon: "iphone", color: .purple)
        statBox(label: l10n("Destination Media", lang: appLanguage), value: (vStats?.destinationFileCount ?? 0) > 0 ? "\(vStats!.destinationFileCount)" : "—", icon: "externaldrive.fill", color: .blue)
        statBox(label: l10n("Elapsed", lang: appLanguage), value: backupEngine.stats.elapsedFormatted, icon: "clock.fill", color: .cyan)
      }

      // Interactive Activity Explanation Card
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Image(systemName: isRecount ? "sparkles" : "bolt.shield.fill")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color.accentColor)
          Text(isRecount ? l10n("Smart Folder Reorganization & Parity Audit", lang: appLanguage) : l10n("Fast Parity & Manifest Audit", lang: appLanguage))
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.primary)
        }

        Text(isRecount
          ? l10n("The audit inspects physical destination storage and automatically relocates media files to match your configured folder structure (Year / Month). Any files found in previous folder layouts are moved into place, ensuring zero duplicate downloads from your iPhone.", lang: appLanguage)
          : l10n("The audit quickly verifies that your iPhone media catalog matches the backup manifest and destination storage without walking the full network drive. Any unbacked files will be downloaded automatically.", lang: appLanguage))
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
          ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.small)
          Text(l10n("Validating media files and destination folders…", lang: appLanguage))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .consoleSurface(cornerRadius: 18)

      Spacer(minLength: 0)
    }
    .frame(maxHeight: .infinity, alignment: .top)
  }

  private func scanningPipeline(currentPhase: ScanPhase, scanMode: BackupScanMode) -> some View {
    HStack(spacing: 8) {
      if scanMode == .fullRecountAndReconcile {
        pipelineStep(
          number: 1,
          title: l10n("Read Catalog", lang: appLanguage),
          isDone: currentPhase == .buildingIndex || currentPhase == .validatingAndReorganizing || currentPhase == .complete,
          isActive: currentPhase == .readingCatalog
        )
        pipelineArrow
        pipelineStep(
          number: 2,
          title: l10n("Build Index", lang: appLanguage),
          isDone: currentPhase == .validatingAndReorganizing || currentPhase == .complete,
          isActive: currentPhase == .buildingIndex
        )
        pipelineArrow
        pipelineStep(
          number: 3,
          title: l10n("Verify & Reorganize", lang: appLanguage),
          isDone: currentPhase == .complete,
          isActive: currentPhase == .validatingAndReorganizing
        )
      } else {
        pipelineStep(
          number: 1,
          title: l10n("Read Catalog", lang: appLanguage),
          isDone: currentPhase == .validatingAndReorganizing || currentPhase == .complete,
          isActive: currentPhase == .readingCatalog
        )
        pipelineArrow
        pipelineStep(
          number: 2,
          title: l10n("Verify Parity", lang: appLanguage),
          isDone: currentPhase == .complete,
          isActive: currentPhase == .validatingAndReorganizing
        )
      }
    }
    .padding(12)
    .consoleSurface(cornerRadius: 16)
  }

  private func pipelineStep(number: Int, title: String, isDone: Bool, isActive: Bool) -> some View {
    HStack(spacing: 7) {
      ZStack {
        Circle()
          .fill(isDone ? Color.green : (isActive ? Color.accentColor : Color.secondary.opacity(0.2)))
          .frame(width: 22, height: 22)
        if isDone {
          Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
        } else {
          Text("\(number)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
        }
      }
      Text(title)
        .font(.system(size: 11, weight: isActive ? .bold : .medium, design: .rounded))
        .foregroundStyle(isActive ? .primary : .secondary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity)
  }

  private var pipelineArrow: some View {
    Image(systemName: "chevron.forward")
      .font(.system(size: 10, weight: .bold))
      .foregroundStyle(.secondary.opacity(0.4))
  }

  // MARK: - Stats

  private var statsGrid: some View {
    let s = backupEngine.stats
    let remaining = s.remainingFiles
    return LazyVGrid(
      columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
      spacing: 8
    ) {
      statBox(label: l10n("Copied", lang: appLanguage), value: "\(s.successCount)", icon: "checkmark", color: .green)
      statBox(label: l10n("Skipped", lang: appLanguage), value: "\(s.skippedFiles)", icon: "forward.end.fill", color: .teal)
      statBox(label: l10n("Reorganized", lang: appLanguage), value: "\(s.reorganizedCount)", icon: "arrow.triangle.swap", color: .purple)
      statBox(label: l10n("Failed", lang: appLanguage), value: "\(s.failedCount)", icon: "exclamationmark", color: s.failedCount > 0 ? .red : .secondary)
      statBox(label: l10n("Elapsed", lang: appLanguage), value: s.elapsedFormatted, icon: "clock.fill", color: .blue)
      statBox(label: l10n("Remaining", lang: appLanguage), value: "\(remaining)", icon: "hourglass", color: .orange)
    }
  }

  private func statBox(label: String, value: String, icon: String, color: Color) -> some View {
    HStack(spacing: 11) {
      Image(systemName: icon)
      .font(.system(size: 12, weight: .bold))
      .foregroundStyle(color)
      .frame(width: 30, height: 30)
      .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(label)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        Text(value)
        .font(.system(size: 20, weight: .bold, design: .rounded))
        .foregroundStyle(color)
        .contentTransition(.numericText())
        .minimumScaleFactor(0.55)
        .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity)
    .padding(12)
    .consoleSurface(cornerRadius: 16)
    .animation(.snappy(duration: 0.35), value: value)
  }

  // MARK: - Thumbnail Section

  private var thumbnailSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label(l10n("Processed Files", lang: appLanguage), systemImage: "photo.stack")
        .font(.system(size: 13, weight: .bold, design: .rounded))
        .foregroundStyle(.primary)
        Spacer()
        let count = backupEngine.recentlyProcessedFileNames.count
        if count > 0 {
          Text("\(count) \(l10n("files", lang: appLanguage))")
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(.primary.opacity(0.07), in: Capsule())
        }
      }

      let files = recentFiles
      if files.isEmpty {
        HStack {
          Spacer()
          VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
            .font(.system(size: 36))
            .foregroundStyle(.secondary.opacity(0.3))
            Text(l10n("Waiting for files to process…", lang: appLanguage))
            .font(.caption)
            .foregroundStyle(.secondary.opacity(0.45))
          }
          Spacer()
        }
        .frame(maxHeight: .infinity)
      } else {
        GeometryReader { geo in
          let spacing: CGFloat = 10
          let cols = max(1, Int((geo.size.width + spacing) / (tileSize + spacing)))
          ScrollView(showsIndicators: false) {
            LazyVGrid(
              columns: Array(repeating: GridItem(.fixed(tileSize), spacing: spacing), count: cols),
              spacing: spacing
            ) {
              ForEach(files, id: \.self) { file in
                thumbnailTile(for: file)
              }
            }
            .padding(.bottom, 4)
          }
        }
      }
    }
    .padding(16)
    .consoleSurface(cornerRadius: 24)
    .frame(maxHeight: .infinity)
    .animation(.snappy(duration: 0.35), value: recentFiles.count)
  }

  private var recentFiles: [ICCameraFile] {
    if !backupEngine.recentlyProcessedFiles.isEmpty {
      return backupEngine.recentlyProcessedFiles
    }

    let allFiles = deviceMonitor.allDiscoveredFiles()
    var names = backupEngine.recentlyProcessedFileNames
    let cur = backupEngine.stats.currentFileName
    if !cur.isEmpty && !names.contains(cur) { names.insert(cur, at: 0) }
    return names.compactMap { name in allFiles.first { $0.name == name } }
  }

  private func thumbnailTile(for file: ICCameraFile) -> some View {
    let isSafe = backupEngine.isAssetAlreadyBackedUp(file)
    let isCurrent = (file.name == backupEngine.stats.currentFileName)
    let isFailed = (file.name != nil && backupEngine.stats.failedFileNames.contains(file.name!))
    let thumbnail = file.name.flatMap { deviceMonitor.thumbnails[$0] }
    let name = file.name ?? "IMG_0000"

    return VStack(alignment: .leading, spacing: 5) {
      ZStack(alignment: .bottomTrailing) {
        ZStack {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.black.opacity(0.22))
          if let thumbnail {
            Image(decorative: thumbnail, scale: 1.0)
            .resizable()
            .scaledToFill()
            .clipped()
          } else {
            Image(systemName: file.isVideoFile ? "film" : "photo")
            .font(.system(size: 20))
            .foregroundStyle(.secondary.opacity(0.35))
          }
          LinearGradient(
            colors: [.clear, .black.opacity(0.24)],
            startPoint: .center,
            endPoint: .bottom
          )
        }
        .frame(width: tileSize, height: tileSize)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.16), radius: 7, y: 3)

        // Status badge
        StatusBadgeView(isSafe: isSafe, isCurrent: isCurrent, isFailed: isFailed)
        .padding(3)
      }

      Text(name)
      .font(.system(size: 8, weight: .medium, design: .monospaced))
      .lineLimit(1)
      .foregroundStyle(.secondary.opacity(0.8))
      .frame(width: tileSize, alignment: .leading)
    }
    .onAppear {
      let localURL = backupEngine.localURL(for: file)
      deviceMonitor.requestThumbnail(for: file, localURL: localURL)
    }
    .onChange(of: isSafe) { _, newValue in
      if newValue {
        let localURL = backupEngine.localURL(for: file)
        deviceMonitor.requestThumbnail(for: file, localURL: localURL)
      }
    }
  }

  // MARK: - Info Row

  private func infoRow(icon: String, label: String, value: String, color: Color) -> some View {
    HStack(spacing: 8) {
      Image(systemName: icon)
      .font(.system(size: 11))
      .foregroundStyle(color)
      .frame(width: 16)
      Text(label)
      .font(.caption2)
      .foregroundStyle(.secondary)
      Spacer()
      Text(value)
      .font(.system(size: 11, weight: .semibold, design: .rounded))
      .foregroundStyle(color)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
  }

  // MARK: - Control Buttons

  private func controlButtons(isPaused: Bool, isInterrupted: Bool) -> some View {
    VStack(spacing: 7) {
      if isInterrupted {
        HStack(spacing: 7) {
          ProgressView()
          .progressViewStyle(.circular)
          .controlSize(.small)
          Text(l10n("Waiting for Reconnection…", lang: appLanguage))
          .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        }
      } else {
        Button {
          if isPaused { backupEngine.resumeBackup() } else { backupEngine.pauseBackup() }
        } label: {
          HStack(spacing: 7) {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
            .font(.system(size: 12, weight: .bold))
            Text(isPaused ? l10n("Resume Backup", lang: appLanguage) : l10n("Pause Backup", lang: appLanguage))
            .font(.system(size: 13, weight: .semibold))
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 10)
        }
        .buttonStyle(ConsoleActionButtonStyle(tint: isPaused ? .green : Color.accentColor))
      }

      Button {
        backupEngine.cancelBackup()
        onClose()
      } label: {
        HStack(spacing: 7) {
          Image(systemName: "xmark.circle.fill").font(.system(size: 12, weight: .bold))
          Text(isInterrupted ? l10n("Cancel Backup", lang: appLanguage) : l10n("Halt Backup", lang: appLanguage)).font(.system(size: 13, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
      }
      .buttonStyle(ConsoleActionButtonStyle(tint: .red))
    }
  }
}

private struct ConsoleBackdrop: View {
  var body: some View {
    ZStack {
      VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
      LinearGradient(
        colors: [
          Color(nsColor: .windowBackgroundColor).opacity(0.84),
          Color.primary.opacity(0.025),
          Color(nsColor: .windowBackgroundColor).opacity(0.96)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    }
    .ignoresSafeArea()
  }
}

private struct ConsoleActionButtonStyle: ButtonStyle {
  var tint: Color
  @State private var isHovered = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(.white)
      .background(
        LinearGradient(
          colors: [tint, tint.opacity(0.72)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ),
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(.white.opacity(isHovered ? 0.32 : 0.18), lineWidth: 0.8)
      }
      .shadow(color: tint.opacity(isHovered ? 0.34 : 0.20), radius: isHovered ? 10 : 5, y: isHovered ? 5 : 2)
      .scaleEffect(configuration.isPressed ? 0.97 : (isHovered ? 1.015 : 1))
      .brightness(configuration.isPressed ? -0.08 : 0)
      .onHover { hovering in
        withAnimation(.snappy(duration: 0.18)) {
          isHovered = hovering
        }
      }
      .animation(.snappy(duration: 0.18), value: configuration.isPressed)
  }
}

private extension View {
  @ViewBuilder
  func consoleSurface(cornerRadius: CGFloat) -> some View {
    if #available(macOS 26.0, *) {
      self
      .glassEffect(
        .regular.tint(Color.primary.opacity(0.045)),
        in: .rect(cornerRadius: cornerRadius)
      )
    } else {
      self
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(
          LinearGradient(
            colors: [.white.opacity(0.22), .primary.opacity(0.07), .white.opacity(0.05)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          lineWidth: 0.8
        )
      }
      .shadow(color: .black.opacity(0.10), radius: 16, y: 8)
    }
  }
}

// MARK: - Status Badge View

struct StatusBadgeView: View {
  let isSafe: Bool
  let isCurrent: Bool
  let isFailed: Bool
  @State private var rotationAngle: Double = 0.0

  var body: some View {
    ZStack {
      Circle()
      .fill(Color.black.opacity(0.75))
      .frame(width: 18, height: 18)

      if isFailed {
        Image(systemName: "xmark.circle.fill")
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(.red)
      } else if isCurrent {
        Image(systemName: "arrow.triangle.2.circlepath")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.blue)
        .rotationEffect(.degrees(rotationAngle))
        .onAppear {
          withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            rotationAngle = 360
          }
        }
      } else if isSafe {
        Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(.green)
      } else {
        Image(systemName: "arrow.triangle.2.circlepath")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.orange)
      }
    }
  }
}
