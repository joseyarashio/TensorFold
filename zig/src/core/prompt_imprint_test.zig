//! Learned prompt states on disk: reopen, eviction order, removal and the sweep of other identities.
const std = @import("std");
const imp = @import("prompt_imprint.zig");
const Imprint = imp.Imprint;

/// `root`, its identity directories and their files removed (a test's scratch tree, two levels deep).
pub fn rmTree(root: []const u8) void {
    var buf: [512]u8 = undefined;
    const r = std.fmt.bufPrintSentinel(&buf, "{s}", .{root}, 0) catch return;
    const d = std.c.opendir(r) orelse return;
    while (std.c.readdir(d)) |ent| {
        const name = std.mem.sliceTo(&ent.name, 0);
        if (name[0] == '.') continue;
        var sub: [512]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&sub, "{s}/{s}", .{ root, name }, 0) catch continue;
        if (std.c.unlink(p) == 0) continue;
        if (std.c.opendir(p)) |s| {
            while (std.c.readdir(s)) |f| {
                const fname = std.mem.sliceTo(&f.name, 0);
                if (fname[0] == '.') continue;
                var fb: [600]u8 = undefined;
                _ = std.c.unlink(std.fmt.bufPrintSentinel(&fb, "{s}/{s}", .{ p, fname }, 0) catch continue);
            }
            _ = std.c.closedir(s);
        }
        _ = std.c.rmdir(p);
    }
    _ = std.c.closedir(d);
    _ = std.c.rmdir(r);
}

fn scratch(buf: []u8, tag: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "/tmp/tf-imprint-{s}-{d}", .{ tag, std.c.getpid() });
}

/// A file of `n` bytes at `dir`/`name`.
fn fill(dir: []const u8, name: []const u8, n: usize) !void {
    var buf: [512]u8 = undefined;
    const fd = std.c.open(try std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, name }, 0), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.TestFile;
    defer _ = std.c.close(fd);
    var zeros: [256]u8 = @splat(0);
    var left = n;
    while (left > 0) : (left -= @min(left, zeros.len)) try imp.writeAll(fd, zeros[0..@min(left, zeros.len)]);
}

fn exists(path: []const u8) bool {
    var buf: [512]u8 = undefined;
    const d = std.c.opendir(std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return false) orelse return false;
    _ = std.c.closedir(d);
    return true;
}

test "learned states survive a reopen; the longest usable prefix wins" {
    const gpa = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const root = try scratch(&tmp_buf, "reopen");
    defer rmTree(root);
    {
        var m = try Imprint.open(gpa, root, 7, 1 << 30);
        defer m.deinit();
        try m.add(Imprint.keyOf(&.{ 1, 2, 3 }), 2, &.{ 1, 2, 3 }, &.{ 1, 2, 5 }, 10);
        try m.add(Imprint.keyOf(&.{ 1, 2, 3, 4, 5 }), 4, &.{ 1, 2, 3, 4, 5 }, &.{ 1, 4 }, 20);
        try std.testing.expect(m.has(Imprint.keyOf(&.{ 1, 2, 3 })));
    }
    var m = try Imprint.open(gpa, root, 7, 1 << 30);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 2), m.metas.items.len);
    try std.testing.expectEqual(@as(u64, 30), m.total());
    const prompt = [_]u32{ 1, 2, 3, 4, 5, 6, 7 };
    try std.testing.expectEqual(@as(u32, 4), m.best(&prompt, &.{ 1, 4, 6 }, true, 0, 0).?.at);
    try std.testing.expectEqual(@as(u32, 2), m.best(&prompt, &.{ 1, 2, 6 }, true, 0, 0).?.at); // other starts below 4: only 2 fits
    try std.testing.expect(m.best(&prompt, &.{ 1, 4, 6 }, true, 4, 0) == null); // memory already holds 4
    try std.testing.expect(m.best(&.{ 1, 2, 9, 9 }, &.{ 1, 2 }, true, 0, 0) == null); // token 2 differs: 3 was read
    var other = try Imprint.open(gpa, root, 8, 1 << 30); // another identity sees nothing
    defer other.deinit();
    try std.testing.expectEqual(@as(usize, 0), other.metas.items.len);
}

test "the least recently used state goes first, and a removed one stays gone after a reopen" {
    const gpa = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const root = try scratch(&tmp_buf, "lru");
    defer rmTree(root);
    const a = Imprint.keyOf(&.{ 1, 2 });
    const b = Imprint.keyOf(&.{ 3, 4 });
    const c = Imprint.keyOf(&.{ 5, 6 });
    {
        var m = try Imprint.open(gpa, root, 1, 100);
        defer m.deinit();
        try m.add(a, 1, &.{ 1, 2 }, &.{}, 30);
        try m.add(b, 1, &.{ 3, 4 }, &.{}, 30);
        try m.add(c, 1, &.{ 5, 6 }, &.{}, 30);
        m.touch(a);
        try std.testing.expectEqual(b, m.victim().?);
        try std.testing.expect(!m.fits(20)); // 90 held of 100
        try m.remove(b);
        try std.testing.expect(m.fits(20));
        try std.testing.expectEqual(c, m.victim().?);
    }
    var m = try Imprint.open(gpa, root, 1, 100);
    defer m.deinit();
    try std.testing.expect(m.has(a) and m.has(c) and !m.has(b));
    try std.testing.expectEqual(@as(u64, 60), m.total());
}

test "other identities are swept, least recently opened first, until the cap fits" {
    const gpa = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const root = try scratch(&tmp_buf, "sweep");
    defer rmTree(root);
    var dirs: [2][300]u8 = undefined;
    var names: [2][]const u8 = undefined;
    for (0..2) |i| {
        var m = try Imprint.open(gpa, root, i + 1, 1 << 30);
        defer m.deinit();
        try fill(m.dir, "state.bin", 100); // with its 8-byte stamp: 108 bytes an identity
        names[i] = try std.fmt.bufPrint(&dirs[i], "{s}", .{m.dir});
    }
    var m = try Imprint.open(gpa, root, 3, 150); // 216 bytes elsewhere: the older identity goes
    defer m.deinit();
    try std.testing.expect(!exists(names[0]));
    try std.testing.expect(exists(names[1]));
    try std.testing.expectEqual(@as(u64, 108), m.others);
    try std.testing.expect(m.fits(42) and !m.fits(43 + 108)); // a larger state sweeps the other identity too
    try std.testing.expect(!exists(names[1]));
    try std.testing.expectEqual(@as(u64, 0), m.others);
}

test "reprobe takes each state's bytes and last use from its files; a state without files is dropped" {
    const gpa = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const root = try scratch(&tmp_buf, "reprobe");
    defer rmTree(root);
    const a = Imprint.keyOf(&.{ 1, 2 });
    const b = Imprint.keyOf(&.{ 3, 4 });
    var m = try Imprint.open(gpa, root, 1, 1 << 30);
    defer m.deinit();
    try m.add(a, 1, &.{ 1, 2 }, &.{}, 10); // the index says 10 bytes (an older build undercounted)
    try m.add(b, 1, &.{ 3, 4 }, &.{}, 10);
    var name: [64]u8 = undefined;
    try fill(m.dir, try std.fmt.bufPrint(&name, "{x:0>16}.r0.bin", .{a}), 700); // the family's real file: 700 bytes
    try std.testing.expectEqual(@as(u64, 700), m.diskBytes(a));
    // b has no file
    try std.testing.expectEqual(@as(usize, 1), try m.reprobe());
    try std.testing.expect(m.has(a) and !m.has(b));
    try std.testing.expectEqual(@as(u64, 700), m.total());
    try m.rewrite();
    var again = try Imprint.open(gpa, root, 1, 1 << 30);
    defer again.deinit();
    try std.testing.expectEqual(@as(u64, 700), again.total()); // the corrected bytes are in the index now
}

test "a state unread past the ttl expires; reading it moves its last use to now" {
    const gpa = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const root = try scratch(&tmp_buf, "ttl");
    defer rmTree(root);
    const a = Imprint.keyOf(&.{ 1, 2 });
    const b = Imprint.keyOf(&.{ 3, 4 });
    var m = try Imprint.open(gpa, root, 1, 1 << 30);
    defer m.deinit();
    m.ttl = 3600;
    try m.add(a, 1, &.{ 1, 2 }, &.{}, 10);
    try m.add(b, 1, &.{ 3, 4 }, &.{}, 10);
    const now = imp.nowSeconds();
    m.metas.items[0].last = now - 7200; // a: two hours unread
    m.metas.items[1].last = now - 60;
    const old = try m.expired(gpa, now);
    defer gpa.free(old);
    try std.testing.expectEqual(@as(usize, 1), old.len);
    try std.testing.expectEqual(a, old[0]);
    m.touch(a); // read now
    const none = try m.expired(gpa, imp.nowSeconds());
    defer gpa.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    m.ttl = 0; // no limit
    m.metas.items[0].last = now - 999999;
    const off = try m.expired(gpa, now);
    defer gpa.free(off);
    try std.testing.expectEqual(@as(usize, 0), off.len);
}

test "victims are the least recently used, enough to fit, never the kept one; removeMany rewrites once" {
    const gpa = std.testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const root = try scratch(&tmp_buf, "victims");
    defer rmTree(root);
    const a = Imprint.keyOf(&.{ 1, 2 });
    const b = Imprint.keyOf(&.{ 3, 4 });
    const c = Imprint.keyOf(&.{ 5, 6 });
    {
        var m = try Imprint.open(gpa, root, 1, 100);
        defer m.deinit();
        try m.add(a, 1, &.{ 1, 2 }, &.{}, 40);
        try m.add(b, 1, &.{ 3, 4 }, &.{}, 40);
        try m.add(c, 1, &.{ 5, 6 }, &.{}, 10);
        const none = try m.victims(gpa, 10, 0); // 90 + 10 fits 100
        defer gpa.free(none);
        try std.testing.expectEqual(@as(usize, 0), none.len);
        m.setBytes(c, 80); // c's files turn out larger: 160 held
        const v = try m.victims(gpa, 0, c); // a then b go; c is kept
        defer gpa.free(v);
        try std.testing.expectEqual(@as(usize, 2), v.len);
        try std.testing.expectEqual(a, v[0]);
        try std.testing.expectEqual(b, v[1]);
        try m.removeMany(v);
        try std.testing.expectEqual(@as(u64, 80), m.total());
    }
    var m = try Imprint.open(gpa, root, 1, 100);
    defer m.deinit();
    try std.testing.expect(!m.has(a) and !m.has(b) and m.has(c));
}
