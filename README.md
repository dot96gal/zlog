# zlog

[![API Docs](https://img.shields.io/badge/API%20Docs-GitHub%20Pages-blue)](https://dot96gal.github.io/zlog/)
[![CI](https://github.com/dot96gal/zlog/actions/workflows/ci.yml/badge.svg)](https://github.com/dot96gal/zlog/actions/workflows/ci.yml)
[![Release](https://github.com/dot96gal/zlog/actions/workflows/release.yml/badge.svg)](https://github.com/dot96gal/zlog/actions/workflows/release.yml)

Zig のシンプルな構造化ロギングのライブラリ。

- タイムスタンプ（RFC 3339）付きログ出力
- ログレベルフィルタリング（`err` / `warn` / `info` / `debug`）
- `log` メソッドによるログレベルの動的指定
- テキスト形式・JSON 形式の切り替え（JSON 出力は文字列を適切にエスケープ）
- ロガー名（スコープ）によるログの区別
- `Logger.Options` 構造体による初期設定

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

```zig
const std = @import("std");
const zlog = @import("zlog");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), io, &buf);
    const writer = &file_writer.interface;

    const logger = zlog.Logger.init(io, writer, .{});
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

出力例（テキスト形式）：

```
2026-04-20T12:34:56Z [ERROR] connection failed host="db.example.com"
2026-04-20T12:34:56Z [WARN] disk usage high percent=85
2026-04-20T12:34:56Z [INFO] server started port=8080
2026-04-20T12:34:56Z [DEBUG] request received method="GET" path="/api/v1/users"
```

#### ログレベルの動的指定

ログレベルを実行時に決定したい場合は `log` メソッドを使う。

```zig
const level: std.log.Level = getLevel(); // 実行時に決まるレベル
try logger.log(level, "threshold exceeded", .{ .value = 42 });
```

#### JSON 形式

```zig
var json_logger = logger;
json_logger.options.format = .json;
try json_logger.info("user logged in", .{ .user_id = 42, .ip = "127.0.0.1" });
```

出力例：

```
{"time":"2026-04-20T12:34:56Z","level":"info","msg":"user logged in","user_id":42,"ip":"127.0.0.1"}
```

#### スコープ

```zig
var db_logger = logger;
db_logger.options.scope = "database";
try db_logger.info("query executed", .{ .duration_ms = 42 });
```

出力例：

```
2026-04-20T12:34:56Z [INFO] [database] query executed duration_ms=42
```

#### ログレベルフィルタリング

`Logger.Options` の `level` フィールドで最小出力レベルを指定する。指定レベルより詳細なログは出力されない。

```zig
// .info レベル以上のみ出力（.debug は出力されない）
const logger = zlog.Logger.init(io, writer, .{ .level = .info });
```

#### `Logger.Options` による設定

`Logger.Options` はすべてのフィールドにデフォルト値を持つ。`.{}` でデフォルト設定のまま初期化でき、必要なフィールドだけを指定できる。

```zig
// デフォルト（level: .info, format: .text）
const logger = zlog.Logger.init(io, writer, .{});

// オプションを指定
const logger = zlog.Logger.init(io, writer, .{
    .level = .debug,
    .format = .json,
    .scope = "api",
});
```

初期化後にフィールドを直接変更して派生ロガーを作ることもできる。

```zig
var db_logger = logger;
db_logger.options.scope = "database";
```

### API リファレンス

#### `Logger.Error`

| 値 | 説明 |
|----|------|
| `WriteFailed` | 出力先への書き込みに失敗した |

#### `Logger.Format`

| 値 | 説明 |
|----|------|
| `.text` | テキスト形式のログ（デフォルト） |
| `.json` | JSON オブジェクト形式のログ |

#### `Logger.Options`

| フィールド | 型 | デフォルト | 説明 |
|-----------|-----|-----------|------|
| `level` | `std.log.Level` | `.info` | 最小出力レベル |
| `format` | `Logger.Format` | `.text` | 出力形式 |
| `scope` | `?[]const u8` | `null` | ロガー名（スコープ） |
| `fixed_timestamp` | `?std.Io.Timestamp` | `null` | 固定タイムスタンプ（テスト用） |

#### `Logger`

| 関数 | シグネチャ | 説明 |
|------|-----------|------|
| `init` | `(io, writer, options: Options) Logger` | Logger を生成する |
| `log` | `(msg_level, msg, attrs) Error!void` | 指定レベルでログを出力する |
| `err` | `(msg, attrs) Error!void` | エラーレベルでログを出力する |
| `warn` | `(msg, attrs) Error!void` | 警告レベルでログを出力する |
| `info` | `(msg, attrs) Error!void` | 情報レベルでログを出力する |
| `debug` | `(msg, attrs) Error!void` | デバッグレベルでログを出力する |

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

**`Logger.Options` による初期設定**

すべてのフィールドにデフォルト値を持つ Options 構造体を `init` に渡す。シグネチャを変えずに新しいオプションを追加できる。

**フォーマットは enum で切り替え**

テキスト / JSON の 2 択を `switch` で分岐するシンプルな実装。

### テスト

テストは `src/logger.zig` 内に実装ごとに記述している。

```sh
mise run test
```

---

## ライセンス

[MIT](LICENSE)
