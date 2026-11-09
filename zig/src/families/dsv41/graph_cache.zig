//! A map with a cap on its entries: past the cap, a put hands back the least recently used entry for its owner to
//! free (round.Graphs: the captured stretches, each an instantiated CUDA graph on the device and the host).

const std = @import("std");

pub fn Lru(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const Slot = struct { v: V, used: u64 };

        map: std.AutoHashMapUnmanaged(K, Slot) = .empty,
        cap: usize, // the entries kept at most (0: no cap)
        tick: u64 = 0,
        evicted: u64 = 0, // the entries put has handed back so far

        pub fn init(cap: usize) Self {
            return .{ .cap = cap };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.map.deinit(gpa);
            self.* = undefined;
        }

        pub fn count(self: *const Self) usize {
            return self.map.count();
        }

        /// The entry of `k`, now the most recently used.
        pub fn get(self: *Self, k: K) ?*V {
            const s = self.map.getPtr(k) orelse return null;
            self.tick += 1;
            s.used = self.tick;
            return &s.v;
        }

        /// Keeps `v` under `k` (not in the map yet); at the cap first takes out the least recently used entry and
        /// returns its value, which the caller frees. A put that fails keeps every entry.
        pub fn put(self: *Self, gpa: std.mem.Allocator, k: K, v: V) !?V {
            try self.map.ensureUnusedCapacity(gpa, 1);
            var out: ?V = null;
            if (self.cap != 0 and self.map.count() >= self.cap) {
                // a scan, on a miss only (each costs a capture anyway): the cap keeps it short
                var it = self.map.iterator();
                var lru = it.next().?;
                while (it.next()) |en| if (en.value_ptr.used < lru.value_ptr.used) {
                    lru = en;
                };
                out = lru.value_ptr.v;
                self.map.removeByPtr(lru.key_ptr);
                self.evicted += 1;
            }
            self.tick += 1;
            self.map.putAssumeCapacityNoClobber(k, .{ .v = v, .used = self.tick });
            return out;
        }

        /// Every value kept, for the owner to free before deinit.
        pub fn valueIterator(self: *const Self) ValueIterator {
            return .{ .it = self.map.valueIterator() };
        }

        pub const ValueIterator = struct {
            it: std.AutoHashMapUnmanaged(K, Slot).ValueIterator,
            pub fn next(i: *ValueIterator) ?*V {
                const s = i.it.next() orelse return null;
                return &s.v;
            }
        };
    };
}
