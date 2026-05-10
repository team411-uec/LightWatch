# LightWatch

LightWatchはmacOSのメニューバー常駐アプリです。Webカメラ画像の明るさ変化を監視し、設定したDiscord Webhookへ通知します。

## 動作要件

- macOS 13以降
- Xcode 15.4以降
- Mac miniに接続されたWebカメラ
- Discord Webhook URL

## ビルド

```sh
xcodebuild -project LightWatch.xcodeproj -scheme LightWatch -configuration Debug -derivedDataPath build build
```

生成されたアプリは`build/Build/Products/Debug/LightWatch.app`です。

## 初回起動

```sh
open build/Build/Products/Debug/LightWatch.app
```

初回起動時にmacOSのカメラ権限ダイアログが出ます。許可しない場合、監視は開始できません。

## Webhook URLの設定

メニューバーの`LightWatch`から`設定を開く`を選び、`Discord Webhook URL`へDiscordのWebhook URLを入力して保存します。

設定ファイルは次の場所に保存されます。

```text
~/Library/Application Support/LightWatch/config.json
```

アプリ上で設定できない場合は、初回起動後に作成される`config.json`を開き、既存の`discordWebhookURL`の値を書き換えます。他のキーは削除しないでください。

## Mac miniでの常駐

1. `LightWatch.app`を起動します。
2. カメラ権限を許可します。
3. メニューバーの`LightWatch`から`設定を開く`を選びます。
4. `Discord Webhook URL`を保存します。
5. `ログイン時に起動`を有効にします。

アプリはメニューバーに常駐します。Dockには表示されません。

## ログ

メニューバーの`LightWatch`から`ログを開く`を選ぶとログディレクトリを開けます。

```text
~/Library/Application Support/LightWatch/logs/
```

- `samples.jsonl`: ROIごとの明るさサンプル
- `events.jsonl`: 状態遷移と通知イベント
- `errors.log`: カメラ、Webhook、設定のエラー

Webhook URLが未設定の場合、通知は送信されず、`errors.log`に記録されます。
