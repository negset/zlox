const std = @import("std");
const Build = std.Build;
const Options = Build.Step.Options;
const OptimizeMode = std.builtin.OptimizeMode;
const ResolvedTarget = Build.ResolvedTarget;

fn createOptions(b: *Build) *Options {
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

fn buildExe(b: *Build, target: ResolvedTarget, optimize: OptimizeMode, opts: *Options) void {
    const exe = b.addExecutable(.{
        .name = "zlox",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("config", opts);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    const step = b.step("run", "Run the app");
    step.dependOn(&run.step);
    run.step.dependOn(b.getInstallStep());

    // Pass the arguments through as is.
    if (b.args) |args| {
        run.addArgs(args);
    }
}

fn buildTest(b: *Build, target: ResolvedTarget, optimize: OptimizeMode, opts: *Options) void {
    const tests = b.addTest(.{
        .name = "zlox-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addOptions("config", opts);

    const run = b.addRunArtifact(tests);
    const step = b.step("test", "Run tests");
    step.dependOn(&run.step);
}

fn buildWasm(b: *Build, optimize: OptimizeMode, opts: *Options) void {
    const exe = b.addExecutable(.{
        .name = "zlox",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("config", opts);

    exe.entry = .disabled;
    exe.rdynamic = true;
    exe.import_memory = true;

    const install = b.addInstallArtifact(exe, .{});
    const step = b.step("wasm", "Build Wasm module");
    step.dependOn(&install.step);

    const copy = b.addInstallFile(exe.getEmittedBin(), "../www/zlox.wasm");
    install.step.dependOn(&copy.step);
}

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const opts = createOptions(b);

    buildExe(b, target, optimize, opts);
    buildTest(b, target, optimize, opts);
    buildWasm(b, optimize, opts);
}
