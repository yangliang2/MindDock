import SwiftUI
import MindDockCore

struct EdgeDockView: View {
    @ObservedObject var viewModel: DockViewModel
    let onOpenQuickDrop: () -> Void
    let onHideDock: () -> Void

    private var accentColor: Color {
        viewModel.snapshot.lane == .work
            ? Color(red: 0.22, green: 0.74, blue: 0.97)
            : Color(red: 0.20, green: 0.83, blue: 0.60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerSection
            berthsSection
            footerSection
        }
        .padding(14)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    ForEach(0..<DockEngine.maxBerths, id: \.self) { index in
                        Circle()
                            .fill(index < viewModel.snapshot.berths.count ? accentColor : Color.secondary.opacity(0.25))
                            .frame(width: 8, height: 8)
                    }
                }

                Text("MindDock")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Button(action: onOpenQuickDrop) {
                    Text("+ Drop")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(accentColor.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Open Quick Drop (Option + Space)")

                Button(action: onHideDock) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Hide Edge Dock (Option + Shift + Space)")
            }

            HStack(spacing: 6) {
                ForEach(Lane.allCases, id: \.self) { lane in
                    let isSelected = viewModel.snapshot.lane == lane
                    Button {
                        viewModel.shift(to: lane)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: lane == .work ? "desktopcomputer" : "figure.walk")
                                .font(.system(size: 10))
                            Text(lane == .work ? "Work Dock" : "Life Dock")
                                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? accentColor.opacity(0.20) : Color.secondary.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var berthsSection: some View {
        VStack(spacing: 8) {
            ForEach(0..<DockEngine.maxBerths, id: \.self) { index in
                if index < viewModel.snapshot.berths.count {
                    BerthSlotCard(
                        item: viewModel.snapshot.berths[index],
                        slotNumber: index + 1,
                        accentColor: accentColor,
                        onResolve: { viewModel.resolve(id: viewModel.snapshot.berths[index].id) },
                        onFlipLane: { viewModel.flipLane(id: viewModel.snapshot.berths[index].id) },
                        onSinkDeep: { viewModel.sinkToDeep(id: viewModel.snapshot.berths[index].id) }
                    )
                } else {
                    EmptyBerthSlot(slotNumber: index + 1)
                }
            }
        }
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(viewModel.snapshot.queuedCount) queued")
                Text("·")
                Text("\(viewModel.snapshot.offstageCount) in \(viewModel.snapshot.lane.opposite.rawValue.capitalized)")
                Spacer()
                Text("Deep \(viewModel.snapshot.deepCount)")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)

            if let banner = viewModel.statusBanner {
                Text(banner)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(accentColor)
                    .lineLimit(1)
            }
        }
        .padding(.top, 2)
    }
}

private struct BerthSlotCard: View {
    let item: DockItem
    let slotNumber: Int
    let accentColor: Color
    let onResolve: () -> Void
    let onFlipLane: () -> Void
    let onSinkDeep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.raw)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .help(item.raw)

            if let prep = item.prep, !prep.isEmpty {
                Text(prep)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 6) {
                Text("Berth #\(slotNumber)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Spacer()

                Button(action: onFlipLane) {
                    Text("⇄ \(item.lane.opposite.rawValue.capitalized)")
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("Flip lane between Work and Life")

                Button(action: onSinkDeep) {
                    Text("↓ Deep")
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("Sink straight into the Deep")

                Button(action: onResolve) {
                    Text("✓ Resolve")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("Resolve Berth and promote oldest queued item")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(accentColor.opacity(0.28), lineWidth: 1)
                )
        )
    }
}

private struct EmptyBerthSlot: View {
    let slotNumber: Int

    var body: some View {
        HStack {
            Text("Berth #\(slotNumber) · Clear mind")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(Color.secondary.opacity(0.22))
        )
    }
}

struct QuickDropBarView: View {
    @ObservedObject var viewModel: DockViewModel
    @FocusState private var isInputFocused: Bool
    let focusTrigger: Int
    let onSubmitted: () -> Void
    let onCancelled: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.cyan)

                TextField("Drop a raw thought without choosing a folder…", text: $viewModel.draftText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .regular))
                    .focused($isInputFocused)
                    .onSubmit {
                        if viewModel.submitDraftDrop() {
                            onSubmitted()
                        }
                    }

                Button {
                    if viewModel.submitDraftDrop() {
                        onSubmitted()
                    }
                } label: {
                    Text("Drop ↵")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.cyan.opacity(0.2), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                ForEach(DropLaneChoice.allCases, id: \.self) { choice in
                    let active = viewModel.dropLaneChoice == choice
                    Button {
                        viewModel.dropLaneChoice = choice
                    } label: {
                        Text(choice.label)
                            .font(.system(size: 11, weight: active ? .semibold : .regular))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(active ? Color.cyan.opacity(0.22) : Color.secondary.opacity(0.10))
                            )
                    }
                    .buttonStyle(.plain)
                }

                Text("→ \(viewModel.predictedLaneForDraft.rawValue.capitalized) Dock")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("↵ Drop · ⇥ Lane · Esc Close")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)

                Button("Esc") {
                    onCancelled()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 540)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.cyan.opacity(0.35), lineWidth: 1)
                )
        )
        .onKeyPress(.tab) {
            viewModel.cycleDropLaneChoice()
            return .handled
        }
        .onAppear {
            isInputFocused = true
        }
        .onChange(of: focusTrigger) { _, _ in
            isInputFocused = true
        }
    }
}
