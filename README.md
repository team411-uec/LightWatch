# LightWatch

LightWatchはmacOSのメニューバー常駐アプリです。Webカメラ画像の明るさ変化を監視し、設定したDiscord Webhookへ通知します。

## 動作要件

- macOS 13以降
- Python 3.11以降
- Macに接続されたWebカメラ
- Discord Webhook URL

## ビルド

開発環境を作成します。

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -e ".[dev]"
```

アプリを起動します。

```sh
lightwatch
```

配布用アプリとDMGは次のコマンドで作成します。

```sh
installer/macos/build-app.sh 0.0.0
```

## 初回起動

```sh
lightwatch
```

初回起動時にmacOSのカメラ権限ダイアログが出ます。許可しない場合、監視は開始できません。

## Webhook URLの設定

メニューバーの電球アイコンから`設定を開く`を選び、`Discord Webhook URL`へDiscordのWebhook URLを入力して保存します。

同じ設定画面で、使用するカメラ番号も選択できます。SplitCamを使う場合は、SplitCamを起動して仮想カメラを作成してからカメラ欄で番号を選んで保存します。

`判定`タブの設定は`保存`を押したあと、次の監視処理から使われます。

Discord通知は`🟢人がいます`または`⚪人がいません`の一行です。

## 判定設定

光判定は、MediaPipeで人物領域を除外したうえで、端のpositive ROIの中央値と明るいピクセル比率を使います。人物領域に隠れて監視領域の有効ピクセルが不足するフレームでは状態を変えません。アプリ起動時は常に消灯中から始まり、監視領域の明るい状態または暗い状態が確認時間だけ続いた場合に状態を確定します。画像基準との比較や短期比較は使いません。

設定ファイルは次の場所に保存されます。

```text
~/Library/Application Support/LightWatch/config.json
```

アプリ上で設定できない場合は、初回起動後に作成される`config.json`を開き、既存の`discordWebhookURL`の値を書き換えます。他のキーは削除しないでください。

## 常駐運用

ビルド済みの`LightWatch.app`を任意の場所へ配置して起動します。ログイン時起動を使う場合は、`/Applications`へ置いてから設定する運用にしてください。

1. `LightWatch.app`を起動します。
2. カメラ権限を許可します。
3. メニューバーの電球アイコンから`設定を開く`を選びます。
4. `Discord Webhook URL`を保存します。
5. SplitCamを使う場合は、カメラ欄でSplitCamを選んで保存します。
6. `ログイン時に起動`を有効にします。

アプリはメニューバーにアイコンだけで常駐します。Dockには表示されません。

## 動作確認

起動できているかは次のコマンドで確認できます。

```sh
pgrep -fl LightWatch
```

初回起動後に`config.json`が作成されていれば、設定保存先は動作しています。

## ログ

メニューバーの電球アイコンから`ログを開く`を選ぶとログディレクトリを開けます。

```text
~/Library/Application Support/LightWatch/logs/
```

通常の明るさサンプルと状態遷移はログへ保存しません。カメラ、Webhook、設定のエラーだけを`errors.log`へ記録します。

Webhook URLが未設定の場合、通知は送信されず、`errors.log`に記録されます。
