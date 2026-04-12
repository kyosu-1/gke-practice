# Cloud Spanner サーベイ

Google Cloud Spanner について、アーキテクチャ・特性・スキーマ設計・クエリまでを調査してまとめる。

---

## 目次

1. [概要](#1-概要)
2. [アーキテクチャ](#2-アーキテクチャ)
3. [特性と使いどころ](#3-特性と使いどころ)
4. [スキーマ設計](#4-スキーマ設計)
5. [クエリ / DML](#5-クエリ--dml)
6. [トランザクション](#6-トランザクション)
7. [運用トピック](#7-運用トピック)
8. [参考リンク](#8-参考リンク)

---

## 1. 概要

Cloud Spanner は Google Cloud が提供するフルマネージドのリレーショナルデータベース。以下を同時に満たす点が特徴:

- **水平スケール**: ノード(Processing Unit) 追加で書き込み・読み取りスループットを線形にスケール
- **強整合性 (External Consistency)**: 分散環境でも直列化可能な ACID トランザクション
- **グローバル分散**: マルチリージョン構成でも同期レプリケーション
- **SQL インターフェース**: GoogleSQL 方言と PostgreSQL 方言の両方をサポート

従来「分散 KVS はスケールするが弱整合」「RDB は強整合だがスケールしない」というトレードオフを、後述の **TrueTime** と **Paxos** によって打ち破った設計になっている。

---

## 2. アーキテクチャ

### 2.1 データ配置の単位: Split

Spanner はすべてのデータを **主キー順で並べた連続範囲 = Split** に分割して管理する。

- 1 つの Split には主キーの連続レンジに属する行が物理的にまとまって格納される
- データ量やアクセスホットネスに応じて Spanner が自動的に Split を分割・マージ (auto-sharding)
- クエリ計画は Split の境界に沿って並列実行される

### 2.2 レプリケーション: Paxos

各 Split は複数の **Zone** にまたがって複製され、Paxos グループを構成する。

- Paxos グループ内の 1 つが **Leader** (書き込みを調停)
- その他は **Read-only レプリカ** / **Witness レプリカ** として読み取り・投票に参加
- 書き込みは Leader が Paxos でコミットを合意 → 同期レプリケート
- 読み取りはどのレプリカからも最新データを読める (グローバル同期レプリケーション)

```
         Paxos Group (1 Split)
   ┌──────────┬──────────┬──────────┐
   │  Zone A  │  Zone B  │  Zone C  │
   │ (Leader) │ (Replica)│ (Replica)│
   └──────────┴──────────┴──────────┘
```

Leader は Zone に固定されず、負荷・障害に応じて再配置される。これにより、書き込みホットスポットや Zone 障害に耐性がある。

### 2.3 TrueTime と External Consistency

Spanner の最大の発明は **TrueTime API**。

- Google のデータセンターには GPS と原子時計を組み合わせた時刻ソースが配備されている
- `TT.now()` は単一の値ではなく **時刻の区間** `[earliest, latest]` を返す (真の時刻がこの中にあることを保証)
- トランザクションのコミット時に `commit wait` を入れ、区間の曖昧さより必ず後でコミットを確定させる
- 結果、グローバル分散環境でもトランザクションに **全順序 (External Consistency = Strict Serializability)** が付く

これにより「あるリージョンで commit した後、地球の反対側で始まるトランザクションから必ず見える」が保証される。CAP 定理の文脈では Spanner は CP 寄り (ネットワーク分断時は可用性を犠牲) だが、実運用上は極めて高い可用性を達成している。

### 2.4 インスタンス構成

- **Processing Unit (PU)** が課金・性能の最小単位。1000 PU = 1 Node 相当
- 2021 年以降は **100 PU** から作成可能 (小規模検証に適する)
- 構成種別:
  - **Regional**: 1 リージョン内の 3 Zone にレプリカ。99.99% SLA
  - **Multi-Region** (例: `nam3`, `eur3`, `asia1`): 複数リージョンにまたがる構成。99.999% SLA

---

## 3. 特性と使いどころ

### 向いているワークロード

- **金融・決済・在庫** など、強整合とグローバル展開が両立必要
- **ゲームのユーザーデータ・ランキング** のように書き込みスループットが読みにくいもの
- **大規模 SaaS のマルチテナント**: テナント ID を先頭主キーにして綺麗にシャーディング
- リレーショナルスキーマを捨てずにスケールアウトしたいとき

### 向かないワークロード

- 小規模アプリで **Cloud SQL で十分** なもの (コスト効率は Cloud SQL が上)
- **大量 JSON / 半構造データ**: Firestore や BigQuery の方が適する
- **OLAP / 集計ダッシュボード**: BigQuery が本命。Spanner は OLTP 向き (Spanner Data Boost など例外あり)
- 書き込みが **単調増加キー** (UUIDv1, タイムスタンプ単体) に集中するケース → ホットスポットで詰まる

### 他データベースとの比較

| 観点 | Spanner | Cloud SQL (Postgres/MySQL) | BigQuery | Firestore |
|---|---|---|---|---|
| 整合性 | 強 (External) | 強 (単一インスタンス) | 弱 (バッチ) | 強 (ドキュメント単位) |
| スケール | 水平 (書き込みも) | 垂直 | 水平 (クエリ) | 水平 |
| トランザクション | グローバル ACID | インスタンス内 ACID | なし/限定 | マルチドキュメント |
| スキーマ | RDB | RDB | RDB (カラム指向) | スキーマレス |
| 最小コスト | 約 $65/月〜 | 小 | クエリ従量 | 小 |

---

## 4. スキーマ設計

### 4.1 主キー設計 — 最重要

Spanner では主キーが **物理配置** を決める。設計を誤るとホットスポットで性能が出ない。

原則:

- **単調増加キー (`INT64 AUTO_INCREMENT` 相当やタイムスタンプ単体) を先頭に置かない**
- 代わりに **UUIDv4**、`GENERATE_UUID()`、もしくはハッシュ値を先頭にする
- テナント ID や顧客 ID を先頭に置くと、テナントごとにきれいに分散する
- **ビット反転シーケンス** (bit-reverse sequential) も推奨パターン

### 4.2 Interleave (物理的親子関係)

Spanner 固有の強力な機能。親テーブルの行と子テーブルの行を **物理的に同じ Split に配置** する。

```sql
CREATE TABLE Singers (
  SingerId    INT64 NOT NULL,
  FirstName   STRING(1024),
  LastName    STRING(1024),
  BirthDate   DATE,
) PRIMARY KEY(SingerId);

CREATE TABLE Albums (
  SingerId        INT64 NOT NULL,
  AlbumId         INT64 NOT NULL,
  AlbumTitle      STRING(MAX),
  MarketingBudget INT64,
) PRIMARY KEY(SingerId, AlbumId),
  INTERLEAVE IN PARENT Singers ON DELETE CASCADE;

CREATE TABLE Songs (
  SingerId  INT64 NOT NULL,
  AlbumId   INT64 NOT NULL,
  TrackId   INT64 NOT NULL,
  SongName  STRING(MAX),
  Duration  INT64,
) PRIMARY KEY(SingerId, AlbumId, TrackId),
  INTERLEAVE IN PARENT Albums ON DELETE CASCADE;
```

ポイント:

- 子テーブルの主キーは **親テーブルの主キーで始まる必要がある** (`SingerId` → `SingerId, AlbumId` → `SingerId, AlbumId, TrackId`)
- 親子 JOIN が同一 Split 内で完結するため高速
- `ON DELETE CASCADE` で親削除時の子削除を宣言可能
- 最大 7 階層までネスト可能

#### FOREIGN KEY との使い分け

- **Interleave**: 物理配置も変わる。親子 JOIN の頻度が高い場合に使う
- **Foreign Key**: 参照整合性のみ担保、物理配置は変わらない。階層が深い・1:N でない関係に向く

PostgreSQL 方言では `INTERLEAVE` が使えないため、代わりに FK で表現する (物理配置の最適化は Spanner 任せ)。

### 4.3 セカンダリインデックス

```sql
CREATE INDEX SingersByLastName ON Singers(LastName);

-- 親子と同じ Split に配置する Interleaved Index
CREATE INDEX SongsBySongName ON Songs(SingerId, AlbumId, SongName),
  INTERLEAVE IN Albums;

-- カバリングインデックス (STORING 句で追加列を含める)
CREATE INDEX AlbumsByTitle ON Albums(AlbumTitle) STORING (MarketingBudget);
```

- インデックスも Spanner では**テーブルの一種**として分散配置される
- `INTERLEAVE IN` でインデックスも親 Split に同居させられる → 親子クエリで特に有効
- `STORING` でカバリング化し、インデックス探索のみでクエリ完結させる

### 4.4 データ型

よく使う型:

- `INT64`, `FLOAT64`, `NUMERIC` (38桁), `BOOL`
- `STRING(MAX)`, `STRING(1024)` (長さ指定)
- `BYTES(MAX)`
- `DATE`, `TIMESTAMP`
- `ARRAY<T>` (配列型)
- `JSON` (半構造)

### 4.5 コミットタイムスタンプ列

```sql
LastUpdated TIMESTAMP
  DEFAULT (PENDING_COMMIT_TIMESTAMP())
  ON UPDATE (PENDING_COMMIT_TIMESTAMP())
  OPTIONS (allow_commit_timestamp = true),
```

トランザクションのコミット時点のタイムスタンプをサーバー側で自動付与できる。イベントソーシング・監査ログ的用途で便利。

---

## 5. クエリ / DML

### 5.1 GoogleSQL (推奨方言)

Spanner は標準で **GoogleSQL** 方言。`JOIN`, `GROUP BY`, `WINDOW`, CTE など一般的な SQL を備える。

```sql
-- シンプルな SELECT
SELECT SingerId, FirstName, LastName
FROM Singers
WHERE LastName = 'Smith';

-- JOIN (Interleave による親子は高速)
SELECT s.FirstName, a.AlbumTitle
FROM Singers AS s
JOIN Albums AS a
  ON s.SingerId = a.SingerId
WHERE s.SingerId = 1;

-- 集計
SELECT AlbumId, COUNT(*) AS track_count, SUM(Duration) AS total_duration
FROM Songs
WHERE SingerId = 1
GROUP BY AlbumId;

-- インデックスのヒント指定
SELECT *
FROM Songs@{FORCE_INDEX=SongsBySongName}
WHERE SongName LIKE 'Hello%';
```

### 5.2 DML 例

```sql
-- INSERT
INSERT INTO Singers (SingerId, FirstName, LastName)
VALUES (1, 'Marc', 'Richards');

-- UPDATE
UPDATE Singers SET LastName = 'Smith' WHERE SingerId = 1;

-- DELETE
DELETE FROM Singers WHERE SingerId = 1;

-- 複数行 INSERT
INSERT INTO Singers (SingerId, FirstName, LastName) VALUES
  (12, 'Melissa', 'Garcia'),
  (13, 'Russell', 'Morales'),
  (14, 'Jacqueline', 'Long');
```

### 5.3 DML vs Mutation

Spanner には SQL の DML とは別に、**Mutation API** と呼ばれる低レベル書き込み API がある。

| | DML | Mutation |
|---|---|---|
| 記法 | SQL (`INSERT/UPDATE/DELETE`) | API (`spanner.Insert`, `spanner.Update` など) |
| 表現力 | 高 (WHERE, サブクエリ可) | 低 (行単位) |
| 性能 | DML 解析のオーバーヘッド | より高速・低レイテンシ |
| 用途 | 条件付き更新、複雑な変更 | 大量バッチ投入、既知のキーでの上書き |

一般に **大量書き込み → Mutation / 複雑な更新 → DML** を使い分ける。

### 5.4 パラメータ化クエリ (Go クライアント例)

```go
stmt := spanner.Statement{
    SQL: `UPDATE Albums
          SET MarketingBudget = @AlbumBudget
          WHERE SingerId = @SingerId AND AlbumId = @AlbumId`,
    Params: map[string]interface{}{
        "SingerId":    int64(1),
        "AlbumId":     int64(1),
        "AlbumBudget": int64(300000),
    },
}
_, err := txn.Update(ctx, stmt)
```

SQL インジェクション防止・クエリプランキャッシュ効率の点から必ず名前付きパラメータを使う。

---

## 6. トランザクション

### 6.1 種別

| 種別 | 用途 | 特徴 |
|---|---|---|
| **Read-Write** | 読み書き混在 | Strict Serializable。コミット時に競合検出→リトライ |
| **Read-Only** | 分析・参照 | ロック不要。過去の時刻を指定した `bounded staleness` 読み取りが可能で高速 |
| **Partitioned DML** | バッチ更新 | `UPDATE/DELETE` を巨大テーブルに対して並列実行 |

### 6.2 Read-Write トランザクション (Go)

```go
_, err = client.ReadWriteTransaction(ctx, func(ctx context.Context, txn *spanner.ReadWriteTransaction) error {
    // Read
    row, err := txn.ReadRow(ctx, "Albums",
        spanner.Key{1, 1}, []string{"MarketingBudget"})
    if err != nil { return err }
    var budget int64
    if err := row.Column(0, &budget); err != nil { return err }

    // Update
    stmt := spanner.Statement{
        SQL: `UPDATE Albums SET MarketingBudget = @b
              WHERE SingerId = 1 AND AlbumId = 1`,
        Params: map[string]interface{}{"b": budget + 1000},
    }
    _, err = txn.Update(ctx, stmt)
    return err
})
```

**重要**: コールバックは **べき等** でなければならない。Spanner クライアントは競合 (Aborted) 時に自動リトライするため、外部副作用を含めない。

### 6.3 Read-Only トランザクション

```go
ro := client.ReadOnlyTransaction().
    WithTimestampBound(spanner.ExactStaleness(15 * time.Second))
defer ro.Close()

iter := ro.Query(ctx, spanner.Statement{SQL: "SELECT ... FROM ..."})
```

- ロックを取らない → 読み取り負荷を Leader 以外にも分散できる
- `ExactStaleness` で少し古いスナップショットを読むことで、Leader 往復を避け低レイテンシ化

### 6.4 Stale Read の活用

リアルタイム性が必須でない参照系 (一覧・検索・集計) は 10〜15 秒の stale read にするだけで劇的にレイテンシとコストが下がる。実務上のベストプラクティス。

---

## 7. 運用トピック

### 7.1 モニタリング

- **Query Insights**: Cloud Console でスロークエリ、実行プラン、ロック待ちを可視化
- **Key Visualizer**: 主キー空間の時系列ヒートマップでホットスポットを検出
- **System Tables**: `SPANNER_SYS.*` に統計情報が蓄積されており SQL で参照可能

### 7.2 バックアップ / PITR

- **Backup**: 任意時点でスナップショット作成 (インスタンス内)
- **Point-in-Time Recovery**: 最大 7 日分の version retention を設定すれば、過去の特定時刻のデータを読める

### 7.3 マイグレーション

- **Harbourbridge / Spanner migration tool**: MySQL/PostgreSQL のスキーマを Spanner に変換
- DDL は `ALTER TABLE` でオンライン変更可能 (カラム追加・インデックス追加など)
- インデックス作成はバックフィルが非同期に走るため、進行状況を `INFORMATION_SCHEMA` で確認

### 7.4 コスト最小化

- 検証は **100 PU + リージョナル** で開始 (約 $65/月) か **無料トライアルインスタンス**
- PU はオンラインで増減可能。ピーク時だけ上げる運用ができる
- ストレージは $0.30/GB/月 (regional) と RDB にしては高めなので、不要データは TTL で削除

---

## 8. 参考リンク

- Spanner 公式: https://cloud.google.com/spanner/docs
- Replication の仕組み: https://cloud.google.com/spanner/docs/replication
- Life of reads and writes (白書): https://cloud.google.com/spanner/docs/whitepapers/life-of-reads-and-writes
- Spanner, TrueTime and CAP (白書): https://cloud.google.com/spanner/docs/whitepapers
- Schema design ベストプラクティス: https://cloud.google.com/spanner/docs/schema-design
- DML 構文 (GoogleSQL): https://cloud.google.com/spanner/docs/dml-syntax
- DDL 構文: https://cloud.google.com/spanner/docs/data-definition-language
- Go クライアントライブラリ: https://pkg.go.dev/cloud.google.com/go/spanner
- 料金: https://cloud.google.com/spanner/pricing
