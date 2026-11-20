//! Receive a Windows default-terminal handoff on the Win32 thread.
const std = @import("std");
const global = @import("../../global.zig");
const w32 = @import("win32.zig");
const GUID = w32.GUID;
const HANDLE = w32.HANDLE;
const HRESULT = w32.HRESULT;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.terminal_handoff);

pub const clsid: GUID = .parse("{A3A39CB0-46F7-4D5D-954E-F311DAE8EB6A}");
const iid_unknown: GUID = .parse("{00000000-0000-0000-C000-000000000046}");
const iid_class_factory: GUID = .parse("{00000001-0000-0000-C000-000000000046}");
const iid_terminal_handoff3: GUID = .parse("{6F23DA90-15C5-4203-9DB0-64E73F1B1B00}");
const iid_default_terminal_marker: GUID = .parse("{746E6BC0-AB05-4E38-AB14-71E86763141F}");
const proxy_clsid: GUID = .parse("{9C11CDBC-C14F-4C6D-AC73-3110BAD9DCA6}");
const iid_proxy_factory: GUID = .parse("{D5F569D0-593B-101A-B569-08002B2DBF7A}");

const s_ok: HRESULT = 0;
const e_nointerface: HRESULT = @bitCast(@as(u32, 0x80004002));
const e_pointer: HRESULT = @bitCast(@as(u32, 0x80004003));
const e_fail: HRESULT = @bitCast(@as(u32, 0x80004005));
const e_outofmemory: HRESULT = @bitCast(@as(u32, 0x8007000E));
const e_invalidarg: HRESULT = @bitCast(@as(u32, 0x80070057));
const class_e_noaggregation: HRESULT = @bitCast(@as(u32, 0x80040110));
const class_e_classnotavailable: HRESULT = @bitCast(@as(u32, 0x80040111));
const clsctx_local_server: u32 = 4;
const regcls_multipleuse: u32 = 1;

extern "ole32" fn CoRegisterClassObject(*const GUID, *ClassFactory, u32, u32, *u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoRevokeClassObject(u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoRegisterPSClsid(*const GUID, *const GUID) callconv(.winapi) HRESULT;
extern "oleaut32" fn SysStringLen(?[*]const u16) callconv(.winapi) u32;

const HMODULE = std.os.windows.HMODULE;
extern "kernel32" fn LoadLibraryExW([*:0]const u16, ?HANDLE, u32) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(HMODULE, [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn FreeLibrary(HMODULE) callconv(.winapi) w32.BOOL;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn DuplicateHandle(HANDLE, HANDLE, HANDLE, *HANDLE, u32, w32.BOOL, u32) callconv(.winapi) w32.BOOL;

pub const Proxy = struct {
    cookie: u32,

    /// Tell COM where to find the generated proxy in this process. The DLL
    /// stays mapped until process exit because outstanding stubs own vtables.
    pub fn register(alloc: Allocator) !Proxy {
        const executable = try std.process.executablePathAlloc(global.io(), alloc);
        defer alloc.free(executable);
        const dir = std.fs.path.dirname(executable) orelse return error.TerminalHandoffProxyMissing;
        const path = try std.fs.path.join(alloc, &.{ dir, "Madotty.TerminalHandoffProxy.dll" });
        defer alloc.free(path);
        const wide = try std.unicode.wtf8ToWtf16LeAllocZ(alloc, path);
        defer alloc.free(wide);

        const search_dll_load_dir = 0x00000100;
        const search_system32 = 0x00000800;
        const module = LoadLibraryExW(wide.ptr, null, search_dll_load_dir | search_system32) orelse
            return error.TerminalHandoffProxyMissing;
        errdefer _ = FreeLibrary(module);

        const GetClassObject = *const fn (*const GUID, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT;
        const get_factory: GetClassObject = @ptrCast(GetProcAddress(module, "DllGetClassObject") orelse
            return error.InvalidTerminalHandoffProxy);
        var raw_factory: ?*anyopaque = null;
        if (get_factory(&proxy_clsid, &iid_proxy_factory, &raw_factory) < 0) return error.InvalidTerminalHandoffProxy;
        // COM uses the IUnknown prefix of IPSFactoryBuffer for registration.
        const factory: *ClassFactory = @ptrCast(@alignCast(raw_factory orelse return error.InvalidTerminalHandoffProxy));
        defer _ = factory.vtable.Release(factory);

        var cookie: u32 = undefined;
        if (CoRegisterClassObject(&proxy_clsid, factory, w32.CLSCTX_INPROC_SERVER, regcls_multipleuse, &cookie) < 0)
            return error.TerminalHandoffProxyRegistrationFailed;
        errdefer _ = CoRevokeClassObject(cookie);
        for ([_]*const GUID{ &iid_terminal_handoff3, &iid_default_terminal_marker }) |iid| {
            if (CoRegisterPSClsid(iid, &proxy_clsid) < 0) return error.TerminalHandoffProxyRegistrationFailed;
        }
        return .{ .cookie = cookie };
    }

    pub fn deinit(self: *Proxy) void {
        _ = CoRevokeClassObject(self.cookie);
        self.* = undefined;
    }
};

pub fn duplicateClient(handle: HANDLE) !HANDLE {
    const process = GetCurrentProcess();
    const same_access = 2;
    var client: HANDLE = undefined;
    if (DuplicateHandle(process, handle, process, &client, 0, .FALSE, same_access) == .FALSE)
        return error.TerminalHandoffClientUnavailable;
    return client;
}

/// TERMINAL_STARTUP_INFO from Microsoft Terminal's ITerminalHandoff.idl.
pub const StartupInfo = extern struct {
    title: ?[*]const u16,
    icon_path: ?[*]const u16,
    icon_index: i32,
    x: u32,
    y: u32,
    x_size: u32,
    y_size: u32,
    x_count_chars: u32,
    y_count_chars: u32,
    fill_attribute: u32,
    flags: u32,
    show_window: u16,
};

/// Borrow a BSTR's text, whose length can include embedded zeroes.
pub fn bstr(value: ?[*]const u16) []const u16 {
    const ptr = value orelse return &.{};
    return ptr[0..SysStringLen(ptr)];
}

/// The COM proxy owns these handles and strings during the callback.
/// Duplicate or copy anything needed after the callback returns.
pub const Request = struct {
    signal: HANDLE,
    reference: HANDLE,
    server: HANDLE,
    client: HANDLE,
    startup_info: *const StartupInfo,
};

/// The separately owned console-side ends of the input and output pipes.
/// Returning them successfully transfers both handles to COM.
pub const Pipes = struct { input: HANDLE, output: HANDLE };

pub const Callback = struct {
    context: ?*anyopaque,
    accept: *const fn (?*anyopaque, Request) anyerror!Pipes,
};

pub const Registration = struct {
    cookie: u32,
    factory: *Factory,

    /// Shut down on the registration thread before destroying the callback
    /// context. COM clients may still hold receiver objects after revocation.
    pub fn deinit(self: *Registration) void {
        self.factory.callback = null;
        const hr = CoRevokeClassObject(self.cookie);
        if (hr < 0) log.warn("CoRevokeClassObject failed HRESULT=0x{x:0>8}", .{@as(u32, @bitCast(hr))});
        _ = self.factory.interface.vtable.Release(&self.factory.interface);
        self.* = undefined;
    }
};

/// Publish the class object on the caller's initialized, pumping COM STA.
/// The allocator must remain valid for any outstanding COM references.
pub fn register(alloc: Allocator, callback: Callback) !Registration {
    return registerClass(&clsid, alloc, callback);
}

fn registerClass(class_id: *const GUID, alloc: Allocator, callback: Callback) !Registration {
    const factory = try Factory.init(alloc, callback);
    errdefer _ = factory.interface.vtable.Release(&factory.interface);

    var cookie: u32 = undefined;
    const hr = CoRegisterClassObject(class_id, &factory.interface, clsctx_local_server, regcls_multipleuse, &cookie);
    if (hr < 0) {
        log.warn("CoRegisterClassObject failed HRESULT=0x{x:0>8}", .{@as(u32, @bitCast(hr))});
        return error.TerminalHandoffRegistrationFailed;
    }
    return .{ .cookie = cookie, .factory = factory };
}

const ClassFactory = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*ClassFactory, ?*const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ClassFactory) callconv(.winapi) u32,
        Release: *const fn (*ClassFactory) callconv(.winapi) u32,
        CreateInstance: *const fn (*ClassFactory, ?*anyopaque, ?*const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
        LockServer: *const fn (*ClassFactory, w32.BOOL) callconv(.winapi) HRESULT,
    };
};

const Handoff = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*Handoff, ?*const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Handoff) callconv(.winapi) u32,
        Release: *const fn (*Handoff) callconv(.winapi) u32,
        EstablishPtyHandoff: *const fn (
            *Handoff,
            ?*?HANDLE,
            ?*?HANDLE,
            ?HANDLE,
            ?HANDLE,
            ?HANDLE,
            ?HANDLE,
            ?*const StartupInfo,
        ) callconv(.winapi) HRESULT,
    };
};

const Factory = struct {
    interface: ClassFactory = .{ .vtable = &vtable },
    refs: std.atomic.Value(u32) = .init(1),
    alloc: Allocator,
    callback: ?Callback,
    locks: u32 = 0,

    const vtable: ClassFactory.VTable = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .CreateInstance = createInstance,
        .LockServer = lockServer,
    };

    fn init(alloc: Allocator, callback: Callback) Allocator.Error!*Factory {
        const self = try alloc.create(Factory);
        self.* = .{ .alloc = alloc, .callback = callback };
        return self;
    }

    fn queryInterface(iface: *ClassFactory, requested: ?*const GUID, result: ?*?*anyopaque) callconv(.winapi) HRESULT {
        const out = result orelse return e_pointer;
        out.* = null;
        const iid = requested orelse return e_pointer;
        if (!sameGuid(iid, &iid_unknown) and !sameGuid(iid, &iid_class_factory)) return e_nointerface;
        _ = addRef(iface);
        out.* = iface;
        return s_ok;
    }

    fn addRef(iface: *ClassFactory) callconv(.winapi) u32 {
        const self: *Factory = @fieldParentPtr("interface", iface);
        return self.refs.fetchAdd(1, .monotonic) + 1;
    }

    fn release(iface: *ClassFactory) callconv(.winapi) u32 {
        const self: *Factory = @fieldParentPtr("interface", iface);
        const remaining = self.refs.fetchSub(1, .acq_rel) - 1;
        if (remaining == 0) self.alloc.destroy(self);
        return remaining;
    }

    fn createInstance(
        iface: *ClassFactory,
        outer: ?*anyopaque,
        requested: ?*const GUID,
        result: ?*?*anyopaque,
    ) callconv(.winapi) HRESULT {
        const out = result orelse return e_pointer;
        out.* = null;
        if (outer != null) return class_e_noaggregation;
        const iid = requested orelse return e_pointer;
        if (!Receiver.supports(iid)) return e_nointerface;
        const self: *Factory = @fieldParentPtr("interface", iface);
        if (self.callback == null) return class_e_classnotavailable;
        const receiver = self.alloc.create(Receiver) catch return e_outofmemory;
        _ = addRef(iface);
        receiver.* = .{ .factory = self };
        out.* = &receiver.interface;
        return s_ok;
    }

    fn lockServer(iface: *ClassFactory, lock: w32.BOOL) callconv(.winapi) HRESULT {
        const self: *Factory = @fieldParentPtr("interface", iface);
        if (lock.toBool()) {
            self.locks += 1;
            _ = addRef(iface);
        } else {
            if (self.locks == 0) return e_fail;
            self.locks -= 1;
            _ = release(iface);
        }
        return s_ok;
    }
};

const Receiver = struct {
    interface: Handoff = .{ .vtable = &vtable },
    refs: std.atomic.Value(u32) = .init(1),
    factory: *Factory,

    const vtable: Handoff.VTable = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .EstablishPtyHandoff = establish,
    };

    fn supports(iid: *const GUID) bool {
        return sameGuid(iid, &iid_unknown) or sameGuid(iid, &iid_terminal_handoff3) or
            sameGuid(iid, &iid_default_terminal_marker);
    }

    fn queryInterface(iface: *Handoff, requested: ?*const GUID, result: ?*?*anyopaque) callconv(.winapi) HRESULT {
        const out = result orelse return e_pointer;
        out.* = null;
        const iid = requested orelse return e_pointer;
        if (!supports(iid)) return e_nointerface;
        _ = addRef(iface);
        out.* = iface;
        return s_ok;
    }

    fn addRef(iface: *Handoff) callconv(.winapi) u32 {
        const self: *Receiver = @fieldParentPtr("interface", iface);
        return self.refs.fetchAdd(1, .monotonic) + 1;
    }

    fn release(iface: *Handoff) callconv(.winapi) u32 {
        const self: *Receiver = @fieldParentPtr("interface", iface);
        const remaining = self.refs.fetchSub(1, .acq_rel) - 1;
        if (remaining == 0) {
            const factory = self.factory;
            factory.alloc.destroy(self);
            _ = Factory.release(&factory.interface);
        }
        return remaining;
    }

    fn establish(
        iface: *Handoff,
        input: ?*?HANDLE,
        output: ?*?HANDLE,
        signal: ?HANDLE,
        reference: ?HANDLE,
        server: ?HANDLE,
        client: ?HANDLE,
        startup_info: ?*const StartupInfo,
    ) callconv(.winapi) HRESULT {
        if (input) |ptr| ptr.* = null;
        if (output) |ptr| ptr.* = null;
        const in = input orelse return e_pointer;
        const out = output orelse return e_pointer;
        if (in == out) return e_invalidarg;

        const self: *Receiver = @fieldParentPtr("interface", iface);
        const callback = self.factory.callback orelse return class_e_classnotavailable;
        const pipes = callback.accept(callback.context, .{
            .signal = validHandle(signal) orelse return e_invalidarg,
            .reference = validHandle(reference) orelse return e_invalidarg,
            .server = validHandle(server) orelse return e_invalidarg,
            .client = validHandle(client) orelse return e_invalidarg,
            .startup_info = startup_info orelse return e_pointer,
        }) catch |err| {
            log.debug("handoff declined: {t}", .{err});
            return if (err == error.OutOfMemory) e_outofmemory else e_fail;
        };
        in.* = pipes.input;
        out.* = pipes.output;
        return s_ok;
    }
};

fn validHandle(handle: ?HANDLE) ?HANDLE {
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) return null;
    return handle;
}

fn sameGuid(lhs: *const GUID, rhs: *const GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(lhs), std.mem.asBytes(rhs));
}

test "ITerminalHandoff3 factory, callback, and failure outputs" {
    const testing = std.testing;
    const Fixture = struct {
        request: ?Request = null,
        fail: bool = false,

        fn accept(ctx: ?*anyopaque, request: Request) !Pipes {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.request = request;
            if (self.fail) return error.HandoffRejected;
            return .{ .input = @ptrFromInt(5), .output = @ptrFromInt(6) };
        }
    };
    var fixture: Fixture = .{};
    const factory = try Factory.init(testing.allocator, .{ .context = &fixture, .accept = Fixture.accept });
    const class = &factory.interface;
    defer _ = class.vtable.Release(class);

    var object: ?*anyopaque = null;
    for ([_]*const GUID{ &iid_unknown, &iid_class_factory }) |iid| {
        try testing.expectEqual(s_ok, class.vtable.QueryInterface(class, iid, &object));
        try testing.expectEqual(@as(?*anyopaque, class), object);
        _ = class.vtable.Release(class);
    }
    try testing.expectEqual(e_nointerface, class.vtable.QueryInterface(class, &iid_terminal_handoff3, &object));
    try testing.expectEqual(null, object);
    try testing.expectEqual(class_e_noaggregation, class.vtable.CreateInstance(class, class, &iid_terminal_handoff3, &object));
    try testing.expectEqual(null, object);
    try testing.expectEqual(s_ok, class.vtable.LockServer(class, .TRUE));
    try testing.expectEqual(s_ok, class.vtable.LockServer(class, .FALSE));

    try testing.expectEqual(s_ok, class.vtable.CreateInstance(class, null, &iid_terminal_handoff3, &object));
    const handoff: *Handoff = @ptrCast(@alignCast(object.?));
    defer _ = handoff.vtable.Release(handoff);
    for ([_]*const GUID{ &iid_unknown, &iid_terminal_handoff3, &iid_default_terminal_marker }) |iid| {
        try testing.expectEqual(s_ok, handoff.vtable.QueryInterface(handoff, iid, &object));
        try testing.expectEqual(@as(?*anyopaque, handoff), object);
        _ = handoff.vtable.Release(handoff);
    }
    try testing.expectEqual(e_nointerface, handoff.vtable.QueryInterface(handoff, &iid_class_factory, &object));
    try testing.expectEqual(null, object);

    const startup: StartupInfo = std.mem.zeroes(StartupInfo);
    const handles = [4]HANDLE{ @ptrFromInt(1), @ptrFromInt(2), @ptrFromInt(3), @ptrFromInt(4) };
    const call = handoff.vtable.EstablishPtyHandoff;
    var input: ?HANDLE = null;
    var output: ?HANDLE = null;
    try testing.expectEqual(s_ok, call(handoff, &input, &output, handles[0], handles[1], handles[2], handles[3], &startup));
    try testing.expectEqual(@as(?HANDLE, @ptrFromInt(5)), input);
    try testing.expectEqual(@as(?HANDLE, @ptrFromInt(6)), output);
    try testing.expectEqualDeep(Request{
        .signal = handles[0],
        .reference = handles[1],
        .server = handles[2],
        .client = handles[3],
        .startup_info = &startup,
    }, fixture.request.?);

    fixture.fail = true;
    try testing.expectEqual(e_fail, call(handoff, &input, &output, handles[0], handles[1], handles[2], handles[3], &startup));
    try testing.expectEqual(null, input);
    try testing.expectEqual(null, output);
    factory.callback = null;
    try testing.expectEqual(class_e_classnotavailable, call(handoff, &input, &output, handles[0], handles[1], handles[2], handles[3], &startup));
}

test "ITerminalHandoff3 publishes a temporary local COM class" {
    const testing = std.testing;
    const Ole = struct {
        extern "ole32" fn CoCreateGuid(*GUID) callconv(.winapi) HRESULT;
        extern "ole32" fn CoUninitialize() callconv(.winapi) void;
        extern "ole32" fn CoGetClassObject(*const GUID, u32, ?*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT;

        fn reject(_: ?*anyopaque, _: Request) !Pipes {
            return error.UnexpectedCallback;
        }
    };

    const apartment_threaded = 2;
    try testing.expect(w32.CoInitializeEx(null, apartment_threaded) >= 0);
    defer Ole.CoUninitialize();

    var test_clsid: GUID = undefined;
    try testing.expectEqual(s_ok, Ole.CoCreateGuid(&test_clsid));
    var registration = try registerClass(&test_clsid, testing.allocator, .{ .context = null, .accept = Ole.reject });
    defer registration.deinit();

    var result: ?*anyopaque = null;
    try testing.expectEqual(s_ok, Ole.CoGetClassObject(&test_clsid, clsctx_local_server, null, &iid_class_factory, &result));
    const factory: *ClassFactory = @ptrCast(@alignCast(result.?));
    defer _ = factory.vtable.Release(factory);
    try testing.expectEqual(s_ok, factory.vtable.CreateInstance(factory, null, &iid_terminal_handoff3, &result));
    const receiver: *Handoff = @ptrCast(@alignCast(result.?));
    _ = receiver.vtable.Release(receiver);
}
