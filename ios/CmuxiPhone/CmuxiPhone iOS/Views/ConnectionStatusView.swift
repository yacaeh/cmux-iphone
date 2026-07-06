import SwiftUI
import UIKit
import PhotosUI
import AVKit
import WebKit

// MARK: - Navigation routes
//
// Hierarchy: Office (Mac) → Workspace (project folder) → Session → full content.
// One Mac is connected at a time; tapping an office switches the active bridge.

private struct OfficeRoute: Hashable { let id: UUID }
private struct FolderRoute: Hashable { let folder: String }
private struct SessionRoute: Hashable { let sessionId: String }
// cmux mirror routes (when the Mac runs cmux): Office → Workspace → Terminal
private struct CmuxWorkspaceRoute: Hashable { let id: String }
private struct CmuxTerminalRoute: Hashable { let id: String; let title: String }
private struct DashboardRoute: Hashable {}

// MARK: - cmux mirror models (decoded from GET /cmux/tree)

struct CmuxTreeResponse: Decodable {
    let available: Bool
    let workspaces: [CmuxWorkspace]
}

struct CmuxWorkspace: Identifiable, Decodable, Equatable {
    let id: String
    let title: String
    let cwd: String?
    let selected: Bool
    let hasUnread: Bool
    let preview: String?
    let terminals: [CmuxTerminal]
}

struct CmuxTerminal: Identifiable, Decodable, Equatable {
    let id: String
    let title: String
    let cwd: String?
    let focused: Bool
    let ready: Bool
}

/// Workspace key for a session: project folder name, falling back to the cwd's
/// last path component, then a placeholder.
fileprivate func workspaceKey(_ s: AgentSession) -> String {
    if !s.folderName.isEmpty { return s.folderName }
    let leaf = (s.cwd as NSString).lastPathComponent
    return leaf.isEmpty ? "(unknown)" : leaf
}

// MARK: - Root: Offices (Macs) — SCREEN 02

struct ConnectionStatusView: View {

    @EnvironmentObject private var relayService: RelayService
    @EnvironmentObject private var sessionManager: WatchSessionManager
    @ObservedObject private var store = ConnectionStore.shared

    @State private var path = NavigationPath()
    @State private var showSettings = false
    @State private var showApprovalQueue = false
    @State private var showNewSession = false
    @State private var renameTarget: SavedConnection?
    @State private var renameText = ""
    @State private var deleteTarget: SavedConnection?

    private var connectedCount: Int {
        (store.activeID != nil || store.connections.isEmpty)
            && relayService.connectionState == .connected ? 1 : 0
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                officesList
            }
            .navigationTitle("오피스")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if relayService.pendingApprovalCount > 0 {
                        Button {
                            showApprovalQueue = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "bell.badge.fill")
                                    .foregroundStyle(Color.claudeAmber)
                                Text("\(relayService.pendingApprovalCount)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.denyRed, in: Capsule())
                            }
                        }
                    }
                }
                if relayService.cmuxAvailable {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showNewSession = true } label: {
                            Image(systemName: "plus.circle")
                                .foregroundStyle(Color.claudeOrange)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            path.append(DashboardRoute())
                        } label: {
                            Image(systemName: "square.grid.2x2")
                                .foregroundStyle(Color.subtleText)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(Color.subtleText)
                    }
                }
            }
            .navigationDestination(for: OfficeRoute.self) { _ in
                WorkspacesView()
            }
            .navigationDestination(for: FolderRoute.self) { route in
                SessionsListView(folder: route.folder)
            }
            .navigationDestination(for: SessionRoute.self) { route in
                SessionDetailView(sessionId: route.sessionId)
            }
            .navigationDestination(for: CmuxWorkspaceRoute.self) { route in
                CmuxTerminalsView(workspaceId: route.id)
            }
            .navigationDestination(for: CmuxTerminalRoute.self) { route in
                CmuxTerminalView(terminalId: route.id, title: route.title)
            }
            .navigationDestination(for: DashboardRoute.self) { _ in
                SessionDashboardView()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(relayService)
        }
        .sheet(isPresented: $showApprovalQueue) {
            ApprovalQueueView().environmentObject(relayService)
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionView().environmentObject(relayService)
        }
        .onChange(of: relayService.pendingApprovalCount) { oldCount, newCount in
            // Auto-present the approval card on ANY screen when a new one arrives
            // (matches the LAN web client's popup UX). Auto-closes when cleared.
            if newCount > oldCount {
                showApprovalQueue = true
            } else if newCount == 0 {
                showApprovalQueue = false
            }
        }
        .alert("오피스 이름 변경", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("이름 (예: office-1)", text: $renameText)
            Button("저장") {
                if let t = renameTarget, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    store.rename(t.id, to: renameText.trimmingCharacters(in: .whitespaces))
                    if t.id == store.activeID { relayService.refreshActiveName() }
                }
                renameTarget = nil
            }
            Button("취소", role: .cancel) { renameTarget = nil }
        }
        .alert("오피스 삭제", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("삭제", role: .destructive) {
                if let t = deleteTarget {
                    if t.id == store.activeID {
                        relayService.forgetActive()
                    } else {
                        store.remove(t.id)
                    }
                }
                deleteTarget = nil
            }
            Button("취소", role: .cancel) { deleteTarget = nil }
        } message: {
            if let t = deleteTarget {
                Text("\(t.name) (\(t.host):\(t.port)) 연결을 삭제할까요?")
            }
        }
    }

    // MARK: Offices list

    @ViewBuilder
    private var officesList: some View {
        ScrollView {
            VStack(spacing: 12) {
                subtitleHeader

                if store.connections.isEmpty {
                    // Legacy pairing with no saved connection — one implicit office.
                    officeRow(
                        name: relayService.machineName ?? "Mac",
                        subtitle: nil,
                        isActive: true,
                        onTap: { path.append(OfficeRoute(id: UUID())) }
                    )
                } else {
                    ForEach(store.connections) { conn in
                        officeRow(
                            name: conn.name,
                            subtitle: "\(conn.host):\(conn.port)",
                            isActive: conn.id == store.activeID,
                            onTap: {
                                if conn.id != store.activeID {
                                    relayService.switchTo(conn)
                                }
                                path.append(OfficeRoute(id: conn.id))
                            }
                        )
                        .contextMenu {
                            Button {
                                renameText = conn.name
                                renameTarget = conn
                            } label: { Label("이름 변경", systemImage: "pencil") }
                            Button(role: .destructive) {
                                deleteTarget = conn
                            } label: { Label("삭제", systemImage: "trash") }
                        }
                    }
                }

                addMacButton
            }
            .padding(16)
        }
    }

    private var subtitleHeader: some View {
        let total = store.connections.isEmpty ? 1 : store.connections.count
        return HStack {
            Text("Mac \(total)대 · \(connectedCount)대 연결됨")
                .font(.system(size: 13))
                .foregroundStyle(Color.subtleText)
            Spacer()
        }
        .padding(.bottom, 2)
    }

    private var addMacButton: some View {
        Button {
            relayService.beginAddMac()
        } label: {
            HStack(spacing: 6) {
                Text("+ 다른 Mac 추가")
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.claudeOrange)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        Color.claudeOrange.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1, dash: [5])
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func officeRow(name: String, subtitle: String?, isActive: Bool, onTap: @escaping () -> Void) -> some View {
        let connected = isActive && relayService.connectionState == .connected
        let connecting = isActive && relayService.connectionState == .connecting
        let degraded = isActive && relayService.connectionState == .degraded
        let sessionCount = isActive ? relayService.sessions.count : nil
        let folderCount = isActive
            ? Set(relayService.sessions.map { workspaceKey($0) }).count
            : nil
        let dotColor: Color = connected
            ? Color.statusGreen
            : ((connecting || degraded) ? Color.claudeAmber : Color.subtleText.opacity(0.5))
        let borderColor: Color = isActive ? Color.claudeOrange.opacity(0.35) : Color.hairline

        return Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.surfaceElevated)
                        .frame(width: 36, height: 36)
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 18))
                        .foregroundStyle(isActive ? Color.claudeOrange : Color.subtleText)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.subtleText)
                            .lineLimit(1)
                    }
                    if isActive, degraded {
                        Text("실시간 끊김 · 재연결 중…")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.claudeAmber)
                    } else if isActive, connected, let sessionCount, let folderCount {
                        Text("워크스페이스 \(folderCount) · 세션 \(sessionCount)")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.subtleText)
                    } else if isActive, connecting {
                        Text("연결 중…")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.claudeAmber)
                    } else {
                        Text("탭하여 연결")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.subtleText)
                    }
                }

                Spacer()

                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.subtleText)
            }
            .padding(14)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Level 2: Workspaces (folders) for the active Mac — SCREEN 03 / 08

private struct WorkspacesView: View {
    @EnvironmentObject private var relayService: RelayService

    /// Sessions grouped by workspace key, order preserved by first appearance.
    private var folders: [(key: String, sessions: [AgentSession])] {
        var order: [String] = []
        var map: [String: [AgentSession]] = [:]
        for s in relayService.sessions {
            let k = workspaceKey(s)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(s)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            if relayService.cmuxAvailable {
                cmuxWorkspaceList
            } else if relayService.sessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        header
                        ForEach(folders, id: \.key) { folder in
                            NavigationLink(value: FolderRoute(folder: folder.key)) {
                                folderRow(folder.key, sessions: folder.sessions)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(relayService.machineName ?? "Workspaces")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if relayService.connectionState == .connected {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 5) {
                        Circle().fill(Color.statusGreen).frame(width: 7, height: 7)
                        Text("연결됨")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.subtleText)
                    }
                }
            } else if relayService.connectionState == .degraded {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 5) {
                        Circle().fill(Color.claudeAmber).frame(width: 7, height: 7)
                        Text("실시간 끊김")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.claudeAmber)
                    }
                }
            }
        }
        .onAppear { relayService.refreshCmuxTree() }
    }

    // MARK: cmux mirror — workspaces list

    private var cmuxWorkspaceList: some View {
        ScrollView {
            VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(relayService.machineName ?? "cmux")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Text("워크스페이스 \(relayService.cmuxWorkspaces.count)")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.subtleText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(relayService.cmuxWorkspaces) { ws in
                    NavigationLink(value: CmuxWorkspaceRoute(id: ws.id)) {
                        cmuxWorkspaceRow(ws)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .task { await relayService.refreshCmuxStatuses() }
    }

    private func cmuxWorkspaceRow(_ ws: CmuxWorkspace) -> some View {
        let approval = Set(relayService.approvalQueue.compactMap { $0.terminalId })
        let status = dashWorkspaceStatus(ws, approval: approval, statuses: relayService.terminalStatuses)
        return HStack(spacing: 12) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 18))
                .foregroundStyle(Color.claudeOrange.opacity(0.9))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(ws.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                if let preview = ws.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.claudeAmber)
                        .lineLimit(1)
                } else {
                    Text("\(ws.terminals.count) sessions")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.subtleText)
                }
            }

            Spacer()
            if status != .idle {
                DashStatusBadge(status: status, showLabel: true)
            }
            if ws.hasUnread {
                Circle().fill(Color.claudeAmber).frame(width: 8, height: 8)
            } else if ws.selected {
                Circle().fill(Color.statusGreen).frame(width: 8, height: 8)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.subtleText.opacity(0.6))
        }
        .padding(14)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(ws.selected ? Color.claudeOrange.opacity(0.35) : Color.hairline, lineWidth: 1)
        )
    }

    private var header: some View {
        let folderCount = folders.count
        let sessionCount = relayService.sessions.count
        return VStack(alignment: .leading, spacing: 4) {
            Text(relayService.machineName ?? "Workspaces")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            Text("워크스페이스 \(folderCount) · 세션 \(sessionCount)")
                .font(.system(size: 13))
                .foregroundStyle(Color.subtleText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    // SCREEN 08 — empty state
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            AppLogo(size: 96)
            Text("세션을 기다리는 중")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            Text("Mac에서 Claude Code 세션을 시작하세요 — 도구 호출과 승인이 여기에 실시간으로 표시됩니다.")
                .font(.system(size: 13))
                .foregroundStyle(Color.subtleText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack(spacing: 6) {
                Circle().fill(Color.statusGreen).frame(width: 7, height: 7)
                Text("\(relayService.machineName ?? "이 Mac")에서 수신 중")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.subtleText)
            }
            Spacer()
            HStack(spacing: 0) {
                Text("아무 프로젝트 폴더에서 ")
                    .foregroundStyle(Color.subtleText)
                Text("claude")
                    .foregroundStyle(Color.claudeOrange)
                Text(" 실행")
                    .foregroundStyle(Color.subtleText)
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.hairline, lineWidth: 1)
            )
            .padding(.bottom, 24)
        }
    }

    private func folderRow(_ name: String, sessions: [AgentSession]) -> some View {
        let running = sessions.contains { $0.activity == .running }
        let waitingApproval = sessions.contains { $0.activity == .waitingApproval }
        let dot: Color = waitingApproval
            ? Color.claudeAmber
            : (running ? Color.statusGreen : Color.subtleText.opacity(0.5))
        let iconTint: Color = (running || waitingApproval) ? Color.claudeOrange : Color.subtleText
        let cwd = sessions.first?.cwd ?? ""

        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.surfaceElevated)
                    .frame(width: 36, height: 36)
                Image(systemName: "folder.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(iconTint)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                if waitingApproval {
                    Text("승인 대기 중")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.claudeAmber)
                } else if !cwd.isEmpty {
                    Text(cwd)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.subtleText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()
            Text("\(sessions.count)")
                .font(.system(size: 13))
                .foregroundStyle(Color.subtleText)
            Circle().fill(dot).frame(width: 8, height: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.subtleText)
        }
        .padding(14)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Level 3: Sessions in a folder — SCREEN 04

// MARK: - cmux mirror: start a new agent session from the phone

private struct NewSessionView: View {
    @EnvironmentObject private var relayService: RelayService
    @Environment(\.dismiss) private var dismiss

    @State private var agent = "claude"
    @State private var cwd = ""
    @State private var name = ""
    @State private var busy = false
    @State private var errorMessage: String?

    // Distinct project dirs from the live mirror, as quick picks.
    private var recentDirs: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for w in relayService.cmuxWorkspaces {
            if let c = w.cwd, !c.isEmpty, seen.insert(c).inserted { out.append(c) }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("에이전트") {
                    Picker("에이전트", selection: $agent) {
                        Text("Claude").tag("claude")
                        Text("Codex").tag("codex")
                    }
                    .pickerStyle(.segmented)
                }
                Section("작업 폴더 (비우면 기본 위치)") {
                    TextField("/path/to/project", text: $cwd)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 13, design: .monospaced))
                    ForEach(recentDirs, id: \.self) { d in
                        Button { cwd = d } label: {
                            HStack {
                                Image(systemName: "folder").foregroundStyle(Color.subtleText)
                                Text(d).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if cwd == d { Image(systemName: "checkmark").foregroundStyle(Color.claudeOrange) }
                            }
                        }
                        .foregroundStyle(Color.textPrimary)
                    }
                }
                Section("이름 (선택)") {
                    TextField("세션 이름", text: $name)
                }
                if let errorMessage {
                    Text(errorMessage).font(.system(size: 13)).foregroundStyle(Color.denyRed)
                }
            }
            .navigationTitle("새 세션 시작")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("시작") { start() }.bold()
                    }
                }
            }
        }
    }

    private func start() {
        busy = true
        errorMessage = nil
        Task {
            let ok = await relayService.newCmuxSession(
                cwd: cwd.trimmingCharacters(in: .whitespaces),
                agent: agent,
                name: name.trimmingCharacters(in: .whitespaces)
            )
            busy = false
            if ok {
                relayService.refreshCmuxTree()
                dismiss()
            } else {
                errorMessage = "세션을 만들지 못했습니다 (경로 확인)"
            }
        }
    }
}

// MARK: - cmux mirror: cross-workspace session dashboard

private enum DashStatus: Int {
    case approval = 0, running = 1, waiting = 2, idle = 3
    // running = green (actively generating), approval = red (blocked on you),
    // waiting = amber (agent idle, awaiting your input), idle = muted gray (shell).
    var color: Color {
        switch self {
        case .approval: return .denyRed
        case .running: return .statusGreen
        case .waiting: return .claudeAmber
        case .idle: return .subtleText
        }
    }
    var label: String {
        switch self {
        case .approval: return "승인 필요"
        case .running: return "생성 중"
        case .waiting: return "입력 대기"
        case .idle: return "유휴"
        }
    }
}

// Status priority: a pending approval > actively running (detected server-side
// from the live screen — "esc to interrupt" / OMC "thinking") > idle. The old
// title-glyph guess was unreliable (idle and working both show ✳), so running
// now comes from relayService.runningTerminalIds.
private func dashTerminalStatus(_ t: CmuxTerminal, approval: Set<String>, statuses: [String: String]) -> DashStatus {
    if approval.contains(t.id) { return .approval }
    switch statuses[t.id] {
    case "running": return .running
    case "waiting": return .waiting
    default: return .idle
    }
}

private func dashWorkspaceStatus(_ ws: CmuxWorkspace, approval: Set<String>, statuses: [String: String]) -> DashStatus {
    let all = ws.terminals.map { dashTerminalStatus($0, approval: approval, statuses: statuses) }
    if all.contains(.approval) { return .approval }
    if all.contains(.running) { return .running }
    if all.contains(.waiting) { return .waiting }
    return .idle
}

/// Status pill (colored dot + label) reused across dashboard, project, and
/// session views. Running pulses + gets a tinted capsule so it's unmistakable;
/// idle stays muted.
private struct DashStatusBadge: View {
    let status: DashStatus
    var showLabel = true
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.color)
                .frame(width: status == .idle ? 7 : 9, height: status == .idle ? 7 : 9)
                .scaleEffect(status == .running && pulse ? 1.35 : 1.0)
                .opacity(status == .running && pulse ? 0.55 : 1.0)
                .animation(status == .running
                    ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                    : .default, value: pulse)
            if showLabel {
                Text(status.label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(status.color)
            }
        }
        .padding(.horizontal, status == .idle ? 0 : 7)
        .padding(.vertical, status == .idle ? 0 : 3)
        .background(
            status == .idle ? Color.clear : status.color.opacity(0.14),
            in: Capsule()
        )
        .onAppear { pulse = true }
    }
}

private func isImageName(_ name: String) -> Bool {
    let ext = (name as NSString).pathExtension.lowercased()
    return ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "tiff", "tif", "ico"].contains(ext)
}

private func isVideoName(_ name: String) -> Bool {
    let ext = (name as NSString).pathExtension.lowercased()
    return ["mp4", "m4v", "mov", "webm", "m3u8"].contains(ext)
}

private func isHTMLName(_ name: String) -> Bool {
    let ext = (name as NSString).pathExtension.lowercased()
    return ext == "html" || ext == "htm"
}

private func isMarkdownName(_ name: String) -> Bool {
    let ext = (name as NSString).pathExtension.lowercased()
    return ext == "md" || ext == "markdown"
}

/// Renders HTML in a WKWebView — either an inline string or a URL. URL mode
/// streams the FULL file from the bridge (inline content is capped at 512KB by
/// /cmux/file, which blanks out big HTML).
private struct WebPreview: UIViewRepresentable {
    enum Source: Equatable { case html(String), url(URL) }
    let source: Source

    init(html: String) { self.source = .html(html) }
    init(url: URL) { self.source = .url(url) }

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.scrollView.backgroundColor = .black
        return wv
    }
    func updateUIView(_ wv: WKWebView, context: Context) {
        guard context.coordinator.last != source else { return }
        context.coordinator.last = source
        switch source {
        case .html(let s): wv.loadHTMLString(s, baseURL: nil)
        case .url(let u): wv.load(URLRequest(url: u))
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var last: Source? }
}

/// Inline thumbnail for an image entry in a directory listing — fetches the image
/// lazily (only visible rows load) and shows a small preview right in the list.
private struct DirThumb: View {
    let terminalId: String
    let path: String
    @EnvironmentObject private var relayService: RelayService
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: failed ? "photo" : "photo")
                    .foregroundStyle(Color.subtleText)
                    .opacity(image == nil ? 0.5 : 1)
            }
        }
        .frame(width: 40, height: 40)
        .background(Color.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task { await load() }
    }

    private func load() async {
        guard image == nil, !failed else { return }
        if case .ok(let node) = await relayService.cmuxFile(terminalId, path: path),
           node.kind == .image, let data = node.imageData, let ui = UIImage(data: data) {
            image = ui
        } else {
            failed = true
        }
    }
}

/// Flat, cross-workspace view of every terminal with a status badge, so the user
/// can spot what needs attention. "주목 필요만" filters to terminals awaiting approval.
private struct SessionDashboardView: View {
    @EnvironmentObject private var relayService: RelayService
    @State private var attentionOnly = false
    private let statusTimer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    private struct Row: Identifiable {
        let id: String
        let title: String
        let workspace: String
        let status: DashStatus
    }

    private var rows: [Row] {
        let approval = Set(relayService.approvalQueue.compactMap { $0.terminalId })
        let statuses = relayService.terminalStatuses
        var out: [Row] = []
        for ws in relayService.cmuxWorkspaces {
            for t in ws.terminals {
                out.append(Row(id: t.id, title: t.title, workspace: ws.title,
                               status: dashTerminalStatus(t, approval: approval, statuses: statuses)))
            }
        }
        out.sort { $0.status.rawValue != $1.status.rawValue ? $0.status.rawValue < $1.status.rawValue : $0.title < $1.title }
        // "주목 필요만" = needs you: blocked on approval or waiting for your input.
        return attentionOnly ? out.filter { $0.status == .approval || $0.status == .waiting } : out
    }

    private func count(_ s: DashStatus) -> Int {
        let approval = Set(relayService.approvalQueue.compactMap { $0.terminalId })
        let statuses = relayService.terminalStatuses
        return relayService.cmuxWorkspaces.flatMap(\.terminals).filter {
            dashTerminalStatus($0, approval: approval, statuses: statuses) == s
        }.count
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                // Summary counts
                HStack(spacing: 12) {
                    if count(.approval) > 0 { summaryChip(.approval, count(.approval)) }
                    summaryChip(.running, count(.running))
                    summaryChip(.waiting, count(.waiting))
                    summaryChip(.idle, count(.idle))
                    Spacer()
                    Toggle("주목 필요만", isOn: $attentionOnly)
                        .toggleStyle(.button)
                        .font(.system(size: 12, weight: .semibold))
                        .tint(Color.claudeOrange)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)

                List {
                    if rows.isEmpty {
                        Text(attentionOnly ? "주목할 세션이 없습니다" : "세션이 없습니다")
                            .foregroundStyle(Color.subtleText)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(rows) { row in
                        NavigationLink(value: CmuxTerminalRoute(id: row.id, title: row.title)) {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color.textPrimary)
                                        .lineLimit(1)
                                    Text(row.workspace)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.subtleText)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                DashStatusBadge(status: row.status)
                            }
                        }
                        .listRowBackground(
                            row.status == .running ? Color.statusGreen.opacity(0.10)
                            : row.status == .waiting ? Color.claudeAmber.opacity(0.06)
                            : Color.cardBackground)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("세션 대시보드")
        .navigationBarTitleDisplayMode(.inline)
        .task { await relayService.refreshCmuxStatuses() }
        .onReceive(statusTimer) { _ in Task { await relayService.refreshCmuxStatuses() } }
    }

    private func summaryChip(_ status: DashStatus, _ n: Int) -> some View {
        HStack(spacing: 5) {
            Circle().fill(status.color).frame(width: 8, height: 8)
            Text("\(n)").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.textPrimary)
            Text(status.label).font(.system(size: 11)).foregroundStyle(Color.subtleText)
        }
    }
}

// MARK: - cmux mirror: terminals in a workspace

private struct CmuxTerminalsView: View {
    let workspaceId: String
    @EnvironmentObject private var relayService: RelayService

    private var workspace: CmuxWorkspace? {
        relayService.cmuxWorkspaces.first { $0.id == workspaceId }
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            if let ws = workspace {
                ScrollView {
                    VStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ws.title)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(2)
                            Text("\(ws.terminals.count) sessions")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.subtleText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        ForEach(ws.terminals) { t in
                            NavigationLink(value: CmuxTerminalRoute(id: t.id, title: t.title)) {
                                terminalRow(t)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            } else {
                Text("워크스페이스를 찾을 수 없습니다.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.subtleText)
            }
        }
        .navigationTitle(workspace?.title ?? "Workspace")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { relayService.refreshCmuxTree() }
        .task { await relayService.refreshCmuxStatuses() }
    }

    private func terminalRow(_ t: CmuxTerminal) -> some View {
        let approval = Set(relayService.approvalQueue.compactMap { $0.terminalId })
        let status = dashTerminalStatus(t, approval: approval, statuses: relayService.terminalStatuses)
        return HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 15))
                .foregroundStyle(t.focused ? Color.claudeOrange : Color.subtleText)
                .frame(width: 30, height: 30)
                .background(Color.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(t.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                if let cwd = t.cwd, !cwd.isEmpty {
                    Text(cwd)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.subtleText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()
            DashStatusBadge(status: status, showLabel: status != .idle)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.subtleText.opacity(0.6))
        }
        .padding(14)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - cmux mirror: live terminal screen + prompt input

private struct CmuxTerminalView: View {
    let terminalId: String
    let title: String
    @EnvironmentObject private var relayService: RelayService

    @State private var screen: String = ""
    @State private var styledScreen: CmuxStyledScreen? = nil
    /// Cached colored render — rebuilt only when the screen changes (not on every
    /// keystroke), so typing in the prompt stays snappy.
    @State private var rendered: AttributedString? = nil
    /// NSAttributedString variant for the selectable UITextView (native text
    /// selection + copy).
    @State private var renderedNS: NSAttributedString? = nil
    @State private var promptText: String = ""
    @State private var sending = false
    @State private var browseTarget: BrowseTarget? = nil
    @State private var photoItem: PhotosPickerItem? = nil
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showImageSource = false
    @State private var uploadingImage = false
    @State private var uploadError: String? = nil
    @State private var showSnippets = false
    @State private var showModelSheet = false
    @State private var codexDriving = false
    @State private var codexStatus = ""
    @FocusState private var inputFocused: Bool
    private let pollTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            VStack(spacing: 10) {
                terminalCard
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                specialKeyBar
                inputBar
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }

            if showModelSheet {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture { if !codexDriving { closeModelSheet() } }
                    .transition(.opacity)

                ModelEffortPanel(
                    initialAgent: detectAgent(from: screen),
                    liveScreen: screen,
                    driving: codexDriving,
                    statusText: codexStatus,
                    onClaudeCommand: { cmd in
                        closeModelSheet()
                        relayService.sendCmux(terminalId: terminalId, text: cmd)
                        Task { try? await Task.sleep(nanoseconds: 600_000_000); await refresh() }
                    },
                    onCodexSelect: { model, effort in driveCodex(model: model, effort: effort) },
                    onKey: { key in
                        Task {
                            await relayService.sendCmuxKey(terminalId: terminalId, key: key)
                            try? await Task.sleep(nanoseconds: 250_000_000); await refresh()
                        }
                    },
                    onDigit: { digit in
                        Task {
                            await relayService.sendCmuxText(terminalId: terminalId, text: digit, submit: false)
                            try? await Task.sleep(nanoseconds: 250_000_000); await refresh()
                        }
                    },
                    onDismiss: { closeModelSheet() }
                )
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: showModelSheet)
        // Tapping a file path in the terminal opens it (scoped to the cwd).
        .environment(\.openURL, OpenURLAction { url in
            handleTerminalURL(url)
            return .handled
        })
        .sheet(item: $browseTarget) { t in
            CmuxBrowser(terminalId: terminalId, rootPath: t.path)
                .environmentObject(relayService)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { showModelSheet = true }
                } label: {
                    Image(systemName: "cpu").foregroundStyle(Color.claudeOrange)
                }
            }
        }
        .task(id: terminalId) { await refresh() }
        .onReceive(pollTimer) { _ in Task { await refresh() } }
        .onChange(of: relayService.cmuxScreenTick) { _, _ in Task { await refresh() } }
    }

    private func refresh() async {
        if let s = await relayService.cmuxScreen(terminalId) {
            screen = s.text
            styledScreen = s.styled
            if let st = s.styled, !st.lines.isEmpty {
                rendered = Self.attributedScreen(st)
                renderedNS = Self.terminalNSAttributed(st)
            } else {
                rendered = nil
                renderedNS = nil
            }
        }
    }


    private func closeModelSheet() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { showModelSheet = false }
    }

    // Best-effort guess of the agent running in this terminal, from its live
    // screen. Only a seed for the Claude/Codex toggle — the user can flip it.
    // (Avoids "claude" matching the cmux-iphone cwd by requiring strong markers.)
    private func detectAgent(from screen: String) -> String {
        let s = screen.lowercased()
        if s.contains("openai codex") || s.contains("codex cli") || s.contains("gpt-5") { return "codex" }
        if s.contains("claude code") || s.contains("anthropic") { return "claude" }
        return "claude"
    }

    // MARK: codex /model picker driver
    //
    // codex's "/model" is an interactive popup (no inline args), so we open it,
    // read the rendered rows, and pick by the on-screen digit (position-proof).
    // If a row can't be parsed we leave the popup open for the manual keypad —
    // never blind-firing a guess into a live session.
    private func driveCodex(model: String, effort: String?) {
        guard !codexDriving else { return }
        codexDriving = true
        codexStatus = "모델 선택 중…"
        Task {
            defer { codexDriving = false }
            let tid = terminalId

            // 1) open the picker
            await relayService.sendCmuxText(terminalId: tid, text: "/model", submit: true)
            try? await Task.sleep(nanoseconds: 750_000_000)
            await refresh()
            var scr = (await relayService.cmuxScreen(tid))?.text ?? ""

            // 2) expand "All models" first if our concrete model isn't listed yet
            if codexDigit(for: model, in: scr) == nil,
               let allDigit = codexDigit(for: "all models", in: scr) {
                await relayService.sendCmuxText(terminalId: tid, text: allDigit, submit: false)
                try? await Task.sleep(nanoseconds: 550_000_000)
                await refresh()
                scr = (await relayService.cmuxScreen(tid))?.text ?? ""
            }

            // 3) pick the model row by its on-screen digit
            guard let modelDigit = codexDigit(for: model, in: scr) else {
                codexStatus = "자동 실패 — 아래 키패드로 직접 선택하세요"
                return   // leave the popup open; manual keypad takes over
            }
            await relayService.sendCmuxText(terminalId: tid, text: modelDigit, submit: false)
            try? await Task.sleep(nanoseconds: 750_000_000)
            await refresh()
            scr = (await relayService.cmuxScreen(tid))?.text ?? ""

            // 4) reasoning-effort stage — only if the popup actually advanced to it
            if let effort, scr.lowercased().contains("reasoning"),
               let effortDigit = codexDigit(for: effort, in: scr, wholeWord: true) {
                await relayService.sendCmuxText(terminalId: tid, text: effortDigit, submit: false)
                try? await Task.sleep(nanoseconds: 450_000_000)
                await refresh()
            }

            codexStatus = "완료"
            try? await Task.sleep(nanoseconds: 600_000_000)
            closeModelSheet()
            await refresh()
        }
    }

    // Find the leading row-number for the picker row matching `label`. Scans only
    // the text *before* the label so "gpt-5.5" never returns the "5" in its name;
    // stops at a word boundary so it won't grab a digit from an earlier token.
    // `wholeWord` rejects substring hits (so "high" won't match the "xhigh" row).
    private func codexDigit(for label: String, in screen: String, wholeWord: Bool = false) -> String? {
        let needle = label.lowercased()
        for raw in screen.split(separator: "\n") {
            let line = String(raw).lowercased()
            guard let r = line.range(of: needle) else { continue }
            if wholeWord {
                let beforeOK = r.lowerBound == line.startIndex || !line[line.index(before: r.lowerBound)].isLetter
                let afterOK = r.upperBound == line.endIndex || !line[r.upperBound].isLetter
                if !(beforeOK && afterOK) { continue }
            }
            for ch in line[..<r.lowerBound].reversed() {
                if let d = ch.wholeNumberValue, (1...9).contains(d) { return String(d) }
                if ch.isLetter { break }
            }
        }
        return nil
    }

    // MARK: terminal card (chrome + screen)

    private var terminalCard: some View {
        VStack(spacing: 0) {
            // window header — traffic lights + title
            HStack(spacing: 6) {
                Circle().fill(Color.denyRed.opacity(0.85)).frame(width: 10, height: 10)
                Circle().fill(Color.claudeAmber.opacity(0.85)).frame(width: 10, height: 10)
                Circle().fill(Color.statusGreen.opacity(0.85)).frame(width: 10, height: 10)
                Text(title)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.subtleText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 6)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.surfaceElevated)

            Rectangle().fill(Color.hairline).frame(height: 1)

            if let renderedNS {
                // Native selectable terminal: drag-select any range → Copy.
                SelectableTerminalText(
                    attributed: renderedNS,
                    background: UIColor(hexString: styledScreen?.bg ?? "1E1E1E") ?? .black,
                    onLink: { handleTerminalURL($0) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        terminalScreen
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(12)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .onChange(of: screen) { _, _ in
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(terminalBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.hairline, lineWidth: 1))
    }

    // Terminal screen background — cmux's real default bg when known, so #666666
    // gray (faint) text reads the same as it does in your real terminal.
    private var terminalBackground: Color {
        if let bg = styledScreen?.bg { return Color(hex: bg) }
        return Color.cardBackground
    }

    // Terminal content: cmux's real per-run colors when a styled screen is
    // available, else a single-color monospace fallback.
    @ViewBuilder
    private var terminalScreen: some View {
        if let rendered {
            Text(rendered)
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(2)
        } else {
            Text(screen.isEmpty ? "…" : screen)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.textPrimary)
        }
    }

    // Build a colored AttributedString from the styled screen. Each run takes its
    // foreground/attributes from the palette; inverse swaps fg/bg, faint dims.
    private static func attributedScreen(_ styled: CmuxStyledScreen) -> AttributedString {
        var out = AttributedString()
        let defaultFg = Color(hex: styled.fg)
        let lineCount = styled.lines.count
        for (i, line) in styled.lines.enumerated() {
            for run in line {
                var piece = AttributedString(run.text)
                let st = styled.style(run.styleId)
                var font = Font.system(size: 12, design: .monospaced)
                if st?.bold == true { font = font.bold() }
                if st?.italic == true { font = font.italic() }
                piece.font = font

                let inverse = st?.inverse == true
                let fgHex = inverse ? st?.bg : st?.fg
                var fg = fgHex.map { Color(hex: $0) } ?? defaultFg
                if st?.faint == true { fg = fg.opacity(0.6) }
                piece.foregroundColor = fg

                if inverse {
                    piece.backgroundColor = (st?.fg).map { Color(hex: $0) } ?? defaultFg
                } else if let bg = st?.bg, bg != styled.bg {
                    piece.backgroundColor = Color(hex: bg)
                }
                if st?.underline == true { piece.underlineStyle = .single }
                if st?.strike == true { piece.strikethroughStyle = .single }
                linkify(&piece, in: run.text)
                out.append(piece)
            }
            if i < lineCount - 1 { out.append(AttributedString("\n")) }
        }
        return out
    }

    // http(s) URLs printed by agents (server URLs, docs, etc.).
    private static let urlRegex = #/https?:\/\/[^\s)\]}>"'`]+/#
    // File-path-ish tokens — must contain a slash so plain words aren't linkified.
    // Matches: src/foo/bar.tsx · ./scripts/x.sh · cinepilot/license/badge.tsx
    private static let pathRegex = #/(?:\.{0,2}/)?(?:[\w.@~+-]+/)+[\w.@~+-]+(?:\.[A-Za-z][\w-]{0,9})?/#

    // Linkify a run: web URLs (blue, open in browser — localhost is rewritten to
    // the Mac's reachable host at tap time) and file paths (orange, cmuxfile://).
    // URLs win over paths on overlap so "app/main.js" inside a URL isn't relinked.
    private static func linkify(_ piece: inout AttributedString, in text: String) {
        var urlRanges: [Range<String.Index>] = []
        for match in text.matches(of: urlRegex) {
            var s = String(text[match.range])
            var trimmed = 0
            while let last = s.last, ".,;:!?)]}>\"'".contains(last) { s.removeLast(); trimmed += 1 }
            guard !s.isEmpty, let url = URL(string: s) else { continue }
            let upper = text.index(match.range.upperBound, offsetBy: -trimmed)
            let r = match.range.lowerBound..<upper
            urlRanges.append(r)
            applyLink(&piece, text: text, range: r, url: url, color: Color(hex: "5AA9FF"))
        }
        for match in text.matches(of: pathRegex) {
            if urlRanges.contains(where: { $0.overlaps(match.range) }) { continue }
            let raw = String(text[match.range])
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=?+#")
            guard let enc = raw.addingPercentEncoding(withAllowedCharacters: allowed),
                  let url = URL(string: "cmuxfile://f?p=\(enc)") else { continue }
            applyLink(&piece, text: text, range: match.range, url: url, color: .claudeOrange)
        }
    }

    private static func applyLink(_ piece: inout AttributedString, text: String,
                                  range: Range<String.Index>, url: URL, color: Color) {
        let lo = text.distance(from: text.startIndex, to: range.lowerBound)
        let hi = text.distance(from: text.startIndex, to: range.upperBound)
        guard lo < hi else { return }
        let aLo = piece.index(piece.startIndex, offsetByCharacters: lo)
        let aHi = piece.index(piece.startIndex, offsetByCharacters: hi)
        piece[aLo..<aHi].link = url
        piece[aLo..<aHi].underlineStyle = .single
        piece[aLo..<aHi].foregroundColor = color
    }

    // NSAttributedString variant (for the selectable UITextView): same colors +
    // links as attributedScreen. Long paths/URLs that soft-wrap across rows
    // (styled.wraps) are re-joined for linkification, so tapping any visible
    // fragment opens the FULL path — not the truncated per-row piece.
    private static func terminalNSAttributed(_ styled: CmuxStyledScreen) -> NSAttributedString {
        let size: CGFloat = 12
        let defaultFg = UIColor(hexString: styled.fg) ?? .white

        // 1) Per-line attributed strings (styles only; links applied per group).
        var lineNS: [NSMutableAttributedString] = []
        for line in styled.lines {
            let ln = NSMutableAttributedString()
            for run in line {
                let st = styled.style(run.styleId)
                let font = UIFont.monospacedSystemFont(ofSize: size, weight: st?.bold == true ? .bold : .regular)
                let inverse = st?.inverse == true
                let fgHex = inverse ? st?.bg : st?.fg
                var fg = fgHex.flatMap { UIColor(hexString: $0) } ?? defaultFg
                if st?.faint == true { fg = fg.withAlphaComponent(0.6) }
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
                if inverse, let bg = (st?.fg).flatMap({ UIColor(hexString: $0) }) {
                    attrs[.backgroundColor] = bg
                } else if let bgHex = st?.bg, bgHex != styled.bg, let bg = UIColor(hexString: bgHex) {
                    attrs[.backgroundColor] = bg
                }
                if st?.underline == true { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if st?.strike == true { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                ln.append(NSAttributedString(string: run.text, attributes: attrs))
            }
            lineNS.append(ln)
        }

        // 2) Group soft-wrapped rows and linkify each group's JOINED text.
        var i = 0
        while i < lineNS.count {
            var end = i
            while end < lineNS.count - 1, styled.wraps.indices.contains(end), styled.wraps[end] { end += 1 }
            linkifyGroup(lineNS, from: i, to: end)
            i = end + 1
        }

        // 3) Join with newlines.
        let out = NSMutableAttributedString()
        for (idx, ln) in lineNS.enumerated() {
            out.append(ln)
            if idx < lineNS.count - 1 { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }

    // Linkify across a wrap-group: regex runs on the concatenated text (so a path
    // split over rows matches whole); the link URL carries the FULL match while
    // the visual attributes land on each row's own sub-range.
    private static func linkifyGroup(_ lines: [NSMutableAttributedString], from: Int, to: Int) {
        let texts = (from...to).map { lines[$0].string }
        let joined = texts.joined()
        var offsets: [Int] = []
        var acc = 0
        for t in texts { offsets.append(acc); acc += (t as NSString).length }

        func apply(_ range: NSRange, url: URL, color: UIColor) {
            for (k, t) in texts.enumerated() {
                let lineRange = NSRange(location: offsets[k], length: (t as NSString).length)
                let inter = NSIntersectionRange(range, lineRange)
                guard inter.length > 0 else { continue }
                let local = NSRange(location: inter.location - offsets[k], length: inter.length)
                guard local.location + local.length <= lines[from + k].length else { continue }
                lines[from + k].addAttributes([.link: url,
                                               .underlineStyle: NSUnderlineStyle.single.rawValue,
                                               .foregroundColor: color], range: local)
            }
        }

        var urlNSRanges: [NSRange] = []
        for match in joined.matches(of: urlRegex) {
            var s = String(joined[match.range])
            var trimmed = 0
            while let last = s.last, ".,;:!?)]}>\"'".contains(last) { s.removeLast(); trimmed += 1 }
            guard !s.isEmpty, let url = URL(string: s) else { continue }
            let upper = joined.index(match.range.upperBound, offsetBy: -trimmed)
            let ns = NSRange(match.range.lowerBound..<upper, in: joined)
            guard ns.length > 0 else { continue }
            urlNSRanges.append(ns)
            apply(ns, url: url, color: UIColor(red: 0.35, green: 0.66, blue: 1, alpha: 1))
        }
        for match in joined.matches(of: pathRegex) {
            let ns = NSRange(match.range, in: joined)
            if urlNSRanges.contains(where: { NSIntersectionRange($0, ns).length > 0 }) { continue }
            let raw = String(joined[match.range])
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=?+#")
            guard let enc = raw.addingPercentEncoding(withAllowedCharacters: allowed),
                  let url = URL(string: "cmuxfile://f?p=\(enc)") else { continue }
            apply(ns, url: url, color: UIColor(red: 0.93, green: 0.49, blue: 0.22, alpha: 1))
        }
    }

    // Quick special-key bar — interrupt a running agent (취소 = Ctrl-C), Esc, Tab,
    // arrows, Enter. Sends raw key sequences straight to the terminal.
    private var specialKeyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                keyButton("취소 ⌃C", key: "ctrl-c", prominent: true)
                keyButton("Esc", key: "escape")
                keyButton("Tab", key: "tab")
                keyButton("↑", key: "up")
                keyButton("↓", key: "down")
                keyButton("←", key: "left")
                keyButton("→", key: "right")
                keyButton("⏎", key: "enter")
            }
            .padding(.horizontal, 12)
        }
    }

    private func keyButton(_ label: String, key: String, prominent: Bool = false) -> some View {
        Button { sendKey(key) } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(prominent ? .white : Color.textPrimary)
                .frame(minWidth: 30)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(prominent ? Color.denyRed : Color.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.hairline, lineWidth: 1))
        }
    }

    private func sendKey(_ key: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            await relayService.sendCmuxKey(terminalId: terminalId, key: key)
            try? await Task.sleep(nanoseconds: 200_000_000)
            await refresh()
        }
    }

    // Route a tapped terminal link: cmuxfile → file/dir browser; localhost http →
    // bridge proxy; other http(s) → the browser.
    private func handleTerminalURL(_ url: URL) {
        if url.scheme == "cmuxfile" {
            let p = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "p" })?.value
            if let p, !p.isEmpty { browseTarget = BrowseTarget(path: p) }
        } else if url.scheme == "http" || url.scheme == "https" {
            if isLocalhost(url) { openViaProxy(url) }
            else { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
        }
    }

    private func isLocalhost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"].contains(host)
    }

    // Open a localhost dev URL via a bridge-side proxy: ask the bridge to forward
    // the port, then open http://<bridgeHost>:<proxyPort><path> in the browser.
    // Falls back to a plain host rewrite if the proxy can't be created.
    private func openViaProxy(_ url: URL) {
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        Task {
            if let proxyPort = await relayService.openProxy(port: port),
               let bridgeHost = relayService.bridgeHost,
               var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                comps.host = bridgeHost
                comps.port = proxyPort
                if let out = comps.url {
                    UIApplication.shared.open(out, options: [:], completionHandler: nil)
                    return
                }
            }
            if let rewritten = rewriteLocalhost(url) {
                UIApplication.shared.open(rewritten, options: [:], completionHandler: nil)
            }
        }
    }

    // Fallback: swap the host for the Mac's bridge host (Tailscale/LAN), no proxy.
    private func rewriteLocalhost(_ url: URL) -> URL? {
        guard isLocalhost(url),
              let bridgeHost = relayService.bridgeHost,
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        comps.host = bridgeHost
        return comps.url
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            // Snippets — frequently-used commands + directory jumps.
            Button { showSnippets = true } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.claudeOrange)
                    .frame(width: 34, height: 38)
            }
            // Attach a photo/screenshot → uploads to cwd, inserts the path.
            Button { showImageSource = true } label: {
                Image(systemName: uploadingImage ? "ellipsis" : "photo")
                    .font(.system(size: 18))
                    .foregroundStyle(uploadingImage ? Color.subtleText : Color.claudeOrange)
                    .frame(width: 34, height: 38)
            }
            .disabled(uploadingImage)

            TextField("프롬프트 입력…", text: $promptText, axis: .vertical)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Color.textPrimary)
                .tint(Color.claudeOrange)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.hairline, lineWidth: 1))
                .focused($inputFocused)

            Button { send() } label: {
                Image(systemName: sending ? "ellipsis" : "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending
                                ? Color.subtleText.opacity(0.4) : Color.claudeOrange)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
        }
        .confirmationDialog("이미지 첨부", isPresented: $showImageSource, titleVisibility: .visible) {
            Button("사진 보관함") { showPhotoPicker = true }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("카메라 촬영") { showCamera = true }
            }
            Button("취소", role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in uploadImage(img) }.ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    uploadImage(img)
                }
                photoItem = nil
            }
        }
        .alert("업로드 오류", isPresented: Binding(
            get: { uploadError != nil },
            set: { if !$0 { uploadError = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: { Text(uploadError ?? "") }
        .sheet(isPresented: $showSnippets) {
            SnippetSheet(
                dirs: dirSnippets,
                onInsert: { insertSnippet($0) },
                onSend: { sendSnippet($0) }
            )
        }
    }

    // Every distinct path in the current cmux mirror → a "cd <path>" snippet.
    private var dirSnippets: [PromptSnippet] {
        var seen = Set<String>()
        var out: [PromptSnippet] = []
        for w in relayService.cmuxWorkspaces {
            if let c = w.cwd, !c.isEmpty, seen.insert(c).inserted {
                out.append(PromptSnippet(label: w.title, text: "cd \(c)"))
            }
            for t in w.terminals {
                if let c = t.cwd, !c.isEmpty, seen.insert(c).inserted {
                    out.append(PromptSnippet(label: t.title, text: "cd \(c)"))
                }
            }
        }
        return out
    }

    private func insertSnippet(_ text: String) {
        promptText = promptText.isEmpty ? text : promptText + " " + text
        inputFocused = true
    }

    private func sendSnippet(_ text: String) {
        relayService.sendCmux(terminalId: terminalId, text: text)
        Task { try? await Task.sleep(nanoseconds: 400_000_000); await refresh() }
    }

    // Compress + downscale an image and upload it; on success insert the saved
    // path into the prompt so the user can add context and send it to the agent.
    private func uploadImage(_ image: UIImage) {
        guard !uploadingImage, let data = Self.jpegForUpload(image) else { return }
        uploadingImage = true
        Task {
            let result = await relayService.cmuxUpload(terminalId, data: data, ext: "jpg")
            uploadingImage = false
            switch result {
            case .ok(_, let rel):
                let prefix = promptText.isEmpty ? "" : promptText + " "
                promptText = prefix + rel + " "
                inputFocused = true
            case .failed(let msg):
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                uploadError = msg
            }
        }
    }

    // JPEG-encode (downscaled to <= maxDimension) to keep uploads small + readable.
    private static func jpegForUpload(_ image: UIImage, maxDimension: CGFloat = 2048) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let factor = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: size.width * factor, height: size.height * factor)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: 0.85)
    }

    // Send the prompt to the terminal (the screen is expected to keep changing).
    // Transactional: clear the input only after the bridge accepts it.
    private func send() {
        let t = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !sending else { return }
        sending = true
        inputFocused = false
        Task {
            let ok = await relayService.sendCmuxPrompt(terminalId: terminalId, text: t)
            sending = false
            if ok {
                promptText = ""
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            await refresh()
        }
    }
}

/// Identifies a tapped path to browse (file or directory).
private struct BrowseTarget: Identifiable {
    let id = UUID()
    let path: String
}

/// File/directory browser presented when a terminal path is tapped. Wraps a
/// NavigationStack so directories push deeper and files show their content.
private struct CmuxBrowser: View {
    let terminalId: String
    let rootPath: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CmuxNodeScreen(terminalId: terminalId, path: rootPath)
                .navigationDestination(for: String.self) { p in
                    CmuxNodeScreen(terminalId: terminalId, path: p)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("닫기") { dismiss() }
                    }
                }
        }
    }
}

/// Fetches one node (file or directory) and renders it: text content for files,
/// a tappable listing for directories. Each row navigates by relative path.
private struct CmuxNodeScreen: View {
    let terminalId: String
    let path: String
    @EnvironmentObject private var relayService: RelayService

    @State private var node: CmuxNode? = nil
    @State private var errorMessage: String? = nil
    @State private var loading = true
    @State private var showSource = false

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.subtleText)
                    Text(errorMessage)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.textPrimary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if let node {
                switch node.kind {
                case .directory: directoryList(node)
                case .file: fileContent(node)
                case .image: imageContent(node)
                case .video: videoContent(node)
                }
            }
        }
        .background(Color.appBackground)
        .navigationTitle((path as NSString).lastPathComponent.isEmpty ? "/" : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: path) { await load() }
    }

    @ViewBuilder
    private func directoryList(_ node: CmuxNode) -> some View {
        List {
            if node.entries.isEmpty {
                Text("(빈 폴더)").foregroundStyle(Color.subtleText)
            }
            ForEach(node.entries) { entry in
                NavigationLink(value: entry.path) {
                    HStack(spacing: 10) {
                        if !entry.isDir && isImageName(entry.name) {
                            DirThumb(terminalId: terminalId, path: entry.path)
                        } else {
                            Image(systemName: entry.isDir ? "folder.fill"
                                  : (isVideoName(entry.name) ? "film" : "doc.text"))
                                .foregroundStyle(entry.isDir ? Color.claudeAmber
                                                 : (isVideoName(entry.name) ? Color.claudeOrange : Color.subtleText))
                                .frame(width: 28)
                        }
                        Text(entry.name)
                            .font(.system(size: 14, design: entry.isDir ? .default : .monospaced))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            if node.truncated {
                Text("…일부만 표시 (항목이 많음)")
                    .font(.system(size: 11)).foregroundStyle(Color.claudeAmber)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func fileContent(_ node: CmuxNode) -> some View {
        if (isHTMLName(node.name) || isMarkdownName(node.name)) && !showSource {
            // HTML: stream the FULL file from the bridge (inline content is capped
            // at 512KB and truncated HTML blanks out). MD: bridge-rendered page.
            Group {
                if isMarkdownName(node.name), let u = relayService.mdviewURL(terminalId, path: node.path) {
                    WebPreview(url: u)
                } else if isHTMLName(node.name), let u = relayService.mediaURL(terminalId, path: node.path) {
                    WebPreview(url: u)
                } else {
                    WebPreview(html: node.content)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Spacer()
                    Button("소스 보기") { showSource = true }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.claudeOrange)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.surfaceElevated)
            }
        } else {
            ScrollView([.vertical, .horizontal]) {
                Text(node.content.isEmpty ? "(빈 파일)" : node.content)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    if node.truncated {
                        Text("일부만 표시 (큰 파일)")
                            .font(.system(size: 11)).foregroundStyle(Color.claudeAmber)
                    }
                    Spacer()
                    if isHTMLName(node.name) || isMarkdownName(node.name) {
                        Button("미리보기") { showSource = false }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.claudeOrange)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.surfaceElevated)
            }
        }
    }

    @ViewBuilder
    private func imageContent(_ node: CmuxNode) -> some View {
        if let data = node.imageData, let ui = UIImage(data: data) {
            ZoomableImage(image: ui)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "photo")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.subtleText)
                Text(node.truncated ? "이미지가 너무 큽니다 (8MB 초과)" : "이미지를 표시할 수 없습니다")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    @ViewBuilder
    private func videoContent(_ node: CmuxNode) -> some View {
        if let url = relayService.mediaURL(terminalId, path: node.path) {
            VideoStreamView(url: url)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "film")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.subtleText)
                Text("영상을 재생할 수 없습니다")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textPrimary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    private func load() async {
        loading = true
        errorMessage = nil
        switch await relayService.cmuxFile(terminalId, path: path) {
        case .ok(let n): node = n
        case .failed(let msg): errorMessage = msg
        }
        loading = false
    }
}

private extension UIColor {
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        switch s.count {
        case 6:
            r = CGFloat((v >> 16) & 0xFF) / 255; g = CGFloat((v >> 8) & 0xFF) / 255
            b = CGFloat(v & 0xFF) / 255; a = 1
        case 8:
            r = CGFloat((v >> 24) & 0xFF) / 255; g = CGFloat((v >> 16) & 0xFF) / 255
            b = CGFloat((v >> 8) & 0xFF) / 255; a = CGFloat(v & 0xFF) / 255
        default:
            return nil
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}

/// Native selectable terminal screen (UITextView) — drag-select any range and
/// Copy, while file/URL links stay tappable. Auto-scrolls to the bottom on new
/// output unless the user has a selection active.
private struct SelectableTerminalText: UIViewRepresentable {
    let attributed: NSAttributedString
    let background: UIColor
    let onLink: (URL) -> Void

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = background
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        tv.dataDetectorTypes = []
        tv.delegate = context.coordinator
        tv.alwaysBounceVertical = true
        // Fill the offered height and scroll internally (don't grow to content).
        tv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        tv.setContentHuggingPriority(.defaultLow, for: .vertical)
        tv.attributedText = attributed
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // Only reset text when it actually changed, so a live poll doesn't clobber
        // an in-progress selection. Auto-scroll to bottom on new output.
        if tv.attributedText?.string != attributed.string {
            let hadSelection = tv.selectedRange.length > 0
            tv.attributedText = attributed
            tv.backgroundColor = background
            if !hadSelection {
                DispatchQueue.main.async {
                    tv.scrollRangeToVisible(NSRange(location: max(0, attributed.length - 1), length: 0))
                }
            }
        } else if tv.backgroundColor != background {
            tv.backgroundColor = background
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onLink: onLink) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let onLink: (URL) -> Void
        init(onLink: @escaping (URL) -> Void) { self.onLink = onLink }
        func textView(_ textView: UITextView, shouldInteractWith URL: URL,
                      in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            onLink(URL)
            return false
        }
    }
}

// MARK: - Prompt snippets (frequently-used commands + directory jumps)

struct PromptSnippet: Identifiable, Codable, Equatable {
    var id = UUID()
    var label: String
    var text: String
}

/// Persisted, user-editable command snippets. Directory snippets are generated
/// live from the cmux session tree, not stored here.
final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()
    @Published var snippets: [PromptSnippet] = []
    private let key = "cmux_prompt_snippets_v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let arr = try? JSONDecoder().decode([PromptSnippet].self, from: data) {
            snippets = arr
        } else {
            snippets = Self.defaults
            save()
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(snippets) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    func add(_ s: PromptSnippet) { snippets.append(s); save() }
    func update(_ s: PromptSnippet) {
        if let i = snippets.firstIndex(where: { $0.id == s.id }) { snippets[i] = s; save() }
    }
    func delete(at offsets: IndexSet) { snippets.remove(atOffsets: offsets); save() }

    static let defaults: [PromptSnippet] = [
        .init(label: "가재코드", text: "gjc --tmux"),
        .init(label: "omo (madmax)", text: "omx --madmax --high"),
        .init(label: "/clear", text: "/clear"),
        .init(label: "/compact", text: "/compact"),
        .init(label: "/model", text: "/model"),
        .init(label: "/cost", text: "/cost"),
        .init(label: "/resume", text: "/resume"),
        .init(label: "git status", text: "git status"),
        .init(label: "계속 진행", text: "계속 진행해줘"),
    ]
}

/// Snippet picker: tap a row to insert into the prompt, ✈︎ to send immediately.
/// Command snippets are editable; the directory section is live from the mirror.
private struct SnippetSheet: View {
    @ObservedObject private var store = SnippetStore.shared
    let dirs: [PromptSnippet]
    let onInsert: (String) -> Void
    let onSend: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editing: PromptSnippet?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                Section("명령") {
                    ForEach(store.snippets) { s in
                        row(s, editable: true)
                    }
                    .onDelete { store.delete(at: $0) }
                }
                if !dirs.isEmpty {
                    Section("디렉토리 이동 (현재 세션 경로)") {
                        ForEach(dirs) { s in row(s, editable: false) }
                    }
                }
            }
            .navigationTitle("스니펫")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $adding) {
                SnippetEditor(existing: nil) { label, text in
                    store.add(PromptSnippet(label: label, text: text))
                }
            }
            .sheet(item: $editing) { s in
                SnippetEditor(existing: s) { label, text in
                    store.update(PromptSnippet(id: s.id, label: label, text: text))
                }
            }
        }
    }

    private func row(_ s: PromptSnippet, editable: Bool) -> some View {
        HStack(spacing: 10) {
            Button { onInsert(s.text); dismiss() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.label).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.textPrimary)
                    Text(s.text).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.subtleText).lineLimit(1).truncationMode(.middle)
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 6)
            Button { onSend(s.text); dismiss() } label: {
                Image(systemName: "paperplane.fill").foregroundStyle(Color.claudeOrange)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if editable {
                Button("편집") { editing = s }
            }
            Button("입력창에 넣기") { onInsert(s.text); dismiss() }
            Button("바로 실행") { onSend(s.text); dismiss() }
        }
    }
}

private struct SnippetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var text: String
    let onSave: (String, String) -> Void

    init(existing: PromptSnippet?, onSave: @escaping (String, String) -> Void) {
        _label = State(initialValue: existing?.label ?? "")
        _text = State(initialValue: existing?.text ?? "")
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("이름") { TextField("예: 가재코드", text: $label) }
                Section("명령/텍스트") {
                    TextField("예: gjc --tmux", text: $text, axis: .vertical)
                        .font(.system(size: 14, design: .monospaced))
                        .lineLimit(1...5)
                }
            }
            .navigationTitle("스니펫")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("저장") {
                        let l = label.trimmingCharacters(in: .whitespaces)
                        let t = text.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty { onSave(l.isEmpty ? t : l, t); dismiss() }
                    }.bold()
                }
            }
        }
    }
}

/// Streams a video from the bridge (Range-backed) with native playback controls.
private struct VideoStreamView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .onAppear {
            if player == nil { player = AVPlayer(url: url) }
            player?.play()
        }
        .onDisappear { player?.pause() }
    }
}

/// Pinch-to-zoom + pan image viewer. Double-tap toggles fit/2×.
private struct ZoomableImage: View {
    let image: UIImage

    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 8

    var body: some View {
        let magnify = MagnificationGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onEnded { value in
                scale = min(max(scale * value, minScale), maxScale)
                if scale <= minScale { withAnimation(.easeOut(duration: 0.2)) { offset = .zero } }
            }
        let pan = DragGesture()
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
                offset.width += value.translation.width
                offset.height += value.translation.height
            }
        let effectiveScale = scale * pinch

        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(effectiveScale)
            .offset(x: offset.width + drag.width, y: offset.height + drag.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(pan)
            .simultaneousGesture(magnify)
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if scale > minScale { scale = minScale; offset = .zero }
                    else { scale = 2 }
                }
            }
            .background(Color.appBackground)
            .clipped()
    }
}

/// Camera capture via UIImagePickerController (SwiftUI has no native camera).
private struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// Model + effort picker — centered overlay modal, agent-aware.
///
/// Claude mode sends `/model <name>` / `/effort <level>` slash commands (Claude
/// accepts inline args). Codex mode drives the interactive `/model` popup: tap a
/// model to auto-select (parent reads the screen and picks by digit), or use the
/// manual keypad while watching the live screen preview. A Claude/Codex segmented
/// toggle (seeded by a screen heuristic) lets the user pick the right mode.
private struct ModelEffortPanel: View {
    let liveScreen: String
    let driving: Bool
    let statusText: String
    let onClaudeCommand: (String) -> Void
    let onCodexSelect: (_ model: String, _ effort: String?) -> Void
    let onKey: (String) -> Void
    let onDigit: (String) -> Void
    let onDismiss: () -> Void

    @State private var agent: String
    @State private var pendingEffort: String? = nil

    init(initialAgent: String,
         liveScreen: String,
         driving: Bool,
         statusText: String,
         onClaudeCommand: @escaping (String) -> Void,
         onCodexSelect: @escaping (String, String?) -> Void,
         onKey: @escaping (String) -> Void,
         onDigit: @escaping (String) -> Void,
         onDismiss: @escaping () -> Void) {
        self.liveScreen = liveScreen
        self.driving = driving
        self.statusText = statusText
        self.onClaudeCommand = onClaudeCommand
        self.onCodexSelect = onCodexSelect
        self.onKey = onKey
        self.onDigit = onDigit
        self.onDismiss = onDismiss
        _agent = State(initialValue: initialAgent)
    }

    private let claudeModels: [(String, String)] = [("Opus", "opus"), ("Sonnet", "sonnet"), ("Haiku", "haiku")]
    private let claudeEfforts: [String] = ["low", "medium", "high", "xhigh", "max", "ultracode"]
    // Labels match codex's "/model" popup rows exactly (verified live, v0.141.0).
    // Other models need `codex -m <name>`; pick them via the keypad if listed.
    private let codexModels: [String] = ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini"]
    private let codexEfforts: [String] = ["Minimal", "Low", "Medium", "High", "Extra high"]
    private let cols = [GridItem(.adaptive(minimum: 88), spacing: 8)]
    private let keypadCols = [GridItem(.adaptive(minimum: 40), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Picker("", selection: $agent) {
                Text("Claude").tag("claude")
                Text("Codex").tag("codex")
            }
            .pickerStyle(.segmented)
            .disabled(driving)

            if agent == "claude" { claudeBody } else { codexBody }
        }
        .padding(20)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 6)
        .padding(.horizontal, 24)
    }

    private var header: some View {
        HStack {
            Text(agent == "codex" ? "Codex 설정" : "Claude 설정")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.subtleText)
            }
            .buttonStyle(.plain)
            .disabled(driving)
        }
    }

    // MARK: Claude

    private var claudeBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("모델") {
                ForEach(claudeModels, id: \.1) { (label, name) in
                    chip(label, color: .claudeOrange) { onClaudeCommand("/model \(name)") }
                }
            }
            section("Effort") {
                ForEach(claudeEfforts, id: \.self) { lvl in
                    chip(lvl, color: .claudeAmber) { onClaudeCommand("/effort \(lvl)") }
                }
            }
            Text("선택하면 Claude에 슬래시 명령으로 전송됩니다.")
                .font(.system(size: 11))
                .foregroundStyle(Color.subtleText)
        }
    }

    // MARK: Codex

    private var codexBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("모델 — 탭하면 자동 선택") {
                    ForEach(codexModels, id: \.self) { m in
                        chip(m, color: .claudeOrange, disabled: driving) { onCodexSelect(m, pendingEffort) }
                    }
                }
                section("Reasoning · effort (모델과 함께 적용)") {
                    ForEach(codexEfforts, id: \.self) { e in
                        chip(e, color: .claudeAmber, selected: pendingEffort == e, disabled: driving) {
                            pendingEffort = (pendingEffort == e) ? nil : e
                        }
                    }
                }

                if !statusText.isEmpty {
                    HStack(spacing: 6) {
                        if driving { ProgressView().scaleEffect(0.7) }
                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(driving ? Color.subtleText : Color.claudeAmber)
                    }
                }

                screenPreview
                keypad

                Text("자동이 안 되면 위 키패드로 팝업을 직접 조작하세요 (화면을 보며 ↑↓·숫자·⏎).")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.subtleText)
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 460)
    }

    private var screenPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("화면 (실시간)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.subtleText)
            ScrollView {
                Text(previewTail.isEmpty ? "…" : previewTail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 116)
            .padding(8)
            .background(Color.appBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.hairline, lineWidth: 1))
        }
    }

    private var keypad: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("수동 키패드")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.subtleText)
            HStack(spacing: 8) {
                keyButton("↑") { onKey("up") }
                keyButton("↓") { onKey("down") }
                keyButton("⏎") { onKey("enter") }
                keyButton("esc") { onKey("escape") }
            }
            LazyVGrid(columns: keypadCols, spacing: 8) {
                ForEach(1...9, id: \.self) { n in
                    keyButton("\(n)") { onDigit("\(n)") }
                }
            }
        }
    }

    private var previewTail: String {
        let lines = liveScreen.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(40).joined(separator: "\n")
    }

    // MARK: shared chrome

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.subtleText)
            LazyVGrid(columns: cols, alignment: .leading, spacing: 8) { content() }
        }
    }

    private func chip(_ label: String, color: Color, selected: Bool = false, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(color.opacity(selected ? 0.32 : 0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(selected ? 0.9 : 0.4), lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private func keyButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Color.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(driving)
        .opacity(driving ? 0.5 : 1)
    }
}

private struct SessionsListView: View {
    let folder: String
    @EnvironmentObject private var relayService: RelayService

    private var sessions: [AgentSession] {
        relayService.sessions.filter { workspaceKey($0) == folder }
    }

    private var cwd: String { sessions.first?.cwd ?? "" }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            if sessions.isEmpty {
                Text("이 워크스페이스에 세션이 없습니다.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.subtleText)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        header
                        ForEach(sessions) { session in
                            NavigationLink(value: SessionRoute(sessionId: session.id)) {
                                sessionRow(session)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(folder)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(folder)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            Text("\(cwd) · 세션 \(sessions.count)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.subtleText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        let lastText = session.terminalLines.last?.text
        let lastAction: String = {
            guard let t = lastText, !t.isEmpty else { return "—" }
            return t.count > 40 ? String(t.prefix(40)) + "…" : t
        }()
        let hasApproval = session.pendingApproval != nil
        let borderColor: Color = hasApproval ? Color.claudeOrange.opacity(0.35) : Color.hairline

        return HStack(spacing: 12) {
            sessionAvatar(session.agent, size: avatarGlyphSize(session.agent))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.agent.rawValue.capitalized)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    if hasApproval {
                        Text("승인")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.claudeAmber)
                            .clipShape(Capsule())
                    }
                }
                Text(lastAction)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.subtleText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()
            Circle().fill(statusColor(session.activity)).frame(width: 8, height: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.subtleText)
        }
        .padding(14)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private func statusColor(_ activity: SessionActivity) -> Color {
        switch activity {
        case .running:         return Color.statusGreen
        case .waitingApproval: return Color.claudeAmber
        case .ended:           return Color.denyRed
        case .idle:            return Color.subtleText
        }
    }
}

// MARK: - Shared avatar (Claude / Codex)

private func avatarGlyphSize(_ agent: AgentType) -> CGFloat {
    agent == .claude ? 26 : 22
}

@ViewBuilder
private func sessionAvatar(_ agent: AgentType, size: CGFloat) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: 8)
            .fill(agent == .claude ? Color.claudeOrange.opacity(0.15) : Color.surfaceElevated)
            .frame(width: 40, height: 40)
        switch agent {
        case .claude: AppLogo(size: size)
        case .codex:  CodexLogo(size: size)
        }
    }
}

// MARK: - Level 4: Full session content — SCREEN 05 / 06

private struct SessionDetailView: View {
    let sessionId: String
    @EnvironmentObject private var relayService: RelayService

    @State private var cursorVisible = true
    @State private var promptText = ""
    @State private var messageText = ""
    @State private var isSending = false
    @FocusState private var isPromptFocused: Bool
    @FocusState private var isMessageFocused: Bool
    private let cursorTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    private var session: AgentSession? {
        relayService.sessions.first { $0.id == sessionId }
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            if let session {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 10) {
                            headerRow(session)
                            if let approval = session.pendingApproval {
                                approvalPrompt(approval)
                            }
                            terminalView(session)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                    }
                    messageBar(session)
                }
            } else {
                Text("세션이 종료되었습니다.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.subtleText)
            }
        }
        .navigationTitle(session.map { workspaceKey($0) } ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    relayService.clearTerminal(sessionId: sessionId)
                } label: {
                    Image(systemName: "trash").foregroundStyle(Color.subtleText)
                }
            }
        }
    }

    // MARK: Header

    private func headerRow(_ session: AgentSession) -> some View {
        let (label, dot): (String, Color) = {
            switch session.activity {
            case .running:         return ("실행 중", Color.statusGreen)
            case .waitingApproval: return ("승인 대기", Color.claudeAmber)
            case .ended:           return ("완료", Color.denyRed)
            case .idle:            return ("대기", Color.subtleText)
            }
        }()

        return HStack(spacing: 12) {
            sessionAvatar(session.agent, size: session.agent == .claude ? 28 : 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.agent.rawValue.capitalized)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.textPrimary)
                HStack(spacing: 6) {
                    Circle().fill(dot).frame(width: 8, height: 8)
                    Text("\(label) · \(workspaceKey(session))")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.subtleText)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Terminal — full output, as-is, selectable.

    private func terminalView(_ session: AgentSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(session.terminalLines) { line in
                        terminalLineView(line)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                    if session.thinking {
                        HStack(spacing: 0) {
                            Text("✳ 생각 중… ")
                            Text(cursorVisible ? "\u{258C}" : " ")
                        }
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.claudeOrange)
                        .onReceive(cursorTimer) { _ in cursorVisible.toggle() }
                        .id("thinking-cursor")
                    }
                }
                .padding(12)
            }
            .onChange(of: session.terminalLines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    if session.thinking {
                        proxy.scrollTo("thinking-cursor", anchor: .bottom)
                    } else if let last = session.terminalLines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 240)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.hairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func terminalLineView(_ line: TerminalLine) -> some View {
        let text = line.text.isEmpty ? " " : line.text
        switch line.type {
        case .command:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("●")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.claudeOrange)
                Text(text)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.textPrimary)
            }
        case .system:
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.subtleText)
        case .output:
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(outputColor(text))
        case .thinking:
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.claudeOrange.opacity(0.5))
        case .error:
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.denyRed)
        }
    }

    private func outputColor(_ text: String) -> Color {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("+ ") { return Color.statusGreen }
        if t.hasPrefix("- ") { return Color.denyRed }
        return Color.textPrimary
    }

    // MARK: Message bar — SCREEN 05

    private func messageBar(_ session: AgentSession) -> some View {
        let placeholder = session.agent == .codex
            ? "Codex에게 메시지 보내기..."
            : "Claude에게 메시지 보내기..."
        let disabled = messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending

        return HStack(spacing: 10) {
            TextField(placeholder, text: $messageText)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Color.textPrimary)
                .tint(Color.claudeOrange)
                .focused($isMessageFocused)
                .submitLabel(.send)
                .onSubmit { sendMessage() }
                .disabled(isSending)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.hairline, lineWidth: 1)
                )

            Button { sendMessage() } label: {
                Image(systemName: isSending ? "ellipsis" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.claudeOrange.opacity(disabled ? 0.4 : 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(disabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.appBackground)
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        isMessageFocused = false
        Task {
            let ok = await relayService.sendCommand(text: text, sessionId: sessionId)
            isSending = false
            if ok {
                messageText = ""          // clear only on success; keep text to retry on failure
            }
        }
    }

    // MARK: Approval — SCREEN 06

    private func approvalPrompt(_ approval: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.claudeAmber)
                    .font(.system(size: 14))
                Text(approval.question ?? "Claude가 명령을 실행하려고 합니다")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !approval.actionSummary.isEmpty && approval.actionSummary != approval.toolName {
                Text(approval.actionSummary)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            ForEach(Array(approval.options.enumerated()), id: \.element.id) { index, option in
                let color = colorForOption(index, total: approval.options.count, isQuestion: approval.question != nil)
                Button {
                    relayService.respond(to: approval, optionLabel: option.label, index: index)
                    promptText = ""
                } label: {
                    HStack(spacing: 8) {
                        Text("\(index + 1).")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.textPrimary)
                            if let desc = option.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.subtleText)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(color.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(approval.status == .submitting)
                .opacity(approval.status == .submitting ? 0.5 : 1)
            }

            if approval.status == .submitting {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("전송 중…").font(.system(size: 12)).foregroundStyle(Color.subtleText)
                }
            } else if approval.status == .failed {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(Color.denyRed)
                    Text(approval.lastError ?? "전송 실패 — 다시 시도하세요")
                        .font(.system(size: 12)).foregroundStyle(Color.denyRed)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                TextField("응답 입력...", text: $promptText)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Color.textPrimary)
                    .tint(Color.claudeOrange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.hairline, lineWidth: 1)
                    )
                    .focused($isPromptFocused)
                    .onSubmit { submitPromptText(approval) }

                Button { submitPromptText(approval) } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.subtleText : Color.claudeOrange)
                }
                .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.claudeAmber.opacity(0.4), lineWidth: 1)
        )
    }

    private func submitPromptText(_ approval: ApprovalRequest) {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        relayService.respond(to: approval, optionLabel: text, index: -1)
        promptText = ""
        isPromptFocused = false
    }

    private func colorForOption(_ index: Int, total: Int, isQuestion: Bool = false) -> Color {
        // AskUserQuestion options are neutral choices — not allow/deny.
        if isQuestion { return Color.claudeOrange }
        if total <= 1 { return Color.statusGreen }
        if index == 0 { return Color.statusGreen }
        if index == total - 1 { return Color.denyRed }
        return Color.claudeOrange
    }
}

// MARK: - Preview

#Preview {
    ConnectionStatusView()
        .environmentObject(WatchSessionManager.shared)
        .environmentObject(RelayService.shared)
}
