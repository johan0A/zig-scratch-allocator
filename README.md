a simple scratch allocator meant for this pattern:
```zig
fn foo(scratch: *Scratch) !void {
    const snapshot = scratch.snapshot();
    defer scratch.restoreSnapshot(snapshot);

    // do your temp allocations with scratch.allocator()
    // they will be automaticaly be released at function exit
}
```