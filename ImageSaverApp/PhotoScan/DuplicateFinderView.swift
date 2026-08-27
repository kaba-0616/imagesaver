import SwiftUI
import Photos

/// The duplicate finder.
///
/// Deliberately holds no selection of its own. `DuplicateScanner.selected` is
/// the only place a chosen photo is recorded, because that is the only place
/// that can prune itself when the groups are replaced -- and a photo left
/// selected after it has gone off screen is a photo deleted without ever having
/// been looked at.
struct DuplicateFinderView: View {

    @StateObject private var scanner = DuplicateScanner()

    /// Which tab is in front of the user. Every bulk action below is scoped to
    /// it, so what is selected on the other tab can neither be counted in nor
    /// deleted by the button here.
    @State private var tab: DuplicateGroup.Kind = .identical
    /// Follows the thumb while it is being dragged; the scanner is only told
    /// once it is let go. Re-grouping a whole library on every step would make
    /// the control unusable.
    @State private var levelDisplay = Double(DuplicateLevel.standard)
    @State private var confirmingDelete = false
    /// Which tab's exclusions the confirmation alert is about, presented from
    /// inside the settings sheet. The two tabs clear independently now, so
    /// there is no single Bool left to ask "is the alert up".
    @State private var confirmingClearKind: DuplicateGroup.Kind?
    @State private var showingSettings = false
    @State private var message: String?
    @State private var showingLog = false
    @State private var preview: PreviewTarget?
    /// On by default, matching how the screen always behaved before this
    /// switch existed. Off only hides the circles -- selection made while
    /// they were showing is untouched, and the bulk actions still work.
    @State private var showsCheckboxes = true

    var body: some View {
        content
            .navigationTitle("写真の重複を整理")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { levelDisplay = Double(scanner.level) }
            .onChange(of: scanner.level) { value in levelDisplay = Double(value) }
            .onChange(of: tab) { newTab in
                message = nil
                // Similar is no longer computed automatically after a scan --
                // it is the expensive pass, and starting it before anyone had
                // looked at this tab read, on device, as an unprompted
                // re-scan. This is the one place it gets kicked off instead:
                // the first time the tab is actually opened.
                guard newTab == .similar, !scanner.hasSimilarResult,
                      scanner.phase == .ready, scanner.regrouping == nil else { return }
                scanner.regroup(note: "類似タブを開いた", kind: .similar)
            }
            // The log is gathered rather than written line by line, so leaving
            // the screen is one of the points it has to be pushed out at.
            .onDisappear { PhotoScanLog.shared.flush() }
            .sheet(isPresented: $showingLog) {
                PhotoScanLogSheet(log: PhotoScanLog.shared) { showingLog = false }
            }
            .sheet(isPresented: $showingSettings) {
                settingsSheet
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    // Deletion no longer re-groups on its own, so this is the
                    // one way back to a fresh pass once the user is ready for
                    // one -- on their schedule, not after every single delete.
                    Button {
                        scanner.regroup(note: "手動再照合", kind: tab)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    // phase stays .ready for the whole of a regroup started
                    // from the results screen -- only `regrouping` moves --
                    // so phase alone lets this get pressed again mid-pass and
                    // queue a second full grouping behind the first on the
                    // same serial queue.
                    .disabled(scanner.phase != .ready || scanner.regrouping != nil)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showsCheckboxes.toggle() } label: {
                        Image(systemName: showsCheckboxes ? "checkmark.circle" : "circle.dashed")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    // Reachable regardless of phase: the footer copy of this
                    // button only exists once results are on screen, and
                    // nothing at all was reachable while counting, scanning
                    // or grouping.
                    Button { showingLog = true } label: {
                        Image(systemName: "doc.text")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .fullScreenCover(item: $preview) { target in
                DuplicatePreviewView(scanner: scanner,
                                     members: target.members,
                                     startIndex: target.index) {
                    preview = nil
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch scanner.access {
        case .authorized, .limited:
            library
        case .notDetermined:
            accessRequest
        default:
            accessRefused
        }
    }

    // MARK: - Permission

    private var accessRequest: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("重複を探すには写真を読み取る必要があります")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("保存だけなら「追加のみ」で足ります。この画面を使うときだけ、すべての写真へのアクセスを許可してください。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("写真へのアクセスを許可する") {
                Task { await scanner.requestAccess() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }

    private var accessRefused: some View {
        VStack(spacing: 16) {
            Text("写真へのアクセスが許可されていません")
                .font(.headline)
            Button("設定アプリを開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
        .padding(32)
    }

    // MARK: - Phases

    @ViewBuilder
    private var library: some View {
        switch scanner.phase {
        case .idle:
            startPrompt
        case .counting:
            counting
        case .scanning(let done, let total, let remaining):
            scanning(done: done, total: total, remaining: remaining)
        case .grouping(let fraction, let remaining):
            grouping(fraction: fraction, remaining: remaining)
        case .ready:
            results
        }
    }

    private var startPrompt: some View {
        VStack(spacing: 16) {
            Text("ライブラリ全体を調べて、同じ写真と似ている写真をまとめます。")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            if scanner.access == .limited { limitedNotice }
            Button("調べる") { scanner.scan() }
                .buttonStyle(.borderedProminent)
            Text("写真は読み取るだけです。削除はこの後の画面で選んだものだけ、iOSの確認を挟んでから行われます。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if scanner.rejectionCount > 0 {
                Text("「違う」として除外中の組: \(scanner.rejectionCount)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            logRow
        }
        .padding(32)
    }

    private var limitedNotice: some View {
        Text("「選択した写真のみ」の設定なので、許可した写真だけが対象になります。")
            .font(.footnote)
            .foregroundColor(.orange)
            .multilineTextAlignment(.center)
    }

    /// No bar: the number of photos is not known yet, so a bar would have to
    /// invent a position for itself.
    private var counting: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("写真を数えています…")
                .font(.footnote)
                .foregroundColor(.secondary)
            stayForegroundNotice
        }
        .padding(32)
    }

    private func scanning(done: Int, total: Int, remaining: TimeInterval?) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: total > 0 ? min(Double(done) / Double(total), 1) : 0)
                .padding(.horizontal, 48)
            Text("\(done) / \(total) 枚")
                .font(.footnote)
            Text(remainingText(remaining))
                .font(.caption)
                .foregroundColor(.secondary)
            stayForegroundNotice
        }
        .padding(32)
    }

    private func grouping(fraction: Double, remaining: TimeInterval?) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: min(max(fraction, 0), 1))
                .padding(.horizontal, 48)
            Text("同じ写真どうしを照合しています…")
                .font(.footnote)
            Text(remainingText(remaining))
                .font(.caption)
                .foregroundColor(.secondary)
            stayForegroundNotice
        }
        .padding(32)
    }

    /// A regular app is never given indefinite time in the background -- iOS
    /// suspends it after a short, unpredictable grace period regardless of
    /// what it is in the middle of. This is the honest version of "can I
    /// switch apps and come back": for a moment, maybe; for as long as this
    /// takes, no.
    private var stayForegroundNotice: some View {
        Text("この画面を開いたままにしてください。バックグラウンドに切り替えると、iOSにより中断されることがあります。")
            .font(.caption2)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
    }

    /// An estimate is only shown once the scan is willing to stand behind one.
    /// The first few seconds of any of these produce numbers that swing by
    /// minutes, and a countdown that jumps reads as broken.
    private func remainingText(_ remaining: TimeInterval?) -> String {
        guard let remaining else { return "残り時間を見積もっています…" }
        return PhotoScanFormat.remaining(remaining)
    }

    // MARK: - Results

    private var results: some View {
        VStack(spacing: 0) {
            tabPicker
            regroupBar
            if scanner.access == .limited {
                limitedNotice.padding(.horizontal, 16).padding(.bottom, 4)
            }
            list
            bottomBar
        }
        .confirmationDialog("「\(tab.tabLabel)」で選んだ\(chosenCount)枚を削除しますか？",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("削除する", role: .destructive) {
                Task { await runDelete() }
            }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("「最近削除した項目」に30日残ります。iCloud写真がオンの場合は他の端末からも消えます。")
        }
    }

    private var tabPicker: some View {
        Picker("表示", selection: $tab) {
            ForEach(DuplicateGroup.Kind.allCases, id: \.self) { kind in
                Text(tabLabel(kind)).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// A re-group started from the results keeps the results. The slider that
    /// starts it lives in the list, and replacing the list with a spinner
    /// takes the control away from under the user's finger halfway through an
    /// adjustment -- so the progress and the estimate come as a thin bar over
    /// the top of everything instead.
    @ViewBuilder
    private var regroupBar: some View {
        if let state = scanner.regrouping {
            VStack(spacing: 2) {
                ProgressView(value: min(max(state.fraction, 0), 1))
                Text("照合し直しています… " + remainingText(state.remaining))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    private func tabLabel(_ kind: DuplicateGroup.Kind) -> String {
        let count = scanner.groupList(in: kind).count
        return count > 0 ? "\(kind.tabLabel) \(count)組" : kind.tabLabel
    }

    private var visibleGroups: [DuplicateGroup] {
        scanner.groupList(in: tab)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                // Only on the similar tab. An exact copy and a burst are found
                // without the threshold taking any part in it, so offering the
                // slider next to them would claim an effect it does not have.
                if tab == .similar { levelControl }
                if visibleGroups.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(visibleGroups.enumerated()), id: \.element.id) { index, group in
                        card(group, number: index + 1)
                    }
                }
                footer
            }
            .padding(16)
        }
    }

    // MARK: - Settings

    private var settingsSheet: some View {
        // NavigationView, not NavigationStack: this app still supports iOS 15.
        NavigationView {
            List {
                clearSection(kind: .identical)
                clearSection(kind: .similar)
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") { showingSettings = false }
                }
            }
            // Presented from here rather than from the button that sets
            // confirmingClearKind, so it works the same whether that press
            // came from this sheet or (via `showingSettings = true`) from the
            // empty state on the results screen.
            .alert("除外をすべて解除しますか？",
                  isPresented: Binding(
                      get: { confirmingClearKind != nil },
                      set: { if !$0 { confirmingClearKind = nil } }
                  ),
                  presenting: confirmingClearKind) { kind in
                Button("解除する", role: .destructive) {
                    Task { await clearRejections(kind: kind) }
                }
                Button("やめる", role: .cancel) {}
            } message: { kind in
                Text("「\(kind.tabLabel)」タブで「違う」とした\(scanner.rejectionCount(in: kind))組が元に戻り、また候補として表示されるようになります。写真は削除されません。")
            }
        }
    }

    private func clearSection(kind: DuplicateGroup.Kind) -> some View {
        Section(kind.tabLabel) {
            HStack {
                Text("「違う」として除外中")
                Spacer()
                Text("\(scanner.rejectionCount(in: kind))組")
                    .foregroundColor(.secondary)
            }
            Button("除外をすべて解除") { confirmingClearKind = kind }
                .disabled(scanner.rejectionCount(in: kind) == 0)
        }
    }

    private func card(_ group: DuplicateGroup, number: Int) -> some View {
        DuplicateGroupCard(
            group: group,
            number: number,
            selected: scanner.selected,
            details: scanner.details,
            showsCheckboxes: showsCheckboxes,
            onToggle: { identifier in scanner.toggle(identifier) },
            onSelectGroup: { scanner.selectGroupButBest(group) },
            onDeselectGroup: { scanner.deselectGroup(group) },
            onReject: { Task { await reject(group) } },
            onOpen: { index in
                preview = PreviewTarget(id: group.id, members: group.displayOrder, index: index)
            }
        )
    }

    // MARK: - Level

    private var levelValue: Int {
        // step: 1 still hands back things like 3.0000000000000004, and Int()
        // truncates. Rounding first is what keeps the label, the log and the
        // grouping talking about the same number.
        DuplicateLevel.clamp(Int(levelDisplay.rounded()))
    }

    private var levelControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("判定のレベル")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(levelValue)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(value: $levelDisplay,
                   in: Double(DuplicateLevel.range.lowerBound)...Double(DuplicateLevel.range.upperBound),
                   step: 1)
                   // Same reason as the reload button: a regroup already in
                   // flight must finish (or be superseded cleanly) before
                   // another one is queued behind it on the serial queue.
                   .disabled(scanner.regrouping != nil)
            HStack(spacing: 8) {
                Text("ゆるい")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(DuplicateLevel.detail(for: levelValue))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                Text("厳しい")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text("判定のレベルを変えると、一度「違う」とした組が再び出ることがあります。")
                .font(.caption2)
                .foregroundColor(.secondary)
            if levelValue != scanner.level {
                HStack {
                    Text("表示中の結果はレベル\(scanner.level)のものです")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Spacer()
                    Button("照合") { scanner.commitLevel(levelValue) }
                        .font(.caption.weight(.semibold))
                        .disabled(scanner.regrouping != nil)
                }
            }
            #if IMAGESAVER_DEV_TOOLS
            Button {
                scanner.runFullLevelSweep()
            } label: {
                if scanner.isSweepRunning {
                    Label("全レベル照合中…", systemImage: "hourglass")
                } else {
                    Label("全レベル照合(開発用)", systemImage: "list.number")
                }
            }
            .font(.caption)
            .disabled(scanner.phase != .ready || scanner.isSweepRunning)
            #endif
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Empty

    /// Never a flat "nothing found" when the user is the reason there is
    /// nothing: that reads as the scan having failed, and hides the one control
    /// that would bring the groups back.
    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            if tab == .similar && scanner.level == DuplicateLevel.range.upperBound {
                Text("レベルが10なので、完全に同じ写真だけを探しています。")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                Text("レベルを下げると、似ている写真も出てきます。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else if scanner.rejectionCount(in: tab) > 0 {
                Text("すべて確認済みです")
                    .font(.headline)
                Text("「違う」とした\(scanner.rejectionCount(in: tab))組は、ここには表示していません。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("設定から除外を解除する") { showingSettings = true }
                    .font(.footnote)
            } else {
                Text(tab.emptyLabel)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: - Footer

    /// Everything that is useful but must not be easy to hit by accident: the
    /// blanket undo, and the log the developer can only ever read by the user
    /// copying it out of here.
    private var footer: some View {
        VStack(spacing: 8) {
            Button("もう一度調べる") { scanner.scan() }
                .font(.caption2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var logRow: some View {
        HStack(spacing: 10) {
            Button("ログ") { showingLog = true }
                .font(.caption2)
            Text(AppVersion.short)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Bottom bar

    /// The one number here is the one the delete button acts on, and it is
    /// asked of the scanner per tab. Anything selected on the other tab is not
    /// in it, is not shown, and cannot be deleted from here.
    private var chosenIdentifiers: Set<String> {
        scanner.selectedIdentifiers(in: tab)
    }

    private var chosenCount: Int { chosenIdentifiers.count }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            undoRow
            HStack(spacing: 12) {
                Button(tab.selectAllLabel) { scanner.selectAllButBest(in: tab) }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .disabled(visibleGroups.isEmpty)
                Spacer(minLength: 8)
                Button("選択を解除") { scanner.clearSelection(in: tab) }
                    .disabled(chosenCount == 0)
            }
            .font(.footnote)
            Button {
                confirmingDelete = true
            } label: {
                Text("削除 (\(chosenCount)枚)")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            // Closed while a re-grouping is in flight. The confirmation dialog
            // fixes its title when it is put up, so a grouping landing behind
            // it leaves a count on screen that is no longer true -- and the
            // same window is what lets a stale grouping land on top of a scan
            // the user has just restarted.
            .disabled(chosenCount == 0 || scanner.regrouping != nil)
            Text("「\(tab.tabLabel)」タブで選んだ写真だけが対象です。")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(.bar)
    }

    @ViewBuilder
    private var undoRow: some View {
        if scanner.canUndoRejection {
            HStack(spacing: 8) {
                Text("1組を「違う」にしました")
                    .font(.footnote)
                Spacer(minLength: 8)
                Button("取り消す") { Task { await undoRejection() } }
                    .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemBackground))
            .cornerRadius(8)
        }
    }

    // MARK: - Actions

    private func runDelete() async {
        // Re-read rather than reuse what the dialog was opened with: the list
        // can have been replaced while the confirmation was up.
        let targets = scanner.selectedIdentifiers(in: tab)
        guard !targets.isEmpty else {
            message = "削除できる写真が選ばれていません。"
            return
        }
        switch await scanner.delete(targets, in: tab) {
        case .done(let count):
            message = count > 0
                ? "\(count)枚を削除しました。「最近削除した項目」に30日残ります。"
                : "削除できる写真がありませんでした。"
        case .cancelled:
            // Told apart from a failure on purpose: the user pressing "cancel"
            // in the iOS sheet is not something to apologise for.
            message = "削除はキャンセルされました。写真はそのままです。"
        case .failed(let text):
            message = "削除できませんでした: \(text)"
        }
    }

    private func reject(_ group: DuplicateGroup) async {
        message = describe(await scanner.reject(group), success: nil)
    }

    private func undoRejection() async {
        message = describe(await scanner.undoRejection(), success: "「違う」を取り消しました。")
    }

    private func clearRejections(kind: DuplicateGroup.Kind) async {
        message = describe(await scanner.clearRejections(kind: kind),
                           success: "「\(kind.tabLabel)」の除外をすべて解除しました。")
    }

    /// A rejection that was not stored must say so. Dropping the card anyway
    /// would leave the user believing a decision was kept that will be gone the
    /// next time the screen is opened.
    private func describe(_ outcome: DuplicateScanner.RejectOutcome,
                          success: String?) -> String? {
        switch outcome {
        case .done:
            return success
        case .busy:
            return "前の「違う」を保存している最中でした。少し待ってからもう一度押してください。"
        case .listChanged:
            return "記録は保存しました。一覧が入れ替わったため、照合をやり直しています。"
        case .groupTooLarge(let count):
            return "\(count)枚の組は大きすぎるため「違う」として記録できませんでした。組を分けてから試してください。"
        case .storeFull(let pairs):
            return "「違う」の記録が上限に達したため保存できませんでした (\(pairs)組相当)。除外を解除すると空きます。"
        case .failed(let text):
            return "「違う」の記録に失敗しました: \(text)"
        }
    }
}

/// What the fullscreen viewer is opened with. The members are copied in at the
/// moment of the tap, so the pages cannot shuffle under the user if the sizes
/// arrive and the group is re-ordered while it is open.
private struct PreviewTarget: Identifiable {
    let id: Int
    let members: [PhotoFingerprint]
    let index: Int
}
