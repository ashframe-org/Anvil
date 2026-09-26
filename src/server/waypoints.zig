const std = @import("std");

const main = @import("main");
const User = main.server.User;

// --- ASHFRAME CUSTOM (Waypoints) ---
// Player-owned pairs of waypoint blocks. Place one, place another to link.
// Standing on either anchor teleports to its counterpart (anyone may ride).
// Breaking an anchor drops it and unlinks the pair. One pair per player.

const Pair = struct {
	owner: usize,
	ownerName: []const u8,
	a: [3]i32,
	b: [3]i32,
};

var pairs: main.ListManaged(Pair) = undefined;
var ready: bool = false;
var lastSave: std.Io.Timestamp = .{.nanoseconds = 0};

pub const teleportCooldownSeconds: i64 = 3;

/// Minimum seconds between "teleport ready in Ns" notices while standing on
/// an anchor during its cooldown. Longer than the cooldown itself, so a
/// normal stand shows exactly one notice and hop-spam is bounded.
pub const noticeThrottleSeconds: i64 = 5;

fn ensure() void {
	if (!ready) {
		pairs = main.ListManaged(Pair).init(main.globalAllocator);
		ready = true;
	}
}

fn eqPos(p: [3]i32, x: i32, y: i32, z: i32) bool {
	return p[0] == x and p[1] == y and p[2] == z;
}

pub fn hasPair(owner: usize) bool {
	ensure();
	for (pairs.items) |*p| {
		if (p.owner == owner) return true;
	}
	return false;
}

/// Both anchors of the player's pair, if they have one. Index 0 is the first
/// block placed (A), index 1 the second (B).
pub fn pairFor(owner: usize) ?[2][3]i32 {
	ensure();
	for (pairs.items) |*p| {
		if (p.owner == owner) return .{p.a, p.b};
	}
	return null;
}

/// The linked counterpart of an anchor at (x,y,z), if any.
pub fn counterpart(x: i32, y: i32, z: i32) ?[3]i32 {
	ensure();
	for (pairs.items) |*p| {
		if (eqPos(p.a, x, y, z)) return p.b;
		if (eqPos(p.b, x, y, z)) return p.a;
	}
	return null;
}

/// Owner of the pair containing this anchor, if any.
pub fn ownerAt(x: i32, y: i32, z: i32) ?usize {
	ensure();
	for (pairs.items) |*p| {
		if (eqPos(p.a, x, y, z) or eqPos(p.b, x, y, z)) return p.owner;
	}
	return null;
}

fn nowSeconds() i64 {
	return @intCast(@divTrunc(main.timestamp().toNanoseconds(), 1000000000));
}

/// Called when a player places a waypoint block. Returns a message to show.
pub fn onPlace(user: *User, x: i32, y: i32, z: i32) void {
	ensure();
	const prof = user.player();
	if (hasPair(user.playerIndex)) {
		user.sendMessage("#e6312cYou already have a waypoint pair. #8a8a8a(Break one to relink.)", .{});
		return;
	}
	if (prof.waypointPending) |pending| {
		pairs.append(.{
			.owner = user.playerIndex,
			.ownerName = main.globalAllocator.dupe(u8, user.name),
			.a = .{ @intFromFloat(pending[0]), @intFromFloat(pending[1]), @intFromFloat(pending[2]) },
			.b = .{ x, y, z },
		});
		prof.waypointPending = null;
		user.sendMessage("#00ff00Waypoints linked! #cfcfcfStand on either to teleport to the other.", .{});
	} else {
		prof.waypointPending = .{ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) };
		user.sendMessage("#00ff00Waypoint 1 placed. #cfcfcfPlace another to link them.", .{});
	}
}

/// Whether this player may break the waypoint anchor at (x,y,z).
pub fn canBreak(user: *User, x: i32, y: i32, z: i32) bool {
	ensure();
	const owner = ownerAt(x, y, z) orelse return true; // not part of a pair: allow
	if (owner != user.playerIndex and !user.isLocal and !main.server.claims.isAdmin(user)) {
		user.sendMessage("#e6312cYou can't break someone else's waypoint.", .{});
		return false;
	}
	return true;
}

fn pendingMatches(prof: *const main.server.Entity, x: i32, y: i32, z: i32) bool {
	const p = prof.waypointPending orelse return false;
	return p[0] == @as(f64, @floatFromInt(x)) and p[1] == @as(f64, @floatFromInt(y)) and p[2] == @as(f64, @floatFromInt(z));
}

/// Cleanup after an allowed break (the block already dropped itself).
/// If a linked anchor was broken, the surviving anchor is remembered as its
/// owner's pending anchor so re-placing the broken one relinks to it.
pub fn onBreak(user: *User, x: i32, y: i32, z: i32) void {
	ensure();
	// Find the pair containing this anchor.
	var found: ?usize = null;
	for (pairs.items, 0..) |*p, i| {
		if (eqPos(p.a, x, y, z) or eqPos(p.b, x, y, z)) {
			found = i;
			break;
		}
	}
	if (found) |i| {
		const p = &pairs.items[i];
		const owner = p.owner;
		const survivor: [3]i32 = if (eqPos(p.a, x, y, z)) p.b else p.a;
		main.globalAllocator.free(p.ownerName);
		_ = pairs.orderedRemove(i);

		if (main.server.getUserByIndex(owner)) |ownerUser| {
			ownerUser.player().waypointPending = .{
				@floatFromInt(survivor[0]),
				@floatFromInt(survivor[1]),
				@floatFromInt(survivor[2]),
			};
		}
		user.sendMessage("#cfcfcfWaypoint Unlinked. #8a8a8a(Place it again to relink.)", .{});
		if (owner != user.playerIndex) {
			if (main.server.getUserByIndex(owner)) |ownerUser| {
				ownerUser.sendMessage("#e6312cYour waypoint was unlinked.", .{});
			}
		}
		return;
	}
	// Not part of a pair: clear any player whose pending anchor this was
	// (covers a lone first waypoint, or a survivor anchor someone else broke).
	const users = main.server.getUserList(main.stackAllocator);
	defer main.stackAllocator.free(users);
	for (users) |other| {
		if (!pendingMatches(other.player(), x, y, z)) continue;
		other.player().waypointPending = null;
		if (other == user) {
			user.sendMessage("#cfcfcfWaypoint removed.", .{});
		} else {
			other.sendMessage("#e6312cYour pending waypoint was removed.", .{});
		}
	}
}

/// World-tick check: teleport a player standing on an anchor.
pub fn check(user: *User) void {
	ensure();
	if (pairs.items.len == 0) return;
	const prof = user.player();
	// Axis order: (x, z, vertical) — the vertical is the THIRD component.
	const hx = main.server.anticheat.toI32(prof.pos[0]) orelse return;
	const hz = main.server.anticheat.toI32(prof.pos[1]) orelse return;
	const below = main.server.anticheat.toI32(prof.pos[2]) orelse return;
	const waypointTyp = main.blocks.getTypeById("ashframe:waypoint");
	if (waypointTyp == 0) return;
	const world = main.server.world orelse return;
	// The anchor may sit at feet-1 or (rarely) at feet depending on rounding.
	var found: ?[3]i32 = null;
	var level: i32 = below;
	while (level >= below - 2) : (level -= 1) {
		const b = world.getBlock(hx, hz, level) orelse continue;
		if (b.typ == waypointTyp) {
			found = counterpart(hx, hz, level);
			if (found != null) break;
		}
	}
	const dest = found orelse return;
	const now = nowSeconds();
	if (now < prof.waypointCooldownUntil) {
		// Throttled notice: at most one message per stand window, so jumping
		// on the anchor (off-and-on every hop) can't spam chat.
		if (now - prof.anchorCooldownNotifiedAt >= noticeThrottleSeconds) {
			prof.anchorCooldownNotifiedAt = now;
			const remaining = prof.waypointCooldownUntil - now + 1;
			user.sendMessage("#8a8a8aWaypoint teleport ready in #cfcfcf{d}s#8a8a8a.", .{remaining});
		}
		return;
	}
	prof.waypointCooldownUntil = nowSeconds() + teleportCooldownSeconds;
	prof.back_pos = prof.pos;
	prof.pos = .{
		@as(f64, @floatFromInt(dest[0])) + 0.5,
		@as(f64, @floatFromInt(dest[1])) + 0.5,
		@as(f64, @floatFromInt(dest[2])) + 1.0,
	};
	main.server.anticheat.expectTeleport(user);
	main.network.protocols.genericUpdate.sendTPCoordinates(user.conn, prof.pos);
	poof(.{ hx, hz, level });
	user.sendMessage("#cfcfcfWaypoint teleport.", .{});
}

/// Spawns a poof on top of the anchor, so the teleport has a visible effect.
fn poof(at: [3]i32) void {
	if (main.server.world == null) return;
	const userList = main.server.getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);
	for (userList) |user| {
		main.network.protocols.genericUpdate.sendParticles(
			user.conn,
			"cubyz:poof",
			.{ @as(f64, @floatFromInt(at[0])) + 0.5, @as(f64, @floatFromInt(at[1])) + 0.5, @as(f64, @floatFromInt(at[2])) + 1.0 },
			true,
			8,
			"",
		);
	}
}

fn filePath(allocator: main.heap.NeverFailingAllocator, worldPath: []const u8) []const u8 {
	return allocator.print("saves/{s}/ashframe_waypoints.zig.zon", .{worldPath});
}

pub fn load(worldPath: []const u8) void {
	ensure();
	for (pairs.items) |*p| main.globalAllocator.free(p.ownerName);
	pairs.clearRetainingCapacity();
	const path = filePath(main.stackAllocator, worldPath);
	defer main.stackAllocator.free(path);
	const zon = main.files.cubyzDir().readToZon(main.stackAllocator, path) catch return;
	defer zon.deinit(main.stackAllocator);
	for (zon.getChild("pairs").toSlice()) |entry| {
		const a = entry.getChild("a").toSlice();
		const b = entry.getChild("b").toSlice();
		if (a.len != 3 or b.len != 3) continue;
		const name = entry.get([]const u8, "ownerName") orelse "";
		pairs.append(.{
			.owner = entry.get(usize, "owner") orelse continue,
			.ownerName = main.globalAllocator.dupe(u8, name),
			.a = .{ a[0].as(i32) orelse continue, a[1].as(i32) orelse continue, a[2].as(i32) orelse continue },
			.b = .{ b[0].as(i32) orelse continue, b[1].as(i32) orelse continue, b[2].as(i32) orelse continue },
		});
	}
}

pub fn save(worldPath: []const u8) void {
	ensure();
	const path = filePath(main.stackAllocator, worldPath);
	defer main.stackAllocator.free(path);
	var zon = main.ZonElement.initObject(main.stackAllocator);
	defer zon.deinit(main.stackAllocator);
	var arr = main.ZonElement.initArray(main.stackAllocator);
	for (pairs.items) |*p| {
		var e = main.ZonElement.initObject(main.stackAllocator);
		e.put("owner", p.owner);
		e.put("ownerName", p.ownerName);
		var aa = main.ZonElement.initArray(main.stackAllocator);
		for (p.a) |v| aa.array.append(.{.int = v});
		e.put("a", aa);
		var bb = main.ZonElement.initArray(main.stackAllocator);
		for (p.b) |v| bb.array.append(.{.int = v});
		e.put("b", bb);
		arr.array.append(e);
	}
	zon.put("pairs", arr);
	main.files.cubyzDir().writeZon(path, zon) catch |err| {
		std.log.err("Could not save Ashframe waypoints: {s}", .{@errorName(err)});
	};
}

pub fn autosave(worldPath: []const u8) void {
	const now = main.timestamp();
	if (lastSave.durationTo(now).toSeconds() > 60) {
		lastSave = now;
		save(worldPath);
	}
}
// --- ASHFRAME CUSTOM (Waypoints) ---
