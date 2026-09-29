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

/// Anti-troll: seconds a player must stand continuously on the same anchor
/// before it fires. Kills under-foot ambushes (waypoint placed beneath you)
/// and spawn-arrival instant-fire (landing on a hostile anchor tps you again
/// before you can react). A clean deliberate stand still works.
pub const standDelaySeconds: i64 = 1;

/// Destination neighborhood load timeout: seconds of waiting before the
/// "taking a while" notice (the wait then continues in a fresh window).
/// Far chunk generation normally takes well under a second; this only fires
/// when the chunk threads are starved or the distance is extreme.
pub const destLoadTimeoutSeconds: i64 = 10;

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

/// Landing candidate offsets around a destination anchor, nearest first, in
/// file axis order (x, z-horizontal, y-vertical). Directly above first (keeps
/// the old behavior when open), then middle sides, upper sides, top, and
/// upper-upper sides — so anchors buried under cover, in hillsides, or sunk
/// with only the top showing still find whatever is actually available.
/// Unloaded cells report .notLoaded (wait), never assumed free or blocked.
fn landingCandidateOffsets() [14][3]i32 {
	return .{
		.{ 0, 0, 1 },
		.{ 1, 0, 0 },
		.{ -1, 0, 0 },
		.{ 0, 1, 0 },
		.{ 0, -1, 0 },
		.{ 1, 0, 1 },
		.{ -1, 0, 1 },
		.{ 0, 1, 1 },
		.{ 0, -1, 1 },
		.{ 0, 0, 2 },
		.{ 1, 0, 2 },
		.{ -1, 0, 2 },
		.{ 0, 1, 2 },
		.{ 0, -1, 2 },
	};
}

/// Releases held destination-chunk refs, if any. Call whenever the wait ends
/// (stand broken, destination changed, teleport fired, missing/blocked).
fn releaseHeldChunks(prof: *main.server.Entity) void {
	for (prof.anchorLoadChunks[0..prof.anchorLoadCount]) |slot| {
		if (slot) |held| held.decreaseRefCount();
	}
	prof.anchorLoadChunks = .{null} ** 8;
	prof.anchorLoadCount = 0;
}

/// Distinct 32-chunk origins covering every cell the landing search touches:
/// feet cells at dest±1 horizontally and dest+0..+2 vertically, plus head
/// cells one higher. At most 2 origins per axis, so at most 8 total. Pure
/// function (unit-tested); mirrors world.getBlock's chunk masking.
fn destHoldOrigins(dest: [3]i32) struct { origins: [8][3]i32, count: usize } {
	var out: [8][3]i32 = undefined;
	var count: usize = 0;
	const mask: i32 = main.chunk.chunkMask;
	const x0 = (dest[0] - 1) & ~mask;
	const x1 = (dest[0] + 1) & ~mask;
	const y0 = (dest[1] - 1) & ~mask;
	const y1 = (dest[1] + 1) & ~mask;
	const z0 = dest[2] & ~mask;
	const z1 = (dest[2] + 3) & ~mask;
	var xi: usize = 0;
	while (xi < 2) : (xi += 1) {
		const ox = if (xi == 0) x0 else x1;
		var yi: usize = 0;
		while (yi < 2) : (yi += 1) {
			const oy = if (yi == 0) y0 else y1;
			var zi: usize = 0;
			while (zi < 2) : (zi += 1) {
				const oz = if (zi == 0) z0 else z1;
				var dup = false;
				for (out[0..count]) |o| {
					if (o[0] == ox and o[1] == oy and o[2] == oz) {
						dup = true;
						break;
					}
				}
				if (!dup) {
					out[count] = .{ ox, oy, oz };
					count += 1;
				}
			}
		}
	}
	return .{ .origins = out, .count = count };
}

/// Ensures the destination neighborhood is loading (or loaded), holding one
/// ref per touched chunk so the background load tasks aren't culled while the
/// player stands waiting. Cheap after the first call per destination; must be
/// paired with releaseHeldChunks. Holding just the anchor chunk is not
/// enough: the landing search reads neighbor chunks, which are usually
/// unloaded for far pairs.
fn ensureDestChunksLoading(prof: *main.server.Entity, dest: [3]i32) void {
	if (prof.anchorLoadCount > 0) {
		const lp = prof.anchorLoadPos;
		if (lp[0] == dest[0] and lp[1] == dest[1] and lp[2] == dest[2]) return;
		releaseHeldChunks(prof);
	}
	const held = destHoldOrigins(dest);
	for (held.origins[0..held.count], 0..) |o, i| {
		prof.anchorLoadChunks[i] = main.server.world_zig.ChunkManager.getOrGenerateSimulationChunkAndIncreaseRefCount(.{
			.wx = o[0],
			.wy = o[1],
			.wz = o[2],
			.voxelSize = 1,
		});
	}
	prof.anchorLoadCount = held.count;
	prof.anchorLoadPos = dest;
	prof.anchorLoadSince = nowSeconds();
}

/// Landing search result. "Unloaded" and "blocked" must stay distinct: an
/// unloaded far chunk means WAIT (the preload will materialize it), never
/// "no valid position" (that false negative broke every long-distance pair).
const LandingResult = union(enum) {
	found: [3]f64,
	notLoaded,
	blocked,
};

/// Finds a safe landing spot near the destination anchor: the first candidate
/// whose feet cell and head cell are both loaded and non-colliding. Returns
/// the player position in the usual +0.5/+1.0 convention, .notLoaded when any
/// required cell is in an unloaded chunk (wait, don't fail), or .blocked when
/// every candidate is verifiably solid.
fn findSafeLanding(world: *main.server.ServerWorld, dest: [3]i32) LandingResult {
	var sawUnloaded = false;
	for (landingCandidateOffsets()) |off| {
		const fx = dest[0] + off[0];
		const fz = dest[1] + off[1];
		const fy = dest[2] + off[2];
		const feet = world.getBlock(fx, fz, fy) orelse {
			sawUnloaded = true;
			continue;
		};
		if (feet.collide()) continue;
		const head = world.getBlock(fx, fz, fy + 1) orelse {
			sawUnloaded = true;
			continue;
		};
		if (head.collide()) continue;
		return .{ .found = .{
			@as(f64, @floatFromInt(fx)) + 0.5,
			@as(f64, @floatFromInt(fz)) + 0.5,
			@as(f64, @floatFromInt(fy)) + 1.0,
		} };
	}
	return if (sawUnloaded) .notLoaded else .blocked;
}

/// World-tick check: teleport a player standing on an anchor.
/// Anti-troll rules (all must hold):
/// - the anchor is the block underfoot (feet-1, or feet for rounding cases),
///   never merely nearby (feet-2 ambush vector excluded);
/// - the block directly above the anchor is passable (no cover trap, not even
///   a slab: anything you can't stand *inside* of blocks the teleport);
/// - the player has stood continuously above the same anchor for
///   `standDelaySeconds` (kills under-foot ambushes and spawn-arrival grabs).
/// - the destination has a free landing spot (never inside a wall/block); and
/// - the player stepped off since the last teleport (no re-fire loop when
///   landing on top of the other anchor).
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
	// Foot tolerance: the anchor is the block directly underfoot (feet-1),
	// falling back to feet level for rounding cases the original tolerated.
	// feet-2 stays excluded (under-foot ambush vector).
	const anchorPos: [3]i32 = blk: {
		for ([2]i32{ below - 1, below }) |level| {
			const b = world.getBlock(hx, hz, level) orelse continue;
			if (b.typ != waypointTyp) continue;
			if (counterpart(hx, hz, level) == null) continue;
			break :blk .{ hx, hz, level };
		}
		prof.anchorStandPos = null;
		prof.anchorSuppressPos = null;
		releaseHeldChunks(prof);
		return;
	};
	const anchorY = anchorPos[2];
	const dest = counterpart(anchorPos[0], anchorPos[1], anchorPos[2]).?;
	// Re-fire suppression: this anchor just teleported the player here — step
	// off (handled above) and step back on before it can fire again.
	if (prof.anchorSuppressPos) |sup| {
		if (sup[0] == anchorPos[0] and sup[1] == anchorPos[1] and sup[2] == anchorPos[2]) {
			prof.anchorStandPos = null;
			return;
		}
	}
	// Cover trap: anything solid directly above the anchor blocks it.
	if (world.getBlock(hx, hz, anchorY + 1)) |cover| {
		if (cover.collide()) {
			prof.anchorStandPos = null;
			return;
		}
	}
	const now = nowSeconds();
	// Stand delay: same anchor, continuously, for the full delay.
	if (prof.anchorStandPos) |stood| {
		if (stood[0] != anchorPos[0] or stood[1] != anchorPos[1] or stood[2] != anchorPos[2]) {
			prof.anchorStandPos = anchorPos;
			prof.anchorStandSince = now;
			return;
		}
	} else {
		prof.anchorStandPos = anchorPos;
		prof.anchorStandSince = now;
		return;
	}
	if (now - prof.anchorStandSince < standDelaySeconds) return;
	prof.anchorStandPos = null;
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
	// The destination neighborhood is usually unloaded (no player nearby):
	// getBlock returns null for unloaded chunks, which must NOT be mistaken
	// for a missing anchor (that false positive broke every long-distance
	// pair). Request the async load, hold refs so the tasks survive, and
	// wait — stand state is kept so it fires once the chunks arrive. Holds
	// stay until the teleport resolves (found/missing/blocked), step-off, or
	// destination change: releasing early lets the chunks unload again before
	// the neighbor cells needed by the landing search are verifiable.
	const destBlock = world.getBlock(dest[0], dest[1], dest[2]);
	if (destBlock == null) {
		ensureDestChunksLoading(prof, dest);
		waitForDestLoad(user, prof, now);
		return;
	}
	// The other anchor may have been destroyed without unlinking: refuse rather
	// than teleporting to stale coordinates.
	if (destBlock.?.typ != waypointTyp) {
		releaseHeldChunks(prof);
		if (now - prof.anchorCooldownNotifiedAt >= noticeThrottleSeconds) {
			prof.anchorCooldownNotifiedAt = now;
			user.sendMessage("#e6312cThe other waypoint is missing.", .{});
		}
		return;
	}
	// Never materialize inside a wall, a roof, or a cover: find the closest
	// free feet+head cells near the anchor instead of going blindly above it.
	// .notLoaded means WAIT (unloaded ≠ blocked); only .blocked reports
	// "no valid position".
	switch (findSafeLanding(world, dest)) {
		.found => |landing| {
			releaseHeldChunks(prof);
			prof.waypointCooldownUntil = nowSeconds() + teleportCooldownSeconds;
			prof.back_pos = prof.pos;
			prof.pos = landing;
			prof.anchorSuppressPos = dest;
			main.server.anticheat.expectTeleport(user);
			main.network.protocols.genericUpdate.sendTPCoordinates(user.conn, prof.pos);
			poof(anchorPos);
			user.sendMessage("#cfcfcfWaypoint teleport.", .{});
		},
		.notLoaded => {
			ensureDestChunksLoading(prof, dest);
			waitForDestLoad(user, prof, now);
		},
		.blocked => {
			releaseHeldChunks(prof);
			if (now - prof.anchorCooldownNotifiedAt >= noticeThrottleSeconds) {
				prof.anchorCooldownNotifiedAt = now;
				user.sendMessage("#e6312cNo valid position found at the other waypoint.", .{});
			}
		},
	}
}

/// Throttled "still loading" UX while the destination neighborhood loads.
/// If the wait exceeds destLoadTimeoutSeconds (pathological: extreme distance
/// or starved chunk threads), say so and restart the window — the player keeps
/// standing, the preload keeps being requested, and the notice repeats at
/// most once per window instead of spamming or failing silently.
fn waitForDestLoad(user: *User, prof: *main.server.Entity, now: i64) void {
	if (now - prof.anchorLoadSince > destLoadTimeoutSeconds) {
		releaseHeldChunks(prof);
		prof.anchorLoadSince = now;
		user.sendMessage("#e6312cThe far waypoint is taking a while to load. #8a8a8a(Keeping you here — it will fire when ready.)", .{});
		return;
	}
	if (now - prof.anchorCooldownNotifiedAt >= noticeThrottleSeconds) {
		prof.anchorCooldownNotifiedAt = now;
		user.sendMessage("#8a8a8aWaiting for the far waypoint to load…", .{});
	}
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

	test "waypoint landing candidates are nearest-first in file axis order" {
	// Axis order is (x, horizontal, vertical), matching check()/getBlock.
	const offs = landingCandidateOffsets();
	try std.testing.expectEqual(@as(usize, 14), offs.len);
	// Directly above first (closest, preserves old behavior when open).
	try std.testing.expectEqual([3]i32{ 0, 0, 1 }, offs[0]);
	// Then middle sides, upper sides, top, upper-upper sides.
	const want = [13][3]i32{
		.{ 1, 0, 0 },
		.{ -1, 0, 0 },
		.{ 0, 1, 0 },
		.{ 0, -1, 0 },
		.{ 1, 0, 1 },
		.{ -1, 0, 1 },
		.{ 0, 1, 1 },
		.{ 0, -1, 1 },
		.{ 0, 0, 2 },
		.{ 1, 0, 2 },
		.{ -1, 0, 2 },
		.{ 0, 1, 2 },
		.{ 0, -1, 2 },
	};
	for (want, 0..) |w, i| try std.testing.expectEqual(w, offs[1 + i]);
}

	test "waypoint dest hold origins cover the landing neighborhood" {
	// Mid-chunk anchor: every touched cell is in one chunk.
	const mid = destHoldOrigins(.{ 16, 16, 16 });
	try std.testing.expectEqual(@as(usize, 1), mid.count);
	try std.testing.expectEqual([3]i32{ 0, 0, 0 }, mid.origins[0]);
	// Corner anchor: ±1 block and +0..+3 vertical span 2 origins per axis.
	const corner = destHoldOrigins(.{ 31, 31, 31 });
	try std.testing.expectEqual(@as(usize, 8), corner.count);
	// All origins 32-aligned, distinct, and the anchor's own chunk included.
	var seenOwn = false;
	for (corner.origins[0..corner.count], 0..) |o, i| {
		try std.testing.expectEqual(@as(i32, 0), o[0] & 31);
		try std.testing.expectEqual(@as(i32, 0), o[1] & 31);
		try std.testing.expectEqual(@as(i32, 0), o[2] & 31);
		for (corner.origins[0..i]) |p| try std.testing.expect(!(p[0] == o[0] and p[1] == o[1] and p[2] == o[2]));
		if (o[0] == 0 and o[1] == 0 and o[2] == 0) seenOwn = true;
	}
	try std.testing.expect(seenOwn);
	// Negative coords align like world.getBlock's masking (two's complement).
	const neg = destHoldOrigins(.{ -1, -1, -1 });
	try std.testing.expect(neg.count >= 1 and neg.count <= 8);
	for (neg.origins[0..neg.count]) |o| {
		try std.testing.expectEqual(@as(i32, 0), o[0] & 31);
	}
}
