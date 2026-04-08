// HFSearchTab.swift -- HuggingFace model search with live results
import SwiftUI

struct HFSearchTab: View {
    let onSelect: (String) -> Void

    @ObservedObject private var service = HFModelSearchService.shared
    @State private var query = ""
    @State private var sort = HFSortOption.trending

    var body: some View {
        VStack(spacing: 0) {
            // Search bar + sort
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(SwiftBuddyTheme.textSecondary)
                    TextField("Search MLX models...", text: $query)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(SwiftBuddyTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(SwiftBuddyTheme.surface.opacity(0.60))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(SwiftBuddyTheme.divider, lineWidth: 1)
                )

                // Sort chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(HFSortOption.allCases, id: \.self) { option in
                            Button {
                                sort = option
                                service.search(query: query, sort: sort)
                            } label: {
                                Text(option.label)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        sort == option ? SwiftBuddyTheme.accent : SwiftBuddyTheme.surface.opacity(0.60),
                                        in: Capsule()
                                    )
                                    .foregroundStyle(sort == option ? .white : SwiftBuddyTheme.textPrimary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider().background(SwiftBuddyTheme.divider)

            // Results
            if service.isSearching && service.results.isEmpty {
                Spacer()
                ProgressView("Searching HuggingFace...")
                    .foregroundStyle(SwiftBuddyTheme.textSecondary)
                Spacer()
            } else if let err = service.errorMessage {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(SwiftBuddyTheme.warning)
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(SwiftBuddyTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                Spacer()
            } else if service.results.isEmpty && !query.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(SwiftBuddyTheme.textSecondary)
                    Text("No MLX models found for \"\(query)\"")
                        .font(.subheadline)
                        .foregroundStyle(SwiftBuddyTheme.textSecondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(service.results) { model in
                        HFModelRow(model: model, onSelect: onSelect)
                    }
                    if service.hasMore {
                        HStack {
                            Spacer()
                            Button("Load More") { service.loadMore() }
                                .buttonStyle(.borderedProminent)
                                .tint(SwiftBuddyTheme.accent)
                                .controlSize(.small)
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .bottom) {
                    if service.isSearching {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Loading...").font(.caption).foregroundStyle(SwiftBuddyTheme.textSecondary)
                        }
                        .padding(6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 8)
                    }
                }
            }
        }
        .onChange(of: query) { _, newValue in
            service.search(query: newValue, sort: sort)
        }
        .onAppear {
            if service.results.isEmpty {
                service.search(query: "", sort: sort)
            }
        }
    }
}

// MARK: -- HF Model Row

private struct HFModelRow: View {
    let model: HFModelResult
    let onSelect: (String) -> Void

    var body: some View {
        Button {
            onSelect(model.id)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.repoName)
                        .font(.system(.subheadline, design: .default, weight: .semibold))
                        .foregroundStyle(SwiftBuddyTheme.textPrimary)
                        .lineLimit(1)

                    Text(model.id)
                        .font(.caption)
                        .foregroundStyle(SwiftBuddyTheme.textSecondary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if model.isMlxCommunity {
                            badge("mlx-community", color: SwiftBuddyTheme.accent)
                        }
                        if model.isMoE {
                            badge("MoE", color: SwiftBuddyTheme.accentSecondary)
                        }
                        if let size = model.paramSizeHint {
                            badge(size, color: SwiftBuddyTheme.warning)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    if !model.downloadsDisplay.isEmpty {
                        Text(model.downloadsDisplay)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(SwiftBuddyTheme.textSecondary)
                    }
                    if !model.likesDisplay.isEmpty {
                        Text(model.likesDisplay)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(SwiftBuddyTheme.error)
                    }
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(SwiftBuddyTheme.accent)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func badge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
