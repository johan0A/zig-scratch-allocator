// TODO: recycle buffers instead of freeing them

child_allocator: std.mem.Allocator,
buffers: std.ArrayListUnmanaged(Buffer),

const Buffer = struct {
    buff: []u8,
    used: usize,
};

const CheckPoint = struct {
    buffer_count: usize,
    used: usize,
};

fn init(child_allocator: std.mem.Allocator) Scratch {
    return .{
        .child_allocator = child_allocator,
        .buffers = .empty,
    };
}

fn deinit(self: *Scratch) void {
    for (self.buffers.items) |buffer| {
        self.child_allocator.free(buffer.buff);
    }
    self.buffers.deinit(self.child_allocator);
    self.* = undefined;
}

pub fn checkPoint(self: *Scratch) CheckPoint {
    return .{
        .buffer_count = self.buffers.items.len,
        .used = if (self.buffers.items.len == 0) 0 else self.buffers.getLast().used,
    };
}

pub fn restoreCheckPoint(self: *Scratch, cp: CheckPoint) void {
    if (cp.buffer_count != 0) {
        self.buffers.items[cp.buffer_count - 1].used = cp.used;
    }
    for (self.buffers.items[cp.buffer_count..]) |buff| {
        self.child_allocator.rawFree(buff.buff, .@"1", @returnAddress());
    }
    self.buffers.resize(self.child_allocator, cp.buffer_count) catch unreachable;
}

fn addOneBuffer(self: *Scratch, min_size: usize, ret_addr: usize) ?*Buffer {
    const slot = self.buffers.addOne(self.child_allocator) catch return null;

    const page_size = std.heap.pageSize();
    const base_size = page_size <<| (self.buffers.items.len - 1);
    const size = @max(base_size, min_size);

    const buffer = self.child_allocator.rawAlloc(size, .@"1", ret_addr) orelse return null;
    slot.* = .{ .buff = buffer[0..size], .used = 0 };
    return slot;
}

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Scratch = @ptrCast(@alignCast(ctx));

    if (self.buffers.items.len == 0) {
        _ = self.addOneBuffer(len, ret_addr) orelse return null;
    } else {
        const current_buffer = &self.buffers.items[self.buffers.items.len - 1];

        const buffer_unused_addr = @intFromPtr(current_buffer.buff[current_buffer.used..].ptr);
        const buffer_unused_addr_aligned = std.mem.alignForward(usize, buffer_unused_addr, alignment.toByteUnits());
        const alignement_padding_size = buffer_unused_addr_aligned - buffer_unused_addr;

        const len_with_padding = len + alignement_padding_size;

        const unused_size = current_buffer.buff.len - current_buffer.used;

        if (unused_size < len_with_padding) {
            const resize_len = current_buffer.used + len_with_padding;
            if (self.child_allocator.rawResize(current_buffer.buff, .@"1", resize_len, ret_addr)) {
                current_buffer.buff = current_buffer.buff.ptr[0..resize_len];
            } else {
                _ = self.addOneBuffer(len, ret_addr) orelse return null;
            }
        }
    }

    const current_buffer = &self.buffers.items[self.buffers.items.len - 1];

    const buffer_unused_addr = @intFromPtr(current_buffer.buff[current_buffer.used..].ptr);
    const buffer_unused_addr_aligned = std.mem.alignForward(usize, buffer_unused_addr, alignment.toByteUnits());
    const alignement_padding_size = buffer_unused_addr_aligned - buffer_unused_addr;

    const len_with_padding = len + alignement_padding_size;

    current_buffer.used += len_with_padding;

    return @ptrFromInt(buffer_unused_addr_aligned);
}

fn allocator(self: *Scratch) std.mem.Allocator {
    return .{
        .ptr = @ptrCast(self),
        .vtable = &.{
            .alloc = alloc,
            .free = std.mem.Allocator.noFree,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
        },
    };
}

test Scratch {
    {
        var scratch = Scratch.init(std.testing.allocator);
        defer scratch.deinit();

        try std.heap.testAllocator(scratch.allocator());
        try std.heap.testAllocatorAligned(scratch.allocator());
        try std.heap.testAllocatorAlignedShrink(scratch.allocator());
        try std.heap.testAllocatorLargeAlignment(scratch.allocator());

        {
            const cp = scratch.checkPoint();
            defer scratch.restoreCheckPoint(cp);

            try std.heap.testAllocator(scratch.allocator());
            try std.heap.testAllocatorAligned(scratch.allocator());
            try std.heap.testAllocatorAlignedShrink(scratch.allocator());
            try std.heap.testAllocatorLargeAlignment(scratch.allocator());
        }
    }

    {
        var scratch = Scratch.init(std.testing.allocator);
        defer scratch.deinit();

        var rand_state = std.Random.DefaultPrng.init(0);
        const rand = rand_state.random();

        {
            const outer_cp = scratch.checkPoint();
            defer scratch.restoreCheckPoint(outer_cp);

            var checkpoints: std.ArrayList(Scratch.CheckPoint) = .empty;
            defer checkpoints.deinit(std.testing.allocator);
            {
                for (0..1e6) |_| {
                    switch (rand.uintLessThan(u8, 3)) {
                        0 => {
                            try checkpoints.append(std.testing.allocator, scratch.checkPoint());
                        },
                        1 => {
                            scratch.restoreCheckPoint(checkpoints.pop() orelse continue);
                        },
                        2 => {
                            _ = scratch.allocator().rawAlloc(rand.int(u14), rand.enumValue(std.mem.Alignment), 0) orelse return error.OutOfMemory;
                        },
                        else => @panic(""),
                    }
                }
                while (checkpoints.pop()) |cp| scratch.restoreCheckPoint(cp);
            }
        }

        try std.testing.expectEqual(0, scratch.buffers.items.len);
    }
}

const std = @import("std");
const Scratch = @This();
