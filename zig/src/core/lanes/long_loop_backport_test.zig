//! Backport safety: history retention, guard-off identity, and failed reservation before publication.
const std = @import("std");
const Stream = @import("stream.zig").Stream;
const a = std.testing.allocator;
const close = [_]u32{ 90, 91, 92 };

test "history is not indexed or rewritten and healthy output is unchanged" {
    var prompt: [3200]u32 = undefined;
    for (&prompt, 0..) |*t, i| t.* = @intCast(1000 + i % 300);
    var tokens: [3000]u32 = undefined;
    for (&tokens, 0..) |*t, i| t.* = @intCast(10000 + i);
    var s = try Stream.init(a, .{ .id = "history retained", .prompt = &prompt, .max_new = 5000, .think_close = &close, .think_end = 91, .loop_guard = true });
    defer s.deinit(a);
    try std.testing.expectEqual(@as(usize, tokens.len), try s.commit(a, &tokens));
    try std.testing.expectEqualSlices(u32, &prompt, s.prompt());
    try std.testing.expectEqualSlices(u32, &tokens, s.emitted());
    try std.testing.expect(s.loop_period == null and s.force.items.len == 0 and s.think_open);
}

test "disabled guard does not allocate an index or change output" {
    var s = try Stream.init(a, .{ .id = "disabled", .prompt = &.{1}, .max_new = 3000, .think_close = &close, .think_end = 91, .loop_guard = false });
    defer s.deinit(a);
    const tokens: [2048]u32 = @splat(7);
    try s.context.ensureUnusedCapacity(a, tokens.len);
    var fail = std.testing.FailingAllocator.init(a, .{ .fail_index = 0, .resize_fail_index = 0 });
    try std.testing.expectEqual(tokens.len, try s.commit(fail.allocator(), &tokens));
    try std.testing.expect(!fail.has_induced_failure and s.long_loop.upto == 0 and s.long_loop.prev.capacity == 0);
    try std.testing.expect(s.loop_period == null);
    try std.testing.expectEqualSlices(u32, &tokens, s.emitted());
}

fn failedReservation(map: bool) !void {
    var s = try Stream.init(a, .{ .id = "reserve", .prompt = &.{ 1, 2 }, .max_new = 200, .think_close = &close, .think_end = 91, .loop_guard = true });
    defer s.deinit(a);
    const tokens: [33]u32 = @splat(7);
    try s.context.ensureUnusedCapacity(a, tokens.len);
    try s.force.append(a, 9);
    try s.force.ensureTotalCapacity(a, close.len);
    if (map) try s.long_loop.prev.ensureTotalCapacity(a, tokens.len);
    var fail = std.testing.FailingAllocator.init(a, .{ .fail_index = 0, .resize_fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, s.commit(fail.allocator(), &tokens));
    try std.testing.expect(fail.has_induced_failure);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, s.context.items);
    try std.testing.expectEqualSlices(u32, &.{9}, s.force.items);
    try std.testing.expect(s.think_open and !s.finished and s.loop_period == null);
    try std.testing.expect(s.long_loop.upto == 0 and s.long_loop.prev.items.len == 0 and s.long_loop.last.count() == 0);
    try std.testing.expectEqual(tokens.len, try s.commit(a, &tokens));
    try std.testing.expectEqualSlices(u32, &tokens, s.emitted());
}

test "index vector failure preserves stream state and retry" {
    try failedReservation(false);
}
test "index map failure preserves stream state and retry" {
    try failedReservation(true);
}

test "empty and finished commits allocate no detector storage" {
    var s = try Stream.init(a, .{ .id = "no-op", .prompt = &.{1}, .max_new = 10, .think_close = &close, .think_end = 91, .loop_guard = true });
    defer s.deinit(a);
    var fail = std.testing.FailingAllocator.init(a, .{ .fail_index = 0, .resize_fail_index = 0 });
    try std.testing.expectEqual(@as(usize, 0), try s.commit(fail.allocator(), &.{}));
    s.finished = true;
    try std.testing.expectEqual(@as(usize, 0), try s.commit(fail.allocator(), &.{7}));
    try std.testing.expect(!fail.has_induced_failure and s.long_loop.upto == 0);
}

test "answer after the think closer is not watched by the guard" {
    var s = try Stream.init(a, .{ .id = "answer", .prompt = &.{1}, .max_new = 5000, .think_close = &close, .think_end = 91, .loop_guard = true });
    defer s.deinit(a);
    try std.testing.expectEqual(@as(usize, 4), try s.commit(a, &.{ 2, 3, 4, 91 }));
    const answer: [2000]u32 = @splat(7);
    try std.testing.expectEqual(answer.len, try s.commit(a, &answer));
    try std.testing.expect(s.loop_period == null and s.long_loop.upto == 3 and !s.think_open);
}
