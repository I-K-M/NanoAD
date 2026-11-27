const std = @import("std");
const builtin = @import("builtin");
const commands = @import("commands.zig");
const types = @import("../types.zig");

const Handle = *anyopaque;
const path_capacity = 260;
const command_capacity = 512;
const stderr_capacity = 4096;
const max_executable_bytes = 64 * 1024 * 1024;
const wait_object_0: u32 = 0;
const wait_timeout: u32 = 258;

const SecurityAttributes = extern struct {
    length: u32,
    descriptor: ?*anyopaque,
    inherit: i32,
};

const StartupInfo = extern struct {
    cb: u32,
    reserved: ?[*:0]u16,
    desktop: ?[*:0]u16,
    title: ?[*:0]u16,
    x: u32,
    y: u32,
    x_size: u32,
    y_size: u32,
    x_chars: u32,
    y_chars: u32,
    fill: u32,
    flags: u32,
    show: u16,
    reserved_bytes: u16,
    reserved2: ?[*]u8,
    input: ?Handle,
    output: ?Handle,
    err: ?Handle,
};

const StartupInfoEx = extern struct {
    info: StartupInfo,
    attributes: ?*anyopaque,
};

const ProcessInfo = extern struct {
    process: Handle,
    thread: Handle,
    process_id: u32,
    thread_id: u32,
};

const AttributeTag = extern struct {
    attributes: u32,
    tag: u32,
};

extern "kernel32" fn CreatePipe(read: *?Handle, write: *?Handle, attributes: *SecurityAttributes, size: u32) callconv(.winapi) i32;
extern "kernel32" fn SetHandleInformation(handle: Handle, mask: u32, flags: u32) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(handle: Handle) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn PeekNamedPipe(handle: Handle, buffer: ?*anyopaque, size: u32, bytes_read: ?*u32, available: ?*u32, remaining: ?*u32) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(handle: Handle, buffer: [*]u8, size: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: u32, flags: u32, size: *usize) callconv(.winapi) i32;
extern "kernel32" fn UpdateProcThreadAttribute(list: *anyopaque, flags: u32, attribute: usize, value: *anyopaque, size: usize, previous: ?*anyopaque, returned: ?*usize) callconv(.winapi) i32;
extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn CreateProcessW(application: [*:0]const u16, command: [*:0]u16, process_attributes: ?*anyopaque, thread_attributes: ?*anyopaque, inherit: i32, flags: u32, environment: ?*anyopaque, directory: [*:0]const u16, startup: *StartupInfo, process: *ProcessInfo) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(handle: Handle, milliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(handle: Handle, code: *u32) callconv(.winapi) i32;
extern "kernel32" fn TerminateProcess(handle: Handle, code: u32) callconv(.winapi) i32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, attributes: ?*anyopaque, disposition: u32, flags: u32, template: ?Handle) callconv(.winapi) ?Handle;
extern "kernel32" fn GetFileSizeEx(handle: Handle, size: *i64) callconv(.winapi) i32;
extern "kernel32" fn GetFileType(handle: Handle) callconv(.winapi) u32;
extern "kernel32" fn GetFileInformationByHandleEx(handle: Handle, class: i32, information: *anyopaque, size: u32) callconv(.winapi) i32;
extern "kernel32" fn GetDriveTypeW(root: [*:0]const u16) callconv(.winapi) u32;

fn close(slot: *?Handle) void {
    if (slot.*) |handle| _ = CloseHandle(handle);
    slot.* = null;
}

const Pipe = struct {
    reader: ?Handle = null,
    writer: ?Handle = null,

    fn create() types.Failure!Pipe {
        var pipe: Pipe = .{};
        var attrs: SecurityAttributes = .{ .length = @sizeOf(SecurityAttributes), .descriptor = null, .inherit = 1 };
        if (CreatePipe(&pipe.reader, &pipe.writer, &attrs, 0) == 0) return error.ProviderFailure;
        return pipe;
    }

    fn deinit(self: *Pipe) void {
        close(&self.reader);
        close(&self.writer);
    }

    fn protectReader(self: Pipe) types.Failure!void {
        if (SetHandleInformation(self.reader.?, 1, 0) == 0) return error.ProviderFailure;
    }
};

fn validatePath(path: []const u8) types.Failure!usize {
    // Restrict this first slice to conventional local ASCII drive paths.
    // The parent directory and its DLLs must be trusted by the operator.
    if (path.len < 4 or path.len >= path_capacity or !std.ascii.isAlphabetic(path[0]) or
        path[1] != ':' or path[2] != '\\') return error.InvalidResponse;
    var segments = std.mem.splitScalar(u8, path[3..], '\\');
    var last: []const u8 = "";
    while (segments.next()) |segment| {
        if (segment.len == 0 or segment[segment.len - 1] == '.' or segment[segment.len - 1] == ' ')
            return error.InvalidResponse;
        for (segment) |c| {
            if (c < 32 or c > 126 or std.mem.indexOfScalar(u8, ":*?<>|\"/", c) != null)
                return error.InvalidResponse;
        }
        last = segment;
    }
    if (!std.ascii.eqlIgnoreCase(last, "VBoxManage.exe")) return error.InvalidResponse;
    return path.len - last.len;
}

pub const NativeTransport = struct {
    executable: [path_capacity:0]u16,
    directory: [path_capacity:0]u16,
    path_len: usize,
    digest: [32]u8,

    // Digest must be supplied from independently trusted local provenance.
    // This is not Authenticode validation or a sandbox against a hostile host.
    pub fn init(path: []const u8, digest: [32]u8) types.Failure!NativeTransport {
        const dir_end = try validatePath(path);
        var result: NativeTransport = .{
            .executable = @splat(0),
            .directory = @splat(0),
            .path_len = path.len,
            .digest = digest,
        };
        for (path, 0..) |c, i| result.executable[i] = c;
        const dir_len = if (dir_end == 3) dir_end else dir_end - 1;
        for (path[0..dir_len], 0..) |c, i| result.directory[i] = c;
        return result;
    }

    pub fn transport(self: *NativeTransport) commands.Transport {
        return .{ .context = self, .invoke_fn = invoke };
    }

    fn commandLine(self: *const NativeTransport, request: *const commands.Request) types.Failure![command_capacity:0]u16 {
        const args = try request.arguments();
        var line: [command_capacity:0]u16 = @splat(0);
        var offset: usize = 1;
        line[0] = '"';
        @memcpy(line[offset .. offset + self.path_len], self.executable[0..self.path_len]);
        offset += self.path_len;
        line[offset] = '"';
        offset += 1;
        for (args.slice()) |arg| {
            if (offset + 1 + arg.len >= command_capacity) return error.OutputLimit;
            line[offset] = ' ';
            offset += 1;
            for (arg) |c| {
                // Typed arguments have no whitespace or Windows quoting metacharacters.
                if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '/' and c != '_')
                    return error.InvalidResponse;
                line[offset] = c;
                offset += 1;
            }
        }
        return line;
    }

    fn openVerified(self: *const NativeTransport) types.Failure!Handle {
        const drive: [3:0]u16 = .{ self.executable[0], ':', '\\' };
        if (GetDriveTypeW(&drive) != 3) return error.Unsupported;
        // GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING, OPEN_REPARSE_POINT.
        // Keep this handle open through child exit; do not allow write/delete sharing.
        const file = CreateFileW(&self.executable, 0x80000000, 1, null, 3, 0x00200000, null) orelse return error.ProviderFailure;
        if (@intFromPtr(file) == std.math.maxInt(usize)) return error.ProviderFailure;
        errdefer _ = CloseHandle(file);
        if (GetFileType(file) != 1) return error.ProviderFailure;
        var tag: AttributeTag = undefined;
        if (GetFileInformationByHandleEx(file, 9, &tag, @sizeOf(AttributeTag)) == 0 or
            (tag.attributes & (0x400 | 0x10)) != 0) return error.ProviderFailure;
        var size: i64 = 0;
        if (GetFileSizeEx(file, &size) == 0 or size <= 0 or size > max_executable_bytes)
            return error.ProviderFailure;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var buffer: [16 * 1024]u8 = undefined;
        var remaining: usize = @intCast(size);
        while (remaining > 0) {
            const amount: u32 = @intCast(@min(remaining, buffer.len));
            var n: u32 = 0;
            if (ReadFile(file, &buffer, amount, &n, null) == 0 or n == 0 or n > amount)
                return error.ProviderFailure;
            hash.update(buffer[0..n]);
            remaining -= n;
        }
        var actual: [32]u8 = undefined;
        hash.final(&actual);
        if (!std.mem.eql(u8, &actual, &self.digest)) return error.ProviderFailure;
        return file;
    }

    fn invoke(ctx: *anyopaque, request: *const commands.Request, output: []u8, timeout: u32) types.Failure!usize {
        if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.Unsupported;
        // No mutation is possible through this transport until admission, journal and
        // full isolation are wired. The fake transport can exercise those operations.
        switch (request.operation) {
            .start, .graceful_stop => return error.Unsupported,
            else => {},
        }
        if (timeout == 0 or timeout > commands.command_timeout_ms) return error.InvalidResponse;
        if (output.len == 0 or output.len > commands.max_output_bytes) return error.OutputLimit;
        const self: *NativeTransport = @ptrCast(@alignCast(ctx));
        var line = try self.commandLine(request);
        const file = try self.openVerified();
        defer _ = CloseHandle(file);

        var input = try Pipe.create();
        defer input.deinit();
        var stdout = try Pipe.create();
        defer stdout.deinit();
        var stderr = try Pipe.create();
        defer stderr.deinit();
        try stdout.protectReader();
        try stderr.protectReader();
        // Child receives EOF, not the parent's console or arbitrary input.
        close(&input.writer);

        var handles = [_]Handle{ input.reader.?, stdout.writer.?, stderr.writer.? };
        var storage: [4096]u8 align(16) = undefined;
        var size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &size);
        if (size == 0 or size > storage.len) return error.ProviderFailure;
        const list: *anyopaque = &storage;
        if (InitializeProcThreadAttributeList(list, 1, 0, &size) == 0) return error.ProviderFailure;
        defer DeleteProcThreadAttributeList(list);
        if (UpdateProcThreadAttribute(list, 0, 0x00020002, @ptrCast(&handles), @sizeOf(@TypeOf(handles)), null, null) == 0)
            return error.ProviderFailure;

        var startup = std.mem.zeroes(StartupInfoEx);
        startup.info.cb = @sizeOf(StartupInfoEx);
        startup.info.flags = 0x100; // STARTF_USESTDHANDLES
        startup.info.input = handles[0];
        startup.info.output = handles[1];
        startup.info.err = handles[2];
        startup.attributes = list;
        var child: ProcessInfo = undefined;
        // EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW. Explicit application path.
        if (CreateProcessW(&self.executable, &line, null, null, 1, 0x00080000 | 0x08000000, null, &self.directory, &startup.info, &child) == 0)
            return error.ProviderFailure;
        defer _ = CloseHandle(child.process);
        _ = CloseHandle(child.thread);
        close(&input.reader);
        close(&stdout.writer);
        close(&stderr.writer);
        return collect(child.process, stdout.reader.?, stderr.reader.?, output, timeout) catch |err| {
            // Abort only the exact read-only child we launched, never a VM or VBoxSVC.
            // Closing the readers first releases any child blocked writing to a full pipe.
            close(&stdout.reader);
            close(&stderr.reader);
            const state = WaitForSingleObject(child.process, 50);
            if (state != wait_object_0) {
                if (state != wait_timeout) return error.RecoveryRequired;
                // TerminateProcess may race a normal exit. Only a confirmed signalled
                // process handle establishes completion, regardless of its return value.
                _ = TerminateProcess(child.process, 1);
                if (WaitForSingleObject(child.process, 2000) != wait_object_0)
                    return error.RecoveryRequired;
            }
            return err;
        };
    }
};

const Capture = struct {
    handle: Handle,
    buffer: []u8,
    used: usize = 0,
    closed: bool = false,

    fn drain(self: *Capture) types.Failure!void {
        if (self.closed) return;
        var available: u32 = 0;
        if (PeekNamedPipe(self.handle, null, 0, null, &available, null) == 0) {
            const code = GetLastError();
            if (code == 109 or code == 232) {
                self.closed = true;
                return;
            }
            return error.ProviderFailure;
        }
        if (available == 0) return;
        if (available > self.buffer.len - self.used) return error.OutputLimit;
        var n: u32 = 0;
        if (ReadFile(self.handle, self.buffer[self.used..].ptr, available, &n, null) == 0 or n == 0 or n > available)
            return error.ProviderFailure;
        self.used += n;
    }
};

fn collect(process: Handle, stdout: Handle, stderr: Handle, output: []u8, timeout: u32) types.Failure!usize {
    var diagnostic: [stderr_capacity]u8 = undefined;
    var out: Capture = .{ .handle = stdout, .buffer = output };
    var err: Capture = .{ .handle = stderr, .buffer = &diagnostic };
    const start = GetTickCount64();
    while (true) {
        if (GetTickCount64() -% start >= timeout) return error.Timeout;
        try out.drain();
        try err.drain();
        const state = WaitForSingleObject(process, 0);
        if (state == wait_object_0 and out.closed and err.closed) {
            var code: u32 = 0;
            if (GetExitCodeProcess(process, &code) == 0 or code != 0) return error.ProviderFailure;
            // Unexpected diagnostic output fails closed; never return it as stdout.
            if (err.used != 0) return error.InvalidResponse;
            return out.used;
        }
        if (state != wait_object_0 and state != wait_timeout) return error.ProviderFailure;
        Sleep(5);
    }
}

test "path and command encoding are bounded and explicit" {
    const path = "C:\\Program Files\\Oracle\\VirtualBox\\VBoxManage.exe";
    const native = try NativeTransport.init(path, @splat(0));
    const request: commands.Request = .{ .operation = .version };
    const line = try native.commandLine(&request);
    const expected = "\"" ++ path ++ "\" --version";
    for (expected, 0..) |c, i| try std.testing.expectEqual(@as(u16, c), line[i]);
    try std.testing.expectEqual(@as(u16, 0), line[expected.len]);
    try std.testing.expectError(error.InvalidResponse, NativeTransport.init("VBoxManage.exe", @splat(0)));
    try std.testing.expectError(error.InvalidResponse, NativeTransport.init("\\\\server\\VBoxManage.exe", @splat(0)));
    try std.testing.expectError(error.InvalidResponse, NativeTransport.init("C:\\tmp\\..\\VBoxManage.exe", @splat(0)));
    try std.testing.expectError(error.InvalidResponse, NativeTransport.init("C:\\tmp\\VBoxManage.exe:stream", @splat(0)));
    try std.testing.expectError(error.InvalidResponse, NativeTransport.init("C:\\tmp\\VBoxManage.exe ", @splat(0)));
}
