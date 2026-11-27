test {
    _ = @import("provider/types.zig");
    _ = @import("provider/virtualbox/commands.zig");
    _ = @import("provider/virtualbox/parse.zig");
    _ = @import("provider/virtualbox/adapter.zig");
    _ = @import("provider/virtualbox/native_transport.zig");
    _ = @import("lifecycle/core/lifecycle.zig");
}
