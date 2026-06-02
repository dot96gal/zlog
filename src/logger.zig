const std = @import("std");

const reserved_log_fields = [_][]const u8{ "time", "level", "msg" };

// 不正な UTF-8 バイト列を出力するときの置換文字 U+FFFD（logfmt・JSON とも有効な UTF-8）。
const replacement_char = "\u{fffd}";

/// フィールドを持たない標準的な Logger。`Logger(struct {})` の糖衣構文。
pub const DefaultLogger = Logger(struct {});

/// zlog の公開 API が返すエラー集合。
pub const Error = error{
    /// 出力先（writer）への書き込みに失敗した。
    WriteFailed,
};

/// ログの出力形式。
pub const Format = enum {
    /// logfmt 形式（`key=value` の羅列）。
    logfmt,
    /// JSON オブジェクト形式。
    json,

    fn write(
        self: Format,
        writer: *std.Io.Writer,
        level: std.log.Level,
        ts: std.Io.Timestamp,
        fields: anytype,
        comptime msg: []const u8,
        attrs: anytype,
    ) Error!void {
        switch (self) {
            inline else => |format| try writeLine(format, writer, level, ts, fields, msg, attrs),
        }
    }
};

/// Logger の初期設定。すべてのフィールドにデフォルト値を持つ。
pub const Options = struct {
    /// 最小出力レベル。これより詳細なレベルのログは出力されない。
    level: std.log.Level = .info,
    /// 出力形式。
    format: Format = .logfmt,
    /// 共有 mutex。指定すると各ログ出力（タイムスタンプ採取〜書き込み〜flush 全体）を
    /// ロックで囲み、並行出力時の行の交錯を防ぐ。呼び出し元が所有・共有する。
    mutex: ?*std.Io.Mutex = null,
};

/// 構造化ロガーを生成する型関数。`FieldsType` にロガーへ固定付与するフィールドの型を指定する。
/// フィールドが不要な場合は `DefaultLogger` を使う。
pub fn Logger(comptime FieldsType: type) type {
    return struct {
        io: std.Io,
        writer: *std.Io.Writer,
        options: Options,
        fields: FieldsType,

        /// Logger を生成する。`io`・`writer` が出力先、`options` が設定、
        /// `fields` がロガーレベルのフィールド値。フィールド名が空・予約名（time/level/msg）・
        /// 不正文字を含む場合はコンパイルエラーになる。
        pub fn init(
            io: std.Io,
            writer: *std.Io.Writer,
            options: Options,
            fields: FieldsType,
        ) @This() {
            comptime validateFields(FieldsType);

            return .{ .io = io, .writer = writer, .options = options, .fields = fields };
        }

        /// 既存のフィールドに `extra` を追加した子ロガーを生成する。親と追加分の型を
        /// コンパイル時にマージした新しい Logger 型を返す。フィールド名が重複する場合や、
        /// 追加分が空・予約名（time/level/msg）・不正文字を含む場合はコンパイルエラーになる。
        pub fn withFields(
            self: @This(),
            extra: anytype,
        ) Logger(MergeFields(FieldsType, @TypeOf(extra))) {
            const merged = mergeStructs(self.fields, extra);
            return Logger(MergeFields(FieldsType, @TypeOf(extra))).init(
                self.io,
                self.writer,
                self.options,
                merged,
            );
        }

        /// 指定したレベルでログを1行出力する。`msg` はコンパイル時定数の文字列、
        /// `attrs` は属性を表す匿名構造体（実行時の値を渡せる）。
        pub fn log(
            self: @This(),
            msg_level: std.log.Level,
            comptime msg: []const u8,
            attrs: anytype,
        ) Error!void {
            try self.logWithTimestamp(msg_level, null, msg, attrs);
        }

        /// エラーレベル（`.err`）でログを出力する。
        pub fn err(self: @This(), comptime msg: []const u8, attrs: anytype) Error!void {
            try self.log(.err, msg, attrs);
        }

        /// 警告レベル（`.warn`）でログを出力する。
        pub fn warn(self: @This(), comptime msg: []const u8, attrs: anytype) Error!void {
            try self.log(.warn, msg, attrs);
        }

        /// 情報レベル（`.info`）でログを出力する。
        pub fn info(self: @This(), comptime msg: []const u8, attrs: anytype) Error!void {
            try self.log(.info, msg, attrs);
        }

        /// デバッグレベル（`.debug`）でログを出力する。
        pub fn debug(self: @This(), comptime msg: []const u8, attrs: anytype) Error!void {
            try self.log(.debug, msg, attrs);
        }

        fn logWithTimestamp(
            self: @This(),
            msg_level: std.log.Level,
            ts: ?std.Io.Timestamp,
            comptime msg: []const u8,
            attrs: anytype,
        ) Error!void {
            comptime validateLogArgs(FieldsType, @TypeOf(attrs));

            if (!self.isEnabled(msg_level)) return;

            // mutex が渡されている場合、1 ログ行が複数の書き込みに分割されるため
            // write+flush 全体をロックで囲み、並行出力時の行の交錯を防ぐ。
            // ロック待ちを中断するとキャンセルエラーが公開 API に漏れて Error=WriteFailed
            // 一本の方針が崩れ、行の交錯防止も保証できなくなるため lockUncancelable を使う。
            if (self.options.mutex) |m| m.lockUncancelable(self.io);
            defer if (self.options.mutex) |m| m.unlock(self.io);

            // 実時刻の採取をロック内で行うため ts は Optional。null のとき現在時刻を採取し、
            // ロック取得順とタイムスタンプ順を揃えて並行出力時の順序逆転を防ぐ。固定タイムスタンプ
            // （テスト）は logWithTimestamp を直接呼んで値を渡す。
            const resolved_ts = ts orelse std.Io.Timestamp.now(self.io, .real);
            try self.options.format.write(
                self.writer,
                msg_level,
                resolved_ts,
                self.fields,
                msg,
                attrs,
            );
            try self.writer.flush();
        }

        fn isEnabled(self: @This(), level: std.log.Level) bool {
            // err=0, warn=1, info=2, debug=3 — 数値が大きいほど重要度が低い
            return @intFromEnum(level) <= @intFromEnum(self.options.level);
        }
    };
}

fn MergeFields(comptime A: type, comptime B: type) type {
    const a_fields = @typeInfo(A).@"struct".fields;
    const b_fields = @typeInfo(B).@"struct".fields;

    for (a_fields) |af| {
        for (b_fields) |bf| {
            if (std.mem.eql(u8, af.name, bf.name)) {
                @compileError("withFields: field '" ++ af.name ++
                    "' already exists in the logger; rename the field");
            }
        }
    }

    const n = a_fields.len + b_fields.len;

    const default_attr = std.builtin.Type.StructField.Attributes{
        .@"comptime" = false,
        .@"align" = 0,
        .default_value_ptr = null,
    };
    var names: [n][]const u8 = [1][]const u8{""} ** n;
    var types: [n]type = [1]type{void} ** n;
    var attrs: [n]std.builtin.Type.StructField.Attributes =
        [1]std.builtin.Type.StructField.Attributes{default_attr} ** n;

    for (a_fields, 0..) |f, i| {
        names[i] = f.name;
        types[i] = f.type;
        attrs[i] = .{
            .@"comptime" = f.is_comptime,
            .@"align" = f.alignment,
            .default_value_ptr = f.default_value_ptr,
        };
    }
    for (b_fields, 0..) |f, i| {
        names[a_fields.len + i] = f.name;
        types[a_fields.len + i] = f.type;
        attrs[a_fields.len + i] = .{
            .@"comptime" = f.is_comptime,
            .@"align" = f.alignment,
            .default_value_ptr = f.default_value_ptr,
        };
    }

    return @Struct(.auto, null, &names, &types, &attrs);
}

fn mergeStructs(a: anytype, b: anytype) MergeFields(@TypeOf(a), @TypeOf(b)) {
    const ResultType = MergeFields(@TypeOf(a), @TypeOf(b));

    var result: ResultType = undefined;
    inline for (@typeInfo(ResultType).@"struct".fields) |field| {
        if (@hasField(@TypeOf(a), field.name)) {
            @field(result, field.name) = @field(a, field.name);
        } else if (@hasField(@TypeOf(b), field.name)) {
            @field(result, field.name) = @field(b, field.name);
        } else {
            @panic("field must belong to either a or b — invariant enforced by MergeFields");
        }
    }

    return result;
}

fn writeLine(
    comptime format: Format,
    writer: *std.Io.Writer,
    level: std.log.Level,
    ts: std.Io.Timestamp,
    fields: anytype,
    comptime msg: []const u8,
    attrs: anytype,
) Error!void {
    try writeTimestamp(format, writer, ts);

    try writeLevel(format, writer, level);

    inline for (std.meta.fields(@TypeOf(fields))) |field| {
        try writeEntry(format, writer, field.name, @field(fields, field.name));
    }

    try writeEntry(format, writer, "msg", msg);

    inline for (std.meta.fields(@TypeOf(attrs))) |field| {
        try writeEntry(format, writer, field.name, @field(attrs, field.name));
    }

    try writeLineTerminator(format, writer);
}

fn writeTimestamp(
    comptime format: Format,
    writer: *std.Io.Writer,
    ts: std.Io.Timestamp,
) Error!void {
    switch (format) {
        .logfmt => try writer.writeAll("time=\""),
        .json => try writer.writeAll("{\"time\":\""),
    }
    try writeRfc3339(writer, ts);
    try writer.writeByte('"');
}

fn writeLevel(comptime format: Format, writer: *std.Io.Writer, level: std.log.Level) Error!void {
    const text = levelText(level);
    switch (format) {
        .logfmt => try writer.print(" level={s}", .{text}),
        .json => try writer.print(",\"level\":\"{s}\"", .{text}),
    }
}

fn writeEntry(
    comptime format: Format,
    writer: *std.Io.Writer,
    comptime name: []const u8,
    value: anytype,
) Error!void {
    const T = @TypeOf(value);
    // 判定順序が重要：文字列（slice/pointer）は array/pointer 判定より先に弾く。
    if (comptime isOptional(T)) {
        if (value) |v| {
            try writeEntry(format, writer, name, v);
        } else {
            try writeKey(format, writer, name);
            try writer.writeAll("null");
        }
    } else if (comptime isStringLike(T)) {
        try writeKey(format, writer, name);
        try writeQuotedString(writer, value);
    } else if (comptime isIntOrBool(T)) {
        try writeKey(format, writer, name);
        try writer.print("{}", .{value});
    } else if (comptime isFloat(T)) {
        try writeKey(format, writer, name);
        if (floatSpecialText(value)) |text| {
            // NaN/Infinity は数値として出力できないため特別な文字列で表現する。
            // JSON は NaN/Infinity をネイティブ表現できないため文字列としてクォートする。
            switch (format) {
                .logfmt => try writer.print("{s}", .{text}),
                .json => try writer.print("\"{s}\"", .{text}),
            }
        } else {
            try writer.print("{}", .{value});
        }
    } else if (comptime isEnum(T)) {
        try writeKey(format, writer, name);
        try writeEnum(writer, value);
    } else if (comptime isStruct(T)) {
        switch (format) {
            // logfmt はネストをドット平坦化（user.id=42）。各フィールドを別エントリとして再帰する。
            // 空 struct は展開対象がなくキーが消えてしまうため、値内 JSON の {} で出力して
            // キーを残す（空配列の key=[] と対称）。
            .logfmt => if (std.meta.fields(T).len == 0) {
                try writeKey(.logfmt, writer, name);
                try writeJsonValue(writer, value);
            } else inline for (std.meta.fields(T)) |field| {
                try writeEntry(
                    .logfmt,
                    writer,
                    name ++ "." ++ field.name,
                    @field(value, field.name),
                );
            },
            // JSON はネイティブのオブジェクト表現。
            .json => {
                try writeKey(.json, writer, name);
                try writeJsonValue(writer, value);
            },
        }
    } else if (comptime isArrayLike(T)) {
        // 配列は両形式とも value 内に JSON 配列リテラルを書く（logfmt のカーディナリティ爆発回避）。
        try writeKey(format, writer, name);
        try writeJsonValue(writer, value);
    } else {
        @compileError(@tagName(format) ++ " format: log field '" ++ name ++
            "' has unsupported type '" ++ @typeName(T) ++
            "'. Supported types: int, bool, float, []const u8, enum, optional," ++
            " struct (nested), array/slice." ++
            " Convert other types first, e.g. @tagName(value) for unions," ++
            " ptr.* to dereference pointers.");
    }
}

// 区切り（先頭 time 以外は前置）+ キー名を書く。logfmt は " name="、JSON は ",\"name\":"。
fn writeKey(comptime format: Format, writer: *std.Io.Writer, comptime name: []const u8) Error!void {
    switch (format) {
        .logfmt => try writer.print(" {s}=", .{name}),
        .json => try writer.print(",\"{s}\":", .{name}),
    }
}

// enum を quoted string で writer に書く。既知バリアントは @tagName、非網羅 enum の未知値は
// unknown(数値) でフォールバック（@intFromEnum 依存で静的文字列を返せないため writer に直接書く）。
fn writeEnum(writer: *std.Io.Writer, value: anytype) Error!void {
    switch (@typeInfo(@TypeOf(value))) {
        .enum_literal => try writeQuotedString(writer, @tagName(value)),
        .@"enum" => |info| if (info.is_exhaustive) switch (value) {
            inline else => |v| try writeQuotedString(writer, @tagName(v)),
        } else switch (value) {
            inline else => |v| try writeQuotedString(writer, @tagName(v)),
            _ => try writer.print("\"unknown({d})\"", .{@intFromEnum(value)}),
        },
        else => @compileError(
            "writeEnum: value must be an enum, got " ++ @typeName(@TypeOf(value)),
        ),
    }
}

// 値を JSON としてエンコードして書く（配列要素・JSON のネスト値で共通）。writeEntry と同じ判定順。
fn writeJsonValue(writer: *std.Io.Writer, value: anytype) Error!void {
    const T = @TypeOf(value);
    if (comptime isOptional(T)) {
        if (value) |v| {
            try writeJsonValue(writer, v);
        } else {
            try writer.writeAll("null");
        }
    } else if (comptime isStringLike(T)) {
        try writeQuotedString(writer, value);
    } else if (comptime isIntOrBool(T)) {
        try writer.print("{}", .{value});
    } else if (comptime isFloat(T)) {
        if (floatSpecialText(value)) |text| {
            try writer.print("\"{s}\"", .{text});
        } else {
            try writer.print("{}", .{value});
        }
    } else if (comptime isEnum(T)) {
        try writeEnum(writer, value);
    } else if (comptime isStruct(T)) {
        try writer.writeByte('{');
        inline for (std.meta.fields(T), 0..) |field, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("\"{s}\":", .{field.name});
            try writeJsonValue(writer, @field(value, field.name));
        }
        try writer.writeByte('}');
    } else if (comptime isArrayLike(T)) {
        try writer.writeByte('[');
        for (value, 0..) |elem, i| {
            if (i > 0) try writer.writeByte(',');
            try writeJsonValue(writer, elem);
        }
        try writer.writeByte(']');
    } else {
        @compileError("json value: unsupported type '" ++ @typeName(T) ++ "'");
    }
}

fn writeLineTerminator(comptime format: Format, writer: *std.Io.Writer) Error!void {
    switch (format) {
        .logfmt => try writer.writeByte('\n'),
        .json => try writer.writeAll("}\n"),
    }
}

fn writeRfc3339(writer: *std.Io.Writer, ts: std.Io.Timestamp) Error!void {
    const seconds = @divFloor(ts.nanoseconds, std.time.ns_per_s);
    if (seconds < 0) @panic("pre-1970 timestamps are not supported");
    if (seconds > std.math.maxInt(u64)) @panic("timestamp out of range");

    const ns_rem = @mod(ts.nanoseconds, std.time.ns_per_s);
    const ms: u16 = @intCast(@divFloor(ns_rem, std.time.ns_per_ms));

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    try writer.print("{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}.{:0>3}Z", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
        ms,
    });
}

fn writeQuotedString(writer: *std.Io.Writer, s: []const u8) Error!void {
    try writer.writeByte('"');

    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => try writer.print("\\u{x:0>4}", .{c}),
                else => try writer.writeByte(c),
            }
            i += 1;
            continue;
        }

        // マルチバイト UTF-8 シーケンス。妥当ならそのまま通し、不正な先頭バイト・長さ不足・
        // 不正なシーケンスは U+FFFD に置換して 1 バイト進める（出力は常に妥当な UTF-8 になる）。
        const seq_len = std.unicode.utf8ByteSequenceLength(c) catch {
            try writer.writeAll(replacement_char);
            i += 1;
            continue;
        };
        if (i + seq_len > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + seq_len])) {
            try writer.writeAll(replacement_char);
            i += 1;
            continue;
        }

        try writer.writeAll(s[i .. i + seq_len]);
        i += seq_len;
    }

    try writer.writeByte('"');
}

fn levelText(level: std.log.Level) []const u8 {
    return switch (level) {
        inline else => |l| comptime l.asText(),
    };
}

// NaN/Infinity は専用文字列を返し、通常の有限値は null を返す（呼び出し元が数値として出力する）。
fn floatSpecialText(value: anytype) ?[]const u8 {
    if (comptime !isFloat(@TypeOf(value))) {
        @compileError("floatSpecialText: value must be a float, got " ++ @typeName(@TypeOf(value)));
    }

    if (std.math.isNan(value)) return "NaN";
    if (std.math.isInf(value)) return if (value > 0) "+Inf" else "-Inf";

    return null;
}

fn validateLogArgs(comptime FieldsType: type, comptime AttrsType: type) void {
    // fields は通常 init で検証済みだが、構造体リテラルで init を経由せず直接構築された
    // ロガーのための backstop として再検証する（comptime のみ・ランタイムコストなし）。
    validateFields(FieldsType);
    validateAttrs(AttrsType);
    validateFieldsAttrsConflict(FieldsType, AttrsType);
}

fn validateFields(comptime T: type) void {
    validateStruct(T, "fields");
    validateName(T, "field");
}

fn validateAttrs(comptime T: type) void {
    validateStruct(T, "attrs");
    validateName(T, "attribute");
}

fn validateStruct(comptime T: type, comptime noun: []const u8) void {
    switch (@typeInfo(T)) {
        // 空の `.{}` は is_tuple=true になりうるため「要素のある位置指定タプル」だけを弾く。
        .@"struct" => |info| if (info.is_tuple and info.fields.len > 0) {
            @compileError(noun ++ " must use named fields, not a positional tuple;" ++
                " use .{ .key = value }");
        },
        else => @compileError(noun ++ " must be a struct, e.g. .{ .key = value }"),
    }
}

fn validateName(comptime T: type, comptime noun: []const u8) void {
    inline for (std.meta.fields(T)) |field| {
        if (field.name.len == 0) {
            @compileError("a " ++ noun ++ " name must not be empty");
        }

        // 予約名チェックはトップレベルのみ。ネストは user.time のように平坦化され予約名と衝突しない。
        inline for (reserved_log_fields) |name| {
            if (std.mem.eql(u8, field.name, name)) {
                @compileError(noun ++ " '" ++ field.name ++
                    "' conflicts with a reserved log field; rename the " ++ noun);
            }
        }

        validateNameChars(field.name, noun);
        validateNestedNames(field.type, noun);
    }
}

// ネストした struct/optional/array/slice の中身を再帰的にたどり、フィールド名の使用文字を検証する。
// 予約名チェックはしない（平坦化でプレフィックスが付くため衝突しない）。単一ポインタは writeEntry 側で弾く。
fn validateNestedNames(comptime T: type, comptime noun: []const u8) void {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            // 値が位置指定タプル（`.{1, 2}`）の場合、logfmt は数値キー平坦化・JSON は
            // 数値キーオブジェクトになり利用者の期待とずれるため、両形式とも comptime で弾く。
            // 空の `.{}` は is_tuple=true になりうるため要素数で除外する。
            if (info.is_tuple and info.fields.len > 0) {
                @compileError(noun ++ " contains a positional tuple value;" ++
                    " use a named struct or an array ([_]T{...}) instead");
            }

            inline for (info.fields) |field| {
                validateNameChars(field.name, noun);
                validateNestedNames(field.type, noun);
            }
        },
        .optional => |opt| validateNestedNames(opt.child, noun),
        .array => |arr| validateNestedNames(arr.child, noun),
        .pointer => |ptr| if (ptr.size == .slice) validateNestedNames(ptr.child, noun),
        else => {},
    }
}

// logfmt（key=value）・JSON（"key":value）のどちらの出力も壊さない文字に限定する。
// 名前はコンパイル時に確定するため @compileError で弾き、ランタイムコストを持たない。
fn validateNameChars(comptime name: []const u8, comptime noun: []const u8) void {
    for (name) |c| {
        if (!isValidNameChar(c)) {
            @compileError(noun ++ " '" ++ name ++
                "' contains an invalid character; use only [A-Za-z0-9_.-]");
        }
    }
}

fn validateFieldsAttrsConflict(comptime FieldsType: type, comptime AttrsType: type) void {
    inline for (std.meta.fields(FieldsType)) |f| {
        inline for (std.meta.fields(AttrsType)) |a| {
            if (std.mem.eql(u8, f.name, a.name)) {
                @compileError("attribute '" ++ a.name ++
                    "' conflicts with a logger field of the same name; rename the attribute");
            }
        }
    }
}

fn isStringLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| switch (ptr.size) {
            .slice => ptr.child == u8,
            .one => switch (@typeInfo(ptr.child)) {
                .array => |arr| arr.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

fn isIntOrBool(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .comptime_int, .bool => true,
        else => false,
    };
}

fn isFloat(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float, .comptime_float => true,
        else => false,
    };
}

fn isEnum(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"enum", .enum_literal => true,
        else => false,
    };
}

fn isStruct(comptime T: type) bool {
    return @typeInfo(T) == .@"struct";
}

fn isArrayLike(comptime T: type) bool {
    // 文字列（[]const u8 / *const [N]u8）は呼び出し側が isStringLike を先に判定して除外する。
    return switch (@typeInfo(T)) {
        .array => true,
        .pointer => |ptr| ptr.size == .slice,
        else => false,
    };
}

fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

fn isValidNameChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-', '.' => true,
        else => false,
    };
}

// --- Format.write ---

test "Format.write" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Format,
        expected: []const u8,
    }{
        .{
            .name = "logfmt",
            .input = .logfmt,
            .expected = "time=\"1970-01-01T00:00:00.000Z\" level=info msg=\"msg\"\n",
        },
        .{
            .name = "json",
            .input = .json,
            .expected = "{\"time\":\"1970-01-01T00:00:00.000Z\"," ++
                "\"level\":\"info\",\"msg\":\"msg\"}\n",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);

        try tc.input.write(
            &writer,
            .info,
            std.Io.Timestamp.fromNanoseconds(0),
            .{},
            "msg",
            .{},
        );

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "Format.write: write fails" {
    var writer = std.Io.Writer.failing;
    try std.testing.expectError(
        error.WriteFailed,
        Format.logfmt.write(
            &writer,
            .info,
            std.Io.Timestamp.fromNanoseconds(0),
            .{},
            "msg",
            .{},
        ),
    );
}

// --- Logger.init ---

test "Logger.init: フィールドなし" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Options,
        expected: Options,
    }{
        .{
            .name = "default options",
            .input = .{},
            .expected = .{ .level = .info, .format = .logfmt },
        },
        .{
            .name = "custom level and format",
            .input = .{ .level = .warn, .format = .json },
            .expected = .{ .level = .warn, .format = .json },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const logger = Logger(struct {}).init(std.testing.io, &writer, tc.input, .{});

        try std.testing.expectEqual(tc.expected.level, logger.options.level);
        try std.testing.expectEqual(tc.expected.format, logger.options.format);
    }
}

test "Logger.init: フィールドあり" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const Fields = struct { scope: []const u8 };
    const logger = Logger(Fields).init(std.testing.io, &writer, .{}, .{ .scope = "app" });

    try std.testing.expectEqualStrings("app", logger.fields.scope);
}

// --- Logger.withFields ---

test "Logger.withFields: フィールド追加" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Format,
        expected: []const u8,
    }{
        .{
            .name = "logfmt",
            .input = .logfmt,
            .expected = "time=\"1970-01-01T00:00:00.000Z\"" ++
                " level=info scope=\"database\" msg=\"query executed\" duration_ms=42\n",
        },
        .{
            .name = "json",
            .input = .json,
            .expected = "{\"time\":\"1970-01-01T00:00:00.000Z\",\"level\":\"info\"," ++
                "\"scope\":\"database\",\"msg\":\"query executed\",\"duration_ms\":42}\n",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const ts = std.Io.Timestamp.fromNanoseconds(0);
        const base = Logger(struct {}).init(
            std.testing.io,
            &writer,
            .{ .format = tc.input },
            .{},
        );
        const child = base.withFields(.{ .scope = "database" });

        try child.logWithTimestamp(.info, ts, "query executed", .{ .duration_ms = 42 });

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "Logger.withFields: 孫ロガー" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const ts = std.Io.Timestamp.fromNanoseconds(0);
    const base = Logger(struct {}).init(std.testing.io, &writer, .{}, .{});
    const child = base.withFields(.{ .service = "api", .request_id = "abc-123" });
    const grandchild = child.withFields(.{ .user_id = @as(u32, 42) });

    try grandchild.logWithTimestamp(.info, ts, "authorized", .{});

    try std.testing.expectEqualStrings(
        "time=\"1970-01-01T00:00:00.000Z\"" ++
            " level=info service=\"api\" request_id=\"abc-123\" user_id=42 msg=\"authorized\"\n",
        buf[0..writer.end],
    );
}

test "Logger.withFields: write fails" {
    var writer = std.Io.Writer.failing;
    const base = DefaultLogger.init(std.testing.io, &writer, .{}, .{});
    const child = base.withFields(.{ .scope = "test" });

    try std.testing.expectError(error.WriteFailed, child.info("msg", .{}));
}

// --- Logger.log ---

test "Logger.log: level filtering, passes" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { min_level: std.log.Level, msg_level: std.log.Level },
        expected: []const u8,
    }{
        .{
            .name = "err:err",
            .input = .{ .min_level = .err, .msg_level = .err },
            .expected = "time=\"1970-01-01T00:00:00.000Z\" level=error msg=\"msg\"\n",
        },
        .{
            .name = "warn:err",
            .input = .{ .min_level = .warn, .msg_level = .err },
            .expected = "time=\"1970-01-01T00:00:00.000Z\" level=error msg=\"msg\"\n",
        },
        .{
            .name = "warn:warn",
            .input = .{ .min_level = .warn, .msg_level = .warn },
            .expected = "time=\"1970-01-01T00:00:00.000Z\" level=warning msg=\"msg\"\n",
        },
        .{
            .name = "info:err",
            .input = .{ .min_level = .info, .msg_level = .err },
            .expected = "time=\"1970-01-01T00:00:00.000Z\" level=error msg=\"msg\"\n",
        },
        .{
            .name = "info:warn",
            .input = .{ .min_level = .info, .msg_level = .warn },
            .expected = "time=\"1970-01-01T00:00:00.000Z\" level=warning msg=\"msg\"\n",
        },
        .{
            .name = "info:info",
            .input = .{ .min_level = .info, .msg_level = .info },
            .expected = "time=\"1970-01-01T00:00:00.000Z\" level=info msg=\"msg\"\n",
        },
        .{
            .name = "debug:err",
            .input = .{ .min_level = .debug, .msg_level = .err },
            .expected = "time=\"1970-01-01T00:00:00.000Z\" level=error msg=\"msg\"\n",
        },
        .{
            .name = "debug:warn",
            .input = .{ .min_level = .debug, .msg_level = .warn },
            .expected = "time=\"1970-01-01T00:00:00.000Z\" level=warning msg=\"msg\"\n",
        },
        .{
            .name = "debug:info",
            .input = .{ .min_level = .debug, .msg_level = .info },
            .expected = "time=\"1970-01-01T00:00:00.000Z\" level=info msg=\"msg\"\n",
        },
        .{
            .name = "debug:debug",
            .input = .{ .min_level = .debug, .msg_level = .debug },
            .expected = "time=\"1970-01-01T00:00:00.000Z\" level=debug msg=\"msg\"\n",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const ts = std.Io.Timestamp.fromNanoseconds(0);
        const logger = Logger(struct {}).init(
            std.testing.io,
            &writer,
            .{ .level = tc.input.min_level },
            .{},
        );

        try logger.logWithTimestamp(tc.input.msg_level, ts, "msg", .{});

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "Logger.log: level filtering, filtered" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { min_level: std.log.Level, msg_level: std.log.Level },
    }{
        .{ .name = "err:warn", .input = .{ .min_level = .err, .msg_level = .warn } },
        .{ .name = "err:info", .input = .{ .min_level = .err, .msg_level = .info } },
        .{ .name = "err:debug", .input = .{ .min_level = .err, .msg_level = .debug } },
        .{ .name = "warn:info", .input = .{ .min_level = .warn, .msg_level = .info } },
        .{ .name = "warn:debug", .input = .{ .min_level = .warn, .msg_level = .debug } },
        .{ .name = "info:debug", .input = .{ .min_level = .info, .msg_level = .debug } },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const ts = std.Io.Timestamp.fromNanoseconds(0);
        const logger = Logger(struct {}).init(
            std.testing.io,
            &writer,
            .{ .level = tc.input.min_level },
            .{},
        );

        try logger.logWithTimestamp(tc.input.msg_level, ts, "msg", .{});

        try std.testing.expectEqual(@as(usize, 0), writer.end);
    }
}

test "Logger.log: write fails" {
    var writer = std.Io.Writer.failing;
    const ts = std.Io.Timestamp.fromNanoseconds(0);
    const logger = Logger(struct {}).init(std.testing.io, &writer, .{}, .{});

    try std.testing.expectError(
        error.WriteFailed,
        logger.logWithTimestamp(.info, ts, "msg", .{}),
    );
}

test "Logger.log: JSON format level labels" {
    const test_cases = [_]struct {
        name: []const u8,
        input: std.log.Level,
        expected: []const u8,
    }{
        .{
            .name = "err",
            .input = .err,
            .expected = "{\"time\":\"1970-01-01T00:00:00.000Z\",\"level\":\"error\"," ++
                "\"msg\":\"msg\"}\n",
        },
        .{
            .name = "warn",
            .input = .warn,
            .expected = "{\"time\":\"1970-01-01T00:00:00.000Z\",\"level\":\"warning\"," ++
                "\"msg\":\"msg\"}\n",
        },
        .{
            .name = "info",
            .input = .info,
            .expected = "{\"time\":\"1970-01-01T00:00:00.000Z\",\"level\":\"info\"," ++
                "\"msg\":\"msg\"}\n",
        },
        .{
            .name = "debug",
            .input = .debug,
            .expected = "{\"time\":\"1970-01-01T00:00:00.000Z\",\"level\":\"debug\"," ++
                "\"msg\":\"msg\"}\n",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const ts = std.Io.Timestamp.fromNanoseconds(0);
        const logger = Logger(struct {}).init(
            std.testing.io,
            &writer,
            .{ .level = tc.input, .format = .json },
            .{},
        );

        try logger.logWithTimestamp(tc.input, ts, "msg", .{});

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

// --- Logger.err ---

test "Logger.err: shorthand" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const logger = Logger(struct {}).init(std.testing.io, &writer, .{}, .{});
    try logger.err("msg", .{});
    try std.testing.expect(std.mem.indexOf(u8, buf[0..writer.end], "level=error") != null);
}

test "Logger.err: write fails" {
    var writer = std.Io.Writer.failing;
    const logger = Logger(struct {}).init(std.testing.io, &writer, .{}, .{});
    try std.testing.expectError(error.WriteFailed, logger.err("msg", .{}));
}

// --- Logger.warn ---

test "Logger.warn: shorthand" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const logger = Logger(struct {}).init(std.testing.io, &writer, .{}, .{});
    try logger.warn("msg", .{});
    try std.testing.expect(std.mem.indexOf(u8, buf[0..writer.end], "level=warning") != null);
}

test "Logger.warn: write fails" {
    var writer = std.Io.Writer.failing;
    const logger = Logger(struct {}).init(std.testing.io, &writer, .{}, .{});
    try std.testing.expectError(error.WriteFailed, logger.warn("msg", .{}));
}

// --- Logger.info ---

test "Logger.info: shorthand" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const logger = Logger(struct {}).init(std.testing.io, &writer, .{}, .{});
    try logger.info("msg", .{});
    try std.testing.expect(std.mem.indexOf(u8, buf[0..writer.end], "level=info") != null);
}

test "Logger.info: write fails" {
    var writer = std.Io.Writer.failing;
    const logger = Logger(struct {}).init(std.testing.io, &writer, .{}, .{});
    try std.testing.expectError(error.WriteFailed, logger.info("msg", .{}));
}

// --- Logger.debug ---

test "Logger.debug: shorthand" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const logger = Logger(struct {}).init(std.testing.io, &writer, .{ .level = .debug }, .{});
    try logger.debug("msg", .{});
    try std.testing.expect(std.mem.indexOf(u8, buf[0..writer.end], "level=debug") != null);
}

test "Logger.debug: write fails" {
    var writer = std.Io.Writer.failing;
    const logger = Logger(struct {}).init(std.testing.io, &writer, .{ .level = .debug }, .{});
    try std.testing.expectError(error.WriteFailed, logger.debug("msg", .{}));
}

// --- Logger.logWithTimestamp ---

test "Logger.logWithTimestamp" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const logger = Logger(struct {}).init(std.testing.io, &writer, .{}, .{});
    try logger.logWithTimestamp(.info, std.Io.Timestamp.fromNanoseconds(0), "msg", .{});
    try std.testing.expectEqualStrings(
        "time=\"1970-01-01T00:00:00.000Z\" level=info msg=\"msg\"\n",
        buf[0..writer.end],
    );
}

test "Logger.logWithTimestamp: null timestamp uses current time" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const logger = Logger(struct {}).init(std.testing.io, &writer, .{}, .{});

    try logger.logWithTimestamp(.info, null, "msg", .{});

    // 実時刻のため値は不定だが、構造（time= 始まり / level=info / msg / 改行終端）が出力される
    const out = buf[0..writer.end];
    try std.testing.expect(std.mem.startsWith(u8, out, "time=\""));
    try std.testing.expect(std.mem.indexOf(u8, out, " level=info ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "msg=\"msg\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\n"));
}

test "Logger.logWithTimestamp: write fails" {
    var writer = std.Io.Writer.failing;
    const logger = Logger(struct {}).init(std.testing.io, &writer, .{}, .{});
    try std.testing.expectError(
        error.WriteFailed,
        logger.logWithTimestamp(.info, std.Io.Timestamp.fromNanoseconds(0), "msg", .{}),
    );
}

test "Logger.logWithTimestamp: always flushes" {
    // fixed writer では flush が noop で観測できないため、drain は fixedDrain（buffer に
    // 直接格納）を流用し flush だけ自前で計数する writer で、ログ出力ごとに必ず flush
    // されることを検証する。
    const FlushSpy = struct {
        writer: std.Io.Writer,
        flush_count: usize,

        fn init(buffer: []u8) @This() {
            return .{
                .writer = .{
                    .vtable = &.{
                        .drain = std.Io.Writer.fixedDrain,
                        .flush = countFlush,
                        .rebase = std.Io.Writer.failingRebase,
                    },
                    .buffer = buffer,
                },
                .flush_count = 0,
            };
        }

        fn countFlush(w: *std.Io.Writer) std.Io.Writer.Error!void {
            const self: *@This() = @fieldParentPtr("writer", w);
            self.flush_count += 1;
        }
    };

    var buf: [256]u8 = undefined;
    var spy = FlushSpy.init(&buf);
    const logger = Logger(struct {}).init(std.testing.io, &spy.writer, .{}, .{});

    try logger.logWithTimestamp(.info, std.Io.Timestamp.fromNanoseconds(0), "msg", .{});

    try std.testing.expectEqual(@as(usize, 1), spy.flush_count);
    try std.testing.expectEqualStrings(
        "time=\"1970-01-01T00:00:00.000Z\" level=info msg=\"msg\"\n",
        spy.writer.buffered(),
    );
}

test "Logger.logWithTimestamp: mutex locks during output" {
    // flush は lock 内（unlock 前）で実行されるため、flush 時点で mutex がロック中であることを
    // 観測すれば、write+flush 全体がロックで囲まれていることを検証できる。
    const LockObserver = struct {
        writer: std.Io.Writer,
        mutex: *std.Io.Mutex,
        locked_during_flush: bool,

        fn init(buffer: []u8, mutex: *std.Io.Mutex) @This() {
            return .{
                .writer = .{
                    .vtable = &.{
                        .drain = std.Io.Writer.fixedDrain,
                        .flush = observeFlush,
                        .rebase = std.Io.Writer.failingRebase,
                    },
                    .buffer = buffer,
                },
                .mutex = mutex,
                .locked_during_flush = false,
            };
        }

        fn observeFlush(w: *std.Io.Writer) std.Io.Writer.Error!void {
            const self: *@This() = @fieldParentPtr("writer", w);
            self.locked_during_flush = self.mutex.state.load(.acquire) != .unlocked;
        }
    };

    var mutex: std.Io.Mutex = .init;
    var buf: [256]u8 = undefined;
    var observer = LockObserver.init(&buf, &mutex);
    const logger = Logger(struct {}).init(
        std.testing.io,
        &observer.writer,
        .{ .mutex = &mutex },
        .{},
    );

    try logger.logWithTimestamp(.info, std.Io.Timestamp.fromNanoseconds(0), "msg", .{});

    // flush 時点でロックされていた（write+flush がロックで囲まれている）
    try std.testing.expect(observer.locked_during_flush);
    // 呼び出し後は解放され、再取得できる（lock/unlock が均衡している）
    try std.testing.expect(mutex.tryLock());
    mutex.unlock(std.testing.io);
    try std.testing.expectEqualStrings(
        "time=\"1970-01-01T00:00:00.000Z\" level=info msg=\"msg\"\n",
        observer.writer.buffered(),
    );
}

// --- Logger.isEnabled ---

test "Logger.isEnabled" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { min_level: std.log.Level, msg_level: std.log.Level },
        expected: bool,
    }{
        .{
            .name = "err:err",
            .input = .{ .min_level = .err, .msg_level = .err },
            .expected = true,
        },
        .{
            .name = "warn:err",
            .input = .{ .min_level = .warn, .msg_level = .err },
            .expected = true,
        },
        .{
            .name = "info:info",
            .input = .{ .min_level = .info, .msg_level = .info },
            .expected = true,
        },
        .{
            .name = "debug:debug",
            .input = .{ .min_level = .debug, .msg_level = .debug },
            .expected = true,
        },
        .{
            .name = "err:warn",
            .input = .{ .min_level = .err, .msg_level = .warn },
            .expected = false,
        },
        .{
            .name = "err:debug",
            .input = .{ .min_level = .err, .msg_level = .debug },
            .expected = false,
        },
        .{
            .name = "info:debug",
            .input = .{ .min_level = .info, .msg_level = .debug },
            .expected = false,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [1]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const logger = Logger(struct {}).init(
            std.testing.io,
            &writer,
            .{ .level = tc.input.min_level },
            .{},
        );

        try std.testing.expectEqual(tc.expected, logger.isEnabled(tc.input.msg_level));
    }
}

// --- MergeFields ---

test "MergeFields" {
    const A = struct { x: u32 };
    const B = struct { y: []const u8 };
    const C = MergeFields(A, B);
    const c: C = .{ .x = 1, .y = "hello" };
    try std.testing.expectEqual(@as(u32, 1), c.x);
    try std.testing.expectEqualStrings("hello", c.y);
}

// --- mergeStructs ---

test "mergeStructs" {
    const a = .{ .x = @as(u32, 1) };
    const b = .{ .y = @as([]const u8, "hello") };
    const c = mergeStructs(a, b);
    try std.testing.expectEqual(@as(u32, 1), c.x);
    try std.testing.expectEqualStrings("hello", c.y);
}

// --- writeLine ---

test "writeLine: logfmt,no attrs" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeLine(
        .logfmt,
        &writer,
        .info,
        std.Io.Timestamp.fromNanoseconds(0),
        .{},
        "server started",
        .{},
    );

    try std.testing.expectEqualStrings(
        "time=\"1970-01-01T00:00:00.000Z\" level=info msg=\"server started\"\n",
        buf[0..writer.end],
    );
}

test "writeLine: empty msg" {
    // format が comptime 引数のため comptime タプル + inline for を使用する。
    const test_cases = .{
        .{
            .name = "logfmt",
            .input = Format.logfmt,
            .expected = "time=\"1970-01-01T00:00:00.000Z\" level=info msg=\"\"\n",
        },
        .{
            .name = "json",
            .input = Format.json,
            .expected = "{\"time\":\"1970-01-01T00:00:00.000Z\",\"level\":\"info\",\"msg\":\"\"}\n",
        },
    };

    inline for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);

        try writeLine(tc.input, &writer, .info, std.Io.Timestamp.fromNanoseconds(0), .{}, "", .{});

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "writeLine: logfmt,with fields" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeLine(
        .logfmt,
        &writer,
        .info,
        std.Io.Timestamp.fromNanoseconds(0),
        .{ .scope = "database" },
        "server started",
        .{},
    );

    try std.testing.expectEqualStrings(
        "time=\"1970-01-01T00:00:00.000Z\" level=info scope=\"database\" msg=\"server started\"\n",
        buf[0..writer.end],
    );
}

test "writeLine: logfmt,special chars in fields" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeLine(
        .logfmt,
        &writer,
        .info,
        std.Io.Timestamp.fromNanoseconds(0),
        .{ .scope = "my\"logger" },
        "msg",
        .{},
    );

    try std.testing.expectEqualStrings(
        "time=\"1970-01-01T00:00:00.000Z\" level=info scope=\"my\\\"logger\" msg=\"msg\"\n",
        buf[0..writer.end],
    );
}

test "writeLine: logfmt,with int attr" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeLine(
        .logfmt,
        &writer,
        .info,
        std.Io.Timestamp.fromNanoseconds(0),
        .{},
        "server started",
        .{ .port = 8080 },
    );

    try std.testing.expectEqualStrings(
        "time=\"1970-01-01T00:00:00.000Z\" level=info msg=\"server started\" port=8080\n",
        buf[0..writer.end],
    );
}

test "writeLine: logfmt,with string attr" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeLine(
        .logfmt,
        &writer,
        .info,
        std.Io.Timestamp.fromNanoseconds(0),
        .{},
        "user logged in",
        .{ .ip = "127.0.0.1" },
    );

    try std.testing.expectEqualStrings(
        "time=\"1970-01-01T00:00:00.000Z\" level=info msg=\"user logged in\" ip=\"127.0.0.1\"\n",
        buf[0..writer.end],
    );
}

test "writeLine: logfmt,string attr with special chars" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "newline",
            .input = "hello\nworld",
            .expected = "time=\"1970-01-01T00:00:00.000Z\"" ++
                " level=info msg=\"msg\" msg=\"hello\\nworld\"\n",
        },
        .{
            .name = "double quote",
            .input = "say \"hi\"",
            .expected = "time=\"1970-01-01T00:00:00.000Z\"" ++
                " level=info msg=\"msg\" msg=\"say \\\"hi\\\"\"\n",
        },
        .{
            .name = "backslash",
            .input = "C:\\path",
            .expected = "time=\"1970-01-01T00:00:00.000Z\"" ++
                " level=info msg=\"msg\" msg=\"C:\\\\path\"\n",
        },
        .{
            .name = "tab",
            .input = "col1\tcol2",
            .expected = "time=\"1970-01-01T00:00:00.000Z\"" ++
                " level=info msg=\"msg\" msg=\"col1\\tcol2\"\n",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);

        try writeLine(
            .logfmt,
            &writer,
            .info,
            std.Io.Timestamp.fromNanoseconds(0),
            .{},
            "msg",
            .{ .msg = tc.input },
        );

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "writeLine: logfmt,special chars in msg" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeLine(
        .logfmt,
        &writer,
        .info,
        std.Io.Timestamp.fromNanoseconds(0),
        .{},
        "say \"hello\"",
        .{},
    );

    try std.testing.expectEqualStrings(
        "time=\"1970-01-01T00:00:00.000Z\" level=info msg=\"say \\\"hello\\\"\"\n",
        buf[0..writer.end],
    );
}

test "writeLine: logfmt,write fails" {
    var writer = std.Io.Writer.failing;

    try std.testing.expectError(
        error.WriteFailed,
        writeLine(
            .logfmt,
            &writer,
            .info,
            std.Io.Timestamp.fromNanoseconds(0),
            .{},
            "msg",
            .{},
        ),
    );
}

test "writeLine: logfmt,with float attr" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeLine(
        .logfmt,
        &writer,
        .info,
        std.Io.Timestamp.fromNanoseconds(0),
        .{},
        "measured",
        .{ .ratio = @as(f64, 0.75) },
    );

    try std.testing.expectEqualStrings(
        "time=\"1970-01-01T00:00:00.000Z\" level=info msg=\"measured\" ratio=0.75\n",
        buf[0..writer.end],
    );
}

test "writeLine: json,no attrs" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeLine(
        .json,
        &writer,
        .info,
        std.Io.Timestamp.fromNanoseconds(0),
        .{},
        "server started",
        .{},
    );

    try std.testing.expectEqualStrings(
        "{\"time\":\"1970-01-01T00:00:00.000Z\",\"level\":\"info\",\"msg\":\"server started\"}\n",
        buf[0..writer.end],
    );
}

test "writeLine: json,write fails" {
    var writer = std.Io.Writer.failing;

    try std.testing.expectError(
        error.WriteFailed,
        writeLine(
            .json,
            &writer,
            .info,
            std.Io.Timestamp.fromNanoseconds(0),
            .{},
            "msg",
            .{},
        ),
    );
}

test "writeLine: json,with float attr" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeLine(
        .json,
        &writer,
        .info,
        std.Io.Timestamp.fromNanoseconds(0),
        .{},
        "measured",
        .{ .ratio = @as(f64, 0.75) },
    );

    try std.testing.expectEqualStrings(
        "{\"time\":\"1970-01-01T00:00:00.000Z\",\"level\":\"info\"," ++
            "\"msg\":\"measured\",\"ratio\":0.75}\n",
        buf[0..writer.end],
    );
}

test "writeLine: json,with fields" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeLine(
        .json,
        &writer,
        .info,
        std.Io.Timestamp.fromNanoseconds(0),
        .{ .scope = "database" },
        "server started",
        .{},
    );

    try std.testing.expectEqualStrings(
        "{\"time\":\"1970-01-01T00:00:00.000Z\",\"level\":\"info\"," ++
            "\"scope\":\"database\",\"msg\":\"server started\"}\n",
        buf[0..writer.end],
    );
}

test "writeLine: json,special chars in fields" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeLine(
        .json,
        &writer,
        .info,
        std.Io.Timestamp.fromNanoseconds(0),
        .{ .scope = "my\"logger" },
        "msg",
        .{},
    );

    try std.testing.expectEqualStrings(
        "{\"time\":\"1970-01-01T00:00:00.000Z\",\"level\":\"info\"," ++
            "\"scope\":\"my\\\"logger\",\"msg\":\"msg\"}\n",
        buf[0..writer.end],
    );
}

test "writeLine: json,special chars in msg" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeLine(
        .json,
        &writer,
        .info,
        std.Io.Timestamp.fromNanoseconds(0),
        .{},
        "say \"hello\"",
        .{},
    );

    try std.testing.expectEqualStrings(
        "{\"time\":\"1970-01-01T00:00:00.000Z\",\"level\":\"info\"," ++
            "\"msg\":\"say \\\"hello\\\"\"}\n",
        buf[0..writer.end],
    );
}

test "writeLine: json,special chars in string attr" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeLine(
        .json,
        &writer,
        .info,
        std.Io.Timestamp.fromNanoseconds(0),
        .{},
        "msg",
        .{ .path = "C:\\Users\\test" },
    );

    try std.testing.expectEqualStrings(
        "{\"time\":\"1970-01-01T00:00:00.000Z\",\"level\":\"info\"," ++
            "\"msg\":\"msg\",\"path\":\"C:\\\\Users\\\\test\"}\n",
        buf[0..writer.end],
    );
}

// --- writeTimestamp ---

test "writeTimestamp: logfmt format" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeTimestamp(.logfmt, &writer, std.Io.Timestamp.fromNanoseconds(0));

    try std.testing.expectEqualStrings("time=\"1970-01-01T00:00:00.000Z\"", buf[0..writer.end]);
}

test "writeTimestamp: json format" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeTimestamp(.json, &writer, std.Io.Timestamp.fromNanoseconds(0));

    try std.testing.expectEqualStrings(
        "{\"time\":\"1970-01-01T00:00:00.000Z\"",
        buf[0..writer.end],
    );
}

test "writeTimestamp: write fails" {
    var writer = std.Io.Writer.failing;

    try std.testing.expectError(
        error.WriteFailed,
        writeTimestamp(.logfmt, &writer, std.Io.Timestamp.fromNanoseconds(0)),
    );
}

// --- writeLevel ---

test "writeLevel: logfmt format" {
    const test_cases = [_]struct {
        name: []const u8,
        input: std.log.Level,
        expected: []const u8,
    }{
        .{ .name = "err", .input = .err, .expected = " level=error" },
        .{ .name = "warn", .input = .warn, .expected = " level=warning" },
        .{ .name = "info", .input = .info, .expected = " level=info" },
        .{ .name = "debug", .input = .debug, .expected = " level=debug" },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);

        try writeLevel(.logfmt, &writer, tc.input);

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "writeLevel: json format" {
    const test_cases = [_]struct {
        name: []const u8,
        input: std.log.Level,
        expected: []const u8,
    }{
        .{ .name = "err", .input = .err, .expected = ",\"level\":\"error\"" },
        .{ .name = "warn", .input = .warn, .expected = ",\"level\":\"warning\"" },
        .{ .name = "info", .input = .info, .expected = ",\"level\":\"info\"" },
        .{ .name = "debug", .input = .debug, .expected = ",\"level\":\"debug\"" },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);

        try writeLevel(.json, &writer, tc.input);

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "writeLevel: write fails" {
    var writer = std.Io.Writer.failing;

    try std.testing.expectError(
        error.WriteFailed,
        writeLevel(.logfmt, &writer, .info),
    );
}

// --- writeEntry ---

test "writeEntry: logfmt format" {
    // input の型がケースごとに異なるため [_]struct + for では扱えず、comptime タプル + inline for を使用する
    const Status = enum { active, idle };
    const test_cases = .{
        .{ .name = "string", .input = "hello", .expected = " key=\"hello\"" },
        .{ .name = "int", .input = @as(u32, 42), .expected = " key=42" },
        .{ .name = "negative int", .input = @as(i64, -1), .expected = " key=-1" },
        .{ .name = "bool", .input = true, .expected = " key=true" },
        .{ .name = "float", .input = @as(f64, 1.5), .expected = " key=1.5" },
        .{ .name = "NaN", .input = std.math.nan(f64), .expected = " key=NaN" },
        .{ .name = "+Inf", .input = std.math.inf(f64), .expected = " key=+Inf" },
        .{ .name = "-Inf", .input = -std.math.inf(f64), .expected = " key=-Inf" },
        .{ .name = "enum", .input = Status.active, .expected = " key=\"active\"" },
        .{ .name = "enum literal", .input = .active, .expected = " key=\"active\"" },
        .{ .name = "optional value", .input = @as(?u32, 42), .expected = " key=42" },
        .{ .name = "optional null", .input = @as(?u32, null), .expected = " key=null" },
        .{ .name = "array", .input = [_]u32{ 1, 2, 3 }, .expected = " key=[1,2,3]" },
        .{
            .name = "nested struct",
            .input = .{ .id = @as(u32, 7), .name = "x" },
            .expected = " key.id=7 key.name=\"x\"",
        },
    };

    inline for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);

        try writeEntry(.logfmt, &writer, "key", tc.input);

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "writeEntry: json format" {
    // input の型がケースごとに異なるため [_]struct + for では扱えず、comptime タプル + inline for を使用する
    const Status = enum { active, idle };
    const test_cases = .{
        .{ .name = "string", .input = "hello", .expected = ",\"key\":\"hello\"" },
        .{ .name = "int", .input = @as(u32, 42), .expected = ",\"key\":42" },
        .{ .name = "negative int", .input = @as(i64, -1), .expected = ",\"key\":-1" },
        .{ .name = "bool", .input = true, .expected = ",\"key\":true" },
        .{ .name = "float", .input = @as(f64, 1.5), .expected = ",\"key\":1.5" },
        .{ .name = "NaN", .input = std.math.nan(f64), .expected = ",\"key\":\"NaN\"" },
        .{ .name = "+Inf", .input = std.math.inf(f64), .expected = ",\"key\":\"+Inf\"" },
        .{ .name = "-Inf", .input = -std.math.inf(f64), .expected = ",\"key\":\"-Inf\"" },
        .{ .name = "enum", .input = Status.active, .expected = ",\"key\":\"active\"" },
        .{ .name = "enum literal", .input = .active, .expected = ",\"key\":\"active\"" },
        .{ .name = "optional value", .input = @as(?u32, 42), .expected = ",\"key\":42" },
        .{ .name = "optional null", .input = @as(?u32, null), .expected = ",\"key\":null" },
        .{ .name = "array", .input = [_]u32{ 1, 2, 3 }, .expected = ",\"key\":[1,2,3]" },
        .{
            .name = "nested struct",
            .input = .{ .id = @as(u32, 7), .name = "x" },
            .expected = ",\"key\":{\"id\":7,\"name\":\"x\"}",
        },
    };

    inline for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);

        try writeEntry(.json, &writer, "key", tc.input);

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "writeEntry: write fails" {
    var writer = std.Io.Writer.failing;

    try std.testing.expectError(
        error.WriteFailed,
        writeEntry(.logfmt, &writer, "key", "value"),
    );
}

test "writeEntry: nested struct containing array (logfmt)" {
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeEntry(.logfmt, &writer, "user", .{ .roles = [_][]const u8{ "admin", "dev" } });

    try std.testing.expectEqualStrings(" user.roles=[\"admin\",\"dev\"]", buf[0..writer.end]);
}

test "writeEntry: nested empty struct keeps key (logfmt)" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeEntry(.logfmt, &writer, "user", .{ .meta = .{} });

    try std.testing.expectEqualStrings(" user.meta={}", buf[0..writer.end]);
}

test "writeEntry: array of struct (json)" {
    const Item = struct { id: u32 };
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeEntry(.json, &writer, "items", [_]Item{ .{ .id = 1 }, .{ .id = 2 } });

    try std.testing.expectEqualStrings(",\"items\":[{\"id\":1},{\"id\":2}]", buf[0..writer.end]);
}

test "writeEntry: empty array and empty struct" {
    // input の型・format がケースごとに異なるため comptime タプル + inline for を使用する
    const test_cases = .{
        .{
            .name = "empty array logfmt",
            .input = .{ .fmt = Format.logfmt, .value = [_]u32{} },
            .expected = " key=[]",
        },
        .{
            .name = "empty array json",
            .input = .{ .fmt = Format.json, .value = [_]u32{} },
            .expected = ",\"key\":[]",
        },
        // 空 struct は展開対象がないが、キーが消えないよう値内 JSON の {} で出力する
        .{
            .name = "empty struct logfmt",
            .input = .{ .fmt = Format.logfmt, .value = .{} },
            .expected = " key={}",
        },
        .{
            .name = "empty struct json",
            .input = .{ .fmt = Format.json, .value = .{} },
            .expected = ",\"key\":{}",
        },
    };

    inline for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [32]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);

        try writeEntry(tc.input.fmt, &writer, "key", tc.input.value);

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

// --- writeKey ---

test "writeKey: logfmt format" {
    var buf: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeKey(.logfmt, &writer, "key");

    try std.testing.expectEqualStrings(" key=", buf[0..writer.end]);
}

test "writeKey: json format" {
    var buf: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeKey(.json, &writer, "key");

    try std.testing.expectEqualStrings(",\"key\":", buf[0..writer.end]);
}

test "writeKey: write fails" {
    var writer = std.Io.Writer.failing;

    try std.testing.expectError(error.WriteFailed, writeKey(.logfmt, &writer, "key"));
}

// --- writeEnum ---

test "writeEnum: exhaustive enum" {
    const Status = enum { active, idle };
    var buf: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeEnum(&writer, Status.active);

    try std.testing.expectEqualStrings("\"active\"", buf[0..writer.end]);
}

test "writeEnum: non-exhaustive known value" {
    const Code = enum(u8) { ok = 0, _ };
    var buf: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeEnum(&writer, Code.ok);

    try std.testing.expectEqualStrings("\"ok\"", buf[0..writer.end]);
}

test "writeEnum: non-exhaustive unknown value" {
    const Code = enum(u8) { ok = 0, _ };
    var buf: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeEnum(&writer, @as(Code, @enumFromInt(99)));

    try std.testing.expectEqualStrings("\"unknown(99)\"", buf[0..writer.end]);
}

test "writeEnum: write fails" {
    const Status = enum { active };
    var writer = std.Io.Writer.failing;

    try std.testing.expectError(error.WriteFailed, writeEnum(&writer, Status.active));
}

// --- writeJsonValue ---

test "writeJsonValue: types" {
    const Status = enum { active };
    const test_cases = .{
        .{ .name = "int", .input = @as(u32, 42), .expected = "42" },
        .{ .name = "bool", .input = true, .expected = "true" },
        .{ .name = "string", .input = "hi", .expected = "\"hi\"" },
        .{ .name = "float", .input = @as(f64, 1.5), .expected = "1.5" },
        .{ .name = "NaN", .input = std.math.nan(f64), .expected = "\"NaN\"" },
        .{ .name = "enum", .input = Status.active, .expected = "\"active\"" },
        .{ .name = "enum literal", .input = .active, .expected = "\"active\"" },
        .{ .name = "optional null", .input = @as(?u32, null), .expected = "null" },
        .{ .name = "optional value", .input = @as(?u32, 5), .expected = "5" },
        .{ .name = "array", .input = [_]u32{ 1, 2 }, .expected = "[1,2]" },
        .{ .name = "struct", .input = .{ .id = @as(u32, 1) }, .expected = "{\"id\":1}" },
        .{ .name = "nested", .input = .{ .a = .{ .b = 2 } }, .expected = "{\"a\":{\"b\":2}}" },
    };

    inline for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);

        try writeJsonValue(&writer, tc.input);

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "writeJsonValue: write fails" {
    var writer = std.Io.Writer.failing;

    try std.testing.expectError(error.WriteFailed, writeJsonValue(&writer, @as(u32, 1)));
}

// --- writeLineTerminator ---

test "writeLineTerminator: logfmt format" {
    var buf: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeLineTerminator(.logfmt, &writer);

    try std.testing.expectEqualStrings("\n", buf[0..writer.end]);
}

test "writeLineTerminator: json format" {
    var buf: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeLineTerminator(.json, &writer);

    try std.testing.expectEqualStrings("}\n", buf[0..writer.end]);
}

test "writeLineTerminator: write fails" {
    var writer = std.Io.Writer.failing;

    try std.testing.expectError(
        error.WriteFailed,
        writeLineTerminator(.logfmt, &writer),
    );
}

// --- writeRfc3339 ---

test "writeRfc3339" {
    const test_cases = [_]struct {
        name: []const u8,
        input: std.Io.Timestamp,
        expected: []const u8,
    }{
        .{
            .name = "epoch",
            .input = std.Io.Timestamp.fromNanoseconds(0),
            .expected = "1970-01-01T00:00:00.000Z",
        },
        .{
            .name = "2026-04-20T12:34:56.000Z",
            .input = std.Io.Timestamp.fromNanoseconds(1776688496 * std.time.ns_per_s),
            .expected = "2026-04-20T12:34:56.000Z",
        },
        .{
            .name = "sub-second (milliseconds)",
            .input = std.Io.Timestamp.fromNanoseconds(1_500_000_000),
            .expected = "1970-01-01T00:00:01.500Z",
        },
        .{
            .name = "year-end (2023-12-31T23:59:59.000Z)",
            .input = std.Io.Timestamp.fromNanoseconds(1704067199 * std.time.ns_per_s),
            .expected = "2023-12-31T23:59:59.000Z",
        },
        .{
            .name = "leap year Feb 29 (2024-02-29T00:00:00.000Z)",
            .input = std.Io.Timestamp.fromNanoseconds(1709164800 * std.time.ns_per_s),
            .expected = "2024-02-29T00:00:00.000Z",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [32]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);

        try writeRfc3339(&writer, tc.input);

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "writeRfc3339: write fails" {
    var writer = std.Io.Writer.failing;

    try std.testing.expectError(
        error.WriteFailed,
        writeRfc3339(&writer, std.Io.Timestamp.fromNanoseconds(0)),
    );
}

// --- writeQuotedString ---

test "writeQuotedString: escaping" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{ .name = "plain string", .input = "hello", .expected = "\"hello\"" },
        .{ .name = "empty string", .input = "", .expected = "\"\"" },
        .{ .name = "double quote", .input = "say \"hi\"", .expected = "\"say \\\"hi\\\"\"" },
        .{ .name = "backslash", .input = "a\\b", .expected = "\"a\\\\b\"" },
        .{ .name = "newline", .input = "a\nb", .expected = "\"a\\nb\"" },
        .{ .name = "carriage return", .input = "a\rb", .expected = "\"a\\rb\"" },
        .{ .name = "tab", .input = "a\tb", .expected = "\"a\\tb\"" },
        .{ .name = "control char NUL", .input = "\x00", .expected = "\"\\u0000\"" },
        .{ .name = "control char SOH", .input = "\x01", .expected = "\"\\u0001\"" },
        .{ .name = "control char BS (0x08)", .input = "\x08", .expected = "\"\\u0008\"" },
        .{ .name = "form feed", .input = "\x0C", .expected = "\"\\u000c\"" },
        .{ .name = "vertical tab", .input = "\x0B", .expected = "\"\\u000b\"" },
        .{ .name = "control char SO (0x0E)", .input = "\x0E", .expected = "\"\\u000e\"" },
        .{ .name = "unit separator", .input = "\x1F", .expected = "\"\\u001f\"" },
        .{ .name = "delete (0x7f)", .input = "\x7F", .expected = "\"\\u007f\"" },
        .{ .name = "valid 2-byte (é)", .input = "é", .expected = "\"é\"" },
        .{ .name = "valid 3-byte (あ)", .input = "あ", .expected = "\"あ\"" },
        .{ .name = "valid 4-byte (😀)", .input = "😀", .expected = "\"😀\"" },
        .{ .name = "invalid lead byte 0xff", .input = "\xff", .expected = "\"\u{fffd}\"" },
        .{ .name = "lone continuation 0x80", .input = "\x80", .expected = "\"\u{fffd}\"" },
        .{ .name = "truncated seq", .input = "\xe3\x81", .expected = "\"\u{fffd}\u{fffd}\"" },
        .{ .name = "invalid byte amid valid", .input = "a\xffb", .expected = "\"a\u{fffd}b\"" },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);

        try writeQuotedString(&writer, tc.input);

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "writeQuotedString: write fails" {
    var writer = std.Io.Writer.failing;

    try std.testing.expectError(
        error.WriteFailed,
        writeQuotedString(&writer, "test"),
    );
}

// --- levelText ---

test "levelText" {
    const test_cases = [_]struct {
        name: []const u8,
        input: std.log.Level,
        expected: []const u8,
    }{
        .{ .name = "err", .input = .err, .expected = "error" },
        .{ .name = "warn", .input = .warn, .expected = "warning" },
        .{ .name = "info", .input = .info, .expected = "info" },
        .{ .name = "debug", .input = .debug, .expected = "debug" },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqualStrings(tc.expected, levelText(tc.input));
    }
}

// --- floatSpecialText ---

test "floatSpecialText: NaN/Inf は専用文字列" {
    const test_cases = [_]struct {
        name: []const u8,
        input: f64,
        expected: []const u8,
    }{
        .{ .name = "NaN", .input = std.math.nan(f64), .expected = "NaN" },
        .{ .name = "+Inf", .input = std.math.inf(f64), .expected = "+Inf" },
        .{ .name = "-Inf", .input = -std.math.inf(f64), .expected = "-Inf" },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        const actual = floatSpecialText(tc.input);
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(tc.expected, actual.?);
    }
}

test "floatSpecialText: 通常の float は null" {
    const test_cases = [_]struct {
        name: []const u8,
        input: f64,
    }{
        .{ .name = "zero", .input = 0.0 },
        .{ .name = "positive", .input = 1.5 },
        .{ .name = "negative", .input = -3.14 },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expect(floatSpecialText(tc.input) == null);
    }
}

// --- validateLogArgs ---

test "validateLogArgs: 正常な組み合わせ" {
    // input が type（コンパイル時専用型）のためテーブルドリブンは使用できない。
    // 非 struct・予約語・不正文字・fields×attrs 衝突は @compileError のためテスト不可。
    comptime validateLogArgs(struct {}, @TypeOf(.{}));
    comptime validateLogArgs(struct { scope: []const u8 }, @TypeOf(.{ .port = 8080 }));
    comptime validateLogArgs(struct { service: []const u8 }, @TypeOf(.{ .method = "GET" }));
}

// --- validateFields ---

test "validateFields: valid fields" {
    // input が type（コンパイル時専用型）のためテーブルドリブンは使用できない。
    // エラーケース（非 struct / 予約語 / 不正文字）は @compileError のためテスト不可。
    comptime validateFields(struct {});
    comptime validateFields(struct { scope: []const u8 });
    comptime validateFields(@TypeOf(.{ .service = "api" }));
}

// --- validateAttrs ---

test "validateAttrs: valid attrs" {
    // input が type（コンパイル時専用型）のためテーブルドリブンは使用できない。
    // エラーケース（非 struct / 予約語 / 位置指定タプル値）は @compileError のためテスト不可。
    comptime validateAttrs(@TypeOf(.{}));
    comptime validateAttrs(@TypeOf(.{ .port = 8080 }));
    comptime validateAttrs(@TypeOf(.{ .user_id = 42, .ip = "127.0.0.1" }));
    comptime validateAttrs(@TypeOf(.{ .timestamp = 0, .log_level = "info" }));
    comptime validateAttrs(@TypeOf(.{ .scope = "app" }));
    // ネストした named struct は通る。空の `.{}` も要素がないため通る。
    comptime validateAttrs(@TypeOf(.{ .user = .{ .id = 42 } }));
    comptime validateAttrs(@TypeOf(.{ .meta = .{} }));
}

// --- validateStruct ---

test "validateStruct: struct types pass" {
    // 非 struct・要素のある位置指定タプルのケースは @compileError のためテスト不可。
    // 空の `.{}` は is_tuple=true だが要素がないため通る。
    comptime validateStruct(struct {}, "fields");
    comptime validateStruct(@TypeOf(.{}), "attrs");
    comptime validateStruct(@TypeOf(.{ .port = 8080 }), "attrs");
}

// --- validateName ---

test "validateName: 正常な名前" {
    // input が type（コンパイル時専用型）のためテーブルドリブンは使用できない。
    // 空名・予約語・不正文字のケースは @compileError のためテスト不可。
    comptime validateName(@TypeOf(.{}), "field");
    comptime validateName(@TypeOf(.{ .scope = "app" }), "field");
    comptime validateName(struct { service: []const u8 }, "field");
    comptime validateName(@TypeOf(.{ .timestamp = 0, .log_level = "info" }), "attribute");
    comptime validateName(@TypeOf(.{ .@"http.status" = 200, .@"req-id" = "x" }), "attribute");
}

// --- validateFieldsAttrsConflict ---

test "validateFieldsAttrsConflict: 衝突なし" {
    // input が type（コンパイル時専用型）のため、組み合わせを個別に検証する。
    // 衝突ありケースは @compileError のためテスト不可。
    comptime validateFieldsAttrsConflict(struct {}, @TypeOf(.{}));
    comptime validateFieldsAttrsConflict(struct { scope: []const u8 }, @TypeOf(.{ .port = 8080 }));
    comptime validateFieldsAttrsConflict(
        struct { service: []const u8 },
        @TypeOf(.{ .method = "GET" }),
    );
}

// --- isStringLike ---

test "isStringLike" {
    // input が type（コンパイル時専用型）のため [_]struct + for では扱えず、comptime タプル + inline for を使用する
    const test_cases = .{
        .{ .name = "[]const u8", .input = []const u8, .expected = true },
        .{ .name = "[]u8", .input = []u8, .expected = true },
        .{ .name = "[:0]const u8", .input = [:0]const u8, .expected = true },
        .{ .name = "[:0]u8", .input = [:0]u8, .expected = true },
        .{ .name = "*const [3]u8", .input = *const [3]u8, .expected = true },
        .{ .name = "*[3]u8", .input = *[3]u8, .expected = true },
        .{ .name = "*const [3:0]u8", .input = *const [3:0]u8, .expected = true },
        .{ .name = "*[3:0]u8", .input = *[3:0]u8, .expected = true },
        .{ .name = "[]const u32", .input = []const u32, .expected = false },
        .{ .name = "*const [3]u32", .input = *const [3]u32, .expected = false },
        .{ .name = "u32", .input = u32, .expected = false },
        .{ .name = "*u8", .input = *u8, .expected = false },
        .{ .name = "[*]u8", .input = [*]u8, .expected = false },
        .{ .name = "[*c]u8", .input = [*c]u8, .expected = false },
    };

    inline for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, isStringLike(tc.input));
    }
}

// --- isIntOrBool ---

test "isIntOrBool" {
    // input が type（コンパイル時専用型）のため [_]struct + for では扱えず、comptime タプル + inline for を使用する
    const test_cases = .{
        .{ .name = "u32", .input = u32, .expected = true },
        .{ .name = "i64", .input = i64, .expected = true },
        .{ .name = "usize", .input = usize, .expected = true },
        .{ .name = "bool", .input = bool, .expected = true },
        .{ .name = "comptime_int", .input = comptime_int, .expected = true },
        .{ .name = "f32", .input = f32, .expected = false },
        .{ .name = "f64", .input = f64, .expected = false },
        .{ .name = "[]const u8", .input = []const u8, .expected = false },
        .{ .name = "struct", .input = struct { x: u32 }, .expected = false },
    };

    inline for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, isIntOrBool(tc.input));
    }
}

// --- isFloat ---

test "isFloat" {
    // input が type（コンパイル時専用型）のため [_]struct + for では扱えず、comptime タプル + inline for を使用する
    const test_cases = .{
        .{ .name = "f32", .input = f32, .expected = true },
        .{ .name = "f64", .input = f64, .expected = true },
        .{ .name = "comptime_float", .input = comptime_float, .expected = true },
        .{ .name = "u32", .input = u32, .expected = false },
        .{ .name = "bool", .input = bool, .expected = false },
        .{ .name = "[]const u8", .input = []const u8, .expected = false },
    };

    inline for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, isFloat(tc.input));
    }
}

// --- isEnum ---

test "isEnum" {
    // input が type（コンパイル時専用型）のため [_]struct + for では扱えず、comptime タプル + inline for を使用する
    const test_cases = .{
        .{ .name = "enum", .input = enum { active, idle }, .expected = true },
        .{ .name = "enum_literal", .input = @TypeOf(.active), .expected = true },
        .{ .name = "u32", .input = u32, .expected = false },
        .{ .name = "struct", .input = struct { x: u32 }, .expected = false },
        .{ .name = "[]const u8", .input = []const u8, .expected = false },
    };

    inline for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, isEnum(tc.input));
    }
}

// --- isStruct ---

test "isStruct" {
    // input が type（コンパイル時専用型）のため [_]struct + for では扱えず、comptime タプル + inline for を使用する
    const test_cases = .{
        .{ .name = "struct", .input = struct { x: u32 }, .expected = true },
        .{ .name = "empty struct", .input = struct {}, .expected = true },
        .{ .name = "u32", .input = u32, .expected = false },
        .{ .name = "enum", .input = enum { active, idle }, .expected = false },
        .{ .name = "[]const u8", .input = []const u8, .expected = false },
    };

    inline for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, isStruct(tc.input));
    }
}

// --- isArrayLike ---

test "isArrayLike" {
    // input が type（コンパイル時専用型）のため [_]struct + for では扱えず、comptime タプル + inline for を使用する
    // isArrayLike 自身は文字列を除外しない（[]const u8 は slice なので true）。除外は呼び出し側が
    // isStringLike を先に判定して行う。*const [N]u8 は pointer .one なので array にも slice にも該当せず false。
    const test_cases = .{
        .{ .name = "[]u32", .input = []u32, .expected = true },
        .{ .name = "[3]u32", .input = [3]u32, .expected = true },
        .{ .name = "[]const u8", .input = []const u8, .expected = true },
        .{ .name = "*const [3]u8", .input = *const [3]u8, .expected = false },
        .{ .name = "u32", .input = u32, .expected = false },
    };

    inline for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, isArrayLike(tc.input));
    }
}

// --- isOptional ---

test "isOptional" {
    // input が type（コンパイル時専用型）のため [_]struct + for では扱えず、comptime タプル + inline for を使用する
    const test_cases = .{
        .{ .name = "?u32", .input = ?u32, .expected = true },
        .{ .name = "?[]const u8", .input = ?[]const u8, .expected = true },
        .{ .name = "u32", .input = u32, .expected = false },
        .{ .name = "[]const u8", .input = []const u8, .expected = false },
    };

    inline for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, isOptional(tc.input));
    }
}

// --- isValidNameChar ---

test "isValidNameChar" {
    const test_cases = [_]struct {
        name: []const u8,
        input: u8,
        expected: bool,
    }{
        .{ .name = "lowercase", .input = 'a', .expected = true },
        .{ .name = "uppercase", .input = 'Z', .expected = true },
        .{ .name = "digit", .input = '0', .expected = true },
        .{ .name = "underscore", .input = '_', .expected = true },
        .{ .name = "hyphen", .input = '-', .expected = true },
        .{ .name = "dot", .input = '.', .expected = true },
        .{ .name = "space", .input = ' ', .expected = false },
        .{ .name = "equals", .input = '=', .expected = false },
        .{ .name = "double quote", .input = '"', .expected = false },
        .{ .name = "backslash", .input = '\\', .expected = false },
        .{ .name = "newline", .input = '\n', .expected = false },
        .{ .name = "high byte (UTF-8 lead)", .input = 0xE3, .expected = false },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, isValidNameChar(tc.input));
    }
}
