const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const module = b.addModule("scratch_allocator", .{
        .root_source_file = b.path("src/Scratch.zig"),
        .optimize = optimize,
        .target = target,
    });

    {
        const tests = b.addTest(.{ .name = "test", .root_module = module });
        const run_tests = b.addRunArtifact(tests);
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_tests.step);
    }
}
