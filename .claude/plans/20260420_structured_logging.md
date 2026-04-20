# 構造化ログ実装計画

## 概要

Zig 向けロギングライブラリ `zlog` に、Go の slog に近いインタフェースを持つ構造化ログ機能を実装する。

## 設計方針

- 出力先の切り替え（stdout / stderr / ファイル）に対応
- ログレベルの切り替えに対応
- 出力フォーマットの切り替え（テキスト / JSON）に対応
- タイムスタンプを常に出力する（RFC 3339 形式、切り替え不要）
- ロガー名（スコープ）を設定できる（`withLoggerName` で名前フィールドをセットした新しい Logger を返す）
- 構造化ログは **comptime anytype**（Option A）で実装する
  - フィールド名はコンパイル時固定、値は実行時でも可
  - アロケータ不要でシンプルに保てる
  - 動的なフィールド名・個数が必要なケースは対象外

## 構造化ログ方式のトレードオフ検討

### Option A: comptime anytype（採用）

```zig
logger.info("user logged in", .{ .user_id = 42, .ip = "127.0.0.1" });
```

| 項目 | 内容 |
|------|------|
| フィールド名 | コンパイル時固定 |
| 値 | 実行時でも可（ユーザー入力・変数も渡せる） |
| アロケータ | 不要 |
| 実装コスト | 低（`@typeInfo` + `inline for` で反復） |
| 制約 | フィールド名・個数が実行時に変わるケースは不可 |

### Option B: Go slog 風の `Attr` ランタイム型（不採用）

```zig
logger.info("user logged in", &.{
    zlog.String("ip", "127.0.0.1"),
    zlog.Int("user_id", 42),
});
```

| 項目 | 内容 |
|------|------|
| フィールド名 | 実行時に動的に決定可 |
| フィールド個数 | 実行時に可変 |
| アロケータ | 必要になるケースあり |
| 実装コスト | 高（`union` / タグ付き値型の設計が必要） |
| 用途 | 汎用ミドルウェア・動的属性が必要な場面 |

### 採用理由

- 値が実行時（ユーザー入力を含む）でも Option A で対応可能
- Option B が必要になるのはフィールド名や個数自体が実行時に変わる場合のみ（通常のアプリログでは稀）
- シンプルさを優先し、アロケータ不要な Option A を選択

## 公開 API

```zig
// 初期化
const logger = zlog.Logger.init(io: std.Io, writer: *std.Io.Writer, level: std.log.Level) Logger;

// ログ出力
logger.err(comptime msg: []const u8, attrs: anytype) !void
logger.warn(comptime msg: []const u8, attrs: anytype) !void
logger.info(comptime msg: []const u8, attrs: anytype) !void
logger.debug(comptime msg: []const u8, attrs: anytype) !void

// 設定変更（新しい Logger を返す）
logger.withWriter(writer: *std.Io.Writer) Logger
logger.withLevel(level: std.log.Level) Logger
logger.withFormat(format: Format) Logger
logger.withLoggerName(name: []const u8) Logger
logger.withTimestamp(ts: std.Io.Timestamp) Logger  // テスト用：固定タイムスタンプを注入（内部では ?std.Io.Timestamp で保持、null なら now(io, .real) を使用）
```

## 出力フォーマット

### テキスト形式（デフォルト）

```
// ロガー名なし
2026-04-20T12:34:56Z [INFO] server started port=8080

// ロガー名あり
2026-04-20T12:34:56Z [INFO] [database] server started port=8080
```

- タイムスタンプ（RFC 3339）が先頭に付く
- ロガー名がある場合はレベルの後に `[name]` で付く
- メッセージの後に `key=value` 形式でフィールドを並べる
- 文字列値はダブルクォートで囲む
- 各ログエントリは改行で終わる

### JSON 形式

```
// ロガー名なし
{"time":"2026-04-20T12:34:56Z","level":"info","msg":"server started","port":8080}

// ロガー名あり
{"time":"2026-04-20T12:34:56Z","level":"info","logger":"database","msg":"server started","port":8080}
```

- `time` キーが先頭に付く（RFC 3339 形式）
- ロガー名がある場合は `logger` キーで付く
- 各ログエントリは改行で終わる
- 文字列値はダブルクォートで囲む
- 数値はクォートなし

## フォーマット方式のトレードオフ検討

### Option X-1: フォーマット enum（採用）

```zig
const logger = Logger.init(io, writer, .info).withFormat(.json);
```

| 項目 | 内容 |
|------|------|
| 実行時切り替え | 可（`withFormat` で新 Logger を返す） |
| アロケータ | 不要 |
| 実装コスト | 低（switch 分岐のみ） |
| 制約 | カスタムフォーマットは追加不可 |

### Option X-2: comptime ジェネリック（不採用）

```zig
Logger(JsonFormatter).init(io, writer, .info)
```

| 項目 | 内容 |
|------|------|
| カスタムフォーマット | 型として差し込める |
| 実行時切り替え | 不可（型が変わるため） |
| 実装コスト | 中 |

### Option X-3: vtable（不採用）

- `attrs: anytype` はコンパイル時型のため関数ポインタに乗せられず、実質不可

### 採用理由

- text / JSON の 2 択で現実のユースケースをカバーできる
- シンプルさを優先し、enum による switch 分岐が最もコストが低い

## テスタビリティ

### 問題と対策

| 問題 | 対策 |
|------|------|
| タイムスタンプが毎回変わり出力の完全一致検証ができない | `withTimestamp(ts)` で固定値を注入する |
| テスト内で `std.Io` の取得方法が不明 | `std.testing.io` が利用可能（解決済み） |

### テスト時の使い方

```zig
test "info log text format" {
    var buf: [256]u8 = undefined;
    var writer = ...; // バッファ書き込み用の Writer

    const fixed_ts = std.Io.Timestamp.fromNanoseconds(0); // 1970-01-01T00:00:00Z
    const logger = zlog.Logger.init(std.testing.io, &writer, .info)
        .withTimestamp(fixed_ts);

    try logger.info("started", .{ .port = 8080 });
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00Z [INFO] started port=8080\n",
        buf[0..writer.end],
    );
}
```

### `withTimestamp` の動作

- `fixed_timestamp` フィールドは `?std.Io.Timestamp` で保持
- `null`（デフォルト）: ログ出力時に `std.Io.Timestamp.now(io, .real)` を取得
- 値あり: 固定値を使用（テスト用途）

## 実装ステップ

1. `Logger` 構造体の定義（io・writer ポインタ、level・format フィールド、logger_name: ?[]const u8 フィールド、fixed_timestamp: ?std.Io.Timestamp フィールド）
2. `init` / `withWriter` / `withLevel` / `withFormat` / `withLoggerName` / `withTimestamp` の実装
3. RFC 3339 フォーマッタの実装（`std.Io.Timestamp` → 文字列変換、標準ライブラリに非存在のため自前実装）
4. 内部ログ出力関数（レベルフィルタ、タイムスタンプ取得、フォーマット書き出し）
5. `attrs` の comptime イテレーション（`@typeInfo` + `inline for`）
6. テキスト形式レンダラの実装
7. JSON 形式レンダラの実装
8. `err` / `warn` / `info` / `debug` の実装
9. 各関数のテスト作成
10. `src/root.zig` への公開エクスポート

## 技術メモ（Zig 0.16 固有）

- 出力先は `std.Io.File.stdout() / .stderr()` → `file.writer(io, &buf)` で取得
- `std.Io.Writer` は非ジェネリック。バッファは呼び出し元が保持
- ログ出力ごとに `writer.flush()` を呼ぶ
- ファイル出力・タイムスタンプ取得ともに `std.Io` インスタンスが必要 → `Logger` に `io: std.Io` フィールドを持たせる
- タイムスタンプは `std.Io.Timestamp.now(io, .real)` で取得（`nanoseconds: i96` を持つ）
- RFC 3339 フォーマッタは標準ライブラリに存在しないため自前実装（Unix 秒から年月日時分秒へ変換）
- ログレベルは `std.log.Level` を流用（.err / .warn / .info / .debug）
- テスト時は `std.testing.io` を `std.Io` として使用できる
