const std = @import("std");

const mem = std.mem;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

const Error = error{ Codec, Overrun };

//
//
// Deserialization
//
//

pub const Deserialize = struct {
    const Self = @This();

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        visit_tag: *const fn (*anyopaque, u64) Visitor,
    };

    pub fn visitTag(self: Self, tag: u64) Visitor {
        return (self.vtable.visit_tag)(tag);
    }
};

pub const Visitor = struct {
    const Self = @This();

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        visit_wire_type_varint: *const fn (*anyopaque, u64) anyerror!void,
        visit_wire_type_i64: *const fn (*anyopaque, u64) anyerror!void,
        visit_wire_type_len: *const fn (*anyopaque, []const u8) anyerror!void,
        visit_wire_type_i32: *const fn (*anyopaque, u32) anyerror!void,
    };

    pub fn visitWireTypeVarint(self: Self, varint: u64) !void {
        return (self.vtable.visit_wire_type_varint)(self.ptr, varint);
    }

    pub fn visitWireTypeI64(self: Self, val: u64) !void {
        return (self.vtable.visit_wire_type_i64)(self.ptr, val);
    }

    pub fn visitWireTypeLen(self: Self, bytes: []const u8) !void {
        return (self.vtable.visit_wire_type_len)(self.ptr, bytes);
    }

    pub fn visitWireTypeI32(self: Self, val: u32) !void {
        return (self.vtable.visit_wire_type_i32)(self.ptr, val);
    }

    //
    // Visitor implementors
    //

    fn visitUInt32(ptr: *anyopaque, val: u64) !void {
        var concrete_ptr: *u32 = @ptrCast(@alignCast(ptr));
        concrete_ptr.* = @truncate(val);
    }

    pub fn UInt32(ptr: *u32) Visitor {
        return .{ .ptr = @ptrCast(ptr), .vtable = &.{
            .visit_wire_type_varint = visitUInt32,
            .visit_wire_type_i64 = visitWireTypeI64Null,
            .visit_wire_type_len = visitWireTypeLenNull,
            .visit_wire_type_i32 = visitWireTypeI32Null,
        } };
    }

    const UInt32ArrayListImpl = struct {
        fn visitWireTypeVarint(ptr: *anyopaque, val: u64) !void {
            var concrete_ptr: *std.ArrayList(u32) = @ptrCast(@alignCast(ptr));
            try concrete_ptr.append(@truncate(val));
        }

        fn visitWireTypeLen(ptr: *anyopaque, bytes: []const u8) !void {
            var concrete_ptr: *std.ArrayList(u32) = @ptrCast(@alignCast(ptr));
            var xs = bytes;
            while (xs.len != 0) {
                const x = try decodeVarint(&xs);
                try concrete_ptr.append(@truncate(x));
            }
        }
    };

    pub fn UInt32ArrayList(ptr: *std.ArrayList(u32)) Visitor {
        return .{
            .ptr = @ptrCast(ptr),
            .vtable = &.{
                .visit_wire_type_varint = UInt32ArrayListImpl.visitWireTypeVarint,
                .visit_wire_type_i64 = visitWireTypeI64Null,
                .visit_wire_type_len = UInt32ArrayListImpl.visitWireTypeLen,
                .visit_wire_type_i32 = visitWireTypeI32Null,
            },
        };
    }

    fn UInt32BoundedArrayImpl(comptime capacity: usize) type {
        return struct {
            fn visitWireTypeVarint(
                ptr: *anyopaque,
                val: u64,
            ) !void {
                var concrete_ptr: *std.BoundedArray(u32, capacity) = @ptrCast(@alignCast(ptr));
                try concrete_ptr.append(@truncate(val));
            }

            fn visitWireTypeLen(
                ptr: *anyopaque,
                bytes: []const u8,
            ) !void {
                var xs = bytes;
                var concrete_ptr: *std.BoundedArray(u32, capacity) = @ptrCast(@alignCast(ptr));
                while (xs.len != 0) {
                    const x = try decodeVarint(&xs);
                    try concrete_ptr.append(@truncate(x));
                }
            }
        };
    }

    pub fn UInt32BoundedArray(
        comptime capacity: usize,
        ptr: *std.BoundedArray(u32, capacity),
    ) Visitor {
        return .{
            .ptr = @ptrCast(ptr),
            .vtable = &.{
                .visit_wire_type_varint = UInt32BoundedArrayImpl(capacity).visitWireTypeVarint,
                .visit_wire_type_i64 = visitWireTypeI64Null,
                .visit_wire_type_len = UInt32BoundedArrayImpl(capacity).visitWireTypeLen,
                .visit_wire_type_i32 = visitWireTypeI32Null,
            },
        };
    }

    /// A visitor which doesn't do anything.
    pub const Null: Visitor = .{
        .ptr = @alignCast(@ptrCast(@constCast(&.{}))),
        .vtable = &.{
            .visit_wire_type_varint = visitWireTypeVarintNull,
            .visit_wire_type_i64 = visitWireTypeI64Null,
            .visit_wire_type_len = visitWireTypeLenNull,
            .visit_wire_type_i32 = visitWireTypeI32Null,
        },
    };
};

fn visitWireTypeVarintNull(_: *anyopaque, _: u64) !void {}
fn visitWireTypeI64Null(_: *anyopaque, _: u64) !void {}
fn visitWireTypeLenNull(_: *anyopaque, _: []const u8) !void {}
fn visitWireTypeI32Null(_: *anyopaque, _: u32) !void {}

//
//
// Helper functions
//
//

fn popByte(xs: *[]const u8) !u8 {
    if (xs.len > 0) {
        const x = xs.*[0];
        xs.* = xs.*[1..];
        return x;
    } else {
        return error.Overrun;
    }
}

fn popBytes(xs: *[]const u8, comptime n: usize) ![n]u8 {
    if (xs.len >= n) {
        const ys = xs.*[0..n];
        xs.* = xs.*[n..];
        return ys.*;
    } else {
        return error.Overrun;
    }
}

fn decodeVarint(xs: *[]const u8) !u64 {
    var varint: u64 = 0;

    for (0..10) |count| {
        const x = @as(u64, try popByte(xs));
        varint |= (x & 0x7f) << @intCast(count * 7);
        if (x <= 0x7f) {
            if (count == 9 and x >= 2) {
                return error.Codec;
            }
            return varint;
        }
    }

    return error.Codec;
}

inline fn decodeFixed32(xs: *[]const u8) !u32 {
    const bytes = try popBytes(xs, 4);
    return mem.readIntNative(u32, bytes);
}

inline fn decodeFixed64(xs: *[]const u8) !u64 {
    const bytes = try popBytes(xs, 8);
    return mem.readIntNative(u64, bytes);
}

//
//
// Test suite
//
//

test "pop byte" {
    var bytes = [_]u8{ 1, 2, 3 };
    var slice: []u8 = &bytes;
    try expectEqual(try popByte(&slice), bytes[0]);
    try expect(mem.eql(u8, slice, bytes[1..]));
    try expectEqual(try popByte(&slice), bytes[1]);
    try expect(mem.eql(u8, slice, bytes[2..]));
    try expectEqual(try popByte(&slice), bytes[2]);
    try expect(mem.eql(u8, slice, &[_]u8{}));
    try expectError(error.Overrun, popByte(&slice));
}

test "pop bytes" {
    var bytes = [_]u8{ 1, 2, 3, 4, 5, 6 };
    var slice: []u8 = &bytes;
    try expect(mem.eql(u8, &try popBytes(&slice, 2), bytes[0..2]));
    try expect(mem.eql(u8, slice, bytes[2..]));
    try expect(mem.eql(u8, &try popBytes(&slice, 3), bytes[2..5]));
    try expect(mem.eql(u8, slice, bytes[5..]));
    try expect(mem.eql(u8, &try popBytes(&slice, 1), bytes[5..]));
    try expect(mem.eql(u8, slice, &[_]u8{}));
    try expectError(error.Overrun, popByte(&slice));
}

test "decode varint" {
    {
        var bytes = [_]u8{1};
        var slice: []u8 = &bytes;
        try expectEqual(try decodeVarint(&slice), 1);
    }
    {
        var bytes = [_]u8{ 128, 1 };
        var slice: []u8 = &bytes;
        try expectEqual(try decodeVarint(&slice), 128);
    }
    {
        var bytes = [_]u8{ 128, 128, 1 };
        var slice: []u8 = &bytes;
        try expectEqual(try decodeVarint(&slice), 16384);
    }
}

test "u32 [uint32] visit varint" {
    var x: u32 = 0;
    const visitor = Visitor.UInt32(&x);
    try visitor.visitWireTypeVarint(123);
    try expectEqual(x, 123);
}

test "ArrayList(u32) [repeated uint32] visit varint" {
    var xs = std.ArrayList(u32).init(std.testing.allocator);
    defer xs.deinit();
    const visitor = Visitor.UInt32ArrayList(&xs);
    try visitor.visitWireTypeVarint(123);
    try visitor.visitWireTypeVarint(456);
    try expectEqual(xs.pop(), 456);
    try expectEqual(xs.pop(), 123);
    try expectEqual(xs.popOrNull(), null);
}

test "ArrayList(u32) [repeated uint32] visit len" {
    const bytes = [_]u8{ 123, 200, 3 };
    var xs = std.ArrayList(u32).init(std.testing.allocator);
    defer xs.deinit();
    const visitor = Visitor.UInt32ArrayList(&xs);
    try visitor.visitWireTypeLen(&bytes);
    try expectEqual(xs.pop(), 456);
    try expectEqual(xs.pop(), 123);
    try expectEqual(xs.popOrNull(), null);
}

test "BoundedArray(u32, 2) [repeated uint32] visit varint" {
    var xs = try std.BoundedArray(u32, 2).init(0);
    const visitor = Visitor.UInt32BoundedArray(2, &xs);
    try visitor.visitWireTypeVarint(123);
    try visitor.visitWireTypeVarint(456);
    try expectEqual(xs.pop(), 456);
    try expectEqual(xs.pop(), 123);
    try expectEqual(xs.popOrNull(), null);
}

test "BoundedArray(u32, 2) [repeated uint32] visit len" {
    const bytes = [_]u8{ 123, 200, 3 };
    var xs = try std.BoundedArray(u32, 2).init(0);
    const visitor = Visitor.UInt32BoundedArray(2, &xs);
    try visitor.visitWireTypeLen(&bytes);
    try expectEqual(xs.pop(), 456);
    try expectEqual(xs.pop(), 123);
    try expectEqual(xs.popOrNull(), null);
}
