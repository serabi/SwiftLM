// ModelsView.swift — Unified iOS-first Models tab (premium theme)
// Combines: active model, downloads in progress, downloaded list, catalog, HF search
import SwiftUI

struct ModelsView: View {
    @EnvironmentObject private var engine: InferenceEngine
    @ObservedObject var viewModel: ChatViewModel

    @State private var showHFSearch = false
    @State private var showManagement = false
    @State private var device = DeviceProfile.current

    private var dm: ModelDownloadManager { engine.downloadManager }

    var body: some View {
        ZStack {
            SwiftLMTheme.background.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // ── 1. Active model hero card ──────────────────────────
                    activeModelCard
                        .padding(.horizontal)
                        .padding(.top, 16)
                        .padding(.bottom, 14)

                    // ── 2. Active downloads ────────────────────────────────
                    if !dm.activeDownloads.isEmpty {
                        sectionHeader("Downloading")
                        ForEach(Array(dm.activeDownloads.keys), id: \.self) { modelId in
                            if let progress = dm.activeDownloads[modelId] {
                                DownloadProgressCard(modelId: modelId, progress: progress)
                                    .padding(.horizontal)
                                    .padding(.bottom, 10)
                            }
                        }
                    }

                    // ── 3. Downloaded models ───────────────────────────────
                    if !dm.downloadedModels.isEmpty {
                        sectionHeader("Downloaded (\(dm.downloadedModels.count))")
                            .padding(.top, 4)
                        VStack(spacing: 0) {
                            ForEach(dm.downloadedModels) { downloaded in
                                let entry = ModelCatalog.all.first(where: { $0.id == downloaded.id })
                                let isActive: Bool = {
                                    if case .ready(let id) = engine.state { return id == downloaded.id }
                                    return false
                                }()
                                DownloadedModelRow(
                                    downloaded: downloaded,
                                    entry: entry,
                                    isActive: isActive,
                                    onLoad: { Task { await engine.load(modelId: downloaded.id) } },
                                    onDelete: { try? dm.delete(downloaded.id) }
                                )
                                .padding(.horizontal)
                                if downloaded.id != dm.downloadedModels.last?.id {
                                    Divider()
                                        .background(SwiftLMTheme.divider)
                                        .padding(.leading, 72)
                                }
                            }
                        }
                        .background(SwiftLMTheme.surface.opacity(0.60))
                        .clipShape(RoundedRectangle(cornerRadius: SwiftLMTheme.radiusMedium))
                        .overlay(
                            RoundedRectangle(cornerRadius: SwiftLMTheme.radiusMedium)
                                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                        )
                        .padding(.horizontal)
                        .padding(.bottom, 10)
                    }

                    // ── 4. Recommended for device ──────────────────────────
                    let recommended = dm.modelsForDevice()
                        .filter { !dm.isDownloaded($0.id) }
                    if !recommended.isEmpty {
                        sectionHeader("Recommended for \(String(format: "%.0f GB", device.physicalRAMGB)) RAM")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(recommended) { model in
                                    CatalogCard(
                                        model: model,
                                        fitStatus: ModelCatalog.fitStatus(for: model, on: device),
                                        onTap: { handleSelect(model.id) }
                                    )
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 4)
                        }
                        .padding(.bottom, 10)
                    }

                    // ── 5. All Models ──────────────────────────────────────
                    let others = ModelCatalog.all
                        .filter { model in
                            !dm.isDownloaded(model.id) &&
                            !recommended.contains(where: { $0.id == model.id })
                        }
                    if !others.isEmpty {
                        sectionHeader("All Models")
                        VStack(spacing: 0) {
                            ForEach(others) { model in
                                CatalogListRow(
                                    model: model,
                                    fitStatus: ModelCatalog.fitStatus(for: model, on: device),
                                    onTap: { handleSelect(model.id) }
                                )
                                .padding(.horizontal)
                                if model.id != others.last?.id {
                                    Divider()
                                        .background(SwiftLMTheme.divider)
                                        .padding(.leading, 56)
                                }
                            }
                        }
                        .background(SwiftLMTheme.surface.opacity(0.60))
                        .clipShape(RoundedRectangle(cornerRadius: SwiftLMTheme.radiusMedium))
                        .overlay(
                            RoundedRectangle(cornerRadius: SwiftLMTheme.radiusMedium)
                                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                        )
                        .padding(.horizontal)
                        .padding(.bottom, 10)
                    }

                    // ── 6. HuggingFace search ──────────────────────────────
                    Button { showHFSearch = true } label: {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(SwiftLMTheme.accent)
                            Text("Search HuggingFace MLX models")
                                .foregroundStyle(SwiftLMTheme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(SwiftLMTheme.textTertiary)
                        }
                        .padding(14)
                        .background(SwiftLMTheme.surface.opacity(0.60))
                        .clipShape(RoundedRectangle(cornerRadius: SwiftLMTheme.radiusMedium))
                        .overlay(
                            RoundedRectangle(cornerRadius: SwiftLMTheme.radiusMedium)
                                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    Spacer(minLength: 32)
                }
            }
        }
        .navigationTitle("Models")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(SwiftLMTheme.background.opacity(0.90), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showManagement = true } label: {
                    Image(systemName: "externaldrive.badge.minus")
                        .foregroundStyle(SwiftLMTheme.accent)
                }
            }
        }
        .sheet(isPresented: $showHFSearch) {
            HFSearchSheet(onSelect: handleSelect)
                .environmentObject(engine)
        }
        .sheet(isPresented: $showManagement) {
            ModelManagementView()
                .environmentObject(engine)
        }
    }

    // MARK: — Helpers

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(SwiftLMTheme.textTertiary)
                .textCase(.uppercase)
            Rectangle()
                .fill(SwiftLMTheme.divider)
                .frame(height: 1)
        }
        .padding(.horizontal)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    private func handleSelect(_ modelId: String) {
        showHFSearch = false
        Task { await engine.load(modelId: modelId) }
    }
}

// MARK: — Active Model Hero Card

extension ModelsView {
    @ViewBuilder
    var activeModelCard: some View {
        ActiveModelCardView()
            .environmentObject(engine)
    }
}

private struct ActiveModelCardView: View {
    @EnvironmentObject private var engine: InferenceEngine

    var body: some View {
        Group {
            switch engine.state {
            case .ready(let id):
                let entry = ModelCatalog.all.first(where: { $0.id == id })
                ActiveModelHeroCard(modelId: id, entry: entry, state: engine.state)
            case .generating:
                ActiveModelHeroCard(
                    modelId: engine.loadedModelId ?? "Model",
                    entry: engine.loadedModelId.flatMap { id in ModelCatalog.all.first(where: { $0.id == id }) },
                    state: engine.state
                )
            case .loading:
                loadingCard
            case .downloading(let progress, let speed):
                downloadingCard(progress: progress, speed: speed)
            case .idle, .error:
                idleCard
            }
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.regular).tint(SwiftLMTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Loading model…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SwiftLMTheme.textPrimary)
                Text("Initializing Metal GPU")
                    .font(.caption)
                    .foregroundStyle(SwiftLMTheme.textSecondary)
            }
            Spacer()
        }
        .padding()
        .glassCard(cornerRadius: SwiftLMTheme.radiusLarge)
    }

    private func downloadingCard(progress: Double, speed: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(SwiftLMTheme.accent)
                Text("Downloading model…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SwiftLMTheme.textPrimary)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(SwiftLMTheme.textSecondary)
            }
            ProgressView(value: progress).tint(SwiftLMTheme.accent)
            Text(speed)
                .font(.caption.monospacedDigit())
                .foregroundStyle(SwiftLMTheme.textSecondary)
        }
        .padding()
        .glassCard(cornerRadius: SwiftLMTheme.radiusLarge)
    }

    private var idleCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(SwiftLMTheme.heroGradient)
                    .frame(width: 46, height: 46)
                    .shadow(color: SwiftLMTheme.accent.opacity(0.30), radius: 8)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("No model loaded")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SwiftLMTheme.textPrimary)
                Text("Select a model below to start chatting")
                    .font(.caption)
                    .foregroundStyle(SwiftLMTheme.textSecondary)
            }
            Spacer()
        }
        .padding()
        .glassCard(cornerRadius: SwiftLMTheme.radiusLarge)
    }
}

private struct ActiveModelHeroCard: View {
    let modelId: String
    let entry: ModelEntry?
    let state: ModelState

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Dark mesh gradient background
            RoundedRectangle(cornerRadius: SwiftLMTheme.radiusLarge)
                .fill(SwiftLMTheme.heroGradient)

            // Glow orb
            Circle()
                .fill(SwiftLMTheme.accent.opacity(0.18))
                .frame(width: 120, height: 120)
                .blur(radius: 30)
                .offset(x: 60, y: -20)

            // Border
            RoundedRectangle(cornerRadius: SwiftLMTheme.radiusLarge)
                .strokeBorder(
                    LinearGradient(
                        colors: [SwiftLMTheme.accent.opacity(0.40), Color.white.opacity(0.05)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )

            // Content
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Active Model")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    stateBadge
                }

                Text(entry?.displayName ?? modelId.components(separatedBy: "/").last ?? modelId)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                HStack(spacing: 10) {
                    if let entry {
                        heroChip(String(format: "%.1f GB RAM", entry.ramRequiredGB), icon: "memorychip")
                        if entry.isMoE {
                            heroChip("MoE", icon: "square.grid.3x3.fill")
                        }
                        heroChip(entry.quantization, icon: "slider.horizontal.3")
                    }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .shadow(
            color: SwiftLMTheme.shadowCard.color,
            radius: SwiftLMTheme.shadowCard.radius,
            x: SwiftLMTheme.shadowCard.x,
            y: SwiftLMTheme.shadowCard.y
        )
    }

    private func heroChip(_ label: String, icon: String) -> some View {
        Label(label, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.white.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch state {
        case .ready:
            badgeView("Ready", icon: "checkmark.circle.fill", color: SwiftLMTheme.success)
        case .generating:
            HStack(spacing: 4) {
                GeneratingDots()
                Text("Generating")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.white.opacity(0.15), in: Capsule())
        default:
            EmptyView()
        }
    }

    private func badgeView(_ label: String, icon: String, color: Color) -> some View {
        Label(label, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
    }
}

// MARK: — Download Progress Card

private struct DownloadProgressCard: View {
    let modelId: String
    let progress: ModelDownloadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(SwiftLMTheme.accent.opacity(0.15), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: progress.fractionCompleted)
                        .stroke(SwiftLMTheme.avatarGradient,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.3), value: progress.fractionCompleted)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(modelId.components(separatedBy: "/").last ?? modelId)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SwiftLMTheme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text("\(Int(progress.fractionCompleted * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(SwiftLMTheme.accent)
                        if let speed = progress.speedMBps {
                            Text("·")
                                .foregroundStyle(SwiftLMTheme.textTertiary).font(.caption)
                            Text(String(format: "%.1f MB/s", speed))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(SwiftLMTheme.textSecondary)
                        }
                    }
                }
                Spacer()
            }
            ProgressView(value: progress.fractionCompleted)
                .tint(SwiftLMTheme.accent)
        }
        .padding(14)
        .glassCard(cornerRadius: SwiftLMTheme.radiusMedium)
    }
}

// MARK: — Downloaded Model Row

private struct DownloadedModelRow: View {
    let downloaded: DownloadedModel
    let entry: ModelEntry?
    let isActive: Bool
    let onLoad: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button {
            if !isActive { onLoad() }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isActive ? AnyShapeStyle(SwiftLMTheme.userBubbleGradient) : AnyShapeStyle(SwiftLMTheme.surface))
                        .frame(width: 44, height: 44)
                    Image(systemName: entry?.isMoE == true ? "square.grid.3x3.fill" : "brain")
                        .font(.body)
                        .foregroundStyle(isActive ? .white : SwiftLMTheme.textSecondary)
                }
                .shadow(color: isActive ? SwiftLMTheme.accent.opacity(0.30) : .clear, radius: 6)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry?.displayName ?? downloaded.id.components(separatedBy: "/").last ?? downloaded.id)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(SwiftLMTheme.textPrimary)
                        if isActive {
                            ThemedBadge(text: "IN USE", color: SwiftLMTheme.accent)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(downloaded.displaySize)
                            .font(.caption)
                            .foregroundStyle(SwiftLMTheme.textSecondary)
                        if let entry {
                            Text("·").foregroundStyle(SwiftLMTheme.textTertiary).font(.caption)
                            Text(entry.quantization)
                                .font(.caption)
                                .foregroundStyle(SwiftLMTheme.textSecondary)
                        }
                    }
                }

                Spacer()

                Image(systemName: isActive ? "checkmark.circle.fill" : "arrow.right.circle")
                    .foregroundStyle(isActive ? SwiftLMTheme.accent : SwiftLMTheme.textTertiary)
                    .font(.title3)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: — Catalog Card (horizontal scroll)

private struct CatalogCard: View {
    let model: ModelEntry
    let fitStatus: ModelCatalog.FitStatus
    let onTap: () -> Void

    @State private var tapped = false

    var body: some View {
        Button {
            withAnimation(SwiftLMTheme.quickSpring) { tapped = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                tapped = false
                onTap()
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: model.isMoE ? "square.grid.3x3.fill" : "brain")
                        .font(.title3)
                        .foregroundStyle(fitColor)
                    Spacer()
                    fitBadgeIcon
                }
                Spacer()
                Text(model.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SwiftLMTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(String(format: "~%.0f GB RAM", model.ramRequiredGB))
                    .font(.caption)
                    .foregroundStyle(SwiftLMTheme.textSecondary)

                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                        .font(.caption)
                    Text("Download")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(fitColor)
                .padding(.top, 2)
            }
            .padding(14)
            .frame(width: 150, height: 165)
            .background(SwiftLMTheme.surface.opacity(0.70))
            .clipShape(RoundedRectangle(cornerRadius: SwiftLMTheme.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: SwiftLMTheme.radiusMedium)
                    .strokeBorder(fitColor.opacity(tapped ? 0.60 : 0.18), lineWidth: 1)
            )
            .scaleEffect(tapped ? 0.96 : 1.0)
            .shadow(color: fitColor.opacity(tapped ? 0.30 : 0.08), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }

    private var fitColor: Color {
        switch fitStatus {
        case .fits:          return SwiftLMTheme.accent
        case .tight:         return SwiftLMTheme.warning
        case .requiresFlash: return Color.indigo
        case .tooLarge:      return SwiftLMTheme.error
        }
    }

    @ViewBuilder
    private var fitBadgeIcon: some View {
        switch fitStatus {
        case .fits:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(SwiftLMTheme.success).font(.caption)
        case .tight:
            Image(systemName: "exclamationmark.circle").foregroundStyle(SwiftLMTheme.warning).font(.caption)
        case .requiresFlash:
            Image(systemName: "externaldrive.badge.wifi").foregroundStyle(Color.indigo).font(.caption)
        case .tooLarge:
            Image(systemName: "xmark.circle").foregroundStyle(SwiftLMTheme.error).font(.caption)
        }
    }
}

// MARK: — Catalog List Row

private struct CatalogListRow: View {
    let model: ModelEntry
    let fitStatus: ModelCatalog.FitStatus
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(fitColor.opacity(0.14))
                        .frame(width: 40, height: 40)
                    Image(systemName: model.isMoE ? "square.grid.3x3.fill" : "brain")
                        .font(.callout)
                        .foregroundStyle(fitColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(SwiftLMTheme.textPrimary)
                        if let badge = model.badge {
                            ThemedBadge(text: badge, color: SwiftLMTheme.accent)
                        }
                    }
                    Text("\(model.parameterSize) · \(model.quantization) · ~\(String(format: "%.0f GB", model.ramRequiredGB)) RAM")
                        .font(.caption)
                        .foregroundStyle(SwiftLMTheme.textSecondary)
                }

                Spacer()

                fitIcon
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var fitColor: Color {
        switch fitStatus {
        case .fits:          return SwiftLMTheme.accent
        case .tight:         return SwiftLMTheme.warning
        case .requiresFlash: return Color.indigo
        case .tooLarge:      return SwiftLMTheme.error
        }
    }

    @ViewBuilder
    private var fitIcon: some View {
        switch fitStatus {
        case .fits:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(SwiftLMTheme.accent).font(.title3)
        case .tight:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(SwiftLMTheme.warning).font(.title3)
        case .requiresFlash:
            Image(systemName: "externaldrive.badge.wifi")
                .foregroundStyle(Color.indigo).font(.title3)
        case .tooLarge:
            Image(systemName: "xmark.circle")
                .foregroundStyle(SwiftLMTheme.error).font(.title3)
        }
    }
}

// MARK: — HF Search Sheet

private struct HFSearchSheet: View {
    @EnvironmentObject private var engine: InferenceEngine
    @Environment(\.dismiss) private var dismiss
    let onSelect: (String) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                SwiftLMTheme.background.ignoresSafeArea()
                HFSearchTab(onSelect: { id in
                    onSelect(id)
                    dismiss()
                })
            }
            .navigationTitle("Search HuggingFace")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SwiftLMTheme.accent)
                }
            }
        }
    }
}
