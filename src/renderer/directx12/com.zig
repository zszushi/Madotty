//! Common COM ABI and HRESULT handling for the native graphics backend.

const std = @import("std");

pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};
pub const HRESULT = i32;
pub const Reserved = *const anyopaque;
pub const S_OK: HRESULT = 0;
pub const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));

pub const IUnknown = extern struct {
    vtable: *const extern struct {
        QueryInterface: *const fn (*IUnknown, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IUnknown) callconv(.winapi) u32,
        Release: *const fn (*IUnknown) callconv(.winapi) u32,
    },
};

pub fn FAILED(hr: HRESULT) bool {
    return hr < 0;
}

pub fn SUCCEEDED(hr: HRESULT) bool {
    return hr >= 0;
}

pub fn check(operation: []const u8, hr: HRESULT) error{DirectX12Failure}!void {
    if (SUCCEEDED(hr)) return;
    std.log.scoped(.directx12).err("{s} failed HRESULT=0x{x:0>8}", .{ operation, @as(u32, @bitCast(hr)) });
    return error.DirectX12Failure;
}

pub fn query(comptime T: type, object: anytype) !*T {
    const unknown: *IUnknown = @ptrCast(object);
    var result: ?*anyopaque = null;
    try check("QueryInterface", unknown.vtable.QueryInterface(unknown, &T.IID, &result));
    return @ptrCast(@alignCast(result orelse return error.DirectX12Failure));
}
