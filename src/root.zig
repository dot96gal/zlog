const std = @import("std");

const logger_mod = @import("logger.zig");

pub const Logger = logger_mod.Logger;
pub const Format = logger_mod.Format;
pub const Error = logger_mod.Error;

test {
    _ = logger_mod;
}
