const std = @import("std");

const main = @import("main");
const User = main.server.User;

// --- ASHFRAME CUSTOM (Shrines / sky cores) ---
// A placed sky_core teleports you to the sky islands. On first use it finds a
// real sky-island surface and builds a landing pad (platform + unbreakable
// return_core) there, linked back to that core. Standing on a linked core
// teleports you to the side of the other end (not on top, so no bounce loop).
// Cores must be at least `coreSpacing` apart in every direction.

const Link = struct {
	base: [3]i32, // player-placed sky core (x, z, vertical)
	sky: [3]i32, // server-created return core (x, z, vertical)
};

var links: main.ListManaged(Link) = undefined;
var cores: main.ListManaged([3]i32) = undefined;
var ready: bool = false;
var lastSave: std.Io.Timestamp = .{.nanoseconds = 0};

pub const cooldownSeconds: i64 = 3;

/// Minimum seconds between "teleport ready in Ns" notices while standing on
/// an anchor during its cooldown. Longer than the cooldown itself, so a
/// normal stand shows exactly one notice and hop-spam is bounded.
pub const noticeThrottleSeconds: i64 = 5;
pub const coreSpacing: i32 = 128;
/// A new core placed within this horizontal distance of an existing core's spot
/// (even if that core was broken) reuses its sky platform instead of building a
/// new one. Keeps a broken+replaced core from spawning duplicate platforms.
const relinkRadius: i32 = 128;
/// Minimum gap between server-wide "Sky Core activated" announcements.
pub const announceCooldownSeconds: i64 = 600;
var lastAnnounce: i64 = 0;
// Islands are observed roughly here; trace top-down within this band.
const skyTraceTop: i32 = 13300;
const skyTraceBottom: i32 = 10800;

fn ensure() void {
	if (!ready) {
		links = main.ListManaged(Link).init(main.globalAllocator);
		cores = main.ListManaged([3]i32).init(main.globalAllocator);
		ready = true;
	}
}

fn eq(p: [3]i32, x: i32, y: i32, z: i32) bool {
	return p[0] == x and p[1] == y and p[2] == z;
}

fn nowSeconds() i64 {
	return @intCast(@divTrunc(main.timestamp().toNanoseconds(), 1000000000));
}

fn counterpart(hx: i32, hz: i32, vert: i32) ?[3]i32 {
	ensure();
	for (links.items) |*l| {
		if (eq(l.base, hx, hz, vert)) return l.sky;
		if (eq(l.sky, hx, hz, vert)) return l.base;
	}
	return null;
}

fn findLinkIndex(hx: i32, hz: i32, vert: i32) ?usize {
	ensure();
	for (links.items, 0..) |*l, i| {
		if (eq(l.base, hx, hz, vert) or eq(l.sky, hx, hz, vert)) return i;
	}
	return null;
}

/// Nearest existing link whose base spot is within `relinkRadius` of (hx,hz).
/// Used so a core placed near a broken core's spot reuses that sky platform.
fn findNearbyLink(hx: i32, hz: i32) ?usize {
	ensure();
	var best: ?usize = null;
	var bestDist: i32 = std.math.maxInt(i32);
	for (links.items, 0..) |*l, i| {
		const dx: i32 = @intCast(@abs(l.base[0] - hx));
		const dz: i32 = @intCast(@abs(l.base[1] - hz));
		if (dx > relinkRadius or dz > relinkRadius) continue;
		const d = dx + dz;
		if (d < bestDist) {
			bestDist = d;
			best = i;
		}
	}
	return best;
}

/// Whether a new core may be placed here (>= coreSpacing from every other).
pub fn canPlaceCore(hx: i32, hz: i32) bool {
	ensure();
	for (cores.items) |c| {
		const dx = @abs(c[0] - hx);
		const dz = @abs(c[1] - hz);
		if (dx < coreSpacing and dz < coreSpacing) return false;
	}
	return true;
}

/// Whether the return core at (hx,hz,vert) is one of ours (unbreakable).
pub fn isReturnCore(hx: i32, hz: i32, vert: i32) bool {
	ensure();
	for (links.items) |*l| {
		if (eq(l.sky, hx, hz, vert)) return true;
	}
	return false;
}

pub fn onCorePlaced(hx: i32, hz: i32, vert: i32) void {
	ensure();
	cores.append(.{ hx, hz, vert });
	saveCurrentWorld();
}

/// Remove a broken player core. The link is intentionally KEPT so the sky
/// platform it created is remembered: a core placed nearby later relinks to it
/// instead of building a second platform. Only the "active" list is cleared.
pub fn onCoreBroken(hx: i32, hz: i32, vert: i32) void {
	ensure();
	var i: usize = 0;
	while (i < cores.items.len) {
		if (eq(cores.items[i], hx, hz, vert)) {
			_ = cores.swapRemove(i);
			continue;
		}
		i += 1;
	}
	saveCurrentWorld();
}

fn isSkyIslands(hx: i32, hz: i32, vert: i32) bool {
	const world = main.server.world orelse return false;
	const biome = world.getBiome(hx, hz, vert);
	return std.mem.indexOf(u8, biome.id, "sky_islands") != null;
}

/// Line-traces downward through the sky band for the first solid surface.
/// Chunks are generated lazily, top chunk first, and stop at the first hit.
/// No biome pre-filter: sampling the 3D cave-biome map is very slow per call,
/// so a direct block trace is faster and more reliable.
pub fn findIslandSurface(hx: i32, hz: i32) ?i32 {
	const world = main.server.world orelse return null;
	const size: i32 = main.chunk.chunkSize;
	var cy: i32 = skyTraceTop - @mod(skyTraceTop, size); // top, chunk-aligned
	while (cy >= skyTraceBottom) : (cy -= size) {
		const baseChunk = world.getOrGenerateChunkAndIncreaseRefCount(.{
			.wx = hx & ~@as(i32, main.chunk.chunkMask),
			.wy = hz & ~@as(i32, main.chunk.chunkMask),
			.wz = cy & ~@as(i32, main.chunk.chunkMask),
			.voxelSize = 1,
		});
		baseChunk.mutex.lock();
		var y: i32 = cy + size - 1;
		while (y >= cy) : (y -= 1) {
			const pos: main.chunk.BlockPos = .fromWorldCoords(hx, hz, y);
			const b = baseChunk.getBlock(pos.x, pos.y, pos.z);
			if (b.collide()) {
				baseChunk.mutex.unlock();
				baseChunk.decreaseRefCount();
				return y + 1;
			}
		}
		baseChunk.mutex.unlock();
		baseChunk.decreaseRefCount();
	}
	return null;
}

/// Finds a sky-islands landing column near (hx,hz). Returns {hx, hz, surfaceY}.
fn findSkySpot(hx: i32, hz: i32) ?[3]i32 {
	// Spiral out from the core; stop at the first column with solid ground.
	var ring: i32 = 0;
	while (ring <= 6) : (ring += 1) {
		var dx: i32 = -ring;
		while (dx <= ring) : (dx += 1) {
			var dz: i32 = -ring;
			while (dz <= ring) : (dz += 1) {
				if (@abs(dx) != ring and @abs(dz) != ring) continue;
				const x = hx + dx*32;
				const z = hz + dz*32;
				if (findIslandSurface(x, z)) |surface| {
					std.log.info("Shrine landing found at {}, {} (surface y={})", .{ x, z, surface });
					return .{ x, z, surface };
				}
			}
		}
	}
	std.log.info("Shrine: no solid ground found near {}, {} (band {}-{})", .{ hx, hz, skyTraceBottom, skyTraceTop });
	return null;
}

/// Builds a 5x5 platform at (hx, hz, surfaceY) with a return_core at its
/// centre, linked to base. Positions are (x, z, vertical).
fn createLanding(base: [3]i32, hx: i32, hz: i32, surfaceY: i32) [3]i32 {
	const world = main.server.world orelse return .{ hx, hz, surfaceY };
	const platformTyp = main.blocks.getTypeById("cubyz:nimbusite/smooth");
	const coreTyp = main.blocks.getTypeById("ashframe:return_core");

	for (0..5) |dx| {
		for (0..5) |dz| {
			world.updateBlock(hx - 2 + @as(i32, @intCast(dx)), hz - 2 + @as(i32, @intCast(dz)), surfaceY, .{.typ = platformTyp, .data = 0});
		}
	}
	world.updateBlock(hx, hz, surfaceY + 1, .{.typ = coreTyp, .data = 0});
	links.append(.{ .base = base, .sky = .{ hx, hz, surfaceY + 1 } });
	saveCurrentWorld();
	return .{ hx, hz, surfaceY + 1 };
}

/// Arrival position: beside the destination core (not on top), so standing on
/// it does not immediately re-trigger.
///
/// For the sky landing we know the exact geometry: `createLanding` builds a flat
/// platform at `surfaceY` and puts the return core at `surfaceY + 1`, so
/// `dest[2]` (the return core's Y) means the player's feet belong at
/// `dest[2] - 1` = the platform top. We use that directly instead of tracing,
/// because tracing the freshly-built/possibly-not-resident sky column was
/// leaving the player a couple of blocks above the platform (they then fell).
///
/// For the overworld (base) end we trace the ground, so uneven terrain can't
/// leave the player in the air.
fn arriveBeside(prof: *main.server.Entity, dest: [3]i32, isSkyLanding: bool) void {
	const x = dest[0] + 1;
	const z = dest[1];
	var feet = dest[2];
	if (isSkyLanding) {
		// Flat platform at `surfaceY`, return core at `surfaceY + 1` = dest[2].
		feet = dest[2] - 1;
	} else if (main.server.world) |world| {
		// Overworld: trace the arrival column for the ground.
		feet = dest[2] + 1;
		var y: i32 = dest[2] + 3;
		var steps: i32 = 0;
		while (steps < 8 and y >= dest[2] - 8) : ({
			y -= 1;
			steps += 1;
		}) {
			const b = world.getBlock(x, z, y) orelse break;
			if (b.collide()) {
				feet = y + 1;
				break;
			}
		}
	}
	prof.pos = .{
		@as(f64, @floatFromInt(x)) + 0.5,
		@as(f64, @floatFromInt(z)) + 0.5,
		@as(f64, @floatFromInt(feet)),
	};
	std.log.info("[arrive] sky={} dest=({d},{d},{d}) -> pos=({d:.1},{d:.1},{d:.1}) feet={d}", .{ isSkyLanding, dest[0], dest[1], dest[2], prof.pos[0], prof.pos[1], prof.pos[2], feet });
	// Show what's actually at the destination column, to confirm the platform.
	if (main.server.world) |world| {
		var yy: i32 = dest[2] + 2;
		while (yy >= dest[2] - 4) : (yy -= 1) {
			const b = world.getBlock(x, z, yy) orelse {
				std.log.info("[arrive]   y={d}: <null>", .{yy});
				continue;
			};
			std.log.info("[arrive]   y={d}: typ={d} collide={}", .{ yy, b.typ, b.collide() });
		}
	}
}

/// Spawns a poof at a core position (on top of the block), for the teleporter
/// and anyone nearby, so the teleport has a visible effect.
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

/// Called when a player stands on a sky core / return core.
pub fn check(user: *User) void {
	ensure();
	const prof = user.player();
	// Axis order: (x, z, vertical).
	const hx = main.server.anticheat.toI32(prof.pos[0]) orelse return;
	const hz = main.server.anticheat.toI32(prof.pos[1]) orelse return;
	const below = main.server.anticheat.toI32(prof.pos[2]) orelse return;
	const world = main.server.world orelse return;
	const coreTyp = main.blocks.getTypeById("ashframe:sky_core");
	const retTyp = main.blocks.getTypeById("ashframe:return_core");
	if (coreTyp == 0) return;
	var level: i32 = below;
	var under: ?main.blocks.Block = null;
	while (level >= below - 2) : (level -= 1) {
		const b = world.getBlock(hx, hz, level) orelse continue;
		if (b.typ == coreTyp or b.typ == retTyp) {
			under = b;
			break;
		}
	}
	const underBlock = under orelse return;
	const now = nowSeconds();
	if (now < prof.waypointCooldownUntil) {
		// Throttled notice: at most one message per stand window, so jumping
		// on the anchor (off-and-on every hop) can't spam chat.
		if (now - prof.anchorCooldownNotifiedAt >= noticeThrottleSeconds) {
			prof.anchorCooldownNotifiedAt = now;
			const remaining = prof.waypointCooldownUntil - now + 1;
			user.sendMessage("#8a8a8aSky teleport ready in #cfcfcf{d}s#8a8a8a.", .{remaining});
		}
		return;
	}

	// Already linked? Teleport beside the other end.
	if (counterpart(hx, hz, level)) |dest| {
		// We're standing on the base core if `underBlock` is the player sky core;
		// then `dest` is the sky landing (flat platform), otherwise it's the base.
		const destIsSky = underBlock.typ == coreTyp;
		prof.waypointCooldownUntil = nowSeconds() + cooldownSeconds;
		prof.back_pos = prof.pos;
		arriveBeside(prof, dest, destIsSky);
		main.server.anticheat.expectTeleport(user);
		main.network.protocols.genericUpdate.sendTPCoordinates(user.conn, prof.pos);
		poof(.{ hx, hz, level });
		user.sendMessage("#cfcfcfSky teleport.", .{});
		return;
	}

	// Unlinked player core: build a landing once, then teleport.
	if (underBlock.typ != coreTyp) return;
	if (findLinkIndex(hx, hz, level) != null) return; // safety

	// A core placed near an existing (possibly broken) core's spot reuses that
	// sky platform instead of generating a duplicate one.
	if (findNearbyLink(hx, hz)) |idx| {
		const sky = links.items[idx].sky;
		links.items[idx].base = .{ hx, hz, level };
		saveCurrentWorld();
		prof.waypointCooldownUntil = nowSeconds() + cooldownSeconds;
		prof.back_pos = prof.pos;
		arriveBeside(prof, sky, true);
		main.server.anticheat.expectTeleport(user);
		main.network.protocols.genericUpdate.sendTPCoordinates(user.conn, prof.pos);
		poof(.{ hx, hz, level });
		user.sendMessage("#cfcfcfSky teleport. #8a8a8a(Reused the nearby landing.)", .{});
		return;
	}

	const spot = findSkySpot(hx, hz) orelse {
		user.sendMessage("#e6312cNo sky island found nearby to land on.", .{});
		return;
	};
	const skyCore = createLanding(.{ hx, hz, level }, spot[0], spot[1], spot[2]);
	prof.waypointCooldownUntil = nowSeconds() + cooldownSeconds;
	prof.back_pos = prof.pos;
	arriveBeside(prof, skyCore, true);
	main.server.anticheat.expectTeleport(user);
	main.network.protocols.genericUpdate.sendTPCoordinates(user.conn, prof.pos);
	poof(.{ hx, hz, level });
	announceActivation(user);
}

/// Server-wide announcement when a Sky Core is first activated, throttled so it
/// can't be spammed (at most once per announceCooldownSeconds).
fn announceActivation(user: *User) void {
	const now = nowSeconds();
	if (now - lastAnnounce < announceCooldownSeconds) return;
	lastAnnounce = now;
	main.server.sendMessage("#e6312c{s} #00ff00has activated a Sky Core.", .{user.name});
}

fn filePath(allocator: main.heap.NeverFailingAllocator, worldPath: []const u8) []const u8 {
	return allocator.print("saves/{s}/ashframe_shrines.zig.zon", .{worldPath});
}

fn saveCurrentWorld() void {
	const world = main.server.world orelse return;
	save(world.path);
}

fn readTriple(entry: main.ZonElement, key: []const u8) ?[3]i32 {
	const a = entry.getChild(key).toSlice();
	if (a.len != 3) return null;
	return .{ a[0].as(i32) orelse return null, a[1].as(i32) orelse return null, a[2].as(i32) orelse return null };
}

pub fn load(worldPath: []const u8) void {
	ensure();
	links.clearRetainingCapacity();
	cores.clearRetainingCapacity();
	const path = filePath(main.stackAllocator, worldPath);
	defer main.stackAllocator.free(path);
	const zon = main.files.cubyzDir().readToZon(main.stackAllocator, path) catch return;
	defer zon.deinit(main.stackAllocator);
	for (zon.getChild("links").toSlice()) |entry| {
		const a = readTriple(entry, "base") orelse continue;
		const b = readTriple(entry, "sky") orelse continue;
		links.append(.{ .base = a, .sky = b });
	}
	for (zon.getChild("cores").toSlice()) |entry| {
		const c = readTriple(entry, "pos") orelse continue;
		cores.append(c);
	}
}

pub fn save(worldPath: []const u8) void {
	ensure();
	const path = filePath(main.stackAllocator, worldPath);
	defer main.stackAllocator.free(path);
	var zon = main.ZonElement.initObject(main.stackAllocator);
	defer zon.deinit(main.stackAllocator);
	var linkArr = main.ZonElement.initArray(main.stackAllocator);
	for (links.items) |*l| {
		var e = main.ZonElement.initObject(main.stackAllocator);
		var aa = main.ZonElement.initArray(main.stackAllocator);
		for (l.base) |v| aa.array.append(.{.int = v});
		e.put("base", aa);
		var bb = main.ZonElement.initArray(main.stackAllocator);
		for (l.sky) |v| bb.array.append(.{.int = v});
		e.put("sky", bb);
		linkArr.array.append(e);
	}
	zon.put("links", linkArr);
	var coreArr = main.ZonElement.initArray(main.stackAllocator);
	for (cores.items) |c| {
		var e = main.ZonElement.initObject(main.stackAllocator);
		var aa = main.ZonElement.initArray(main.stackAllocator);
		for (c) |v| aa.array.append(.{.int = v});
		e.put("pos", aa);
		coreArr.array.append(e);
	}
	zon.put("cores", coreArr);
	main.files.cubyzDir().writeZon(path, zon) catch |err| {
		std.log.err("Could not save Ashframe shrines: {s}", .{@errorName(err)});
	};
}

pub fn autosave(worldPath: []const u8) void {
	const now = main.timestamp();
	if (lastSave.durationTo(now).toSeconds() > 60) {
		lastSave = now;
		save(worldPath);
	}
}
// --- ASHFRAME CUSTOM (Shrines) ---
