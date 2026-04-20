const std = @import("std");
const Io = std.Io;

const logger_mod = @import("logger.zig");

pub const Logger = logger_mod.Logger;
pub const Format = logger_mod.Format;

test {
    _ = logger_mod;
}
