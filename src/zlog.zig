const std = @import("std");

const logger_mod = @import("logger.zig");

pub const Logger = logger_mod.Logger;

test {
    _ = logger_mod;
}
