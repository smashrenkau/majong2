# majoing3（Firebaseで回数→相手が回数分ハプティクス）

2台のiPhoneで同じアプリを起動し、Firestore経由で「押下回数（1〜6）」を相手に送って、相手端末が同回数だけ振動します（双方向）。

## 前提

- **フォアグラウンド利用**前提（ポケットに入れて利用）
- 通信: Firebase（Cloud Firestore）
- 認証: Firebase **Anonymous Auth**

## セットアップ手順（Firebase Console）

1. Firebaseプロジェクトを作成
2. iOSアプリを追加（Bundle IDは `com.okugawa.majoing3`）
3. `GoogleService-Info.plist` をダウンロードしてXcodeプロジェクトに追加
   - このリポジトリには既に `majoing3/Preview Content/GoogleService-Info.plist` が入っています（Bundle ID一致が前提）
4. Authentication → **Anonymous** を有効化
5. Firestore Database を作成
6. Firestore Rules を `firestore.rules` の内容に差し替え（ルーム参加者のみ読み書き可）

## 使い方

1. 2台のiPhoneでアプリを起動
2. 片方で「ルーム作成」→表示されたルームIDを相手に共有
3. 相手がルームIDを入力して「参加」
4. 送信側で以下のどちらかを実行
   - **テスト送信**: `1〜6` ボタン
   - **カウント確定送信**: 「押下（音量ボタン代替）」を連打 → 最後の押下から **0.6秒** 無操作で確定送信
5. 受信側が **同回数だけ** ハプティクス

## 音量ボタン入力（ベストエフォート）

UIの「音量ボタン入力を有効にする」をONにすると、`outputVolume` の変化を監視して押下扱いにします。

注意:
- iOSは物理音量ボタンを公式に直接フックできません
- システム音量が上下限付近だと反応しない/不安定になる場合があります
- そのため **テスト送信ボタンは常に残しています**

