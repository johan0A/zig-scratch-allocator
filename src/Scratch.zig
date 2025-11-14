const buffer_count = 32;

child_allocator: Allocator,
buffers: [buffer_count]Buffer,
current_buffer_idx: std.math.IntFittingRange(0, buffer_count - 1),
allocated_buffer_count: std.math.IntFittingRange(0, buffer_count),

const Buffer = struct {
    data: []u8,
    used: usize,
};

const Checkpoint = struct {
    buffer_idx: std.math.IntFittingRange(0, buffer_count - 1),
    used: usize,
};

pub fn init(child_allocator: Allocator) Allocator.Error!Scratch {
    var result: Scratch = .{
        .child_allocator = child_allocator,
        .current_buffer_idx = 0,
        .allocated_buffer_count = 1,
        .buffers = @splat(undefined),
    };

    const size = std.heap.pageSize();
    const buffer = child_allocator.rawAlloc(size, .@"1", @returnAddress()) orelse return error.OutOfMemory;
    result.buffers[0] = .{ .data = buffer[0..size], .used = 0 };

    return result;
}

pub fn deinit(self: *Scratch) void {
    for (self.buffers[0..self.allocated_buffer_count]) |buffer| self.child_allocator.free(buffer.data);
    self.* = undefined;
}

/// create a checkpoint to use with `restoreCheckpoint`
pub fn checkpoint(self: *Scratch) Checkpoint {
    return .{
        .buffer_idx = self.current_buffer_idx,
        .used = self.buffers[self.current_buffer_idx].used,
    };
}

/// free all allocations since checkpoint
pub fn restoreCheckpoint(self: *Scratch, snap: Checkpoint) void {
    std.debug.assert(self.current_buffer_idx >= snap.buffer_idx);
    self.current_buffer_idx = snap.buffer_idx;
    self.buffers[self.current_buffer_idx].used = snap.used;
}

fn nextBuffer(self: *Scratch, ret_addr: usize) bool {
    std.debug.assert(self.current_buffer_idx < self.allocated_buffer_count);
    if (self.current_buffer_idx == self.allocated_buffer_count - 1) {
        const page_size = std.heap.pageSize();
        const size = page_size << self.current_buffer_idx;

        const buffer = self.child_allocator.rawAlloc(size, .@"1", ret_addr) orelse return false;
        self.current_buffer_idx += 1;
        self.buffers[self.current_buffer_idx] = .{ .data = buffer[0..size], .used = undefined };
        self.allocated_buffer_count += 1;
    } else {
        self.current_buffer_idx += 1;
    }
    self.buffers[self.current_buffer_idx].used = 0;
    return true;
}

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Scratch = @ptrCast(@alignCast(ctx));

    while (true) {
        const current_buffer = &self.buffers[self.current_buffer_idx];

        const unused_addr = @intFromPtr(current_buffer.data[current_buffer.used..].ptr);
        const unused_addr_aligned = std.mem.alignForward(usize, unused_addr, alignment.toByteUnits());
        const padding = unused_addr_aligned - unused_addr;
        const len_with_padding = len + padding;

        const unused_size = current_buffer.data.len - current_buffer.used;
        if (unused_size < len_with_padding) {
            if (!self.nextBuffer(ret_addr)) return null;
        } else {
            current_buffer.used += len_with_padding;
            return @ptrFromInt(unused_addr_aligned);
        }
    }
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *Scratch = @ptrCast(@alignCast(ctx));
    _ = alignment;
    _ = ret_addr;

    const current_buffer = &self.buffers[self.current_buffer_idx];

    const memory_end = @intFromPtr(memory.ptr) + memory.len;
    const buffer_used_end = @intFromPtr(current_buffer.data.ptr) + current_buffer.used;
    if (memory_end != buffer_used_end) return false;

    const new_used = current_buffer.used - memory.len + new_len;
    if (new_used > current_buffer.data.len) return false;

    current_buffer.used = new_used;
    return true;
}

pub fn allocator(self: *Scratch) Allocator {
    return .{
        .ptr = @ptrCast(self),
        .vtable = &.{
            .alloc = alloc,
            .free = Allocator.noFree,
            .resize = resize,
            .remap = Allocator.noRemap,
        },
    };
}

test Scratch {
    {
        var scratch: Scratch = try .init(std.testing.allocator);
        defer scratch.deinit();

        const empty = try scratch.allocator().alloc(u8, 0);
        try std.testing.expectEqualSlices(u8, &.{}, empty);

        try std.heap.testAllocator(scratch.allocator());
        try std.heap.testAllocatorAligned(scratch.allocator());
        try std.heap.testAllocatorAlignedShrink(scratch.allocator());
        try std.heap.testAllocatorLargeAlignment(scratch.allocator());

        {
            const cp = scratch.checkpoint();
            defer scratch.restoreCheckpoint(cp);

            try std.heap.testAllocator(scratch.allocator());
            try std.heap.testAllocatorAligned(scratch.allocator());
            try std.heap.testAllocatorAlignedShrink(scratch.allocator());
            try std.heap.testAllocatorLargeAlignment(scratch.allocator());
        }
    }

    {
        var scratch: Scratch = try .init(std.testing.allocator);
        defer scratch.deinit();

        var rand_state = std.Random.DefaultPrng.init(0);
        const rand = rand_state.random();

        {
            const outer_cp = scratch.checkpoint();
            defer scratch.restoreCheckpoint(outer_cp);

            var checkpoints: std.ArrayList(Scratch.Checkpoint) = .empty;
            defer checkpoints.deinit(std.testing.allocator);
            {
                for (0..1e6) |_| {
                    switch (rand.uintLessThan(u8, 3)) {
                        0 => try checkpoints.append(std.testing.allocator, scratch.checkpoint()),
                        1 => scratch.restoreCheckpoint(checkpoints.pop() orelse continue),
                        2 => _ = scratch.allocator().rawAlloc(rand.int(u14), rand.enumValue(std.mem.Alignment), 0) orelse return error.OutOfMemory,
                        else => @panic(""),
                    }
                }
                while (checkpoints.pop()) |cp| scratch.restoreCheckpoint(cp);
            }
        }
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Scratch = @This();
