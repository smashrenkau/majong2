//
//  ContentView.swift
//  majoing3
//
//  Created by Kodai Okugawa on 2026/01/27.
//

import SwiftUI
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import Network

#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(CoreHaptics)
import CoreHaptics
#endif

#if canImport(UIKit)
import UIKit
#endif

#if canImport(MediaPlayer)
import MediaPlayer
#endif

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    longVibrationSection
                    roomSection
                    sendSection
                    logSection
                }
                .padding()
            }
            .navigationTitle("シフト管理表")
            .overlay(alignment: .bottomTrailing) {
                if let error = appModel.lastErrorMessage, !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.red.opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding()
                }
            }
            .background {
                // 振動受信時の背景色点滅
                (appModel.isFlashing ? Color.red.opacity(0.3) : Color.clear)
                    .animation(.easeInOut(duration: 0.15), value: appModel.isFlashing)
                    .ignoresSafeArea()
            }
            .background {
                // 音量ボタン監視用（ベストエフォート）。UI上は見えない/邪魔にならないようにする。
                VolumeViewHost()
                    .frame(width: 0, height: 0)
                    .opacity(0.01)
            }
        }
    }

    private var longVibrationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "長振動")
            Button {
                Task { await appModel.sendLongVibration() }
            } label: {
                Text("シフトを提出する")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!appModel.canSend)
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var roomSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "ルーム")

            HStack(spacing: 8) {
                Button("参加") {
                    Task { await appModel.joinRoom(roomId: AppModel.fixedRoomId) }
                }
                .buttonStyle(.bordered)
                .disabled(!appModel.canOperateFirebase)

                Button("再接続") {
                    Task { await appModel.joinRoom(roomId: AppModel.fixedRoomId) }
                }
                .buttonStyle(.bordered)
                .disabled(!appModel.canOperateFirebase)

                Button("退出") {
                    Task { await appModel.leaveRoomWaitingFirestore() }
                }
                .buttonStyle(.bordered)
                .disabled(appModel.roomId == nil)
            }

            LabeledRow(label: "参加中ルーム", value: appModel.roomId ?? "未参加（常にAAAで入室）")
            LabeledRow(label: "相手", value: appModel.peerJoined ? "ON" : (appModel.roomId == nil ? "—" : "未参加"))
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var sendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "シフト回数")

            HStack(spacing: 8) {
                ForEach(1...9, id: \.self) { n in
                    Button("\(n)") {
                        Task { await appModel.sendCount(n) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!appModel.canSend)
                }
            }
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "ログ（直近）")

            if appModel.logs.isEmpty {
                Text("まだログはありません")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(appModel.logs) { item in
                        HStack {
                            Text(item.kindText)
                                .font(.caption)
                                .fontWeight(.bold)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .background(item.kind == .rx ? Color.green.opacity(0.2) : Color.blue.opacity(0.2))
                                .clipShape(Capsule())

                            Text(item.countText)
                            Spacer()
                            Text(item.timeText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Button("ログをクリア") {
                appModel.logs.removeAll()
            }
            .buttonStyle(.bordered)
            .disabled(appModel.logs.isEmpty)
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - View helpers

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .font(.subheadline)
        }
    }
}

// MARK: - App model

@MainActor
final class AppModel: ObservableObject {
    static let fixedRoomId = "AAA"
    @Published var roomIdInput: String = AppModel.fixedRoomId
    @Published var roomId: String?
    @Published var peerJoined: Bool = false
    @Published var logs: [LogItem] = []
    @Published var lastErrorMessage: String?
    @Published var isVolumeInputEnabled: Bool = false
    @Published var isFlashing: Bool = false

    @Published private(set) var firebaseConfigured: Bool = false
    @Published private(set) var myUid: String?

    let networkMonitor = NetworkMonitor()
    let hapticsPlayer = HapticsPlayer()
    let countAggregator: CountAggregator
    let volumeButtonObserver: VolumeButtonObserver

    private var roomListener: ListenerRegistration?
    private var eventsListener: ListenerRegistration?
    private var seenEventIds = Set<String>()
    private var recentPressTimestamps: [Date] = []
    private var longPressCooldownUntil: Date?

    init() {
        self.countAggregator = CountAggregator()
        self.volumeButtonObserver = VolumeButtonObserver()

        self.countAggregator.onCommit = { [weak self] count in
            guard let self else { return }
            Task { await self.sendCount(count) }
        }
        
        self.countAggregator.onCommitCompleted = { [weak self] in
            guard let self else { return }
            // 送信完了後すぐに音量を0%にリセット
            self.volumeButtonObserver.resetVolumeAfterSend()
        }

        self.volumeButtonObserver.onPress = { [weak self] in
            guard let self else { return }
            let now = Date()
            if let until = self.longPressCooldownUntil, now < until {
                return
            }
            self.recentPressTimestamps.append(now)
            self.recentPressTimestamps.removeAll { now.timeIntervalSince($0) > 0.5 }
            
            // 0.5秒以内に5回以上押された場合は長押しとみなす
            if self.recentPressTimestamps.count >= 5,
               let first = self.recentPressTimestamps.first,
               now.timeIntervalSince(first) <= 0.5 {
                self.recentPressTimestamps.removeAll()
                self.longPressCooldownUntil = now.addingTimeInterval(2.0)
                self.countAggregator.reset()
                Task {
                    await self.sendLongVibration()
                    // 長振動送信後も音量をリセット
                    await MainActor.run {
                        self.volumeButtonObserver.resetVolumeAfterSend()
                    }
                }
                return
            }
            
            // 通常の押下はCountAggregatorで集約（最後の押下から1秒後に送信）
            self.countAggregator.press()
        }
    }

    var networkStatusText: String {
        switch networkMonitor.status {
        case .online: return "オンライン"
        case .offline: return "オフライン"
        case .unknown: return "不明"
        }
    }

    var firebaseStatusText: String { firebaseConfigured ? "構成済み" : "未構成" }
    var authStatusText: String { myUid == nil ? "未サインイン" : "匿名サインイン済み" }

    var canOperateFirebase: Bool { firebaseConfigured && myUid != nil && networkMonitor.status != .offline }
    var canSend: Bool { canOperateFirebase && roomId != nil }

    func startIfNeeded() async {
        print("[DEBUG] startIfNeeded entry firebaseConfigured=\(firebaseConfigured) myUid=\(myUid ?? "nil")")
        
        // FirebaseがAppDelegateで初期化されるまで少し待つ
        var retries = 0
        while FirebaseApp.app() == nil && retries < 10 {
            print("[DEBUG] startIfNeeded: Waiting for Firebase initialization... attempt \(retries + 1)")
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            retries += 1
        }
        
        // FirebaseがAppDelegateで既に初期化されているか確認
        if FirebaseApp.app() != nil {
            firebaseConfigured = true
            print("[DEBUG] startIfNeeded: Firebase already configured by AppDelegate")
        } else {
            print("[ERROR] startIfNeeded: Firebase initialization failed after \(retries) retries")
            lastErrorMessage = "Firebase初期化タイムアウト"
        }

        if myUid == nil, firebaseConfigured {
            print("[DEBUG] startIfNeeded calling signInAnonymously")
            await signInAnonymously()
            print("[DEBUG] startIfNeeded after signIn myUid=\(myUid ?? "nil")")
        }

        networkMonitor.start()
        print("[DEBUG] startIfNeeded done")
    }

    private func signInAnonymously() async {
        print("[DEBUG] signInAnonymously start")
        do {
            let result = try await AuthService.signInAnonymously()
            myUid = result.user.uid
            print("[DEBUG] signInAnonymously success uid=\(result.user.uid)")
        } catch {
            print("[DEBUG] signInAnonymously failed \(error.localizedDescription)")
            lastErrorMessage = "匿名サインイン失敗: \(error.localizedDescription)"
        }
    }

    func createRoom() async {
        guard let uid = myUid else { return }
        do {
            let newRoomId = AppModel.fixedRoomId
            try await RoomService.createRoom(roomId: newRoomId, myUid: uid)
            attachToRoom(roomId: newRoomId)
            roomIdInput = newRoomId
        } catch {
            let nsErr = error as NSError
            if nsErr.domain == "FIRFirestoreErrorDomain", nsErr.code == 7 {
                lastErrorMessage = "ルーム作成失敗: 権限がありません。Firebase Console → Firestore → ルール で firestore.rules の内容を貼り付けて「公開」してください。"
            } else {
                lastErrorMessage = "ルーム作成失敗: \(error.localizedDescription)"
            }
        }
    }

    func joinRoom(roomId: String) async {
        print("[DEBUG] joinRoom(entry) roomId=\(roomId), myUid=\(myUid ?? "nil"), firebaseConfigured=\(firebaseConfigured)")
        guard !roomId.isEmpty else {
            print("[DEBUG] joinRoom(exit) roomId empty")
            return
        }
        guard let uid = myUid else {
            print("[DEBUG] joinRoom(exit) myUid is nil - 未サインインの可能性")
            return
        }
        print("[DEBUG] joinRoom calling RoomService.joinRoom")
        do {
            try await RoomService.joinRoom(roomId: roomId, myUid: uid)
            print("[DEBUG] joinRoom RoomService done, calling attachToRoom")
            attachToRoom(roomId: roomId)
        } catch {
            let nsErr = error as NSError
            print("[DEBUG] joinRoom catch domain=\(nsErr.domain) code=\(nsErr.code) desc=\(error.localizedDescription)")
            lastErrorMessage = "ルーム参加失敗: \(error.localizedDescription)"
        }
    }

    /// 退室: Firestore の members から自分を削除してから状態をクリア（直後の「参加」で満員にならないようにする）
    func leaveRoomWaitingFirestore() async {
        let currentRoomId = roomId
        let currentUid = myUid
        if let rid = currentRoomId, let uid = currentUid {
            try? await RoomService.leaveRoom(roomId: rid, myUid: uid)
        }
        roomListener?.remove()
        eventsListener?.remove()
        roomListener = nil
        eventsListener = nil
        roomId = nil
        peerJoined = false
        seenEventIds.removeAll()
        recentPressTimestamps.removeAll()
        longPressCooldownUntil = nil
        isVolumeInputEnabled = true
        countAggregator.reset()
    }

    private func attachToRoom(roomId: String) {
        // 既存listenerを解除して付け直し
        roomListener?.remove()
        eventsListener?.remove()

        self.roomId = roomId
        self.peerJoined = false
        self.seenEventIds.removeAll()
        volumeButtonObserver.setEnabled(true)
        hapticsPlayer.prepareEngine()

        roomListener = EventService.listenRoom(roomId: roomId) { [weak self] members in
            guard let self else { return }
            self.peerJoined = members.count >= 2
        }

        eventsListener = EventService.listenEvents(roomId: roomId, onInitialEventIds: { [weak self] ids in
            guard let self else { return }
            self.seenEventIds.formUnion(ids)
        }) { [weak self] event in
            guard let self else { return }
            guard let myUid = self.myUid else { return }
            guard event.senderId != myUid else { return } // 自己受信除外
            guard !self.seenEventIds.contains(event.eventId) else { return } // 重複排除

            self.seenEventIds.insert(event.eventId)
            if event.isLongVibration {
                self.logs.insert(LogItem(kind: .rx, count: 0, date: Date(), isLongVibration: true), at: 0)
                Task {
                    await self.hapticsPlayer.playLong(duration: 4.0)
                }
                self.flashBackground(duration: 4.0)
            } else {
                self.logs.insert(LogItem(kind: .rx, count: event.count, date: Date()), at: 0)
                Task {
                    await self.hapticsPlayer.play(count: event.count)
                }
                let duration = Double(event.count) * (HapticsPlayer.vibrationDuration + HapticsPlayer.gapBetweenVibrations)
                self.flashBackground(duration: duration)
            }
        }
    }

    func sendCount(_ count: Int) async {
        guard let roomId, let myUid else { return }
        guard (1...9).contains(count) else { return }

        do {
            let eventId = UUID().uuidString
            try await EventService.sendEvent(roomId: roomId, eventId: eventId, senderId: myUid, count: count)
            logs.insert(LogItem(kind: .tx, count: count, date: Date()), at: 0)
        } catch {
            lastErrorMessage = "送信失敗: \(error.localizedDescription)"
        }
    }

    /// 音量ボタン長押しで送信: 受信側で約4秒の連続振動
    func sendLongVibration() async {
        guard let roomId, let myUid else { return }
        do {
            let eventId = UUID().uuidString
            try await EventService.sendEvent(roomId: roomId, eventId: eventId, senderId: myUid, count: 0, longVibration: true)
            logs.insert(LogItem(kind: .tx, count: 0, date: Date(), isLongVibration: true), at: 0)
        } catch {
            lastErrorMessage = "送信失敗: \(error.localizedDescription)"
        }
    }
    
    /// 背景色を点滅させる
    private func flashBackground(duration: TimeInterval) {
        guard duration > 0 else { return }
        isFlashing = true
        Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            } catch {
                // キャンセル時も点滅を終了
            }
            await MainActor.run {
                self.isFlashing = false
            }
        }
    }
}

// MARK: - Models

struct LogItem: Identifiable {
    enum Kind { case tx, rx }
    let id = UUID()
    let kind: Kind
    let count: Int
    let date: Date
    /// 長時間振動（長押し）の送受信ログか
    var isLongVibration: Bool = false

    var kindText: String { kind == .tx ? "Tx" : "Rx" }
    var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
    var countText: String { isLongVibration ? "長振動" : "回数: \(count)" }
}

struct RemoteEvent {
    let eventId: String
    let senderId: String
    let count: Int
    /// 音量ボタン長押しによる長時間振動（約4秒）イベントか
    let isLongVibration: Bool
}

enum AppError: LocalizedError {
    case roomNotFound

    var errorDescription: String? {
        switch self {
        case .roomNotFound: return "ルームが見つかりません"
        }
    }
}

// MARK: - Firebase services

enum AuthService {
    static func signInAnonymously() async throws -> AuthDataResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AuthDataResult, Error>) in
            Auth.auth().signInAnonymously { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let result else {
                    continuation.resume(throwing: NSError(domain: "AuthService", code: -1, userInfo: nil))
                    return
                }
                continuation.resume(returning: result)
            }
        }
    }
}

enum RoomService {
    static func createRoom(roomId: String, myUid: String) async throws {
        print("[DEBUG] createRoom roomId=\(roomId)")
        let db = Firestore.firestore()
        let ref = db.collection("rooms").document(roomId)
        let data: [String: Any] = [
            "members": [myUid],
            "createdAt": FieldValue.serverTimestamp()
        ]
        try await ref.setData(data, merge: false)
        print("[DEBUG] createRoom done")
    }

    static func joinRoom(roomId: String, myUid: String) async throws {
        let authUid = Auth.auth().currentUser?.uid
        print("[DEBUG] RoomService.joinRoom start roomId=\(roomId) authCurrentUid=\(authUid ?? "nil")")
        let db = Firestore.firestore()
        let ref = db.collection("rooms").document(roomId)
        print("[DEBUG] RoomService.joinRoom path=rooms/\(roomId) (getDocument then updateData)")

        // getDocument を試み、権限エラーや未存在の場合はルームを自動作成する
        let snapshot: DocumentSnapshot
        do {
            snapshot = try await ref.getDocument()
            print("[DEBUG] RoomService.joinRoom getDocument OK exists=\(snapshot.exists)")
        } catch {
            let ne = error as NSError
            print("[DEBUG] RoomService.joinRoom getDocument failed domain=\(ne.domain) code=\(ne.code)")

            // 権限エラー (code=7) の場合、ルームが未作成の可能性が高い → 自動作成を試みる
            if ne.domain == "FIRFirestoreErrorDomain" && ne.code == 7 {
                print("[DEBUG] RoomService.joinRoom permission denied → attempting to create room")
                do {
                    try await RoomService.createRoom(roomId: roomId, myUid: myUid)
                    print("[DEBUG] RoomService.joinRoom room auto-created successfully")
                    return
                } catch {
                    let createErr = error as NSError
                    print("[DEBUG] RoomService.joinRoom auto-create also failed domain=\(createErr.domain) code=\(createErr.code) desc=\(error.localizedDescription)")
                    // 自動作成も失敗した場合は元のエラーではなく分かりやすいメッセージを返す
                    throw NSError(
                        domain: "RoomService",
                        code: ne.code,
                        userInfo: [NSLocalizedDescriptionKey: "ルームの読み取りに失敗しました（権限エラー）。Firestore ルールが正しくデプロイされているか確認してください。"]
                    )
                }
            }
            throw error
        }

        // ルームが存在しない場合は自動作成
        guard snapshot.exists else {
            print("[DEBUG] RoomService.joinRoom room not found → creating room")
            try await RoomService.createRoom(roomId: roomId, myUid: myUid)
            print("[DEBUG] RoomService.joinRoom room created successfully")
            return
        }

        let members = (snapshot.data()?["members"] as? [String]) ?? []
        print("[DEBUG] joinRoom members.count=\(members.count), containsMyUid=\(members.contains(myUid))")
        if members.contains(myUid) {
            print("[DEBUG] joinRoom already in room")
            return
        }

        do {
            print("[DEBUG] joinRoom updateData members")
            try await ref.updateData(["members": members + [myUid]])
            print("[DEBUG] RoomService.joinRoom success")
        } catch {
            let ne = error as NSError
            print("[DEBUG] RoomService.joinRoom updateData failed domain=\(ne.domain) code=\(ne.code)")
            throw error
        }
    }

    /// ルームの members から自分を削除する（退室）。未参加の場合は何もしない。
    static func leaveRoom(roomId: String, myUid: String) async throws {
        let db = Firestore.firestore()
        let ref = db.collection("rooms").document(roomId)
        let snapshot = try await ref.getDocument()
        print("[DEBUG] leaveRoom roomId=\(roomId), exists=\(snapshot.exists)")
        guard snapshot.exists,
              var members = snapshot.data()?["members"] as? [String] else { return }
        guard members.contains(myUid) else { return }
        members.removeAll { $0 == myUid }
        print("[DEBUG] leaveRoom updating members count=\(members.count)")
        try await ref.updateData(["members": members])
    }
}

enum EventService {
    static func sendEvent(roomId: String, eventId: String, senderId: String, count: Int, longVibration: Bool = false) async throws {
        let db = Firestore.firestore()
        let ref = db
            .collection("rooms").document(roomId)
            .collection("events").document(eventId)

        var data: [String: Any] = [
            "eventId": eventId,
            "senderId": senderId,
            "count": count,
            "createdAt": FieldValue.serverTimestamp()
        ]
        if longVibration {
            data["longVibration"] = true
        }
        try await ref.setData(data, merge: false)
    }

    static func listenRoom(roomId: String, onMembers: @escaping ([String]) -> Void) -> ListenerRegistration {
        let db = Firestore.firestore()
        let ref = db.collection("rooms").document(roomId)
        return ref.addSnapshotListener { snapshot, _ in
            let members = (snapshot?.data()?["members"] as? [String]) ?? []
            onMembers(members)
        }
    }

    static func listenEvents(roomId: String, onInitialEventIds: @escaping ([String]) -> Void, onEvent: @escaping (RemoteEvent) -> Void) -> ListenerRegistration {
        let db = Firestore.firestore()
        let ref = db
            .collection("rooms").document(roomId)
            .collection("events")
            .order(by: "createdAt", descending: false)

        // 参加・再接続時: ドキュメントが含まれる「最初の1回」を初期スナップとして扱い、その eventId だけ seen に追加して振動しない
        let initialSkipped = RefBox(false)
        return ref.addSnapshotListener { snapshot, _ in
            guard let snapshot else { return }
            let documents = snapshot.documents
            if !documents.isEmpty && !initialSkipped.value {
                let ids = documents.map { doc -> String in
                    (doc.data()["eventId"] as? String) ?? doc.documentID
                }
                onInitialEventIds(ids)
                initialSkipped.value = true
                return
            }
            for change in snapshot.documentChanges where change.type == .added {
                let data = change.document.data()
                let eventId = (data["eventId"] as? String) ?? change.document.documentID
                let senderId = (data["senderId"] as? String) ?? ""
                let count = data["count"] as? Int ?? 0
                let isLongVibration = (data["longVibration"] as? Bool) == true
                guard !senderId.isEmpty else { continue }
                guard isLongVibration || (1...9).contains(count) else { continue }
                onEvent(RemoteEvent(eventId: eventId, senderId: senderId, count: count, isLongVibration: isLongVibration))
            }
        }
    }
}

/// リスナー内で変更可能なフラグ用（初回スナップショットスキップなど）
private final class RefBox<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Utilities

enum RoomIdGenerator {
    static func generate(length: Int) -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") // 紛らわしい文字を除外
        var out = ""
        out.reserveCapacity(length)
        for _ in 0..<length {
            out.append(chars.randomElement()!)
        }
        return out
    }
}

@MainActor
final class CountAggregator: ObservableObject {
    @Published private(set) var currentCount: Int = 0
    @Published private(set) var isCoolingDown: Bool = false

    var onCommit: ((Int) -> Void)?
    var onCommitCompleted: (() -> Void)?

    private var debounceTask: Task<Void, Never>?
    private var cooldownTask: Task<Void, Never>?

    func press() {
        guard !isCoolingDown else { return }

        currentCount = min(currentCount + 1, 9)

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1.0s
            } catch {
                return
            }
            await self.commit()
        }
    }

    func reset() {
        debounceTask?.cancel()
        cooldownTask?.cancel()
        currentCount = 0
        isCoolingDown = false
    }

    private func commit() async {
        let n = currentCount
        guard n > 0 else { return }

        currentCount = 0
        isCoolingDown = true
        onCommit?(n)
        
        // 送信完了を通知
        onCommitCompleted?()

        cooldownTask?.cancel()
        cooldownTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            } catch {
                return
            }
            await MainActor.run { self.isCoolingDown = false }
        }
    }
}

// MARK: - Network

@MainActor
final class NetworkMonitor: ObservableObject {
    enum Status { case unknown, online, offline }

    @Published private(set) var status: Status = .unknown

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { @MainActor in
                if path.status == .satisfied {
                    self.status = .online
                } else {
                    self.status = .offline
                }
            }
        }
        monitor.start(queue: queue)
    }
}

// MARK: - Haptics

@MainActor
final class HapticsPlayer {
    #if canImport(CoreHaptics)
    private var engine: CHHapticEngine?
    #endif
    #if canImport(UIKit)
    private var impactGenerator: UIImpactFeedbackGenerator?
    #endif

    /// 1回の振動の長さ（秒）
    static let vibrationDuration: Double = 0.5
    /// 振動と振動の間隔（秒）。長い振動のあと区切りをはっきり
    static let gapBetweenVibrations: Double = 0.15
    /// 1回分のスロット（振動＋間隔）
    private static let slotDuration: Double = vibrationDuration + gapBetweenVibrations

    /// ルーム入室時に呼び、エンジンを事前起動しておく（初回再生時の弱い振動を防ぐ）
    func prepareEngine() {
        #if canImport(AVFoundation)
        // AVAudioSessionを設定して振動を最大化
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // より安全なカテゴリ設定
            try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true, options: [])
            print("✅ [Haptics] AVAudioSession設定成功")
        } catch let error as NSError {
            print("⚠️ [Haptics] AVAudioSession設定失敗: \(error.domain) code=\(error.code) - \(error.localizedDescription)")
            // AVAudioSessionの設定失敗は致命的ではないので続行
        }
        #endif
        
        #if canImport(CoreHaptics)
        let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        print("🔧 [Haptics] supportsHaptics: \(supportsHaptics)")
        guard supportsHaptics else {
            print("⚠️ [Haptics] ハードウェアが振動をサポートしていません")
            return
        }
        guard engine == nil else {
            print("🔧 [Haptics] エンジンはすでに初期化済み")
            return
        }
        do {
            engine = try CHHapticEngine()
            try engine?.start()
            print("✅ [Haptics] エンジンの起動に成功")
        } catch {
            print("❌ [Haptics] エンジンの起動に失敗: \(error)")
            engine = nil
        }
        #endif
        #if canImport(UIKit)
        if impactGenerator == nil {
            impactGenerator = UIImpactFeedbackGenerator(style: .heavy)
            impactGenerator?.prepare()
            print("✅ [Haptics] UIImpactFeedbackGenerator (heavy) を準備")
        }
        #endif
    }

    func play(count: Int) async {
        guard count > 0 else { return }
        print("🎵 [Haptics] play(count: \(count)) 呼び出し")

        #if canImport(CoreHaptics)
        if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            print("🎵 [Haptics] CoreHaptics使用を試行")
            do {
                if engine == nil {
                    print("🎵 [Haptics] エンジン未初期化のため prepareEngine 呼び出し")
                    prepareEngine()
                }
                guard engine != nil else {
                    print("❌ [Haptics] エンジンがnil、フォールバック")
                    throw NSError(domain: "HapticsPlayer", code: 0, userInfo: nil)
                }

                // 回数どおり N 回、CoreHaptics で振動。強度・シャープネス最大
                // hapticContinuous（連続）とhapticTransient（瞬間衝撃）を組み合わせてより強い振動に
                print("🎵 [Haptics] パラメータ - intensity: 1.0, sharpness: 1.0, duration: \(Self.vibrationDuration)秒（Continuous + Transient併用）")
                var events: [CHHapticEvent] = []
                for i in 0..<count {
                    let startTime = Double(i) * Self.slotDuration
                    // 瞬間的な強い衝撃（より強く感じる）
                    events.append(CHHapticEvent(
                        eventType: .hapticTransient,
                        parameters: [
                            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                            CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                        ],
                        relativeTime: startTime
                    ))
                    // 連続振動で持続感を追加
                    events.append(CHHapticEvent(
                        eventType: .hapticContinuous,
                        parameters: [
                            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                            CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                        ],
                        relativeTime: startTime,
                        duration: Self.vibrationDuration
                    ))
                }
                let pattern = try CHHapticPattern(events: events, parameters: [])
                let player = try engine?.makePlayer(with: pattern)
                try player?.start(atTime: 0)
                print("✅ [Haptics] CoreHaptics再生成功")
                return
            } catch {
                print("❌ [Haptics] CoreHaptics再生エラー、フォールバック: \(error)")
                // フォールバックへ
            }
        } else {
            print("⚠️ [Haptics] CoreHapticsがサポートされていない、フォールバック")
        }
        #endif

        #if canImport(UIKit)
        print("🎵 [Haptics] UIImpactFeedbackGeneratorでフォールバック再生")
        if impactGenerator == nil { prepareEngine() }
        guard let g = impactGenerator else {
            print("❌ [Haptics] UIImpactFeedbackGenerator取得失敗")
            return
        }
        g.prepare()
        for i in 0..<count {
            print("🎵 [Haptics] impactOccurred (\(i+1)/\(count))")
            g.impactOccurred()
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.vibrationDuration * 1_000_000_000))
            } catch {
                print("❌ [Haptics] sleep中断")
                break
            }
        }
        print("✅ [Haptics] フォールバック再生完了")
        #endif
    }

    /// 長時間の連続振動（例: 音量ボタン長押しで約4秒）
    func playLong(duration: TimeInterval) async {
        guard duration > 0 else { return }
        print("🎵 [Haptics] playLong(duration: \(duration)秒) 呼び出し")

        #if canImport(CoreHaptics)
        if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            print("🎵 [Haptics] CoreHaptics使用を試行（長振動）")
            do {
                if engine == nil {
                    print("🎵 [Haptics] エンジン未初期化のため prepareEngine 呼び出し")
                    prepareEngine()
                }
                guard engine != nil else {
                    print("❌ [Haptics] エンジンがnil、フォールバック")
                    throw NSError(domain: "HapticsPlayer", code: 0, userInfo: nil)
                }
                print("🎵 [Haptics] パラメータ - intensity: 1.0, sharpness: 1.0, duration: \(duration)秒（Transient + Continuous併用）")
                // 長振動：最初に強い衝撃を与えてから連続振動
                var events: [CHHapticEvent] = []
                // 最初の強い衝撃
                events.append(CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                    ],
                    relativeTime: 0
                ))
                // 連続振動
                events.append(CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                    ],
                    relativeTime: 0,
                    duration: duration
                ))
                let pattern = try CHHapticPattern(events: events, parameters: [])
                let player = try engine?.makePlayer(with: pattern)
                try player?.start(atTime: 0)
                print("✅ [Haptics] CoreHaptics長振動再生成功")
                return
            } catch {
                print("❌ [Haptics] CoreHaptics長振動再生エラー、フォールバック: \(error)")
                // フォールバックへ
            }
        } else {
            print("⚠️ [Haptics] CoreHapticsがサポートされていない、フォールバック")
        }
        #endif

        #if canImport(UIKit)
        print("🎵 [Haptics] UIImpactFeedbackGeneratorでフォールバック再生（長振動）")
        if impactGenerator == nil { prepareEngine() }
        guard let g = impactGenerator else {
            print("❌ [Haptics] UIImpactFeedbackGenerator取得失敗")
            return
        }
        g.prepare()
        let slot = Self.vibrationDuration
        let steps = max(1, Int(duration / slot))
        print("🎵 [Haptics] \(steps)回に分割して再生")
        for i in 0..<steps {
            print("🎵 [Haptics] impactOccurred (\(i+1)/\(steps))")
            g.impactOccurred()
            do {
                try await Task.sleep(nanoseconds: UInt64(slot * 1_000_000_000))
            } catch {
                print("❌ [Haptics] sleep中断")
                break
            }
        }
        print("✅ [Haptics] フォールバック長振動再生完了")
        #endif
    }
}

// MARK: - Volume button (best effort)

@MainActor
final class VolumeButtonObserver {
    var onPress: (() -> Void)?
    var onCommit: (() -> Void)?

    private var isEnabled = false
    private var lastVolume: Float?
    private var observation: NSKeyValueObservation?
    #if canImport(MediaPlayer) && canImport(UIKit)
    private var volumeView: MPVolumeView?
    #endif
    private var isResetting = false

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled

        if enabled {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        #if canImport(AVFoundation)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true, options: [])
            print("[VolumeButton] AVAudioSession activated successfully")
        } catch {
            // 失敗してもボタン送信があるので致命的ではない
            print("[VolumeButton] AVAudioSession activation failed: \(error.localizedDescription)")
        }

        // MPVolumeViewを初期化（音量設定用）
        #if canImport(MediaPlayer) && canImport(UIKit)
        if volumeView == nil {
            volumeView = MPVolumeView(frame: .zero)
            volumeView?.showsRouteButton = false
            volumeView?.showsVolumeSlider = true
            print("[VolumeButton] MPVolumeView created")
        }
        #endif

        // 音量監視を開始（エラーハンドリング付き）
        lastVolume = AVAudioSession.sharedInstance().outputVolume
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            
            // リセット中の音量変化は無視
            if self.isResetting {
                return
            }
            
            let newValue = change.newValue ?? 0
            // 初回や同値通知を避ける
            if let last = self.lastVolume, abs(last - newValue) < 0.0001 {
                return
            }
            self.lastVolume = newValue
            Task { @MainActor in
                self.onPress?()
            }
        }
        print("[VolumeButton] Volume observation started")
        #endif
    }

    private func stop() {
        observation?.invalidate()
        observation = nil
    }
    
    /// 送信完了後に音量を0%にリセット
    func resetVolumeAfterSend() {
        Task { @MainActor in
            self.isResetting = true
            
            #if canImport(MediaPlayer) && canImport(UIKit)
            guard let volumeView = self.volumeView else {
                self.isResetting = false
                return
            }
            
            // MPVolumeViewからスライダーを取得して音量を設定
            for subview in volumeView.subviews {
                if let slider = subview as? UISlider {
                    let targetVolume: Float = 0.0
                    slider.value = targetVolume
                    self.lastVolume = targetVolume
                    print("[VolumeButton] 音量を\(targetVolume)にリセット（送信完了後）")
                    break
                }
            }
            #endif
            
            // リセット後、少し待ってからフラグを解除
            do {
                try await Task.sleep(nanoseconds: 300_000_000) // 300ms
            } catch {
                // キャンセルされても問題なし
            }
            self.isResetting = false
        }
    }
}

struct VolumeViewHost: View {
    var body: some View {
        #if canImport(UIKit) && canImport(MediaPlayer)
        VolumeViewRepresentable()
        #else
        EmptyView()
        #endif
    }
}

#if canImport(UIKit) && canImport(MediaPlayer)
private struct VolumeViewRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        view.showsVolumeSlider = false
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
#endif

#Preview {
    ContentView()
        .environmentObject(AppModel())
}
