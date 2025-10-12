child_allocator: std.heap.Allocator,
buffer_list: std.ArrayListUnmanaged(Buffer),

const Buffer = struct {
    buff: []u8,
    used: usize,
};

const CheckPoint = struct {
    buffer_idx: usize,
    used: usize,
};

fn init(child_allocator: std.heap.Allocator) Scratch {
    return .{
        .child_allocator = child_allocator,
        .buffer_list = .{},
        .buffer_count = 0,
    };
}

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const self: *Scratch = @ptrCast(ctx);

    if (self.buffer_list.items.len == 0) {
        const slot = self.buffer_list.addOne(self.child_allocator) catch return null;

        const page_size = std.heap.pageSize();
        const size = @max(page_size, len);

        const buffer = self.child_allocator.rawAlloc(size, alignment, @returnAddress()) orelse return null;
        slot.* = .{ .buff = buffer[0..size], .used = len };

        return buffer;
    }

    const current_buffer = self.buffer_list.items[self.buffer_list.items.len - 1];

    const buffer_unused_addr = @intFromPtr(current_buffer.buff[current_buffer.used..]);
    const buffer_unused_addr_aligned = std.mem.alignForward(usize, buffer_unused_addr, alignment.toByteUnits());

    const alignement_padding_size = buffer_unused_addr_aligned - buffer_unused_addr;
    const len_with_padding = len + alignement_padding_size;

    var unused_size = current_buffer.buff.len - current_buffer.used;
    if (unused_size < len_with_padding) {}
    while (true) {
        const unused_size = current_buffer.buff.len - current_buffer.used;
        if (!unused_size < len_with_padding) break;
    }

    while (true) {
        if (!unused_size < len_with_padding) break;

        const slot = self.buffer_list.addOne(self.child_allocator) catch return null;

        const page_size = std.heap.pageSize();
        const size = @max(page_size, len);

        const buffer = self.child_allocator.rawAlloc(size, alignment, @returnAddress()) orelse return null;
        slot.* = .{ .buff = buffer[0..size], .used = len };

        return buffer;
    }
}

fn allocator(self: *Scratch) std.mem.Allocator {
    return .{
        .ptr = @ptrCast(self),
        .vtable = .{
            .alloc = alloc,
            .free = std.mem.Allocator.noFree,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
        },
    };
}

const std = @import("std");
const Scratch = @This();
