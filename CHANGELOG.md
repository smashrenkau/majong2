# 変更履歴

## 2026-02-10 - TestFlightクラッシュ修正

### 問題
TestFlightでアプリを配布後、アプリ起動時にクラッシュが発生。

### 原因
1. **GoogleService-Info.plistの配置ミス**
   - `Preview Content`フォルダ内にあり、リリースビルドに含まれていなかった

2. **Firebase二重初期化**
   - `majoing3App.swift`の`init()`と`configureFirebaseIfPossible()`で二重に呼ばれていた

3. **プラットフォーム設定の問題**
   - macOSもサポート対象に含まれており、entitlementsにmacOS用の設定が含まれていた

### 修正内容

#### 1. GoogleService-Info.plistの移動
- `majoing3/Preview Content/GoogleService-Info.plist` → `majoing3/GoogleService-Info.plist`
- `project.pbxproj`のファイル参照を更新

#### 2. Firebase初期化の修正
- `majoing3App.swift`の`init()`から`FirebaseApp.configure()`を削除
- `startIfNeeded()`内の`configureFirebaseIfPossible()`のみで初期化

#### 3. entitlementsの修正
- macOS用の`com.apple.security.app-sandbox`を削除
- iOS用の最小限の設定に変更

#### 4. プロジェクト設定の修正
- `SDKROOT`を`auto`から`iphoneos`に変更
- `SUPPORTED_PLATFORMS`から`macosx`を除外
- `SUPPORTS_MACCATALYST`を`NO`に設定
- macOS用の設定を削除:
  - `MACOSX_DEPLOYMENT_TARGET`
  - `ENABLE_HARDENED_RUNTIME`
  - macOS用の`LD_RUNPATH_SEARCH_PATHS`

#### 5. エラーハンドリングの改善
- `configureFirebaseIfPossible()`にデバッグログ追加
- `VolumeButtonObserver.start()`のエラーハンドリング強化
- より詳細なログ出力

### ビルド手順

1. Xcodeでプロジェクトを開く
2. Product → Clean Build Folder (Shift + Cmd + K)
3. Product → Archive
4. TestFlightにアップロード

### 確認事項
- GoogleService-Info.plistが`majoing3/`直下にあること
- Bundle IDが`com.okugawa.majoing3`であること
- Firebase Consoleで該当のBundle IDが登録されていること
- Firestore Rulesがデプロイされていること
- Anonymous Authenticationが有効になっていること
