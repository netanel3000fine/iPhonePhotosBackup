import SwiftUI

struct SettingsGuideAnimation: View {
    let stage: GuideStage

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30.0, paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0.5 : context.date.timeIntervalSinceReferenceDate
            stageArtwork(phase: phase)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [stage.color.opacity(0.18), stage.color.opacity(0.04), Color.black.opacity(0.20)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                
                Circle()
                    .fill(stage.color.opacity(0.12))
                    .frame(width: 140, height: 140)
                    .blur(radius: 20)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(stage.color.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stage.accessibilityLabel)
    }

    @ViewBuilder
    private func stageArtwork(phase: TimeInterval) -> some View {
        switch stage {
        case .connection:
            connectionArtwork(phase: phase)
        case .syncStatus:
            syncStatusArtwork(phase: phase)
        case .gallery:
            galleryArtwork(phase: phase)
        case .photoFilter:
            photoFilterArtwork(phase: phase)
        case .troubleshooting:
            troubleshootingArtwork(phase: phase)
        case .destination:
            destinationArtwork(phase: phase)
        case .coreInfrastructure:
            coreInfrastructureArtwork(phase: phase)
        }
    }

    // MARK: - 1. Connect & Trust Artwork
    private func connectionArtwork(phase: TimeInterval) -> some View {
        let travel = wave(phase, duration: 1.8)
        let trustPulse = wave(phase, duration: 1.2)

        return ZStack {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [stage.color.opacity(0.2), stage.color.opacity(0.85), stage.color.opacity(0.2)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 120, height: 3)
                .shadow(color: stage.color.opacity(0.5), radius: 4)

            Circle()
                .fill(Color.white)
                .frame(width: 8, height: 8)
                .shadow(color: stage.color, radius: 6)
                .offset(x: -45 + travel * 90)

            VStack(spacing: 2) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(stage.color)
                Text("iPhone")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .offset(x: -78)

            VStack(spacing: 2) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.primary.opacity(0.85))
                Text("Mac")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .offset(x: 78)

            HStack(spacing: 4) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("Trust")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.green, in: Capsule())
            .shadow(color: .green.opacity(0.5), radius: 6)
            .offset(x: -48, y: -30)
            .scaleEffect(0.92 + trustPulse * 0.12)
        }
    }

    // MARK: - 2. Sync Status & Live Backup Artwork
    private func syncStatusArtwork(phase: TimeInterval) -> some View {
        let progress = wave(phase, duration: 2.4)
        let pulse = wave(phase, duration: 1.0)

        return ZStack {
            VStack(spacing: 6) {
                HStack {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                            .scaleEffect(0.8 + pulse * 0.3)
                        Text("Live Backup Active")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundStyle(stage.color)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.blue, Color.cyan, Color.green],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(12, geo.size.width * progress))
                            .shadow(color: Color.cyan.opacity(0.6), radius: 4)
                    }
                }
                .frame(height: 7)

                HStack {
                    Label("\(Int(progress * 1420)) / 1,420 files", systemImage: "photo.stack")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label("48.2 MB/s", systemImage: "bolt.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.cyan)
                }
            }
            .padding(10)
            .frame(width: 220)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(stage.color.opacity(0.35), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        }
    }

    // MARK: - 3. Phone Gallery Library Artwork
    private func galleryArtwork(phase: TimeInterval) -> some View {
        let cycle = wave(phase, duration: 2.2)

        return ZStack {
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(["All", "New", "Backed Up"], id: \.self) { label in
                        let isSelected = (label == "New" && cycle > 0.5) || (label == "All" && cycle <= 0.5)
                        Text(label)
                            .font(.system(size: 8, weight: isSelected ? .bold : .medium))
                            .foregroundStyle(isSelected ? .white : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(isSelected ? stage.color : Color.clear, in: Capsule())
                    }
                }
                .padding(2)
                .background(Color.black.opacity(0.2), in: Capsule())

                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { idx in
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [stage.color.opacity(0.35 + Double(idx) * 0.12), Color.indigo.opacity(0.4)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 44, height: 38)
                            .overlay {
                                Image(systemName: idx == 1 ? "film.fill" : "photo.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                            .overlay(alignment: .bottomTrailing) {
                                if idx % 2 == 0 {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.green)
                                        .padding(2)
                                }
                            }
                    }
                }
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(stage.color.opacity(0.3), lineWidth: 1)
            }
        }
    }

    // MARK: - 4. Photo Filter Swipe & Clean Artwork
    private func photoFilterArtwork(phase: TimeInterval) -> some View {
        let swipePhase = sin(phase * .pi * 2 / 2.5)
        let isRight = swipePhase > 0
        let cardOffset = CGFloat(swipePhase * 36)
        let cardRotation = Double(swipePhase * 9)

        return ZStack {
            HStack {
                Label("DELETE", systemImage: "trash.fill")
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundStyle(.red)
                    .padding(5)
                    .background(Color.red.opacity(!isRight ? 0.25 : 0.08), in: Capsule())
                    .scaleEffect(!isRight ? 1.08 : 0.9)

                Spacer()

                Label("KEEP", systemImage: "heart.fill")
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundStyle(.green)
                    .padding(5)
                    .background(Color.green.opacity(isRight ? 0.25 : 0.08), in: Capsule())
                    .scaleEffect(isRight ? 1.08 : 0.9)
            }
            .frame(width: 210)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.5), Color.purple.opacity(0.6), Color.black.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Image(systemName: "photo.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.8))

                if abs(swipePhase) > 0.3 {
                    Label(isRight ? "KEEP" : "DELETE", systemImage: isRight ? "heart.fill" : "trash.fill")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .foregroundStyle(isRight ? .green : .red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(isRight ? Color.green : Color.red, lineWidth: 1.5)
                        }
                        .offset(y: -22)
                }

                VStack {
                    Spacer()
                    HStack(spacing: 3) {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 7))
                        Text("Space for Quick Look")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(.bottom, 5)
                }
            }
            .frame(width: 108, height: 86)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            .offset(x: cardOffset)
            .rotationEffect(.degrees(cardRotation))
        }
    }

    // MARK: - 5. Reconnect & Troubleshooting Artwork
    private func troubleshootingArtwork(phase: TimeInterval) -> some View {
        let spin = CGFloat(fmod(phase * 90, 360))
        let plug = wave(phase, duration: 1.6)

        return ZStack {
            HStack(spacing: 24) {
                VStack(spacing: 3) {
                    ZStack {
                        Image(systemName: "iphone.gen3")
                            .font(.system(size: 42, weight: .light))
                            .foregroundStyle(stage.color)
                        
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.green)
                            .offset(y: -4)
                    }
                    Text("1. Unlock")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .strokeBorder(stage.color.opacity(0.25), lineWidth: 2)
                            .frame(width: 38, height: 38)
                        
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(stage.color)
                            .rotationEffect(.degrees(Double(spin)))
                    }
                    
                    HStack(spacing: 3) {
                        Image(systemName: "cable.connector")
                            .font(.system(size: 9))
                        Text("2. Re-plug USB")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(stage.color)
                    .offset(y: (plug - 0.5) * 4)
                }

                VStack(spacing: 3) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.2))
                            .frame(width: 36, height: 36)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.green)
                            .scaleEffect(0.9 + plug * 0.2)
                    }
                    Text("3. Auto-Live")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(stage.color.opacity(0.3), lineWidth: 1)
            }
        }
    }

    // MARK: - 6. Safe Local Destination Artwork
    private func destinationArtwork(phase: TimeInterval) -> some View {
        let glow = 0.55 + wave(phase, duration: 1.7) * 0.45

        return ZStack {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(stage.color.opacity(0.15))
                        .frame(width: 72, height: 60)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(stage.color.opacity(glow), lineWidth: 1.5)
                        }

                    VStack(spacing: 3) {
                        Image(systemName: "folder.fill.badge.gearshape")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(stage.color)
                        Text("Mac / SSD")
                            .font(.system(size: 8, weight: .heavy, design: .rounded))
                            .foregroundStyle(.primary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.cyan)
                        Text("iPhone Backup / 2026")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    }
                    HStack(spacing: 4) {
                        Text("  └")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Image(systemName: "photo.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.green)
                        Text("August (Organized)")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack(spacing: 3) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                        Text("100% Local & Private")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.green)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(stage.color.opacity(0.3), lineWidth: 1)
            }
        }
    }

    // MARK: - 7. Core Infrastructure & Privacy Artwork
    private func coreInfrastructureArtwork(phase: TimeInterval) -> some View {
        let pulse = 0.65 + wave(phase, duration: 1.5) * 0.35

        return ZStack {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(stage.color.opacity(0.18))
                        .frame(width: 76, height: 68)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(stage.color.opacity(pulse), lineWidth: 1.5)
                        }

                    VStack(spacing: 3) {
                        Image(systemName: "cpu.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(stage.color)
                        Text("SANDBOX")
                            .font(.system(size: 7, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.primary)
                        HStack(spacing: 2) {
                            Circle().fill(Color.green).frame(width: 4, height: 4)
                            Text("ACTIVE")
                                .font(.system(size: 6, weight: .bold))
                                .foregroundStyle(.green)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "cable.connector.horizontal")
                            .font(.system(size: 9))
                            .foregroundStyle(.cyan)
                        Text("ImageCaptureCore Driver")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                        Text("Apple Sandbox Security")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.indigo)
                        Text("Multi-Port Daemon Monitor")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(stage.color.opacity(0.32), lineWidth: 1)
            }
        }
    }

    private func wave(_ phase: TimeInterval, duration: TimeInterval) -> CGFloat {
        CGFloat((sin(phase * .pi * 2 / duration) + 1) / 2)
    }
}

enum GuideStage: CaseIterable {
    case syncStatus
    case gallery
    case photoFilter
    case connection
    case troubleshooting
    case destination
    case coreInfrastructure

    var title: String {
        switch self {
        case .syncStatus: return l10n("Guide: Sync Status & Backup")
        case .gallery: return l10n("Guide: Phone Gallery Library")
        case .photoFilter: return l10n("Guide: Photo Filter Swipe & Clean")
        case .connection: return l10n("Guide: Connect & Trust")
        case .troubleshooting: return l10n("Guide: Reconnect & Troubleshooting")
        case .destination: return l10n("Guide: Safe Local Destination")
        case .coreInfrastructure: return l10n("Guide: Core Infrastructure & Privacy")
        }
    }

    var detail: String {
        switch self {
        case .syncStatus:
            return l10n("Guide detail: Monitor real-time file transfers, speed, and live indexes. Multiple connected phones wait safely in line.")
        case .gallery:
            return l10n("Guide detail: Browse your full phone gallery over USB. Filter by New, Backed Up, and capture dates with instant preview.")
        case .photoFilter:
            return l10n("Guide detail: Filter your photos effortlessly. Swipe right (→) to Keep, swipe left (←) to Delete, and press Space for full-res Quick Look.")
        case .connection:
            return l10n("Guide detail: Connect an unlocked iPhone with a data-capable USB cable, then tap Trust when the phone asks.")
        case .troubleshooting:
            return l10n("Guide detail: If a phone is missing, unlock it, reconnect it, and accept Trust. If a drive is offline, reconnect it in Finder or choose its folder again.")
        case .destination:
            return l10n("Guide detail: Choose a backup folder for each phone. Your media stays local there and can be organized by year and month.")
        case .coreInfrastructure:
            return l10n("Guide detail: Hardware-level ImageCaptureCore driver layer, Apple Sandbox local storage array security standards, and automated background multi-port daemon monitoring.")
        }
    }

    var color: Color {
        switch self {
        case .syncStatus: return .blue
        case .gallery: return .purple
        case .photoFilter: return .pink
        case .connection: return .cyan
        case .troubleshooting: return .orange
        case .destination: return .teal
        case .coreInfrastructure: return .indigo
        }
    }

    var accessibilityLabel: String {
        "\(title). \(detail)"
    }
}
