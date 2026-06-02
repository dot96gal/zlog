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

zlog のログ 1 行は、自動付与される `time`・`level` と、利用者が渡す `msg`・`fields`・`attrs` から成る。

```
time="2026-04-20T12:34:56.000Z" level=info <fields> msg="event" <attrs>
```

| 用語 | 意味 | 指定方法 |
|------|------|---------|
| `level`（レベル） | ログの重要度（`err` / `warn` / `info` / `debug`） | `logger.info(...)` 等のメソッドで指定。`Options.level` で出力をフィルタできる |
| `msg`（メッセージ） | イベントを表す固定文字列（コンパイル時定数） | 各ログ呼び出しの第 1 引数 |
| `fields`（フィールド） | ログ共通で渡す key-value | `withFields` で付与（以降の全ログに自動で載る） |
| `attrs`（属性） | ログ呼び出しごとに渡す key-value | 各ログ呼び出しの第 2 引数（`.{ .key = value }`） |

`time`（RFC3339 のタイムスタンプ）と `level` は自動で付与される。`fields` はロガー生成時に固定し、`attrs` は呼び出しごとに変える、という使い分けになる。属性に使える型は後述（int/bool/float/string + enum/optional/struct/array）。

#### Logger の初期化

`DefaultLogger` はフィールドなしの標準的なロガー。

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

各レベルのメソッド（`err` / `warn` / `info` / `debug`）は、第 1 引数に `msg`（固定のイベント名）、第 2 引数に `attrs` を取る。`attrs` はコンパイル時固定のキー名と実行時の値を持つ匿名構造体（`.{ .key = value }`）。

```zig
try logger.err("connection failed", .{ .host = "db.example.com" });
try logger.warn("disk usage high", .{ .percent = 85 });
try logger.info("server started", .{ .port = 8080 });
try logger.debug("request received", .{ .method = "GET", .path = "/api/v1/users" });
```

ログレベルを実行時に決定したい場合は `log` メソッドを使う。第 1 引数に `std.log.Level` を取り、以降は各レベルメソッドと同じ（第 2 引数に `msg`、第 3 引数に `attrs`）。

```zig
const level: std.log.Level = getLevel(); // 実行時に決まるレベル
try logger.log(level, "threshold exceeded", .{ .value = 42 });
```

#### メッセージ（`msg`）

`msg` はコンパイル時定数（コンパイル時に決まる文字列リテラル）に限定される。構造化ログでは「メッセージは固定のイベント名にし、動的な値は属性（`attrs`）に載せる」のが望ましい使い方で、`msg` に実行時の値を埋め込むと同種のイベントをまとめて集計・検索しにくくなる（アンチパターン）。zlog はこの使い方を型で強制し、実行時に組み立てた文字列を渡すとコンパイルエラーになる。実行時の値は `attrs` に載せる。

```zig
// OK: 固定の msg + attrs で実行時の値を渡す
try logger.info("user logged in", .{ .user_id = user_id });

// NG: 実行時文字列は msg に渡せない（コンパイルエラー）
var buf: [64]u8 = undefined;
const label = try std.fmt.bufPrint(&buf, "user {} logged in", .{user_id});
try logger.info(label, .{});
```

#### フィールド・属性の型

`fields`・`attrs` に使用できる型は以下の通り。サポート外の型を渡すとコンパイルエラーになる。

| 型 | サポート | 表現 |
|----|---------|------|
| `int`（`u32`・`i64`・`usize` など） | ○ | `port=8080` / `"port":8080` |
| `bool` | ○ | `enabled=true` / `"enabled":true` |
| `f32`・`f64`（浮動小数点） | ○ | NaN・Infinity は特別な文字列で出力 |
| `[]const u8`（文字列） | ○ | `ip="127.0.0.1"` / `"ip":"127.0.0.1"` |
| `enum` | ○ | `@tagName` で `status="active"`（後述） |
| optional `?T` | ○ | 値はそのまま、`null` は `key=null` / `"key":null` |
| struct（ネスト） | ○ | logfmt はドット平坦化 `user.id=42`、JSON はネイティブ `"user":{…}` |
| array / slice（配列） | ○ | logfmt は値内 JSON `ids=[1,2,3]`、JSON はネイティブ `"ids":[…]` |
| 位置指定タプル `.{ 1, 2 }` | **コンパイルエラー** | 並びは配列 `[_]T{...}`、レコードは named struct を使う |
| ポインタ `*T`・`union`・その他 | **コンパイルエラー** | 呼び出し側で変換して渡す |

> **予約済みのフィールド名・属性名**
>
> `time` / `level` / `msg` はログの基本フィールド名として予約されており、`attrs`・`fields` の**トップレベル**のキーには使えない（コンパイルエラー）。ネスト struct の内側では平坦化でプレフィックスが付く（`user.time`）ため、予約名と衝突せず使用できる。

> **フィールド名・属性名に使える文字**
>
> フィールド名・属性名に使える文字は `[A-Za-z0-9_.-]` に限定される。logfmt・JSON いずれの出力も壊さないための制約で、それ以外の文字（スペース・記号・マルチバイト文字など）を含む名前を `@"..."` 構文で指定するとコンパイルエラーになる。通常の Zig 識別子はこの範囲に収まる。

`enum` は `@tagName` でバリアント名を文字列として出力する（非網羅 enum の未知値は `unknown(数値)` でフォールバック）。数値で出したい場合は `@intFromEnum(value)` を渡す。`union`・ポインタなどサポート外の型は、ライブラリ側で一律に変換せず、呼び出し側で明示的に変換して渡す（`union` は `@tagName(value)`、ポインタは `ptr.*` でデリファレンス、error は `@errorName(e)`）。変換方法を呼び出し側が選べるようにするための設計。

> **JSON 数値の精度**
>
> `int` 型の属性は JSON でも数値として出力する。受信側の JSON パーサが数値を IEEE 754 倍精度で扱う場合（JavaScript の `JSON.parse` など）、2^53 を超える整数は精度を失う可能性がある。大きな整数（ID など）を正確に保持したい場合は、文字列（`[]const u8`）として渡す。これも「ライブラリは値を一律変換せず、必要なら呼び出し側が変換する」という上記の設計方針に沿っている。

出力例：

```
time="2026-04-20T12:34:56.000Z" level=error msg="connection failed" host="db.example.com"
time="2026-04-20T12:34:56.000Z" level=warning msg="disk usage high" percent=85
time="2026-04-20T12:34:56.000Z" level=info msg="server started" port=8080
time="2026-04-20T12:34:56.000Z" level=debug msg="request received" method="GET" path="/api/v1/users"
```

**ネスト構造・配列・optional** も属性に渡せる。

```zig
try logger.info("request handled", .{
    .user = .{ .id = 42, .name = "alice" },   // ネスト struct
    .tags = [_][]const u8{ "a", "b" },          // 配列
    .parent_id = @as(?u32, null),               // optional（null）
});
```

出力例：

```
# logfmt
... user.id=42 user.name="alice" tags=["a","b"] parent_id=null
# JSON
... "user":{"id":42,"name":"alice"},"tags":["a","b"],"parent_id":null
```

> **logfmt の構造表現は平坦化**
>
> logfmt はフラットな `key=value` 形式のため、ネストはドット平坦化（`user.id=42`）、配列は値内 JSON（`tags=["a","b"]`）で表現する。標準の logfmt パーサーはこれらを**フラットなキー/文字列としてパースするのみで、構造には復元しない**（ドットを区切りとして展開するかは受信側の集計基盤の設定次第）。構造を完全に保持・復元したい場合は JSON 形式（`.format = .json`）を使う。

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

##### ログレベルフィルタリング

`Options` の `level` フィールドで最小出力レベルを指定する。指定レベルより詳細なログは出力されない。

```zig
// .info レベル以上のみ出力（.debug は出力されない）
const logger = zlog.DefaultLogger.init(io, writer, .{ .level = .info }, .{});
```

##### ログフォーマット

出力形式は `Options.format` で切り替える。デフォルトは **logfmt**（`key=value` を空白区切りで並べる形式）、`.json` で **JSON** オブジェクト形式になる。

```zig
// logfmt（デフォルト）
const logger = zlog.DefaultLogger.init(io, writer, .{}, .{});
// JSON
const json_logger = zlog.DefaultLogger.init(io, writer, .{ .format = .json }, .{});
```

同じログ（`info("user logged in", .{ .user_id = 42, .ip = "127.0.0.1" })`）の出力：

```
# logfmt
time="2026-04-20T12:34:56.000Z" level=info msg="user logged in" user_id=42 ip="127.0.0.1"
# JSON
{"time":"2026-04-20T12:34:56.000Z","level":"info","msg":"user logged in","user_id":42,"ip":"127.0.0.1"}
```

##### スレッド安全性

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

なお mutex は各ログ出力（タイムスタンプ採取〜書き込み〜flush）全体を直列化するため、高並行下では全スレッドのログがこの区間でシリアライズされる。これは行の交錯を防ぐための意図的なトレードオフ。出力先をスレッドごとに分けられる場合は、各スレッドに別の `writer` を渡せば mutex なしで交錯を避けられる（per-thread 出力）。同一の出力先へ高並行に書く場合は、正しさ（行の atomicity）のため直列化は避けられない。

#### フィールドの付与（`withFields`）

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

**最も摩擦が少ないのは、ロガーを状態として保持せず、必要なときに生成すること。** 型が変わらない `io` / `writer` / `Options` と、付与したいフィールドを持つ**コンテキスト構造体**を引き回し、ログ箇所で `init().withFields(ctx)` する。ロガーを変数や構造体に保持しないため、型が変わる問題そのものが発生しない。

```zig
const ReqCtx = struct { request_id: []const u8, user_id: u32 };

fn handleRequest(io: std.Io, writer: *std.Io.Writer, opts: zlog.Options, ctx: ReqCtx) !void {
    const logger = zlog.DefaultLogger.init(io, writer, opts, .{}).withFields(ctx);
    try logger.info("handling request", .{});
    // => ... request_id="..." user_id=... msg="handling request"
}
```

`ReqCtx` は型が固定なので構造体フィールドにも引数にも自由に置ける。`withFields(ctx)` の戻り値型は可変だが、その場で使い切るため型の取り回しは問題にならない。コンテキストを増やしたいときは、ロガーの型ではなく `ReqCtx`（データの型）にフィールドを足す。

ロガー自体を引き回したい場合は、以下の方法がある。

**関数に渡す場合は `anytype` で受ける**。フィールド構成の異なるロガーを区別なく受け取れる。

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

zlog の設計は次の 3 つの原則に貫かれている。以下の個別の判断は、いずれもこの原則の帰結として導かれる。

1. **コンパイル時に型で固め、実行時アロケーションを持たない** — 名前と型はコンパイル時に確定させ、隠れた割り当て（アロケータ）を持たない。
2. **ログは止まらない** — 不正な値・入力でプロセスを落とさず、1 行ごとに確実に出力する（可用性・クラッシュ耐性を優先）。
3. **制御は呼び出し側に渡し、境界に例外を作らない** — `writer`・`mutex`・型変換は利用者が所有・選択し、ライブラリは一律のルールだけを持つ。

#### 原則 1：コンパイル時に型で固め、実行時アロケーションを持たない

**構造化ログの attrs に `comptime anytype` を採用**

フィールド名はコンパイル時固定、値は実行時でも渡せる。アロケータ不要でシンプルに保てる。

```zig
logger.info("user logged in", .{ .user_id = user_id, .ip = ip_str });
```

**`withFields` によるロガーレベルフィールドの型安全な付与**

`Logger` を `comptime FieldsType: type` でパラメータ化することで、ロガーレベルのフィールドを型安全に保持できる。`withFields` は親の `FieldsType` と追加フィールドの型をコンパイル時にマージした新しい `Logger` 型を返す。`fields` と `attrs` のフィールド名が衝突する場合、および予約語（`time` / `level` / `msg`）と衝突する場合はコンパイルエラーになる。

このアプローチの代償として、`withFields` のたびにロガーの型が変わる。関数や構造体へ受け渡す際は型の扱いに注意が必要で、その指針は利用者向けの「[関数・構造体へのロガーの受け渡し](#関数構造体へのロガーの受け渡し)」を参照。アロケータや動的ディスパッチを避けるため、ランタイムにフィールドを保持する型消去はあえて提供していない。代わりに、ロガーを状態として保持せず `io` / `Options` とコンテキスト構造体を引き回してログ箇所で都度生成する**ステートレスな使い方**を推奨し、型が変わる摩擦を回避する。

**属性の型サポートも comptime 再帰で処理する**

スカラー（`int`・`bool`・`float`・`[]const u8`）に加え、構造化ログの自然な拡張として `enum`・optional（`?T`）・`struct`（ネスト）・array/slice（配列）を受け入れる。いずれも comptime 再帰 + writer ストリーミングで処理し、アロケータを使わない。logfmt は struct をドット平坦化・配列を値内 JSON で、JSON はネイティブで表現する（両形式で同じ型制約のため `format` を切り替えても型エラーは発生しない）。サポート外の型の扱いは原則 3、`NaN`・`Infinity`・非網羅 enum の未知値の表現は原則 2 を参照。

**`msg` はコンパイル時定数で構造化の規律を型強制する**

`msg` はコンパイル時定数に限定し、「固定イベント名 + 構造化フィールド」を型で強制する（データを `msg` に埋めるアンチパターンを防ぐ）。実行時の可変情報は `attrs` に載せる。`msg` は logfmt・JSON 両形式で常に出力し、`\n` が含まれる場合はエスケープされて `\n` として出力されるため、1 行 1 ログの構造は維持される。

**フォーマットは enum で切り替え**

logfmt / JSON の 2 択を `switch` で分岐するシンプルな実装。

#### 原則 2：ログは止まらない（可用性・クラッシュ耐性を優先）

**常に flush する**

各ログ出力の最後で必ず `writer` を flush する。バッファリングによる性能最適化よりも、1 行ごとに確実に出力する単純さとクラッシュ耐性を優先した（`std.log` も `unlockStderr` 内で毎回 flush する同じ方針）。flush を任意にすると、バッファを吐くための手動 flush がロック外に漏れてスレッド安全性の穴になるため、その選択肢は設けない（ロックの詳細は原則 3 を参照）。

この方針は低〜中頻度のログを前提とする。毎秒大量の行を出す高スループット用途では 1 行ごとの flush（syscall）がボトルネックになりうるが、それは zlog のスコープ外であり、`std.log` も同じ割り切りである。

**`NaN`・`Infinity`・未知の enum 値は文字列でフォールバックする**

`f32`・`f64` の `NaN`・`Infinity` は、属性値 1 つでプロセスをクラッシュさせず文字列にフォールバックする。logfmt では `NaN`・`+Inf`・`-Inf`、JSON ではネイティブに表現できないためクォートした文字列（`"NaN"` など）として出力する。非網羅 enum の未知値も同じく `unknown(数値)` にフォールバックし、想定外の値でもログを止めない。

**不正な UTF-8 は U+FFFD に置換する**

文字列値（`msg`・文字列の `attrs`/`fields`）に不正な UTF-8 バイト列が含まれる場合、置換文字 `�`（U+FFFD）に置き換えて出力する。不正な入力でログ出力を止めず（プロセスを落とさず）、出力が常に妥当な UTF-8（したがって妥当な JSON）になることを保証する。

**例外：範囲外タイムスタンプは `@panic` で弾く**

上記と対照的に、RFC3339 整形で範囲外のタイムスタンプ（紀元前・`u64` 超過）を受け取った場合は `@panic` する。これは実システムのクロックでは起こらず、渡された場合は利用者のバグ（誤用）であり、`NaN`・不正 UTF-8 のような「自然に発生しうる入力」とは性質が異なるため、フォールバックせずプログラミングエラーとして弾く。

#### 原則 3：制御は呼び出し側に渡し、境界に例外を作らない

**`Options` による初期設定**

すべてのフィールドにデフォルト値を持つ Options 構造体を `init` に渡す。シグネチャを変えずに新しいオプションを追加できる。

**`writer`・`mutex` は呼び出し元が所有する**

出力先 `writer` は呼び出し元が用意して渡す。複数出力・ログ加工（複数 sink・フィルタ）は `std.Io.Writer` をラップして対応する。スレッド安全性も同様に、並行出力のためのロックは `Options.mutex` でオプトインし、書き込み〜flush 全体を囲む。mutex は呼び出し元が所有・共有し、デフォルト（`null`）はロックなし・ゼロコスト。

**`Error` は `WriteFailed` 一本**

`Error` は `std.Io.Writer.Error` と一致する `error{WriteFailed}` のみ。詳細診断は具体 Writer 実装（`File.Writer` 等）が保持するという std 0.16 の新 IO 設計に従い、抽象 `writer` しか持たない zlog はエラー種別を増やさない。

**サポート外の型・付加情報は利用者が変換して渡す**

型サポートの境界に例外を作らず、サポート外の型は呼び出し側で明示的に変換して渡す。`union`・ポインタ（`*T`）などは `@compileError` で拒否する（`union` は `@tagName`、ポインタは `ptr.*` でデリファレンス）。同様に、ソースコード位置は `@src()` を属性として渡し（集計キーの安定性のため自動付与はしない）、エラー内容は `@errorName(e)` を属性として渡す。変換方法を呼び出し側が選べるようにするための方針。

### テスト

テストは `src/logger.zig` 内に実装ごとに記述している。

```sh
mise run test
```

---

## ライセンス

[MIT](LICENSE)
