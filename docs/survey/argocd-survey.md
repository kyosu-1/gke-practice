# ArgoCD サーベイ — アーキテクチャ・仕組み・ベストプラクティス

## 目次

1. [コアアーキテクチャ](#1-コアアーキテクチャ)
2. [Sync メカニズム](#2-sync-メカニズム)
3. [ヘルスアセスメント](#3-ヘルスアセスメント)
4. [マルチテナンシーモデル](#4-マルチテナンシーモデル)
5. [アプリケーションデリバリーパターン](#5-アプリケーションデリバリーパターン)
6. [GitOps 原則の実装](#6-gitops-原則の実装)
7. [リポジトリ構造のベストプラクティス](#7-リポジトリ構造のベストプラクティス)
8. [セキュリティのベストプラクティス](#8-セキュリティのベストプラクティス)
9. [パフォーマンスとスケーラビリティ](#9-パフォーマンスとスケーラビリティ)
10. [運用ベストプラクティス](#10-運用ベストプラクティス)
11. [CI/CD 統合パターン](#11-cicd-統合パターン)
12. [よくある落とし穴とアンチパターン](#12-よくある落とし穴とアンチパターン)
13. [ArgoCD vs Flux CD 比較](#13-argocd-vs-flux-cd-比較)

---

## 1. コアアーキテクチャ

ArgoCD は複数の独立したコンポーネントから構成され、それぞれが Kubernetes 上で個別の Pod としてデプロイされる。コンポーネント間通信は gRPC を使用し、TLS で暗号化される。

### 1.1 API Server (`argocd-server`)

- **デプロイ形態**: ステートレス Deployment
- **ポート**: 8080 (gRPC/HTTPS ゲートウェイ)
- **役割**: Web UI、CLI (`argocd`)、CI/CD システムが利用する REST/gRPC API を公開する中央ハブ。認証・認可の処理、RBAC ポリシーの適用、リクエストのバックエンドへのルーティングを担う。
- **データ管理**: ユーザー認証情報は Kubernetes Secret に、設定は ConfigMap に、Application / AppProject / ApplicationSet などの CRD は etcd に保存。
- **通信先**: Repo Server (gRPC)、Redis (キャッシュ)、Kubernetes API (CRD 読み書き)、Dex (認証)
- **障害時の影響**: UI と CLI が使用不可になるが、Application Controller の Reconciliation ループは独立して動作を継続するため、**同期処理自体は停止しない**。水平スケーリング可能。

### 1.2 Application Controller (`argocd-application-controller`)

- **デプロイ形態**: **StatefulSet** (他コンポーネントと異なる)
- **ポート**: 8082 (メトリクス)
- **役割**: ArgoCD の心臓部。Application CRD を監視し、Git 上の望ましい状態 (desired state) とクラスタ上の現在の状態 (live state) を継続的に比較し、差分を検出して同期処理を実行する。
- **内部構造**: 3つのワークキュー (refresh, operation, hydrate) を持ち、デフォルトで 10-20 の Reconciliation ワーカーが並行動作。
- **スケーリング**: シャーディングにより水平スケーリングをサポート。各レプリカが異なるクラスタを担当し、レプリカ数の変更時に動的にリシャーディングが行われる。
- **障害時の影響**: 状態の同期が完全に停止する。

### 1.3 Repository Server (`argocd-repo-server`)

- **デプロイ形態**: ステートレス Deployment
- **ポート**: 8081 (gRPC)
- **役割**: Git リポジトリとの対話を担当し、Kubernetes マニフェストの生成を行う。素の YAML、Helm チャート、Kustomize、カスタムプラグインをサポート。
- **キャッシュ戦略**: 生成されたマニフェストを Redis にキャッシュ。キーは `repo|revision|path|hash` の形式。デフォルトの有効期限は24時間。
- **Git ポーリング**: デフォルトで3分間隔。Webhook 構成で即座に反映も可能。
- **排他制御**: Redis ベースの分散ロックで、同一リビジョンに対する並行マニフェスト生成を防止。
- **障害時の影響**: 新しいマニフェストの生成が不可能になり、同期処理が停止する。ただしキャッシュ済みのマニフェストは Redis に残る。

### 1.4 Redis

- **デプロイ形態**: 単一 Pod、または HA モード (3 Sentinel 構成)
- **役割**: 分散キャッシュおよびロック機構。以下のデータをキャッシュ:
  - **Application state**: 各 Application の最新既知状態
  - **Manifest cache**: Repo Server が生成したマニフェスト
  - **Cluster cache**: 管理対象クラスタ上のリソースのライブ状態
  - **Git revision cache**: 追跡対象ブランチの最新コミット SHA
- **障害時の影響**: Kubernetes API および Git プロバイダへのリクエスト負荷が急増する。ただしデータは再生成可能であり、データ損失は発生しない。

### 1.5 Dex Server (`argocd-dex-server`)

- **デプロイ形態**: ステートレス Deployment
- **役割**: 外部 ID プロバイダ (GitHub、Google、Azure AD、Okta 等) を介した OIDC/SSO 認証プロキシ。

### 1.6 ApplicationSet Controller (`argocd-applicationset-controller`)

- **デプロイ形態**: ステートレス Deployment
- **役割**: ApplicationSet CRD を監視し、テンプレートとジェネレーターに基づいて複数の Application リソースを自動生成・管理する。

### 1.7 Notifications Controller (`argocd-notifications-controller`)

- **デプロイ形態**: ステートレス Deployment
- **役割**: Application リソースのイベント (sync 成功/失敗、ヘルス変化等) を監視し、Slack、Teams、GitHub、Email、PagerDuty 等へ通知を送信する。

### コンポーネント間の関係図

```
                    ┌─────────────────┐
                    │   Web UI / CLI  │
                    └────────┬────────┘
                             │ gRPC / REST
                    ┌────────▼────────┐
                    │   API Server    │◄──── Dex (SSO)
                    └───┬────────┬────┘
                        │        │
              ┌─────────▼──┐  ┌──▼──────────┐
              │ Repo Server │  │    Redis     │
              └─────────────┘  └──▲──────────┘
                                  │
                    ┌─────────────┴────────────┐
                    │  Application Controller  │
                    │     (StatefulSet)         │
                    └─────────────┬────────────┘
                                  │ Kubernetes API
                    ┌─────────────▼────────────┐
                    │    管理対象クラスタ        │
                    └──────────────────────────┘
```

---

## 2. Sync メカニズム

### 2.1 Reconciliation ループ

Application Controller が実行する継続的なループ:

| トリガー種別 | 間隔/条件 | 説明 |
|---|---|---|
| 定期リフレッシュ | 約3分 + ジッタ | ワークキュー経由でスケジュール |
| イベント駆動 | 即時 | Application CRD の変更を Kubernetes Watch API で検出 |
| Webhook | 即時 | Git リポジトリの変更を Webhook で通知 |
| 手動 | 即時 | API/UI/CLI 経由で明示的に同期実行 |

### 2.2 Diff エンジン (3-way diff)

ArgoCD の Diff エンジンは `gitops-engine` ライブラリに基づき、3つの状態を比較する:

1. **Desired State**: Repo Server が Git ソース (Helm/Kustomize 等) から生成したマニフェスト
2. **Live State**: Kubernetes API から取得した実際のクラスタ上のリソース
3. **Last Applied State**: `kubectl.kubernetes.io/last-applied-configuration` アノテーションに保存された前回適用時の設定

この 3-way diff により、ユーザーが意図的に変更した項目と、Kubernetes コントローラーが自動的に付与したデフォルト値を区別できる。

**比較前の正規化処理**:
- `ignoreDifferences` で指定されたフィールドをスキップ
- JSON Pointer または JQ パス式でフィールドを柔軟にマッチ

```yaml
# ignoreDifferences の設定例
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas        # HPA が管理するフィールドを無視
    - group: "*"
      kind: "*"
      managedFieldsManagers:
        - kube-controller-manager
```

**Diff 戦略**:

| 戦略 | 説明 |
|---|---|
| Legacy diff | 従来の kubectl 互換のクライアントサイド diff |
| Structured-merge-diff | Kubernetes の構造化マージパッチを利用 |
| Server-side diff | Kubernetes API の server-side apply を利用した差分検出 |

同期ステータスは比較結果に基づき **Synced**、**OutOfSync**、**Unknown** のいずれかに決定される。

### 2.3 Sync フェーズとフック

同期操作は3つのフェーズを順序的に実行する:

```
PreSync → Sync → PostSync
              ↓ (失敗時)
           SyncFail
```

| フェーズ | タイミング | 用途 |
|---|---|---|
| **PreSync** | リソース適用前 | DB マイグレーション、バックアップ、事前検証 |
| **Sync** | 通常のリソース適用 | アプリケーションのデプロイ |
| **PostSync** | Sync 成功後 | スモークテスト、通知、検証 |
| **SyncFail** | Sync 失敗時 | クリーンアップ、ロールバック |
| **PreDelete** | プルーニング前 | バックアップ取得 |
| **PostDelete** | プルーニング後 | クリーンアップ |

PreSync フックが失敗すると、同期プロセス全体が停止し、アプリケーションリソースには一切触れない。

```yaml
# フック定義例 (DB マイグレーション Job)
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
spec:
  template:
    spec:
      containers:
        - name: migrate
          image: myapp:latest
          command: ["./migrate.sh"]
      restartPolicy: Never
```

**フック削除ポリシー**:
- `HookSucceeded`: 成功後に削除
- `HookFailed`: 失敗後に削除
- `BeforeHookCreation`: 次のフック作成前に削除 (デフォルト)

### 2.4 Sync Wave (同期ウェーブ)

`argocd.argoproj.io/sync-wave` アノテーションでリソースの適用順序を制御する。値は整数で、小さい番号から順に適用。

```yaml
# Wave -1: まず Namespace を作成
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"

# Wave 0: デフォルト (アノテーション無し)

# Wave 1: 依存リソースの後に適用
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"
```

コントローラは次のウェーブに進む前に、現在のウェーブの全リソースが Healthy になるまで待機する。

### 2.5 Sync オプション

| オプション | 説明 |
|---|---|
| `Prune` | Git から削除されたリソースをクラスタからも削除 |
| `DryRun` | 変更のプレビューのみ (適用しない) |
| `Force` | kubectl の `--force` フラグを使用 |
| `ServerSideApply` | Kubernetes server-side apply を使用 |
| `ApplyOutOfSyncOnly` | ドリフトしたリソースのみ同期 |
| `CreateNamespace` | ターゲット namespace を自動作成 |
| `PruneLast` | 同期成功後にプルーニングを遅延実行 |
| `SkipDryRunOnMissingResource` | CRD 未存在時の dry-run エラーを回避 |

### 2.6 Self-Heal とリトライ

- **Self-Heal**: `selfHeal: true` により、クラスタ上のリソースが手動変更された場合に自動的に Git の状態に戻す
- **リトライ**: 指数バックオフを使用 (初期遅延 2秒、乗数 3倍、上限 300秒)。ジッタを加えてサンダリングハード問題を防止

### 2.7 Sync Window

時間ベースのウィンドウで同期操作を制御:

- **Allow window**: 指定時間内のみ同期を許可
- **Deny window**: メンテナンス中に同期をブロック
- auto-sync はブロック中にサイレントにスキップされる

### 2.8 リソーストラッキング方式

| 方式 | 追跡メカニズム | 特徴 |
|---|---|---|
| **label** (デフォルト) | `app.kubernetes.io/instance` ラベル | 後方互換性あり。セレクタ衝突リスクと 63 文字制限あり |
| **annotation** | `argocd.argoproj.io/tracking-id` アノテーション | セレクタに影響しない。文字数制限なし |
| **annotation+label** | 両方を使用 | 本番環境で最も推奨。正確な追跡 + 互換性 |

tracking-id のフォーマット: `<app-name>:<group>/<kind>:<namespace>/<name>`

---

## 3. ヘルスアセスメント

### 3.1 ヘルスステータスの種類

| ステータス | 意味 |
|---|---|
| **Healthy** | リソースが完全に正常に動作 |
| **Suspended** | 一時停止状態 (例: Rollout の Paused) |
| **Progressing** | まだ健全な状態に達していないが進行中 |
| **Missing** | Git 上に定義されているがクラスタに存在しない |
| **Degraded** | リソースが異常な状態 |
| **Unknown** | ヘルスを判定できない |

**Application 全体のヘルスは、子リソースの最も悪いステータスに集約される。**

### 3.2 ビルトインヘルスチェック

ArgoCD は主要な Kubernetes リソースに対してハードコードされたヘルスチェックロジックを持つ:

| リソース | 判定基準 |
|---|---|
| Deployment | すべての ReplicaSet が利用可能か |
| StatefulSet | 要求されたレプリカ数が準備完了か |
| DaemonSet | 全ノードでスケジュール・実行されているか |
| Pod | 全コンテナが Running/Ready か |
| Service (LB) | External IP が割り当て済みか |
| Ingress | アドレスが割り当て済みか |
| PVC | Bound 状態か |
| Job | 成功/失敗の判定 |

その他のリソースは `conditions` フィールドの `status` を基にフォールバック的に判定。

### 3.3 カスタム Lua ヘルスチェック

`argocd-cm` ConfigMap にカスタム Lua スクリプトを定義して、任意のリソースタイプに対するヘルスチェックを追加できる:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
data:
  resource.customizations.health.cert-manager.io_Certificate: |
    hs = {}
    if obj.status ~= nil then
      if obj.status.conditions ~= nil then
        for i, condition in ipairs(obj.status.conditions) do
          if condition.type == "Ready" and condition.status == "False" then
            hs.status = "Degraded"
            hs.message = condition.message
            return hs
          end
          if condition.type == "Ready" and condition.status == "True" then
            hs.status = "Healthy"
            hs.message = condition.message
            return hs
          end
        end
      end
    end
    hs.status = "Progressing"
    hs.message = "Waiting for certificate"
    return hs
```

---

## 4. マルチテナンシーモデル

### 4.1 AppProject (プロジェクト)

AppProject は Application に対して以下の制約を課す:

- **許可されるソースリポジトリ** (`sourceRepos`)
- **許可されるデプロイ先** (`destinations`: クラスタ + namespace)
- **許可されるクラスタスコープリソース** (`clusterResourceWhitelist`)
- **拒否される namespace スコープリソース** (`namespaceResourceBlacklist`)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: team-frontend
  namespace: argocd
spec:
  description: "フロントエンドチーム用プロジェクト"
  sourceRepos:
    - 'https://github.com/myorg/frontend-*'   # ワイルドカード対応
    - '!https://github.com/myorg/frontend-secrets'  # 否定パターン
  destinations:
    - server: https://kubernetes.default.svc
      namespace: 'frontend-*'
    - server: https://kubernetes.default.svc
      namespace: '!kube-system'                # 拒否パターン
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota
    - group: ''
      kind: LimitRange
  roles:
    - name: developers
      description: "フロントエンド開発者"
      policies:
        - p, proj:team-frontend:developers, applications, get, team-frontend/*, allow
        - p, proj:team-frontend:developers, applications, sync, team-frontend/*, allow
      groups:
        - frontend-team    # SSO グループとのマッピング
```

### 4.2 RBAC

ArgoCD は Kubernetes RBAC とは独立した独自の RBAC 機構を持つ。`argocd-rbac-cm` ConfigMap で設定する。

**ポリシー構文**: `p, <subject>, <resource>, <action>, <object>, <effect>`

**リソース種別と操作**:
- `applications`: get, create, update, delete, sync, override, action
- `projects`: get, create, update, delete
- `repositories`: get, create, update, delete
- `clusters`: get, create, update, delete
- `logs`: get

### 4.3 分離モデルの前提

1. コントロールプレーン namespace (`argocd`) へのフルアクセスは管理者のみ
2. マルチテナンシーは **ArgoCD API を通じて** 強制される (Kubernetes RBAC ではない)
3. AppProject の namespace 制限は、ArgoCD RBAC と組み合わせて初めてセキュアになる

---

## 5. アプリケーションデリバリーパターン

### 5.1 App of Apps パターン

1つの「親」Application が、他の Application 定義を含むディレクトリを指す構造。新しい Application YAML をディレクトリに追加するだけで自動的にデプロイされる。

```
argocd/applications/
  root.yaml       ← 親 Application (このディレクトリ自身を参照)
  echo-dev.yaml   ← 子 Application
  echo-prod.yaml  ← 子 Application
  infra.yaml      ← 子 Application
```

### 5.2 ApplicationSet とジェネレーター

ApplicationSet は単一の定義から複数の Application を自動生成する。

| ジェネレーター | 入力ソース | 用途 |
|---|---|---|
| **List** | リテラルリスト | 静的な環境リスト |
| **Cluster** | ArgoCD 登録クラスタ | マルチクラスタ展開 |
| **Git (ディレクトリ)** | リポジトリ内のディレクトリ構造 | マイクロサービス自動検出 |
| **Git (ファイル)** | リポジトリ内の設定ファイル | 環境別パラメータ管理 |
| **Pull Request** | GitHub/GitLab PR API | PR プレビュー環境 |
| **SCM Provider** | GitHub Org/GitLab Group | 組織横断リポジトリ検出 |
| **Matrix** | 2つのジェネレーターの直積 | クラスタ x 環境の組合せ |
| **Merge** | 複数ジェネレーターのマージ | 条件付きパラメータ上書き |

```yaml
# Matrix ジェネレーターの例 (クラスタ x Git ディレクトリ)
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: multi-cluster-apps
spec:
  generators:
    - matrix:
        generators:
          - git:
              repoURL: https://github.com/myorg/apps.git
              revision: HEAD
              directories:
                - path: services/*
          - clusters:
              selector:
                matchLabels:
                  env: production
  template:
    metadata:
      name: '{{path.basename}}-{{name}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/myorg/apps.git
        targetRevision: HEAD
        path: '{{path}}'
      destination:
        server: '{{server}}'
        namespace: '{{path.basename}}'
```

### 5.3 Progressive Sync (段階的同期)

ApplicationSet の `RollingSync` 戦略により、Application を段階的に同期:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: progressive-deploy
spec:
  strategy:
    type: RollingSync
    rollingSync:
      steps:
        - matchExpressions:
            - key: env
              operator: In
              values: [staging]
        - matchExpressions:
            - key: env
              operator: In
              values: [production]
          maxUpdate: 25%     # 本番は25%ずつ段階展開
```

**重要な特性**:
- RollingSync は管理対象の全 Application の auto-sync を強制的に無効化する
- ステップ内の全 Application が Healthy になるまで次のステップに進まない

---

## 6. GitOps 原則の実装

### 6.1 Single Source of Truth

Git リポジトリがクラスタの望ましい状態の唯一の信頼源。ArgoCD は Git に保存されたマニフェストを「正」とし、クラスタの状態を常にこれに合わせる。

### 6.2 宣言的な望ましい状態

全ての構成が宣言的な YAML/JSON で Git に保存される。ArgoCD の Application CRD 自体も宣言的に管理される (App of Apps パターン)。

### 6.3 自動 Reconciliation

```yaml
syncPolicy:
  automated:
    prune: true      # Git から削除されたリソースをクラスタからも削除
    selfHeal: true   # 手動変更を自動的に Git の状態に戻す
```

### 6.4 Git 履歴による監査証跡

Git の履歴自体が変更の監査証跡として機能する:
- **誰が**: Git のコミッター情報
- **いつ**: コミットタイムスタンプ
- **何を**: diff で変更内容を確認
- **なぜ**: コミットメッセージ

ArgoCD はさらに同期操作の結果を Application CRD の `status.operationState` に記録する。

---

## 7. リポジトリ構造のベストプラクティス

### 最重要原則: アプリコードとデプロイ設定は別リポジトリに分離

理由:
- アプリのリリースサイクルとインフラ設定の変更サイクルが異なる
- CI パイプラインがコード変更時にデプロイ設定まで再ビルドする無駄を避ける
- セキュリティ境界の明確化
- ArgoCD がマニフェストリポジトリの変更のみを監視すればよく、ノイズが減る

### モノレポ vs ポリレポ

**モノレポ (設定リポジトリが1つ) が向いている場合:**
- 小規模チーム (10人以下)
- アプリケーション数が少ない
- 環境間の一貫性を重視

**ポリレポ (設定リポジトリを分割) が向いている場合:**
- 大規模組織、複数チーム
- チームごとにアクセス制御が必要
- リポジトリサイズが大きくなりすぎて repo-server に負荷がかかる場合

### アンチパターン: ブランチ戦略で環境を分ける

`dev` ブランチ、`staging` ブランチ、`prod` ブランチで環境を分けるのは避けるべき:
- マージ地獄になる
- プロモーションの追跡が困難
- 差分の確認が面倒

代わりに**ディレクトリ (overlays) で環境を分ける**のが正解。

---

## 8. セキュリティのベストプラクティス

### RBAC 設定

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.default: role:readonly    # デフォルトは読み取り専用
  policy.csv: |
    p, role:team-a-admin, applications, *, team-a/*, allow
    p, role:team-a-admin, logs, get, team-a/*, allow
    g, github-org:team-a, role:team-a-admin
```

### AppProject 制限設定

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: team-a
  namespace: argocd
spec:
  sourceRepos:
    - 'https://github.com/myorg/team-a-manifests.git'
  destinations:
    - namespace: 'team-a-*'
      server: 'https://kubernetes.default.svc'
  clusterResourceWhitelist: []   # クラスタスコープリソースを禁止
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota
    - group: 'networking.k8s.io'
      kind: NetworkPolicy
  roles:
    - name: ci-deployer
      policies:
        - p, proj:team-a:ci-deployer, applications, sync, team-a/*, allow
        - p, proj:team-a:ci-deployer, applications, get, team-a/*, allow
      jwtTokens:
        - expiresIn: "24h"   # トークンには必ず有効期限を設定
```

**重要**: `default` プロジェクトは本番では使わない。必ず専用プロジェクトを作成する。

### シークレット管理

**推奨: クラスタ側でシークレットを解決する方式** (ArgoCD がシークレットの中身に触れない)

| ツール | 適用場面 | 特徴 |
|---|---|---|
| Sealed Secrets | 小規模チーム | Git に暗号化済み Secret を保存。シンプルだが鍵管理が必要 |
| External Secrets Operator (ESO) | 中〜大規模 | 外部ストア (GCP Secret Manager 等) から自動取得。最も GitOps 的 |
| CSI Secret Store Driver | Vault 連携が必要な場合 | Pod に Volume としてマウント |

**自動ローテーションされるシークレットのドリフト対策:**

```yaml
spec:
  ignoreDifferences:
    - group: ""
      kind: Secret
      jsonPointers:
        - /data
```

### SSO 統合

テスト完了後はローカル `admin` アカウントを無効にする (`accounts.admin.enabled: "false"`)。

### API Server 露出の最小化

- TLS 1.2 以上を強制
- Ingress 経由のアクセスに限定
- 不要な API エンドポイントは NetworkPolicy で遮断
- WAF や IP 制限を併用

---

## 9. パフォーマンスとスケーラビリティ

### アプリケーション規模別の対策

| 規模 | 推奨構成 |
|---|---|
| 〜200 アプリ | デフォルト構成で十分 |
| 200〜1,000 アプリ | repo-server レプリカ増加、キャッシュ最適化 |
| 1,000〜5,000 アプリ | コントローラシャーディング必須 |
| 5,000+ アプリ | 複数 ArgoCD インスタンスに分割推奨 |

### コントローラシャーディング

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: argocd-application-controller
spec:
  replicas: 3
  template:
    spec:
      containers:
        - name: argocd-application-controller
          env:
            - name: ARGOCD_CONTROLLER_REPLICAS
              value: "3"
          args:
            - --sharding-method
            - consistent-hashing   # round-robin より再分配が少ない
            - --status-processors
            - "50"                 # デフォルト 20 から増加
            - --operation-processors
            - "25"                 # デフォルト 10 から増加
```

各シャードは **400 アプリ以下** に抑えるのが推奨。

### Repo Server 最適化

```yaml
spec:
  replicas: 5    # 大規模環境では 5 以上
  containers:
    - name: argocd-repo-server
      env:
        - name: ARGOCD_EXEC_TIMEOUT
          value: "180"    # 大規模 Helm チャートの場合
      resources:
        requests:
          cpu: "1"
          memory: "1Gi"
        limits:
          cpu: "2"
          memory: "2Gi"
```

### リソース除外

不要なリソースの監視を除外して負荷を軽減:

```yaml
# argocd-cm ConfigMap
data:
  resource.exclusions: |
    - apiGroups:
        - "events.k8s.io"
      kinds:
        - Event
      clusters:
        - "*"
    - apiGroups:
        - "metrics.k8s.io"
      kinds:
        - "*"
      clusters:
        - "*"
```

### モノレポのパフォーマンス問題

モノレポが大きくなると、1つのアプリの変更で全アプリが再マニフェスト生成される。対策:
- Webhook で変更パスをフィルタリング
- `source.directory.include`/`exclude` でパスを限定
- リポジトリサイズが肥大化したら設定リポジトリを分割検討

---

## 10. 運用ベストプラクティス

### Sync Policy の使い分け

| 環境 | auto-sync | self-heal | prune | 理由 |
|---|---|---|---|---|
| dev | ON | ON | ON | 高速イテレーション、ドリフト即修正 |
| staging | ON | ON | ON | 本番と同じ挙動を検証 |
| prod | ON | ON | ON (慎重に) | 本番こそドリフトを防ぐべき。ただし初期導入時は manual から始める |

**ポイント**: 本番で auto-sync を無効にするのは実はアンチパターン。本番こそ設定ドリフトを防ぐべき環境。ただし、チームが GitOps 運用に慣れてから有効化する。

```yaml
spec:
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

### CRD の取り扱い

CRD は特別な扱いが必要:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-5"          # CRD を先にデプロイ
    argocd.argoproj.io/sync-options: ServerSideApply=true
    argocd.argoproj.io/sync-options: Prune=false  # CRD 削除を防止
```

**Sync Wave の推奨順序:**
1. Wave -5: CRD 定義
2. Wave -3: Operator/Controller
3. Wave 0: Custom Resources (デフォルト)
4. Wave 5: 依存するアプリケーション

### 環境プロモーション (dev → staging → prod)

**推奨: Git コミットベースのプロモーション**

CI パイプラインがイメージタグをコミットで更新:
- dev: 自動でイメージタグを更新
- staging: dev で検証済みのタグを PR で反映
- prod: staging で検証済みのタグを PR で反映 (承認必須)

### ロールバック戦略

- ArgoCD の History & Rollback 機能で過去の Sync 状態に戻せる
- ただし**本来の GitOps ロールバックは `git revert` で Git の状態を戻すこと**
- UI/CLI からのロールバックは Git と乖離するため、一時的な緊急対応として使う

### 災害復旧

```bash
# バックアップ
argocd admin export > argocd-backup.yaml

# リストア
argocd admin import - < argocd-backup.yaml
```

**DR 計画の必須事項:**
- RPO/RTO を定義する
- バックアップ対象: Application、AppProject、Secret、ConfigMap、クラスタ認証情報
- 四半期ごとにリストアテストを実施
- Git が Single Source of Truth なので、ArgoCD 自体のリストアは比較的容易

---

## 11. CI/CD 統合パターン

### Image Updater vs CI 駆動マニフェスト更新

| 方式 | メリット | デメリット |
|---|---|---|
| CI 駆動 (CI が Git 更新) | 完全な監査証跡、柔軟なロジック | CI→Git の認証設定が必要 |
| ArgoCD Image Updater | 設定がシンプル、CI 不要 | 監査証跡が Annotation のみ、Kustomize のみ対応 |

**推奨: CI 駆動方式。** CI パイプラインが設定リポジトリのイメージタグをコミットで更新する。

### Webhook 設定

デフォルトでは ArgoCD は 3 分間隔で Git をポーリング。Webhook で即時反映:

```yaml
# argocd-cm
data:
  webhook.github.secret: $webhook.github.secret
```

GitHub 側の Webhook URL: `https://argocd.example.com/api/webhook`

### 通知統合

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-notifications-cm
data:
  trigger.on-sync-failed: |
    - when: app.status.operationState.phase in ['Error', 'Failed']
      send: [app-sync-failed]
  template.app-sync-failed: |
    message: |
      Application {{.app.metadata.name}} sync failed.
      {{.app.status.operationState.message}}
  service.slack: |
    token: $slack-token
    channel: argocd-alerts
```

---

## 12. よくある落とし穴とアンチパターン

### OutOfSync 問題の主な原因と対策

**1. MutatingWebhook/Controller によるフィールド追加**

Kubernetes のコントローラ (例: istio-injector) がリソースにフィールドを追加し、Git と差分が生じる。

```yaml
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jqPathExpressions:
        - .spec.template.metadata.annotations."sidecar.istio.io/status"
```

**2. HPA と replicas の競合**

HPA が replicas 数を変更するが、Git では固定値が定義されている。

```yaml
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
```

**3. Helm の `randAlphaNum` 関数**

テンプレートに乱数生成関数があると、毎回異なるマニフェストが生成されて永久に OutOfSync。対策: Helm チャートで乱数関数を使わない。

**4. CRD のカスタムマーシャラー**

CRD のシリアライズ形式が ArgoCD の期待と異なり false positive が発生。対策: `ServerSideApply=true` と server-side diff の併用。

### Sync Loop の対処

sync → 成功 → drift 検知 → sync を無限ループする場合:
- ログで何のフィールドがドリフトしているか特定
- `ignoreDifferences` で対象フィールドを除外
- `argocd.argoproj.io/compare-options: ServerSideDiff=true` を設定

### その他のアンチパターン

| アンチパターン | 問題 | 対策 |
|---|---|---|
| `default` プロジェクトの使用 | 全リソースへのアクセスが可能 | 専用 AppProject を作成 |
| `targetRevision: HEAD` の本番使用 | main への push が即座に反映 | 固定タグかコミット SHA を指定 |
| 1つの Application に大量のリソース | パフォーマンス低下 | 適切な粒度で分割 |
| `Replace=true` の多用 | リソース再作成によるダウンタイム | 必要最小限に |
| ブランチで環境を分ける | マージ地獄 | ディレクトリ (overlays) で分離 |

---

## 13. ArgoCD vs Flux CD 比較

| 観点 | ArgoCD | Flux CD |
|---|---|---|
| アーキテクチャ | 集中型サーバー + Web UI | 分散型コントローラ群 (Kubernetes Native) |
| UI | 組み込み Web UI (視覚的で強力) | UI なし (Weave GitOps 等の外部ツール) |
| Helm 対応 | テンプレートとしてレンダリング→差分表示 | ファーストクラスサポート (hooks, rollback 完全対応) |
| RBAC | 組み込み RBAC (AppProject 単位) | Kubernetes native RBAC に委譲 |
| リソース消費 | 比較的多い (API server, repo-server, Redis 等) | 軽量 (CRD ベース、ステートレス) |
| マルチテナント | AppProject で強力にサポート | Namespace 分離で対応 |
| 学習コスト | UI があるため取っつきやすい | CLI 前提で学習コスト高め |
| 大規模運用 | シャーディングで対応可能だが複雑 | Kubernetes native なため自然にスケール |
| エコシステム | Argo Rollouts, Workflows, Events | Flagger (Progressive Delivery) |

**選択の指針:**
- **ArgoCD**: Web UI が必要、マルチテナント要件がある、可視化と監査を重視、Kubernetes 熟練者が少ない
- **Flux**: Kubernetes native な軽量運用を重視、Helm のフル機能が必要、リソース消費を最小化したい

---

## 参考文献

- [Architectural Overview - Argo CD](https://argo-cd.readthedocs.io/en/stable/operator-manual/architecture/)
- [Sync Phases and Waves - Argo CD](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/)
- [Resource Health - Argo CD](https://argo-cd.readthedocs.io/en/stable/operator-manual/health/)
- [Resource Tracking - Argo CD](https://argo-cd.readthedocs.io/en/stable/user-guide/resource_tracking/)
- [Diff Customization - Argo CD](https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/)
- [Projects - Argo CD](https://argo-cd.readthedocs.io/en/stable/user-guide/projects/)
- [RBAC Configuration - Argo CD](https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/)
- [ApplicationSet Generators - Argo CD](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators/)
- [Progressive Syncs - Argo CD](https://argo-cd.readthedocs.io/en/latest/operator-manual/applicationset/Progressive-Syncs/)
- [High Availability - Argo CD](https://argo-cd.readthedocs.io/en/stable/operator-manual/high_availability/)
- [Secret Management - Argo CD](https://argo-cd.readthedocs.io/en/stable/operator-manual/secret-management/)
- [Disaster Recovery - Argo CD](https://argo-cd.readthedocs.io/en/latest/operator-manual/disaster_recovery/)
- [Security - Argo CD](https://argo-cd.readthedocs.io/en/stable/operator-manual/security/)
- [Best Practices for Multi-tenancy in Argo CD](https://blog.argoproj.io/best-practices-for-multi-tenancy-in-argo-cd-273e25a047b0)
- [Top 30 Argo CD Anti-Patterns | Codefresh](https://codefresh.io/blog/argo-cd-anti-patterns-for-gitops/)
