# zlog

[![API Docs](https://img.shields.io/badge/API%20Docs-GitHub%20Pages-blue)](https://dot96gal.github.io/zlog/)
[![CI](https://github.com/dot96gal/zlog/actions/workflows/ci.yml/badge.svg)](https://github.com/dot96gal/zlog/actions/workflows/ci.yml)
[![Release](https://github.com/dot96gal/zlog/actions/workflows/release.yml/badge.svg)](https://github.com/dot96gal/zlog/actions/workflows/release.yml)

Zig のシンプルな構造化ロギングのライブラリ。

- タイムスタンプ（RFC 3339、ミリ秒精度）付きログ出力
- ログレベルフィルタリング（`err` / `warn` / `info` / `debug`）
- `log` メソッドによるログレベルの動的指定
- logfmt 形式・JSON 形式の切り替え（文字列は適切にエスケープ）
- `withFields` によるロガーレベルフィールドの型安全な付与
- `Options` 構造体による初期設定
- 共有 `std.Io.Mutex` によるスレッド安全な出力（オプトイン）

> **注意:** このリポジトリは個人的な興味・学習を目的としたホビーライブラリです。設計上の判断はすべて作者が個人で行っており、事前の告知なく破壊的変更が加わることがあります。安定した API を前提としたい場合は、任意のコミットやタグ時点でフォークし、独自に管理されることをおすすめします。

## 要件

- Zig 0.16.0 以上

## 利用者向け

### インストール

#### 1. `build.zig.zon` に zlog を追加する。

最新のタグは [GitHub Releases](https://github.com/dot96gal/zlog/releases) で確認できる。

以下のコマンドを実行すると、`build.zig.zon` の `.dependencies` に自動的に追加される。

```sh
zig fetch --save https://github.com/dot96gal/zlog/archive/refs/tags/<version>.tar.gz
```

```zig
// build.zig.zon（自動追加される内容の例）
.dependencies = .{
    .zlog = .{
        .url = "https://github.com/dot96gal/zlog/archive/refs/tags/<version>.tar.gz",
        .hash = "<hash>",
    },
},
```

#### 2. `build.zig` で zlog モジュールをインポートする。

```zig
const zlog_dep = b.dependency("zlog", .{
    .target = target,
    .optimize = optimize,
});
const zlog_mod = zlog_dep.module("zlog");
exe.root_module.addImport("zlog", zlog_mod);
```

### 使い方

#### Logger の初期化

`DefaultLogger` はフィールドなしの標準的なロガーで、`Logger(struct {})` の糖衣構文。

```zig
const std = @import("std");
const zlog = @import("zlog");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), io, &buf);
    const writer = &file_writer.interface;

    const logger = zlog.DefaultLogger.init(io, writer, .{}, .{});
}
```

#### ログ出力

`attrs` にはコンパイル時固定のフィールド名と実行時の値を持つ匿名構造体を渡す。

```zig
try logger.err("connection failed", .{ .host = "db.example.com" });
try logger.warn("disk usage high", .{ .percent = 85 });
try logger.info("server started", .{ .port = 8080 });
try logger.debug("request received", .{ .method = "GET", .path = "/api/v1/users" });
```

> **`msg` はコンパイル時定数**
>
> `msg` にはコンパイル時に決まる文字列リテラルのみ渡せる。実行時に組み立てた文字列を渡すとコンパイルエラーになる。実行時の値は `attrs` に載せる。
>
> ```zig
> // NG: 実行時文字列は msg に渡せない（コンパイルエラー）
> var buf: [64]u8 = undefined;
> const label = try std.fmt.bufPrint(&buf, "user {} logged in", .{user_id});
> try logger.info(label, .{});
>
> // OK: 固定の msg + attrs で実行時の値を渡す
> try logger.info("user logged in", .{ .user_id = user_id });
> ```

属性値に使用できる型は以下の通り。サポート外の型（struct など）を渡すとコンパイルエラーになる。

| 型 | サポート |
|----|---------|
| `int`（`u32`・`i64`・`usize` など） | ○ |
| `bool` | ○ |
| `f32`・`f64`（浮動小数点） | ○（NaN・Infinity は特別な文字列で出力） |
| `[]const u8`（文字列） | ○ |
| struct・enum・その他 | **コンパイルエラー** |

`enum` や `struct` などサポート外の型は、ライブラリ側で一律に文字列化せず、呼び出し側で明示的に変換して渡す（例：`enum` は `@tagName(value)`）。変換方法を呼び出し側が選べるようにするための設計。

> **JSON 数値の精度**
>
> `int` 型の属性値は JSON でも数値として出力する。受信側の JSON パーサが数値を IEEE 754 倍精度で扱う場合（JavaScript の `JSON.parse` など）、2^53 を超える整数は精度を失う可能性がある。大きな整数（ID など）を正確に保持したい場合は、文字列（`[]const u8`）として渡す。これも「ライブラリは値を一律変換せず、必要なら呼び出し側が変換する」という上記の設計方針に沿っている。

> **予約済みの属性名**
>
> `time` / `level` / `msg` はログの基本フィールド名として予約されており、`attrs` のキーには使えない。指定するとコンパイルエラーになる（後述の `withFields` で付与する `fields` も同様）。

> **属性名・フィールド名に使える文字**
>
> キー名（`attrs` および `withFields` の `fields`）に使える文字は `[A-Za-z0-9_.-]` に限定される。logfmt・JSON いずれの出力も壊さないための制約で、それ以外の文字（スペース・記号・マルチバイト文字など）を含む名前を `@"..."` 構文で指定するとコンパイルエラーになる。通常の Zig 識別子はこの範囲に収まる。

出力例（logfmt 形式）：

```
time="2026-04-20T12:34:56.000Z" level=error msg="connection failed" host="db.example.com"
time="2026-04-20T12:34:56.000Z" level=warning msg="disk usage high" percent=85
time="2026-04-20T12:34:56.000Z" level=info msg="server started" port=8080
time="2026-04-20T12:34:56.000Z" level=debug msg="request received" method="GET" path="/api/v1/users"
```

#### ログレベルの動的指定

ログレベルを実行時に決定したい場合は `log` メソッドを使う。

```zig
const level: std.log.Level = getLevel(); // 実行時に決まるレベル
try logger.log(level, "threshold exceeded", .{ .value = 42 });
```

#### JSON 形式

```zig
const json_logger = zlog.DefaultLogger.init(io, writer, .{ .format = .json }, .{});
try json_logger.info("user logged in", .{ .user_id = 42, .ip = "127.0.0.1" });
```

出力例：

```
{"time":"2026-04-20T12:34:56.000Z","level":"info","msg":"user logged in","user_id":42,"ip":"127.0.0.1"}
```

#### ロガーレベルフィールド

`withFields` を使うと、親ロガーにフィールドを追加した子ロガーを型安全に生成できる。フィールドはログ出力の `level` と `msg` の間に挿入される。

```zig
const db_logger = logger.withFields(.{ .scope = "database" });
try db_logger.info("query executed", .{ .duration_ms = 42 });
```

出力例：

```
time="2026-04-20T12:34:56.000Z" level=info scope="database" msg="query executed" duration_ms=42
```

`withFields` は連鎖できる。各呼び出しで新しい型の子ロガーが生成され、フィールドが累積される。

```zig
const req_logger = logger.withFields(.{ .service = "api", .request_id = "abc-123" });
const user_logger = req_logger.withFields(.{ .user_id = 42 });
try user_logger.info("authorized", .{});
// => time="..." level=info service="api" request_id="abc-123" user_id=42 msg="authorized"
```

#### 関数・構造体へのロガーの受け渡し

`Logger` は `FieldsType` を型パラメータに取るため、`withFields` を呼ぶたびに**別の型**になる（フィールドが累積されるたびに型が変わる）。これは型安全の代償であり、ロガーを関数や構造体へ渡すときは型の扱いに注意する。

**関数に渡す場合は `anytype` で受ける**のが最もシンプル。フィールド構成の異なるロガーを区別なく受け取れる。

```zig
fn handleRequest(logger: anytype) !void {
    try logger.info("handling request", .{});
}
```

特定のフィールド構成だけを受け取りたい場合は、具体型を明示する。

```zig
fn handleRequest(logger: zlog.Logger(struct { scope: []const u8 })) !void {
    try logger.info("handling request", .{});
}
```

**構造体にロガーを保持する場合は具体型が必須**（フィールドの型は `anytype` にできない）。`withFields` でフィールドを足すと型が変わるため、保持したい構成を型として書く。

```zig
const Server = struct {
    logger: zlog.Logger(struct { scope: []const u8 }),
};
```

#### ログレベルフィルタリング

`Options` の `level` フィールドで最小出力レベルを指定する。指定レベルより詳細なログは出力されない。

```zig
// .info レベル以上のみ出力（.debug は出力されない）
const logger = zlog.DefaultLogger.init(io, writer, .{ .level = .info }, .{});
```

#### `Options` による設定

`Options` はすべてのフィールドにデフォルト値を持つ。`.{}` でデフォルト設定のまま初期化でき、必要なフィールドだけを指定できる。

```zig
// デフォルト（level: .info, format: .logfmt）
const logger = zlog.DefaultLogger.init(io, writer, .{}, .{});

// オプションを指定
const logger = zlog.DefaultLogger.init(io, writer, .{
    .level = .debug,
    .format = .json,
}, .{});
```

#### スレッド安全性

zlog は各ログ出力の最後で必ず `writer` を flush する（書き込みをバッファに溜めず、1 行ごとに確実に出力する）。そのためクラッシュ時もログが残る。

ただしデフォルトではロックを持たないため、複数スレッドから同じ `writer` を共有して出力すると、1 ログ行が複数の書き込みに分割されることで出力が交錯する可能性がある。

並行出力する場合は `Options.mutex` に共有 `std.Io.Mutex` を渡す。zlog が各ログ出力（タイムスタンプの採取〜書き込み〜flush 全体）をロックで囲むため、ログ行の交錯を防ぎ、出力順とタイムスタンプ順も一致する。`withFields` で派生したロガーにも同じ mutex が引き継がれる。

```zig
var log_mutex: std.Io.Mutex = .init;
const logger = zlog.DefaultLogger.init(io, writer, .{ .mutex = &log_mutex }, .{});

// 複数スレッドから安全に出力できる
try logger.info("from thread", .{ .id = thread_id });
```

mutex は呼び出し元が所有し、ロガー間で共有する。ロガーは値型のため、ポインタで渡すことで全ロガーが同じ mutex を参照する。

### API リファレンス

#### `Error`

| 値 | 説明 |
|----|------|
| `WriteFailed` | 出力先への書き込みに失敗した |

#### `Format`

| 値 | 説明 |
|----|------|
| `.logfmt` | logfmt 形式のログ（`key=value` の羅列、デフォルト） |
| `.json` | JSON オブジェクト形式のログ |

#### `Options`

| フィールド | 型 | デフォルト | 説明 |
|-----------|-----|-----------|------|
| `level` | `std.log.Level` | `.info` | 最小出力レベル |
| `format` | `Format` | `.logfmt` | 出力形式 |
| `mutex` | `?*std.Io.Mutex` | `null` | 指定すると各ログ出力をロックで囲み、並行出力時の行の交錯を防ぐ |

#### `DefaultLogger`

`Logger(struct {})` の糖衣構文。フィールドなしの一般的なユースケース向け。

#### `Logger(FieldsType)`

`comptime FieldsType: type` でパラメータ化された型生成関数。

| 関数 | シグネチャ | 説明 |
|------|-----------|------|
| `init` | `(io, writer, options: Options, fields: FieldsType) Logger(FieldsType)` | Logger を生成する |
| `withFields` | `(extra: anytype) Logger(...)` | 親の `FieldsType` に `extra` をマージした新しい Logger 型の子ロガーを生成する |
| `log` | `(msg_level, comptime msg, attrs) Error!void` | 指定レベルでログを出力する |
| `err` | `(comptime msg, attrs) Error!void` | エラーレベルでログを出力する |
| `warn` | `(comptime msg, attrs) Error!void` | 警告レベルでログを出力する |
| `info` | `(comptime msg, attrs) Error!void` | 情報レベルでログを出力する |
| `debug` | `(comptime msg, attrs) Error!void` | デバッグレベルでログを出力する |

---

## 開発者向け

### 必要なツール

| ツール | 説明 |
|-------|------|
| [mise](https://mise.jdx.dev/) | ツールバージョン管理（Zig・zls を自動インストール） |
| `zig-lint` | Zig 簡易リントスクリプト（`~/.local/bin/` にインストール済み） |
| `zig-release` | バージョン更新・タグ付けスクリプト（`~/.local/bin/` にインストール済み） |

### セットアップ

```sh
git clone https://github.com/dot96gal/zlog
cd zlog
mise install
```

### タスク一覧

| コマンド | 説明 |
|---------|------|
| `mise run fmt` | フォーマット |
| `mise run fmt-check` | フォーマットチェック |
| `mise run lint` | リント |
| `mise run build` | ビルド |
| `mise run test` | テスト |
| `mise run example:basic` | basic サンプルの実行 |
| `mise run build-coverage` | カバレッジレポートのビルド |
| `mise run serve-coverage` | カバレッジレポートのローカルサーブ |
| `mise run build-docs` | API ドキュメントのビルド |
| `mise run serve-docs` | API ドキュメントのローカルサーブ |
| `mise run release <version>` | バージョンバンプ・コミット・タグ・プッシュ |

### ファイル構成

```
zlog/
├── src/
│   ├── zlog.zig      # 公開 API のエクスポート
│   └── logger.zig    # Logger 実装・テスト
├── examples/
│   └── basic.zig     # 使用例
├── build.zig         # ビルドスクリプト
└── build.zig.zon     # 依存関係・パッケージ定義
```

### 設計方針

**構造化ログの attrs に `comptime anytype` を採用**

フィールド名はコンパイル時固定、値は実行時でも渡せる。アロケータ不要でシンプルに保てる。

```zig
logger.info("user logged in", .{ .user_id = user_id, .ip = ip_str });
```

**`Options` による初期設定**

すべてのフィールドにデフォルト値を持つ Options 構造体を `init` に渡す。シグネチャを変えずに新しいオプションを追加できる。

**`withFields` によるロガーレベルフィールドの型安全な付与**

`Logger` を `comptime FieldsType: type` でパラメータ化することで、ロガーレベルのフィールドを型安全に保持できる。`withFields` は親の `FieldsType` と追加フィールドの型をコンパイル時にマージした新しい `Logger` 型を返す。`fields` と `attrs` のフィールド名が衝突する場合、および予約語（`time` / `level` / `msg`）と衝突する場合はコンパイルエラーになる。

このアプローチの代償として、`withFields` のたびにロガーの型が変わる。関数や構造体へ受け渡す際は型の扱いに注意が必要で、その指針は利用者向けの「[関数・構造体へのロガーの受け渡し](#関数構造体へのロガーの受け渡し)」を参照。アロケータや動的ディスパッチを避けるため、ランタイムにフィールドを保持する型消去はあえて提供していない。

**フォーマットは enum で切り替え**

logfmt / JSON の 2 択を `switch` で分岐するシンプルな実装。

**属性値は `int`・`bool`・`float`・`string` に限定**

`struct`・`enum` 等のカスタム型はコンパイル時に `@compileError` で拒否する。`enum` を一部だけ（網羅的なもののみ）受け入れるといった条件付きサポートはせず、サポート外の型は一律に呼び出し側で文字列化して渡す設計とした。これにより型サポートの境界に例外がなくなり、`enum` の文字列化方法（`@tagName` か独自のラベルか）も呼び出し側が選べる。`f32`・`f64` は受け入れる。JSON 仕様で数値として表現できない `NaN`・`Infinity` はプロセスを止めず、logfmt では `NaN`・`+Inf`・`-Inf`、JSON ではクォートした文字列（`"NaN"` など）として出力する。テキスト形式・JSON 形式で同じ型制約を適用するため、`format` を切り替えても型エラーは発生しない。

**文字列値の不正な UTF-8 は U+FFFD に置換する**

文字列値（`msg`・文字列の `attrs`/`fields`）に不正な UTF-8 バイト列が含まれる場合、置換文字 `�`（U+FFFD）に置き換えて出力する。`NaN`・`Infinity` と同じく、不正な入力でログ出力を止めず（プロセスを落とさず）、出力が常に妥当な UTF-8（したがって妥当な JSON）になることを保証する設計とした。

**`msg` は logfmt・JSON 両形式で常に出力する**

`msg` はコンパイル時定数のため、動的な内容は `attrs` に渡す設計を前提としている。`msg` に `\n` が含まれる場合、エスケープされて `\n` として出力されるため、1 行 1 ログの構造は維持される。

**常に flush し、スレッド安全性はロックでオプトインする**

各ログ出力の最後で必ず `writer` を flush する。バッファリングによる性能最適化よりも、1 行ごとに確実に出力する単純さとクラッシュ耐性を優先した（`std.log` と同じ方針）。flush を任意にすると、バッファを吐くための手動 flush がロック外に漏れてスレッド安全性の穴になるため、その選択肢は設けない。並行出力のためのロックは `Options.mutex` でオプトインし、書き込み〜flush 全体を囲む。mutex は呼び出し元が所有・共有する。

### テスト

テストは `src/logger.zig` 内に実装ごとに記述している。

```sh
mise run test
```

---

## ライセンス

[MIT](LICENSE)
