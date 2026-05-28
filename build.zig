const std = @import("std");
const Build = std.Build;
const Module = Build.Module;
const Options = Build.Step.Options;

fn options(b: *Build) *Options {
    const trace_execution = b.option(bool, "trace_execution", "Enable execution trace.") orelse false;
    const print_code = b.option(bool, "print_code", "Enable code print.") orelse false;
    const stress_gc = b.option(bool, "stress_gc", "Enable GC stress test.") orelse false;
    const log_gc = b.option(bool, "log_gc", "Enable GC logging.") orelse false;
    const debug = b.option(bool, "debug", "Enable all debug flags.") orelse false;
    const nan_boxing = b.option(bool, "nan_boxing", "Enable NaN boxing (default: true).") orelse true;

    const opts = b.addOptions();
    opts.addOption(bool, "trace_execution", trace_execution or debug);
    opts.addOption(bool, "print_code", print_code or debug);
    opts.addOption(bool, "stress_gc", stress_gc or debug);
    opts.addOption(bool, "log_gc", log_gc or debug);
    opts.addOption(bool, "nan_boxing", nan_boxing);
    return opts;
}

fn buildExe(b: *Build, root_module: *Module) void {
    const exe = b.addExecutable(.{
        .name = "zlox",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_exe.step);
    run_exe.step.dependOn(b.getInstallStep());

    // Pass the arguments through as is.
    if (b.args) |args| {
        run_exe.addArgs(args);
    }
}

fn buildTest(b: *Build, root_module: *Module) void {
    const tests = b.addTest(.{
        .name = "zlox-test",
        .root_module = root_module,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}

pub fn build(b: *Build) void {
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    root_module.addOptions("config", options(b));

    buildExe(b, root_module);
    buildTest(b, root_module);
}
