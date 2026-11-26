import MindDockCore
import SwiftUI

struct EdgeDockView: View {
    @ObservedObject var viewModel: DockViewModel
    let onOpenQuickDrop: () -> Void
    let onOpenRecall: () -> Void
    let onOpenSettings: () -> Void
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

                Button(action: onOpenRecall) {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkle.magnifyingglass")
                            .font(.system(size: 10))
                        Text("打捞")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("凭模糊印象从深海打捞过往事项")

                Button(action: onOpenQuickDrop) {
                    Text("+ 闪投")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(accentColor.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("打开快速闪投栏 (⌥Space)")

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("设置与手机连接… (⌘,)")

                Button(action: onHideDock) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("隐藏边缘停靠台 (⌥⇧Space)")
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
                            Text(lane.dockTitle)
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
                    BerthSlotView(
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
                Text("候补 \(viewModel.snapshot.queuedCount) 项")
                Text("·")
                Text("\(viewModel.snapshot.lane.opposite.displayTitle)后台 \(viewModel.snapshot.offstageCount) 项")
                Spacer()
                Button(action: onOpenRecall) {
                    Text("深海 \(viewModel.snapshot.deepCount) ↗")
                        .underline()
                }
                .buttonStyle(.plain)
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

private struct BerthSlotView: View {
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

            if item.prepState == .ready, let prep = item.prep, !prep.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9))
                        Text("AI 备料")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(accentColor)

                    Text(prep)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            } else if item.prepState == .pending {
                HStack(spacing: 5) {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 10))
                    Text("正在后台备料…")
                        .font(.system(size: 10.5))
                }
                .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                Text("泊位 #\(slotNumber)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Spacer()

                Button(action: onFlipLane) {
                    Text("⇄ 切到\(item.lane.opposite.displayTitle)")
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("在工作与生活分道之间切换")

                Button(action: onSinkDeep) {
                    Text("↓ 沉底")
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("无需待办，直接沉入深海留存")

                Button(action: onResolve) {
                    Text("✓ 办结")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("办结释放泊位，并自动递补候补首项")
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
            Text("泊位 #\(slotNumber) · 台面留白")
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

    private var isRecording: Bool {
        viewModel.voiceController.isRecording
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            modeHeaderBar

            if viewModel.quickBarMode == .drop {
                dropInputSection
                dropFooterBar
            } else {
                recallInputSection
                recallResultsSection
            }
        }
        .padding(16)
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            viewModel.quickBarMode == .drop ? Color.cyan.opacity(0.35) : Color.purple.opacity(0.38),
                            lineWidth: 1
                        )
                )
        )
        .onKeyPress(.tab) {
            if viewModel.quickBarMode == .drop {
                viewModel.cycleDropLaneChoice()
                return .handled
            }
            return .ignored
        }
        .onAppear {
            isInputFocused = true
        }
        .onChange(of: focusTrigger) { _, _ in
            isInputFocused = true
        }
    }

    private var modeHeaderBar: some View {
        HStack(spacing: 6) {
            ForEach(QuickBarMode.allCases, id: \.self) { mode in
                let selected = viewModel.quickBarMode == mode
                Button {
                    viewModel.setQuickBarMode(mode)
                    isInputFocused = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode == .drop ? "bolt.horizontal.fill" : "sparkle.magnifyingglass")
                            .font(.system(size: 10.5))
                        Text(mode.label)
                            .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(selected
                                  ? (mode == .drop ? Color.cyan.opacity(0.22) : Color.purple.opacity(0.22))
                                  : Color.secondary.opacity(0.10))
                    )
                }
                .buttonStyle(.plain)
            }

            if let voiceMessage = viewModel.voiceController.voiceStatusMessage {
                HStack(spacing: 4) {
                    Circle()
                        .fill(isRecording ? Color.red : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(voiceMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isRecording ? Color.red : Color.secondary)
                }
                .padding(.leading, 6)
            }

            Spacer()

            Button("收起 Esc") {
                viewModel.cancelQuickBarSession()
                onCancelled()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
    }

    private var dropInputSection: some View {
        HStack(spacing: 8) {
            Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                .font(.system(size: 21))
                .foregroundStyle(isRecording ? Color.red : Color.cyan)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            viewModel.beginVoiceMicPress()
                        }
                        .onEnded { _ in
                            viewModel.endVoiceMicPress()
                        }
                )
                .accessibilityElement()
                .accessibilityLabel(isRecording ? "停止语音录制" : "语音闪投")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    viewModel.toggleVoiceCapture()
                }
                .help(isRecording
                      ? "松开或点击结束录音，立即释放麦克风"
                      : "点击切换录音，或按住直接说话闪投（平时零麦克风占用）")

            speechLocaleSelector

            TextField("随手闪投一个念头，或点击/按住左侧麦克风直接说…", text: $viewModel.draftText)
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
                Text("闪投 ↵")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.cyan.opacity(0.2), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
        }
    }

    private var speechLocaleSelector: some View {
        HStack(spacing: 2) {
            ForEach(SpeechLocale.allCases, id: \.self) { locale in
                let selected = viewModel.speechLocale == locale
                Button {
                    viewModel.setSpeechLocale(locale)
                } label: {
                    Text(locale.shortLabel)
                        .font(.system(size: 10, weight: selected ? .semibold : .regular))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule()
                                .fill(selected ? Color.cyan.opacity(0.24) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help("语音识别语言：\(locale.displayName)")
            }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.10), in: Capsule())
    }

    private var dropFooterBar: some View {
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

            Text("→ 归入\(viewModel.predictedLaneForDraft.dockTitle)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()

            Text("🎤 点击或长按说话 · ↵ 闪投 · ⇥ 切换分道")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var recallInputSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 17))
                .foregroundStyle(.purple)

            TextField("输入模糊印象或近义词，从深海打捞历史事项…", text: $viewModel.recallQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 15.5, weight: .regular))
                .focused($isInputFocused)
                .onSubmit {
                    Task { await viewModel.performRecall() }
                }

            Button {
                Task { await viewModel.performRecall() }
            } label: {
                Text(viewModel.isRecalling ? "打捞中…" : "打捞 ↵")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.purple.opacity(0.2), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isRecalling)
        }
    }

    private var recallResultsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if viewModel.recallResults.isEmpty {
                Text(viewModel.isRecalling
                     ? "正在按语境关联度从深海打捞…"
                     : "暂无匹配的深海记录，输入模糊印象按 ↵ 即可打捞。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.recallResults) { item in
                            RecallHitItem(item: item) {
                                _ = viewModel.resurfaceFromRecall(id: item.id)
                            }
                        }
                    }
                }
                .frame(maxHeight: 210)
            }
        }
    }
}

private struct RecallHitItem: View {
    let item: DockItem
    let onResurface: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.raw)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let prep = item.prep, !prep.isEmpty {
                    Text(prep)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Text(item.lane.displayTitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())

            Button(action: onResurface) {
                Text("↑ 捞回台面")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("将这条深海记录重新捞回当前停靠台")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.purple.opacity(0.22), lineWidth: 1)
                )
        )
    }
}
