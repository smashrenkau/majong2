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
                    volumeSection
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
            Text("相手に約4秒の連続振動を送ります。音量ボタン長押しでも送信できます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                Task { await appModel.sendLongVibration() }
            } label: {
                Text("長振動を送信")
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
            LabeledRow(label: "相手", value: appModel.peerJoined ? "参加中" : (appModel.roomId == nil ? "—" : "未参加"))
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var sendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "シフト回数")

            Text("音量ボタンが取れない場合に備えて、必ずボタン送信も残しています。")
                .font(.footnote)
                .foregroundStyle(.secondary)

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

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "音量ボタン（ベストエフォート）")

            Text("ルーム入室中は常に音量ボタン入力を有効にしています。iOSは物理音量ボタンを公式にフックできないため、音量変化（outputVolume）を監視して押下扱いにしています。システム音量が上下限付近だと反応しない場合があります。")
                .font(.footnote)
                .foregroundStyle(.secondary)
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

        self.volumeButtonObserver.onPress = { [weak self] in
            guard let self else { return }
            let now = Date()
            if let until = self.longPressCooldownUntil, now < until {
                return
            }
            self.recentPressTimestamps.append(now)
            self.recentPressTimestamps.removeAll { now.timeIntervalSince($0) > 2.0 }
            if self.recentPressTimestamps.count >= 4,
               let first = self.recentPressTimestamps.first,
               now.timeIntervalSince(first) >= 1.0 {
                self.recentPressTimestamps.removeAll()
                self.longPressCooldownUntil = now.addingTimeInterval(2.0)
                Task { await self.sendLongVibration() }
                return
            }
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
        if !firebaseConfigured {
            configureFirebaseIfPossible()
            print("[DEBUG] startIfNeeded after configure firebaseConfigured=\(firebaseConfigured)")
        }

        if myUid == nil, firebaseConfigured {
            print("[DEBUG] startIfNeeded calling signInAnonymously")
            await signInAnonymously()
            print("[DEBUG] startIfNeeded after signIn myUid=\(myUid ?? "nil")")
        }

        networkMonitor.start()
        print("[DEBUG] startIfNeeded done")
    }

    private func configureFirebaseIfPossible() {
        guard FirebaseApp.app() == nil else {
            firebaseConfigured = true
            return
        }

        // GoogleService-Info.plist が無いと configure が失敗し得るので、存在チェックを入れる
        let hasPlist = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil
        guard hasPlist else {
            firebaseConfigured = false
            lastErrorMessage = "GoogleService-Info.plist が見つかりません（Firebase未構成）"
            return
        }

        FirebaseApp.configure()
        firebaseConfigured = true
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
                Task { await self.hapticsPlayer.playLong(duration: 4.0) }
            } else {
                self.logs.insert(LogItem(kind: .rx, count: event.count, date: Date()), at: 0)
                Task { await self.hapticsPlayer.play(count: event.count) }
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

    private var debounceTask: Task<Void, Never>?
    private var cooldownTask: Task<Void, Never>?

    func press() {
        guard !isCoolingDown else { return }

        currentCount = min(currentCount + 1, 9)

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 600_000_000) // 0.6s
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

    /// 1回の振動の長さ（秒）。着信バイブに近づけるため長め（APIの強度は0〜1で上限のため、長さで補う）
    private static let vibrationDuration: Double = 1.0
    /// 振動と振動の間隔（秒）。長い振動のあと区切りをはっきり
    private static let gapBetweenVibrations: Double = 0.15
    /// 1回分のスロット（振動＋間隔）
    private static let slotDuration: Double = vibrationDuration + gapBetweenVibrations

    /// ルーム入室時に呼び、エンジンを事前起動しておく（初回再生時の弱い振動を防ぐ）
    func prepareEngine() {
        #if canImport(CoreHaptics)
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        guard engine == nil else { return }
        do {
            engine = try CHHapticEngine()
            try engine?.start()
        } catch {
            engine = nil
        }
        #endif
        #if canImport(UIKit)
        if impactGenerator == nil {
            impactGenerator = UIImpactFeedbackGenerator(style: .heavy)
            impactGenerator?.prepare()
        }
        #endif
    }

    func play(count: Int) async {
        guard count > 0 else { return }

        #if canImport(CoreHaptics)
        if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            do {
                if engine == nil { prepareEngine() }
                guard engine != nil else { throw NSError(domain: "HapticsPlayer", code: 0, userInfo: nil) }

                // 回数どおり N 回、CoreHaptics で連続振動（1秒）を N 回。強度・シャープネス最大で着信バイブに近い長さ
                let events: [CHHapticEvent] = (0..<count).map { i in
                    CHHapticEvent(
                        eventType: .hapticContinuous,
                        parameters: [
                            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                            CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                        ],
                        relativeTime: Double(i) * Self.slotDuration,
                        duration: Self.vibrationDuration
                    )
                }
                let pattern = try CHHapticPattern(events: events, parameters: [])
                let player = try engine?.makePlayer(with: pattern)
                try player?.start(atTime: 0)
                return
            } catch {
                // フォールバックへ
            }
        }
        #endif

        #if canImport(UIKit)
        if impactGenerator == nil { prepareEngine() }
        guard let g = impactGenerator else { return }
        g.prepare()
        for _ in 0..<count {
            g.impactOccurred()
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.vibrationDuration * 1_000_000_000))
            } catch {
                break
            }
        }
        #endif
    }

    /// 長時間の連続振動（例: 音量ボタン長押しで約4秒）
    func playLong(duration: TimeInterval) async {
        guard duration > 0 else { return }

        #if canImport(CoreHaptics)
        if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            do {
                if engine == nil { prepareEngine() }
                guard engine != nil else { throw NSError(domain: "HapticsPlayer", code: 0, userInfo: nil) }
                let event = CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                    ],
                    relativeTime: 0,
                    duration: duration
                )
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                let player = try engine?.makePlayer(with: pattern)
                try player?.start(atTime: 0)
                return
            } catch {
                // フォールバックへ
            }
        }
        #endif

        #if canImport(UIKit)
        if impactGenerator == nil { prepareEngine() }
        guard let g = impactGenerator else { return }
        g.prepare()
        let slot = Self.vibrationDuration
        let steps = max(1, Int(duration / slot))
        for _ in 0..<steps {
            g.impactOccurred()
            do {
                try await Task.sleep(nanoseconds: UInt64(slot * 1_000_000_000))
            } catch {
                break
            }
        }
        #endif
    }
}

// MARK: - Volume button (best effort)

@MainActor
final class VolumeButtonObserver {
    var onPress: (() -> Void)?

    private var isEnabled = false
    private var lastVolume: Float?
    private var observation: NSKeyValueObservation?

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
        } catch {
            // 失敗してもボタン送信があるので致命的ではない
        }

        lastVolume = AVAudioSession.sharedInstance().outputVolume
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let self else { return }
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
        #endif
    }

    private func stop() {
        observation?.invalidate()
        observation = nil
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
