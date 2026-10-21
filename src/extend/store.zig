//! 物品堆叠与固定槽位仓库，增减和回滚逻辑独立于界面。
const std = @import("std");

pub fn StackT(T: type) type {
    return struct {
        item: T,
        count: u32,

        pub const empty: @This() = .{ .item = undefined, .count = 0 };
        pub fn one(item: T) @This() {
            return .{ .item = item, .count = 1 };
        }
    };
}

pub fn StackStore(T: type, len: usize, limitOf: fn (T) u32) type {
    return struct {
        pub const Stack = StackT(T);
        pub const Put = struct {
            subs: []const Stack = &.{},
            adds: []const Stack = &.{},
        };
        pub const Entry = struct {
            index: usize,
            item: T,
            count: u32,

            pub fn init(index: usize, item: T, count: u32) Entry {
                return .{ .index = index, .item = item, .count = count };
            }
        };
        pub const Patch = union(enum) { add: Entry, sub: Entry };
        pub const Move = enum { merge, clear, swap };
        pub const Done = struct { ok: bool, patches: []const Patch };
        const Try = struct {
            buffer: ?*std.ArrayList(Patch) = null,
            items: []const Stack,
        };

        stacks: [len]Stack = @splat(.empty),

        pub fn add(self: *@This(), item: T, count: u32) u32 {
            const args: Stack = .{ .item = item, .count = count };
            return self.tryAdd(.{ .items = &.{args} }) catch unreachable;
        }

        pub fn sub(self: *@This(), item: T, count: u32) u32 {
            const args: Stack = .{ .item = item, .count = count };
            return self.trySub(.{ .items = &.{args} }) catch unreachable;
        }

        pub fn addAll(self: *@This(), item: T, count: u32) bool {
            var patches: [len + 1]Patch = undefined;

            const args: Stack = .{ .item = item, .count = count };
            const done = self.put(&patches, .{ .adds = &.{args} });
            if (done.ok) return true;

            self.rollback(done.patches);
            return false;
        }

        pub fn subAll(self: *@This(), item: T, count: u32) bool {
            var patches: [len + 1]Patch = undefined;

            const args: Stack = .{ .item = item, .count = count };
            const done = self.put(&patches, .{ .subs = &.{args} });
            if (done.ok) return true;

            self.rollback(done.patches);
            return false;
        }

        pub fn get(self: *@This(), index: usize) ?Stack {
            return if (self.getPtr(index)) |ptr| ptr.* else null;
        }

        pub fn getPtr(self: *@This(), index: usize) ?*Stack {
            if (self.stacks[index].count == 0) return null;
            return &self.stacks[index];
        }

        pub fn first(self: *const @This(), item: T) ?usize {
            for (&self.stacks, 0..) |*stack, index| {
                if (stack.count == 0) continue;
                if (std.meta.eql(stack.item, item)) return index;
            }
            return null;
        }

        pub fn firstEmpty(self: *const @This()) ?usize {
            for (self.stacks, 0..) |*stack, index| {
                if (stack.count == 0) return index;
            }
            return null;
        }

        pub fn clearAt(self: *@This(), index: usize) void {
            self.stacks[index].count = 0;
        }

        pub fn clear(self: *@This()) void {
            for (&self.stacks) |*stack| stack.count = 0;
        }

        pub fn move(self: *@This(), from: usize, to: usize) ?Move {
            if (from == to) return null;

            const source = &self.stacks[from];
            const target = &self.stacks[to];
            if (source.count == 0) return null;
            const empty = target.count == 0;
            if (empty or !std.meta.eql(source.item, target.item)) {
                std.mem.swap(Stack, source, target);
                return .swap;
            }

            const limit = limitOf(source.item);
            std.debug.assert(limit > 0);
            if (target.count >= limit) return null;

            const moved = @min(limit - target.count, source.count);
            target.count += moved;
            source.count -= moved;
            return if (source.count > 0) .merge else .clear;
        }

        pub fn tryPut(self: *@This(), buf: []Patch, ops: Put) !Done {
            var buffer = std.ArrayList(Patch).initBuffer(buf);
            errdefer self.rollback(buffer.items);

            var args: Try = .{ .buffer = &buffer, .items = ops.subs };
            const subLeft = try self.trySub(args);
            args = .{ .buffer = &buffer, .items = ops.adds };
            const addLeft = try self.tryAdd(args);
            const ok = subLeft == 0 and addLeft == 0;
            return .{ .ok = ok, .patches = buffer.items };
        }

        pub fn put(self: *@This(), buf: []Patch, ops: Put) Done {
            return self.tryPut(buf, ops) catch @panic("buffer too small");
        }

        pub fn rollback(self: *@This(), patches: []const Patch) void {
            var iterator = std.mem.reverseIterator(patches);
            while (iterator.next()) |patch| {
                switch (patch) {
                    .add => |entry| self.putOne(.{ .sub = entry }),
                    .sub => |entry| self.putOne(.{ .add = entry }),
                }
            }
        }

        fn addOne(self: *@This(), args: Stack) ?Entry {
            const limit = limitOf(args.item);
            std.debug.assert(limit > 0);

            if (limit > 1) if (self.merge(args, limit)) |e| return e;
            return self.fill(args, limit);
        }

        fn trySub(self: *@This(), args: Try) !u32 {
            var left: u32 = 0;
            for (args.items) |entry| {
                if (entry.count == 0) continue;

                var remaining = entry.count;
                for (&self.stacks, 0..) |*stack, index| {
                    if (remaining == 0) break;
                    if (stack.count == 0) continue;
                    if (!std.meta.eql(stack.item, entry.item)) continue;

                    const count = @min(stack.count, remaining);
                    const patch = Entry.init(index, stack.item, count);
                    stack.count -= count;
                    errdefer stack.count += count;
                    if (args.buffer) |buffer|
                        try buffer.appendBounded(.{ .sub = patch });
                    remaining -= count;
                }
                left += remaining;
            }
            return left;
        }

        fn tryAdd(self: *@This(), args: Try) !u32 {
            var left: u32 = 0;
            for (args.items) |entry| {
                var remaining = entry;
                while (remaining.count > 0) {
                    const one = self.addOne(remaining) orelse break;
                    errdefer self.putOne(.{ .sub = one });
                    if (args.buffer) |buffer|
                        try buffer.appendBounded(.{ .add = one });
                    remaining.count -= one.count;
                }
                left += remaining.count;
            }
            return left;
        }

        pub fn subAt(self: *@This(), index: usize, count: u32) ?Entry {
            std.debug.assert(count > 0);
            const stack = self.getPtr(index) orelse return null;
            if (stack.count < count) return null;

            const entry = Entry.init(index, stack.item, count);
            stack.count -= count;
            return entry;
        }

        pub fn useAt(self: *@This(), index: usize, count: Stack) bool {
            var patches: [len + 1]Patch = undefined;
            var buffer = std.ArrayList(Patch).initBuffer(&patches);

            const taken = self.subAt(index, 1) orelse return false;
            buffer.appendAssumeCapacity(.{ .sub = taken });
            const args: Try = .{ .buffer = &buffer, .items = &.{count} };
            const left = self.tryAdd(args) catch @panic("buffer too small");
            if (left == 0) return true;

            self.rollback(buffer.items);
            return false;
        }

        fn merge(self: *@This(), args: Stack, limit: u32) ?Entry {
            for (0..self.stacks.len) |index| {
                const stack = self.getPtr(index) orelse continue;
                if (!std.meta.eql(stack.item, args.item)) continue;
                if (stack.count >= limit) continue;

                const moved = @min(limit - stack.count, args.count);
                stack.count += moved;
                return .init(index, args.item, moved);
            }
            return null;
        }

        fn fill(self: *@This(), args: Stack, limit: u32) ?Entry {
            for (&self.stacks, 0..) |*stack, index| {
                if (stack.count != 0) continue;

                const moved = @min(limit, args.count);
                stack.* = .{ .item = args.item, .count = moved };
                return .init(index, args.item, moved);
            }
            return null;
        }

        fn putOne(self: *@This(), patch: Patch) void {
            switch (patch) {
                .add => |entry| {
                    const stack = &self.stacks[entry.index];
                    if (stack.count == 0) stack.item = entry.item;
                    std.debug.assert(std.meta.eql(entry.item, stack.item));
                    stack.count += entry.count;
                },
                .sub => |entry| {
                    const taken = self.subAt(entry.index, entry.count).?;
                    std.debug.assert(std.meta.eql(entry.item, taken.item));
                },
            }
        }
    };
}
