# NomadPad Server

**iPhone/iPadをMacのワイヤレストラックパッドに。**

NomadPad Serverは、[NomadPad iOSアプリ](https://apps.apple.com/app/nomadpad)からの入力を受け取り、Macのマウス、キーボード、ジェスチャーを制御するmacOSコンパニオンアプリです。

## 機能

- ワイヤレストラックパッド操作
- マウス移動、クリック、スクロール
- キーボード入力
- マルチフィンガージェスチャー（右クリック、スクロール、Spaces切り替え）
- TLS + 事前共有鍵（QRコードペアリング）による安全な接続

## 動作環境

- macOS 14.0以降
- アクセシビリティ権限（マウス/キーボード制御に必要）

## インストール

1. [Releases](https://github.com/r1cA18/NomadPadServer/releases)から最新版をダウンロード
2. `NomadPadServer.app`をアプリケーションフォルダに移動
3. アプリを起動
4. アクセシビリティ権限を許可
5. NomadPad iOSアプリでQRコードをスキャン

## ソースからビルド

```bash
git clone https://github.com/r1cA18/NomadPadServer.git
cd NomadPadServer
open NomadPadServer/NomadPadServer.xcodeproj
```

Xcodeでビルド・実行。

## アーキテクチャ

- **NomadPadServer**: ネットワーク接続と入力処理を行うメニューバーアプリ
- **NomadPadHelper**: システムレベルのキーボードショートカット用ログインアイテムヘルパー（Spaces切り替え）
- **Shared**: 共通プロトコル定義

## セキュリティ

- すべての接続はTLS（事前共有鍵）で暗号化
- ペアリングはQRコードで行われ、鍵はネットワーク上を流れない
- 鍵はmacOSキーチェーンに安全に保存

## ライセンス

MIT License - 詳細は[LICENSE](LICENSE)を参照。

## 関連

- [NomadPad iOSアプリ](https://apps.apple.com/app/nomadpad) - iOSコンパニオンアプリ
