a simple scratch allocator meant for this pattern:
```zig
fn foo(scratch: *Scratch) !void {
    const checkpoint = scratch.checkpoint();
    defer scratch.restoreCheckpoint(checkpoint);

    // do your temp allocations with scratch.allocator()
    // they will be automaticaly be released at function exit
}
```