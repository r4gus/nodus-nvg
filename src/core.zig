const std = @import("std");
const uuid = @import("uuid-zig");
const Allocator = std.mem.Allocator;

const Uuid = uuid.Uuid;

pub const State = enum {
    Ndef,
    Low,
    High,
};

pub const Target = struct {
    id: Uuid,
    index: usize,
};

pub const Source = Target;
pub const Sources = []?Source;
pub const Targets = []?[]Target;

pub const Tag = enum {
    And,
    Or,
    Not,

    pub fn defaultInput(tag: @This()) usize {
        return switch (tag) {
            .And => 2,
            .Or => 2,
            .Not => 1,
        };
    }

    pub fn defaultOutput(tag: @This()) usize {
        return switch (tag) {
            else => 1,
        };
    }
};

pub const Component = struct {
    id: Uuid,
    tag: Tag,

    in: []State,
    out: []State,
    source: Sources,
    target: Targets,

    allocator: Allocator,

    pub fn default(allocator: Allocator, tag: Tag) !@This() {
        var comp = @This(){
            .id = uuid.v7.new(),
            .tag = tag,
            .in = try allocator.alloc(State, Tag.defaultInput(tag)),
            .out = try allocator.alloc(State, Tag.defaultOutput(tag)),
            .source = try allocator.alloc(?Source, Tag.defaultInput(tag)),
            .target = try allocator.alloc(?[]Target, Tag.defaultOutput(tag)),
            .allocator = allocator,
        };

        for (comp.source) |*s| {
            s.* = null;
        }

        for (comp.target) |*t| {
            t.* = null;
        }

        std.mem.set(State, comp.in[0..], State.Ndef);
        std.mem.set(State, comp.out[0..], State.Ndef);

        return comp;
    }

    /// Allocate a new Component on the heap
    ///
    /// The caller is reponsible for destroying this object
    /// by calling the `destroy` function on it.
    pub fn new(allocator: Allocator, tag: Tag, in: usize, out: usize) !*@This() {
        var comp = try allocator.create(@This());

        comp.id = uuid.v7.new();
        comp.tag = tag;
        comp.in = try allocator.alloc(State, in);
        comp.out = try allocator.alloc(State, out);
        comp.source = try allocator.alloc(?Source, in);
        comp.target = try allocator.alloc(?[]Target, out);
        comp.allocator = allocator;

        for (comp.source) |*s| {
            s.* = null;
        }

        for (comp.target) |*t| {
            t.* = null;
        }

        std.mem.set(State, comp.in[0..], State.Ndef);
        std.mem.set(State, comp.out[0..], State.Ndef);

        return comp;
    }

    /// Deinitialize the given Component
    pub fn deinit(self: *@This()) void {
        self.*.allocator.free(self.*.in);
        self.*.allocator.free(self.*.out);
        self.*.allocator.free(self.*.source);

        for (self.*.target) |t| {
            if (t != null) {
                self.*.allocator.free(t.?);
            }
        }
        self.*.allocator.free(self.*.target);
    }

    /// Deinitialize the given component and destroy it
    ///
    /// WARNING: Call only if the object is allocated on the heap
    pub fn destroy(self: *@This()) void {
        deinit(self);
        self.allocator.destroy(self);
    }

    pub fn getIn(self: *@This(), i: usize) ?State {
        return if (i >= self.*.in.len) null else self.*.in[i];
    }

    pub fn setIn(self: *@This(), i: usize, v: State) void {
        if (i < self.*.in.len) {
            self.*.in[i] = v;
        }
    }

    pub fn getOut(self: *@This(), i: usize) ?State {
        return if (i >= self.*.out.len) null else self.*.out[i];
    }

    pub fn setOut(self: *@This(), i: usize, v: State) void {
        if (i < self.*.out.len) {
            self.*.out[i] = v;
        }
    }
};

pub const Authority = struct {
    components: std.AutoHashMap(Uuid, *Component),
    allocator: Allocator,

    pub fn init(alloc: Allocator) @This() {
        return .{
            .components = std.AutoHashMap(Uuid, *Component).init(alloc),
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *@This()) void {
        // Destroy all components
        var iterator = self.components.iterator();
        while (iterator.next()) |e| {
            e.value_ptr.*.destroy();
        }
        // Deinit the ArrayList
        self.components.deinit();
    }

    pub fn new(self: *@This(), tag: Tag, in: usize, out: usize) !Uuid {
        const comp = try Component.new(self.allocator, tag, in, out);
        try self.components.put(comp.id, comp);
        return comp.id;
    }

    pub fn connect(self: *@This(), src: Uuid, srcidx: usize, dst: Uuid, dstidx: usize) !void {
        var s = self.components.get(src);
        var d = self.components.get(dst);

        // Do they exist?
        if (s == null or d == null) {
            return error.NonexistentComponent;
        }

        // Sanity checks for destination component
        if (d.?.source.len <= dstidx) {
            return error.InvalidConnectorIndex;
        } else if (d.?.source[dstidx] != null) {
            return error.ConnectorOccupied;
        }

        // Sanity checks for source component
        if (s.?.target.len <= srcidx) {
            return error.InvalidConnectorIndex;
        } else if (s.?.target[srcidx] != null) {
            for (s.?.target[srcidx].?) |t| {
                if (t.id == dst and t.index == dstidx) {
                    return error.AlreadyConnected;
                }
            }
        }

        // Make target input point back to source output
        d.?.source[dstidx] = Target{
            .id = src,
            .index = srcidx,
        };

        // Make source output point to target input
        if (s.?.target[srcidx] == null) {
            s.?.target[srcidx] = try self.allocator.alloc(Target, 1);
            s.?.target[srcidx].?[0] = Target{
                .id = dst,
                .index = dstidx,
            };
        } else {
            const l = s.?.target[srcidx].?.len;
            var tmp = try self.allocator.alloc(Target, l + 1);

            var i: usize = 0;
            while (i < l) : (i += 1) {
                tmp[i] = s.?.target[srcidx].?[i];
            }
            tmp[i] = Target{
                .id = dst,
                .index = dstidx,
            };

            self.allocator.free(s.?.target[srcidx].?);
            s.?.target[srcidx] = tmp;
        }
    }
};

test "set input and output" {
    const allocator = std.testing.allocator;

    var comp = try Component.default(allocator, Tag.And);
    defer comp.deinit();

    // Check default values
    try std.testing.expectEqual(State.Ndef, comp.getIn(0).?);
    try std.testing.expectEqual(State.Ndef, comp.getIn(1).?);
    try std.testing.expectEqual(null, comp.getIn(2));

    try std.testing.expectEqual(State.Ndef, comp.getOut(0).?);
    try std.testing.expectEqual(null, comp.getOut(1));

    // Set new states
    comp.setIn(0, State.High);
    comp.setIn(1, State.Low);
    comp.setOut(0, State.Low);

    // Check new states
    try std.testing.expectEqual(State.High, comp.getIn(0).?);
    try std.testing.expectEqual(State.Low, comp.getIn(1).?);
    try std.testing.expectEqual(State.Low, comp.getOut(0).?);
}

test "set input and output 2" {
    const allocator = std.testing.allocator;

    var comp = try Component.new(allocator, Tag.And, 2, 1);
    defer comp.destroy();

    // Check default values
    try std.testing.expectEqual(State.Ndef, comp.getIn(0).?);
    try std.testing.expectEqual(State.Ndef, comp.getIn(1).?);
    try std.testing.expectEqual(null, comp.getIn(2));

    try std.testing.expectEqual(State.Ndef, comp.getOut(0).?);
    try std.testing.expectEqual(null, comp.getOut(1));

    // Set new states
    comp.setIn(0, State.High);
    comp.setIn(1, State.Low);
    comp.setOut(0, State.Low);

    // Check new states
    try std.testing.expectEqual(State.High, comp.getIn(0).?);
    try std.testing.expectEqual(State.Low, comp.getIn(1).?);
    try std.testing.expectEqual(State.Low, comp.getOut(0).?);
}

test "Add Components to Authority" {
    const allocator = std.testing.allocator;

    var auth = Authority.init(allocator);
    defer auth.deinit();

    _ = try auth.new(Tag.And, 2, 1);
    _ = try auth.new(Tag.Or, 2, 1);
    _ = try auth.new(Tag.Not, 1, 1);
}

test "Connect two components" {
    const allocator = std.testing.allocator;

    var auth = Authority.init(allocator);
    defer auth.deinit();

    var c1 = try auth.new(Tag.And, 2, 1);
    var c2 = try auth.new(Tag.Or, 2, 1);

    try auth.connect(c1, 0, c2, 0);
}
