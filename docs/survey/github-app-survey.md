# GitHub App サーベイ — 仕組み・ユースケース・ベストプラクティス

## 目次

1. [GitHub App とは](#1-github-app-とは)
2. [認証の仕組み](#2-認証の仕組み)
3. [主要ケーパビリティ](#3-主要ケーパビリティ)
4. [ユースケース別カテゴリ](#4-ユースケース別カテゴリ)
5. [GitHub App vs OAuth App](#5-github-app-vs-oauth-app)
6. [アーキテクチャパターン](#6-アーキテクチャパターン)
7. [注目すべき実運用事例](#7-注目すべき実運用事例)
8. [セキュリティのベストプラクティス](#8-セキュリティのベストプラクティス)
9. [ArgoCD Image Updater との連携](#9-argocd-image-updater-との連携)

---

## 1. GitHub App とは

GitHub が提供する公式のインテグレーション機構。外部ツールやサービスが GitHub と安全に連携するための仕組みであり、GitHub は OAuth App よりも GitHub App の利用を推奨している。

### 基本的な特徴

- **App（bot）として動作** — 個人ユーザーに紐づかず、`app-name[bot]` として操作が記録される
- **細粒度の権限制御** — リポジトリ単位・操作種別単位で必要最小限の権限のみ付与可能
- **短命トークン** — Installation Access Token は1時間で自動失効
- **Organization 単位の管理** — 管理者がインストール・権限を一元制御
- **Marketplace** — GitHub Marketplace で公開・配布が可能

---

## 2. 認証の仕組み

### トークン発行フロー

```
1. GitHub 上で App を登録（名前・権限・対象リポを設定）
2. 秘密鍵（Private Key）が発行される
3. 秘密鍵で JWT を生成（有効期限10分）
4. JWT を使って Installation Access Token を取得（有効期限1時間）
5. Installation Access Token で GitHub API / Git 操作を実行
```

### トークンの種類

| トークン | 用途 | 有効期限 |
|---|---|---|
| JWT | App として認証、Installation Token の取得 | 10分 |
| Installation Access Token | リポジトリ操作（API / Git push 等） | 1時間 |
| User-to-Server Token | ユーザーの代理操作（OAuth-like フロー） | 8時間 |

### 権限スコープの例

```yaml
permissions:
  contents: write      # リポジトリ内容の読み書き
  pull_requests: write # PR の作成・更新
  checks: write        # Checks の作成・更新
  issues: read         # Issue の読み取り
  metadata: read       # リポジトリメタデータの読み取り（必須）
```

---

## 3. 主要ケーパビリティ

### Webhook イベント

GitHub App は 70 以上のイベントを受信可能。主要なもの:

| イベント | 説明 |
|---|---|
| `push` | コードプッシュ |
| `pull_request` | PR 作成・更新・マージ |
| `issues` | Issue 操作 |
| `check_run` / `check_suite` | CI 結果 |
| `deployment` / `deployment_status` | デプロイイベント |
| `installation` | App のインストール・アンインストール |
| `repository` | リポジトリ作成・削除 |
| `release` | リリース公開 |

### Checks API

- PR 上にチェック結果を表示（成功 / 失敗 / 中立）
- **行単位のアノテーション**付きでフィードバック可能
- 複数チェックの並行実行をサポート
- **OAuth App では利用不可** — GitHub App 固有の機能

### Deployments API

- デプロイ状態の管理（pending → in_progress → success / failure）
- PR 上にデプロイ結果を表示
- 環境（production / staging 等）の管理

### Content / Git Data API

- ファイルの読み書き
- ブランチ・タグ・コミットの操作
- Git push（Installation Access Token 経由）

---

## 4. ユースケース別カテゴリ

### 4.1 CI/CD

| App | 概要 |
|---|---|
| CircleCI | GitHub App として連携し、PR ごとにビルド・テスト実行 |
| Buildkite | Checks API を活用したビルドステータス報告 |
| Travis CI | push / PR 契機のビルド自動化 |
| Jenkins | GitHub Branch Source Plugin による連携 |

### 4.2 コードレビュー・品質管理

| App | 概要 |
|---|---|
| SonarCloud | コード品質・技術的負債の自動分析 |
| Codecov | カバレッジレポートを PR にコメント |
| Code Climate | コード品質メトリクス、メンテナビリティスコア |
| Reviewdog | lint 結果を PR のレビューコメントとして投稿 |

### 4.3 セキュリティ

| App | 概要 |
|---|---|
| Dependabot | GitHub 公式の依存関係脆弱性検出・自動 PR 作成 |
| Snyk | 脆弱性スキャンとセキュリティ修正 PR 自動生成 |
| GitGuardian | シークレット（API キー等）漏洩検出 |
| Socket | サプライチェーン攻撃検出 |

### 4.4 プロジェクト管理

| App | 概要 |
|---|---|
| Jira for GitHub | Jira チケットと GitHub PR の双方向連携 |
| Linear | Issue と Linear タスクの自動同期 |
| ZenHub | GitHub 上のアジャイルプロジェクト管理 |

### 4.5 デプロイメント

| App | 概要 |
|---|---|
| Vercel | PR ごとのプレビューデプロイ自動生成 |
| Netlify | 静的サイトのプレビューデプロイ |
| Heroku (Review Apps) | PR ベースの一時環境 |

### 4.6 通知・モニタリング

| App | 概要 |
|---|---|
| Slack + GitHub | PR イベント等の Slack 通知 |
| Microsoft Teams | Teams 上で GitHub 通知 |
| PagerDuty | インシデント管理連携 |
| Datadog | デプロイイベントのモニタリング連携 |

### 4.7 依存関係管理

| App | 概要 |
|---|---|
| Dependabot | 依存関係の自動更新 PR（GitHub 公式） |
| Renovate | 高度なカスタマイズが可能な依存関係更新。monorepo 対応 |

### 4.8 AI 支援

| App | 概要 |
|---|---|
| GitHub Copilot | AI コード補完（GitHub App 基盤を活用） |
| CodeRabbit | AI による PR 自動レビュー |
| Sweep | AI による Issue からの自動 PR 作成 |

### 4.9 Bot・自動化

| App | 概要 |
|---|---|
| Mergify | 条件ベースの自動マージルール設定 |
| Release Drafter | リリースノート自動生成 |
| Stale Bot | 非アクティブな Issue/PR の自動クローズ |
| Semantic Release | セマンティックバージョニング自動化 |
| auto-assign | PR レビュアーの自動割当 |

---

## 5. GitHub App vs OAuth App

### 比較表

| 観点 | GitHub App | OAuth App |
|---|---|---|
| 認証主体 | **App（bot）** として動作 | ユーザーとして動作 |
| 権限粒度 | リポジトリ単位・操作種別単位で**細かく制御** | scope ベースで粗い |
| インストール単位 | Organization / リポジトリ単位 | ユーザー単位 |
| トークン寿命 | **1時間**（Installation Token） | 長期間有効 |
| Checks API | **利用可能** | 利用不可 |
| レート制限 | インストールあたり 5,000/時 | ユーザーあたり 5,000/時 |
| Webhook | App 単位で一元管理 | ユーザーが個別設定 |
| 監査ログ | App 名で記録 | 個人名で記録 |
| 推奨度 | **GitHub 公式が推奨** | レガシー寄り |

### 選択基準

**GitHub App を選ぶべきケース:**
- CI/CD、Bot、自動化ツールなどユーザーに紐づかない操作
- 細かい権限制御が必要な場合
- Checks API を使いたい場合
- Organization の管理者が一括管理したい場合

**OAuth App を選ぶべきケース:**
- ユーザーの代理として操作する Web アプリ（例: ダッシュボード）
- ユーザー認証フロー（ログイン機能）がメイン目的の場合
- ただし、GitHub App でも user-to-server token で代替可能な場合が多い

---

## 6. アーキテクチャパターン

### パターン 1: Webhook 駆動型

```
GitHub Event → Webhook → App Server → GitHub API で応答
```

- **用途**: Bot、自動ラベル付け、通知
- **例**: Stale Bot, auto-assign

### パターン 2: Checks API 統合型

```
Push/PR → Webhook → App Server → 解析実行 → Checks API で結果報告
```

- **用途**: CI、静的解析、セキュリティスキャン
- **例**: SonarCloud, Codecov

### パターン 3: スケジュール駆動型

```
Cron → App Server → GitHub API でリポジトリ操作
```

- **用途**: 依存関係更新、stale リソース管理
- **例**: Dependabot, Renovate

### パターン 4: ユーザー承認フロー型

```
User → OAuth-like flow → User-to-Server Token → ユーザー代理操作
```

- **用途**: Web ダッシュボード、ユーザー設定画面
- **例**: ZenHub, Vercel の設定画面

---

## 7. 注目すべき実運用事例

### Vercel

- PR が作成されるたびにプレビューデプロイを自動生成
- Checks API でデプロイ結果を PR 上に表示
- Deployments API でデプロイ状態を管理
- 数百万のリポジトリで稼働

### Dependabot

- 元々は独立した GitHub App として開発（Dependabot 社）
- GitHub が買収し公式機能に統合
- 依存関係の脆弱性検出と自動更新 PR の作成
- GitHub App のサクセスストーリーの代表例

### Renovate（Mend）

- Dependabot の高機能代替
- 複雑な monorepo 対応、グルーピング、スケジューリング
- 大規模 OSS プロジェクト（Kubernetes 等）で採用

### CodeRabbit

- AI を活用した PR 自動レビュー
- GitHub App としてインストールし、全 PR に自動でレビューコメント
- AI + GitHub App 統合の代表例

### Probot エコシステム

- GitHub 公式の App 構築フレームワーク（Node.js）
- stale（非アクティブ Issue 管理）、settings（リポジトリ設定のコード管理）等が有名
- コミュニティ App が多数構築されている

---

## 8. セキュリティのベストプラクティス

### 権限設定

- **最小権限の原則** — 必要な権限のみ付与。`contents: write` が不要なら `read` に留める
- **リポジトリの限定** — 「All repositories」ではなく「Only select repositories」を選択
- **定期的な権限レビュー** — 不要になった権限やリポジトリを削除

### 秘密鍵の管理

- 秘密鍵は Kubernetes Secret や Vault 等のシークレット管理ツールに保管
- 環境変数やコードに直接埋め込まない
- 定期的にローテーション（GitHub の App 設定画面から新しい鍵を生成し、古い鍵を削除）

### Webhook のセキュリティ

- **Webhook Secret** を設定し、リクエストの署名を検証する
- HTTPS エンドポイントのみを使用
- ペイロードの内容をバリデーションしてから処理

### 監査

- GitHub の監査ログで App の操作履歴を確認
- Installation Access Token の発行・利用状況を監視

---

## 9. ArgoCD Image Updater との連携

ArgoCD Image Updater が Git write-back 方式でイメージタグを更新する際、GitHub App を認証手段として利用できる。

### なぜ GitHub App が推奨されるか

| 方式 | トークン寿命 | スコープ | ローテーション |
|---|---|---|---|
| SSH Deploy Key | 無期限 | リポジトリ単位 | 手動 |
| Personal Access Token | 最大無期限 | ユーザー権限に依存 | 手動 |
| **GitHub App** | **1時間** | **リポ単位・操作単位で限定** | **自動** |

### 設定手順

1. **GitHub App を作成** — `contents: write` 権限を付与し、対象リポにインストール
2. **秘密鍵を Secret として保存**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: github-app-creds
  namespace: argocd
type: Opaque
data:
  github-app-id: <base64 エンコードした App ID>
  github-app-installation-id: <base64 エンコードした Installation ID>
  github-app-private-key: <base64 エンコードした秘密鍵>
```

3. **Image Updater の annotation で指定**

```yaml
metadata:
  annotations:
    argocd-image-updater.argoproj.io/write-back-method: git
    argocd-image-updater.argoproj.io/git-credentials: secret:argocd/github-app-creds
```

### メリット

- 個人に依存しない（退職・異動の影響を受けない）
- トークンが短命で漏洩リスクが低い
- `app/image-updater[bot]` として commit が記録され、監査が容易
- 対象リポジトリと権限を最小限に限定可能
