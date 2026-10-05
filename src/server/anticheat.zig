const std = @import("std");

const main = @import("main");

// --- ASHFRAME CUSTOM (Anticheat / validation) ---
// Central validation for data that comes from clients. The client is open-source
// and may be modified, so anything it sends is untrusted.
//
// Two tiers:
//  - `valid*` helpers: data a legitimate client can never produce (NaN/Inf,
//    absurd magnitudes). Failing these is treated as malformed and disconnects.
//  - `toI32`: a checked float->int conversion so a bad position can never trap
//    the server in an `@intFromFloat`.
//
// Phase 3 will add per-player rate limits and violation logging here.

/// World coordinates are (x, z, vertical); the vertical is the third component.
pub const maxHorizontal: f64 = 1.0e9;
pub const maxVertical: f64 = 1.0e5;
pub const maxVelocity: f64 = 1.0e6;

pub fn validPosition(pos: [3]f64) bool {
	if (!std.math.isFinite(pos[0]) or !std.math.isFinite(pos[1]) or !std.math.isFinite(pos[2])) return false;
	if (@abs(pos[0]) > maxHorizontal or @abs(pos[1]) > maxHorizontal) return false;
	if (pos[2] < -maxVertical or pos[2] > maxVertical) return false;
	return true;
}

pub fn validVelocity(vel: [3]f64) bool {
	if (!std.math.isFinite(vel[0]) or !std.math.isFinite(vel[1]) or !std.math.isFinite(vel[2])) return false;
	if (@abs(vel[0]) > maxVelocity or @abs(vel[1]) > maxVelocity or @abs(vel[2]) > maxVelocity) return false;
	return true;
}

pub fn validRotation(rot: [3]f32) bool {
	return std.math.isFinite(rot[0]) and std.math.isFinite(rot[1]) and std.math.isFinite(rot[2]);
}

/// Checked f64 -> i32 floor conversion. Returns null for non-finite or
/// out-of-range values instead of trapping.
pub fn toI32(v: f64) ?i32 {
	const floored = @floor(v);
	if (!std.math.isFinite(floored)) return null;
	if (floored < -2147483648.0 or floored > 2147483647.0) return null;
	return @intFromFloat(floored);
}

/// Checked f64 -> i64 floor conversion, for counters that may be client-derived.
pub fn toI64(v: f64) ?i64 {
	const floored = @floor(v);
	if (!std.math.isFinite(floored)) return null;
	if (floored < -9.0e15 or floored > 9.0e15) return null;
	return @intFromFloat(floored);
}

// --- Rate limiting ---

/// Simple token bucket. `allow` consumes one token if available.
pub const TokenBucket = struct {
	tokens: f64 = 0,
	lastRefill: i64 = 0,
	capacity: f64 = 20,
	refillPerSec: f64 = 10,

	pub fn allow(self: *TokenBucket, now: i64) bool {
		const dt = @as(f64, @floatFromInt(now - self.lastRefill))/1000.0;
		self.tokens = @min(self.capacity, self.tokens + dt*self.refillPerSec);
		self.lastRefill = now;
		if (self.tokens >= 1.0) {
			self.tokens -= 1.0;
			return true;
		}
		return false;
	}
};

pub fn nowMilliseconds() i64 {
	return main.timestamp().toMilliseconds();
}

// --- Violation logging (wave 1 collection) ---

pub const Category = enum { protocol, movement, reach, inventory, chat, rate, mining };

const Violation = struct {
	time: i64,
	player: []const u8,
	category: Category,
	detail: []const u8,
};

const maxViolations = 500;
var violations: main.ListManaged(Violation) = undefined;
var violationsReady: bool = false;
var lastSave: std.Io.Timestamp = .{.nanoseconds = 0};

fn ensureViolations() void {
	if (!violationsReady) {
		violations = main.ListManaged(Violation).init(main.globalAllocator);
		suspects = main.ListManaged(Violation).init(main.globalAllocator);
		violationsReady = true;
	}
}

// Suspicions: plausible-but-odd observations we are NOT sure are cheating
// (heuristics, staff movement, edge cases). Logged separately from confirmed
// violations, never operator-notified, never enforced - purely for manual review.
const maxSuspects = 500;
var suspects: main.ListManaged(Violation) = undefined;

/// Records a violation: logs it live and keeps a bounded in-memory history that
/// is persisted to `saves/<world>/ashframe_anticheat.zig.zon` for review.
/// How often a category may be logged per player. `.movement` and `.rate` fire
/// on a hot path (every position update while moving fast), so they are capped;
/// rare categories are not.
fn noteIntervalMs(category: Category) i64 {
	return switch (category) {
		.movement, .rate, .mining, .reach => 1000,
		else => 0,
	};
}

pub fn note(user: ?*main.server.User, category: Category, detail: []const u8) void {
	const name = if (user) |u| u.name else "?";
	if (user) |u| {
		const now = nowMilliseconds();
		const i = @intFromEnum(category);
		if (now < u.noteMuteUntilMs[i]) {
			main.server.metrics.noteAnticheatThrottled();
			return;
		}
		u.noteMuteUntilMs[i] = now + noteIntervalMs(category);
	}
	main.server.metrics.noteAnticheatNote();
	std.log.warn("[anticheat] {s} {s}: {s}", .{ name, @tagName(category), detail });
	main.server.report.record(.violation, name, detail);
	main.server.report.notifyAggregated(name, @tagName(category), detail);
	ensureViolations();
	while (violations.items.len >= maxViolations) {
		const old = violations.swapRemove(0);
		main.globalAllocator.free(old.player);
		main.globalAllocator.free(old.detail);
	}
	violations.append(.{
		.time = nowMilliseconds(),
		.player = main.globalAllocator.dupe(u8, name),
		.category = category,
		.detail = main.globalAllocator.dupe(u8, detail),
	});
}

/// Logs a *suspicion*: something we cannot be certain is cheating. Separate from
/// confirmed violations - info-level only, never operator-notified, never
/// enforced, persisted for manual review.
pub fn suspect(user: ?*main.server.User, category: Category, detail: []const u8) void {
	const name = if (user) |u| u.name else "?";
	if (user) |u| {
		const now = nowMilliseconds();
		const i = @intFromEnum(category);
		if (now < u.noteMuteUntilMs[i]) return;
		u.noteMuteUntilMs[i] = now + noteIntervalMs(category);
	}
	main.server.metrics.noteSuspect();
	std.log.info("[suspect] {s} {s}: {s}", .{ name, @tagName(category), detail });
	ensureViolations();
	while (suspects.items.len >= maxSuspects) {
		const old = suspects.swapRemove(0);
		main.globalAllocator.free(old.player);
		main.globalAllocator.free(old.detail);
	}
	suspects.append(.{
		.time = nowMilliseconds(),
		.player = main.globalAllocator.dupe(u8, name),
		.category = category,
		.detail = main.globalAllocator.dupe(u8, detail),
	});
}

fn filePath(allocator: main.heap.NeverFailingAllocator, worldPath: []const u8) []const u8 {
	return allocator.print("saves/{s}/ashframe_anticheat.zig.zon", .{worldPath});
}

pub fn load(worldPath: []const u8) void {
	ensureViolations();
	for (violations.items) |v| {
		main.globalAllocator.free(v.player);
		main.globalAllocator.free(v.detail);
	}
	violations.clearRetainingCapacity();
	for (suspects.items) |v| {
		main.globalAllocator.free(v.player);
		main.globalAllocator.free(v.detail);
	}
	suspects.clearRetainingCapacity();
	const path = filePath(main.stackAllocator, worldPath);
	defer main.stackAllocator.free(path);
	const zon = main.files.cubyzDir().readToZon(main.stackAllocator, path) catch return;
	defer zon.deinit(main.stackAllocator);
	for (zon.getChild("violations").toSlice()) |e| {
		const player = e.get([]const u8, "player") orelse continue;
		const detail = e.get([]const u8, "detail") orelse "";
		const categoryStr = e.get([]const u8, "category") orelse "protocol";
		const category = std.meta.stringToEnum(Category, categoryStr) orelse .protocol;
		const time = e.get(i64, "time") orelse 0;
		violations.append(.{
			.time = time,
			.player = main.globalAllocator.dupe(u8, player),
			.category = category,
			.detail = main.globalAllocator.dupe(u8, detail),
		});
	}
	for (zon.getChild("suspects").toSlice()) |e| {
		const player = e.get([]const u8, "player") orelse continue;
		const detail = e.get([]const u8, "detail") orelse "";
		const categoryStr = e.get([]const u8, "category") orelse "protocol";
		const category = std.meta.stringToEnum(Category, categoryStr) orelse .protocol;
		const time = e.get(i64, "time") orelse 0;
		suspects.append(.{
			.time = time,
			.player = main.globalAllocator.dupe(u8, player),
			.category = category,
			.detail = main.globalAllocator.dupe(u8, detail),
		});
	}
}

pub fn save(worldPath: []const u8) void {
	ensureViolations();
	const path = filePath(main.stackAllocator, worldPath);
	defer main.stackAllocator.free(path);
	var zon = main.ZonElement.initObject(main.stackAllocator);
	defer zon.deinit(main.stackAllocator);
	var arr = main.ZonElement.initArray(main.stackAllocator);
	for (violations.items) |*v| {
		var e = main.ZonElement.initObject(main.stackAllocator);
		e.put("time", v.time);
		e.put("player", v.player);
		e.put("category", @tagName(v.category));
		e.put("detail", v.detail);
		arr.array.append(e);
	}
	zon.put("violations", arr);
	var suspArr = main.ZonElement.initArray(main.stackAllocator);
	for (suspects.items) |*v| {
		var e = main.ZonElement.initObject(main.stackAllocator);
		e.put("time", v.time);
		e.put("player", v.player);
		e.put("category", @tagName(v.category));
		e.put("detail", v.detail);
		suspArr.array.append(e);
	}
	zon.put("suspects", suspArr);
	main.files.cubyzDir().writeZon(path, zon) catch |err| {
		std.log.err("Could not save Ashframe anticheat log: {s}", .{@errorName(err)});
	};
}

pub fn autosave(worldPath: []const u8) void {
	const now = main.timestamp();
	if (lastSave.durationTo(now).toSeconds() > 60) {
		lastSave = now;
		save(worldPath);
	}
}

// --- Enforcement switches ---
// --- ASHFRAME CUSTOM (Anticheat v2) ---
// Each v2 check runs in a mode from launchConfig (anticheatMovement,
// anticheatMining, anticheatReach): off, log (default) or enforce. In log
// mode a check only records "(log only)" suspects and the player is treated
// exactly like v1 did: positions accepted, breaks and interactions allowed,
// never set back or kicked. Turn on enforce per check once the logs show no
// false positives in real play.
pub const Mode = main.settings.launchConfig.AnticheatMode;
pub fn movementMode() Mode {
	return main.settings.launchConfig.anticheatMovement;
}
pub fn miningMode() Mode {
	return main.settings.launchConfig.anticheatMining;
}
pub fn reachMode() Mode {
	return main.settings.launchConfig.anticheatReach;
}
// Legacy v1 speed threshold: log-only (never rejects). Real movement
// enforcement is `validateMovement`, gated by `movementMode()`.
pub var enforceMovement: bool = false;
// --- ASHFRAME CUSTOM (Anticheat v2) ---

/// Legacy center-to-block radius, kept for `withinReach` callers/tests.
pub const reachRadius: f64 = 12.0;
/// Client reach is 6 blocks from the eye to the hit point (renderer.zig);
/// 1.5 blocks of slack cover eye smoothing/crouching and packet spacing.
pub const eyeReach: f64 = 7.5;
/// Eye height above the player's position (bounding-box center), game.zig.
pub const eyeOffset: f64 = 0.8;

/// Distance from the eye (player center + eyeOffset) to the nearest point of
/// the unit block at `block`.
pub fn eyeToBlockDistance(pos: [3]f64, block: [3]i32) f64 {
	const eye = [3]f64{pos[0], pos[1], pos[2] + eyeOffset};
	var sq: f64 = 0;
	for (0..3) |i| {
		const lo: f64 = @floatFromInt(block[i]);
		const d = @max(lo - eye[i], 0, eye[i] - (lo + 1));
		sq += d*d;
	}
	return @sqrt(sq);
}

/// Whether `block` (x, z, vertical) is within `radius` of `pos` (x, z, vertical).
pub fn withinReach(pos: [3]f64, block: [3]i32, radius: f64) bool {
	const dx = @as(f64, @floatFromInt(block[0])) - pos[0];
	const dz = @as(f64, @floatFromInt(block[1])) - pos[1];
	const dv = @as(f64, @floatFromInt(block[2])) - pos[2];
	return dx*dx + dz*dz + dv*dv <= radius*radius;
}

/// Reach check for a block interaction. Returns true if the action should be
/// allowed. Must be called without `user.mutex` held (server thread, command
/// execution).
pub fn checkReach(user: *main.server.User, block: [3]i32) bool {
	if (user.isLocal or reachMode() == .off) return true;
	user.mutex.lock();
	const raw = user.acLastGood;
	user.mutex.unlock();
	const interpolated = user.player().pos;
	// Accept if either the latest accepted position or the interpolated one
	// is in reach: one of them is always current to within a packet.
	var dist = eyeToBlockDistance(interpolated, block);
	if (raw) |p| dist = @min(dist, eyeToBlockDistance(p, block));
	// Positions are up to one packet (50 ms) old: add the distance covered in
	// 0.1 s at the player's current speed (matters when falling fast).
	const limit = eyeReach + @min(user.observedSpeed, 100.0)*0.1;
	if (dist <= limit) return true;
	var buf: [160]u8 = undefined;
	const detail = std.fmt.bufPrint(&buf, "reach {d:.1} (max {d:.1}) to block {d},{d},{d}", .{ dist, limit, block[0], block[1], block[2] }) catch "out of reach";
	if (reachMode() == .enforce and !user.anticheatStaff) {
		note(user, .reach, detail);
		return false;
	}
	// Log mode (v1 behaviour): review-only, the interaction goes through.
	suspect(user, .reach, detail);
	return true;
}

// --- Movement ---
// Max legitimate speed: walk 4.5, sprint 8, fly 32, ghost 128, terminal fall 90
// (physics.zig). Survival threshold covers fast flight plus a vertical
// component (128 fly + fall combines to ~160); creative also covers ghost.
pub const survivalMaxSpeed: f64 = 175.0;
pub const creativeMaxSpeed: f64 = 200.0;
/// Staff are given a much higher (but not infinite) threshold so that egregious
/// cheating by a staff account is still recorded - as a *suspicion*, never
/// enforced. Singleplayer (`isLocal`) is fully exempt.
pub const staffMaxSpeed: f64 = 500.0;

fn maxSpeedFor(user: *main.server.User) f64 {
	// `isAdmin`/`hasPermission` may only run on the server thread, so use the
	// cached staff flag (set at connect) instead.
	if (user.isLocal) return std.math.inf(f64);
	if (user.anticheatStaff) return staffMaxSpeed;
	if (user.gamemode.load(.monotonic) == .creative) return creativeMaxSpeed;
	return survivalMaxSpeed;
}

/// Grants a short grace window after a server-initiated teleport so the sudden
/// position jump isn't flagged.
pub fn expectTeleport(user: *main.server.User) void {
	user.teleportGraceUntil = nowMilliseconds() + 1500;
}

// --- ASHFRAME CUSTOM (Anticheat v2: authoritative teleports) ---
// The old 1.5 s grace accepted whatever the client sent, including positions
// from *before* it applied the teleport. Those became the movement baseline,
// so the real position at the destination looked like a huge jump and was set
// back to the old spot; the server kept streaming chunks there (`/spawn`
// stopped loading chunks). Now the destination is recorded and positions are
// not judged until the client reports being there.

/// The client counts as arrived within this distance of the destination.
pub const teleportArrivalRadius: f64 = 4.0;
/// Stop waiting after this long (very slow client): accept and start over.
pub const teleportArrivalTimeoutMs: i64 = 10_000;

/// Registers a server teleport to `target`. Called from
/// `genericUpdate.sendTPCoordinates` (every teleport), respawns and joins.
/// Safe with or without `user.mutex` held.
pub fn expectTeleportTo(user: *main.server.User, target: [3]f64) void {
	expectTeleport(user);
	if (user.acInSetback) return; // setbacks track their own target
	user.acTeleportMutex.lock();
	defer user.acTeleportMutex.unlock();
	user.acTeleportTarget = target;
	user.acTeleportSentMs = nowMilliseconds();
}

fn teleportPending(user: *main.server.User) bool {
	user.acTeleportMutex.lock();
	defer user.acTeleportMutex.unlock();
	return user.acTeleportTarget != null;
}

/// Pending-teleport handling for one position update. null: none pending.
/// Otherwise whether to accept the position: on arrival (or timeout) it is
/// accepted as the fresh movement baseline; before that it is stale and not
/// judged, accepted in log mode (as v1 did) and dropped in enforce mode, so
/// the server keeps the destination. Never sets back or kicks.
/// Caller holds `user.mutex`.
fn handlePendingTeleport(user: *main.server.User, pos: [3]f64, now: i64) ?bool {
	user.acTeleportMutex.lock();
	defer user.acTeleportMutex.unlock();
	const target = user.acTeleportTarget orelse return null;
	switch (teleportDecision(target, user.acTeleportSentMs, pos, now, movementMode() == .enforce)) {
		.arrived => {
			user.acTeleportTarget = null;
			resetMovementState(user, pos, now);
			return true;
		},
		.staleAccept => return true,
		.staleDrop => return false,
	}
}

pub const TeleportDecision = enum { arrived, staleAccept, staleDrop };

/// What to do with a position while a teleport to `target` (sent at `sentMs`)
/// is pending. Pure: unit-tested.
pub fn teleportDecision(target: [3]f64, sentMs: i64, pos: [3]f64, now: i64, enforce: bool) TeleportDecision {
	if (distance(pos, target) <= teleportArrivalRadius or now - sentMs > teleportArrivalTimeoutMs) return .arrived;
	return if (enforce) .staleDrop else .staleAccept;
}
// --- ASHFRAME CUSTOM (Anticheat v2: authoritative teleports) ---

/// Movement check: logs (and, in wave 2, rejects) speeds a legitimate client
/// can't reach. Returns true if the movement should be accepted.
pub fn checkMovement(user: *main.server.User, pos: [3]f64, vel: [3]f64, probe: WorldProbe) bool {
	const now = nowMilliseconds();
	var observed: f64 = @sqrt(vel[0]*vel[0] + vel[1]*vel[1] + vel[2]*vel[2]);
	// Movement actually covered since the last update. Used for the dynamic
	// render distance: unlike the reported velocity, this is 0 for a player who
	// is pushing against unloaded terrain, so a stuck player recovers instead of
	// staying capped forever.
	var movedSpeed: f64 = 0;
	if (user.anticheatLastPos) |last| {
		const dt = @as(f64, @floatFromInt(now - user.anticheatLastTime))/1000.0;
		// Lag-gap guard: position packets arriving faster than the 20 Hz
		// server tick (or batched after a stall) turn tiny position noise
		// into huge per-second speeds. Only trust the delta measurement at
		// sane sample spacing; otherwise fall back to reported velocity.
		if (dt >= 0.05) {
			const dx = pos[0] - last[0];
			const dz = pos[1] - last[1];
			const dv = pos[2] - last[2];
			movedSpeed = @sqrt(dx*dx + dz*dz + dv*dv)/dt;
			observed = @max(observed, movedSpeed);
		}
	}
	user.anticheatLastPos = .{pos[0], pos[1], pos[2]};
	user.anticheatLastTime = now;
	if (handlePendingTeleport(user, pos, now)) |accept| return accept;
	if (user.teleportGraceUntil > now) {
		resetMovementState(user, pos, now);
		return true;
	}
	// --- ASHFRAME CUSTOM (Anticheat v2) ---
	// While a setback is pending the client is still sending its old
	// positions; skip the legacy speed log so the setback jump isn't counted.
	if (user.acSetbackPos != null) return validateMovement(user, pos, now, probe);
	// --- ASHFRAME CUSTOM (Anticheat v2) ---
	// --- ASHFRAME CUSTOM (Anticheat: flight pattern, log-only) ---
	// Ghost/fly/hyperspeed are creative-gated client-side, so a server-side
	// survival account showing sustained flight-like movement is either a
	// spoofed client or a desync. Speed alone can't catch it (fly ~32 and
	// ghost ~128 sit far below the magnitude thresholds), so detect the
	// *pattern*: fast horizontal travel while not falling, held for seconds.
	// Log-only suspicion, never enforced: no kick, no reject.
	if (!user.isLocal and !user.anticheatStaff and user.gamemode.load(.monotonic) != .creative) {
		const flyHoriz = @sqrt(vel[0]*vel[0] + vel[1]*vel[1]);
		const flyVert: f64 = vel[2];
		// Above sprint envelope (~8) with margin, and not in freefall
		// (terminal fall is ~-90; jumps/falls reset the streak quickly).
		if (isFlightLike(flyHoriz, flyVert)) {
			user.flyStreak +|= 1;
		} else {
			user.flyStreak = 0;
		}
		// ~5 s of continuous flight-likes at 20 Hz. Re-arms after logging.
		if (user.flyStreak >= 100) {
			user.flyStreak = 0;
			var flyBuf: [160]u8 = undefined;
			const flyDetail = std.fmt.bufPrint(&flyBuf, "sustained flight pattern ({d:.0} horizontal) at {d:.0},{d:.0},{d:.0}", .{ flyHoriz, pos[0], pos[1], pos[2] }) catch "flight pattern";
			suspect(user, .movement, flyDetail);
		}
	} else {
		user.flyStreak = 0;
	}
	// --- ASHFRAME CUSTOM (Anticheat) ---
	// --- ASHFRAME CUSTOM (Dynamic render distance) ---
	// Cache the measured *movement* speed (network thread) and refresh the
	// effective render distance from it. Skipped during teleport grace so server
	// teleports don't register as huge speeds.
	user.observedSpeed = movedSpeed;
	user.refreshDynamicRenderDistance();
	// --- ASHFRAME CUSTOM (Dynamic render distance) ---
	const max = maxSpeedFor(user);
	const prof = user.player();
	if (observed > max) {
		// A single over-threshold sample is usually lag, not cheating: only
		// page the operators after 3 consecutive bad samples.
		prof.moveViolationStreak +|= 1;
		if (prof.moveViolationStreak < 3) {
			if (enforceMovement) return false;
			return validateMovement(user, pos, now, probe);
		}
		var buf: [160]u8 = undefined;
		const detail = std.fmt.bufPrint(&buf, "observed {d:.0}/s (max {d:.0}) at {d:.0},{d:.0},{d:.0}", .{ observed, max, pos[0], pos[1], pos[2] }) catch "speed";
		if (user.anticheatStaff) {
			// Staff fly legitimately; only record truly egregious speeds, as a
			// suspicion for manual review (never enforced).
			suspect(user, .movement, detail);
		} else {
			note(user, .movement, detail);
			// Repeat speeders get kicked: sustained impossible speed is either
			// a hacked client or someone deliberately spamming staff with
			// violation notices. Staff/local are exempt (suspect-only above).
			// Runs on the network thread, so only set the flag — the server
			// thread performs the kick (same pattern as pendingBan).
			if (!user.isLocal) {
				if (now - prof.moveViolationWindowStart > 60_000) {
					prof.moveViolationWindowStart = now;
					prof.moveViolations = 0;
				}
				prof.moveViolations += 1;
				if (prof.moveViolations > 10 and !prof.pendingKick) {
					prof.pendingKick = true;
					note(user, .movement, "repeat speeder: kicking");
				}
			}
		}
		if (enforceMovement) return false;
		return validateMovement(user, pos, now, probe);
	}
	prof.moveViolationStreak = 0;
	return validateMovement(user, pos, now, probe);
}

// --- ASHFRAME CUSTOM (Anticheat: flight pattern) ---
// True for movement that looks like sustained flight rather than walking,
// sprinting, jumping or falling: fast horizontal travel while not in freefall.
// Ghost/fly/hyperspeed are creative-gated client-side, so a server-side
// survival account doing this is spoofing (or desynced). Pure: unit-tested.
pub fn isFlightLike(horizVel: f64, vertVel: f64) bool {
	return horizVel > 12.0 and vertVel > -5.0;
}

// --- ASHFRAME CUSTOM (Anticheat: creative-op abuse) ---
// Windowed counter for gamemode-mismatch abuse: sustained instant-break and
// creative-only packets sent by a server-side survival account. Same shape as
// the movement repeat-speeder kick (server thread performs the kick; network
// code only sets the flag). Runs on the server thread via the command path.
pub fn noteCreativeOp(user: *main.server.User, detail: []const u8) void {
	const now = nowMilliseconds();
	const prof = user.player();
	if (now - prof.creativeOpWindowStart > 60_000) {
		prof.creativeOpWindowStart = now;
		prof.creativeOpViolations = 0;
	}
	prof.creativeOpViolations += 1;
	var buf: [160]u8 = undefined;
	const full = std.fmt.bufPrint(&buf, "creative-op abuse ({d}/min): {s}", .{ prof.creativeOpViolations, detail }) catch "creative-op abuse";
	note(user, .protocol, full);
	if (prof.creativeOpViolations > 10 and !prof.pendingKick and !user.isLocal) {
		prof.pendingKick = true;
		note(user, .protocol, "creative-op abuse: kicking");
	}
}
// --- ASHFRAME CUSTOM (Anticheat v2: server-authoritative movement) ---
// The public cheat client (creative spoof, flight, ghost/noclip, teleport)
// works by flipping client-side flags; the server used to accept any position
// it was told. Position updates are now validated against server-side terrain
// and a failing one sets the player back to their last valid position.
// Survival only: creative, staff and singleplayer are exempt.
//
// Split across two threads:
//  - network thread (`validateMovement`, every position packet): speed, fall
//    speed and flight. These only need the terrain *below* the player.
//  - server thread (`checkNoclipTick`, every tick, after the player's queued
//    block changes ran): noclip/ghost. Done there because a player digging
//    down or walking into a tunnel they just mined is inside a block the
//    server hasn't broken yet until their command is executed.

/// Sustained movement speed for survival. The client caps horizontal speed
/// at the movement speed (sprint 8), so this is ~40% slack.
pub const survivalMoveSpeed: f64 = 11.0;
/// Blocks of movement that may be banked between packets.
pub const moveBurst: f64 = 12.0;
/// Longest packet gap that still earns movement allowance (lossy channel:
/// dropped position packets just make the next one jump further). 5 s covers
/// a wifi dropout while sprinting; a teleport hack would have to wait 5 s for
/// ~67 blocks.
pub const maxMoveGapSeconds: f64 = 5.0;
/// Terminal velocity in air is 90 (physics.zig).
pub const maxFallSpeed: f64 = 95.0;
pub const fallBurst: f64 = 16.0;
/// physics.baseGravity
pub const gravity: f64 = 30.0;
/// Take-off speed of a normal jump: sqrt(2*gravity*jumpHeight), jumpHeight 1.25.
pub const jumpVelocity: f64 = 8.67;
/// Swimming out of a fluid can launch a little harder than a jump.
pub const fluidExitVelocity: f64 = 14.0;
/// Setbacks per minute before the player is kicked.
pub const maxSetbacksPerMinute: u32 = 20;
/// Consecutive ticks a player must be in/through blocks before a noclip
/// setback (covers a block break arriving a little after the position).
pub const noclipTicks: u8 = 3;

pub const Support = enum { none, ground, fluid, unknown };

/// Terrain facts below a position update. Gathered by `probeWorld` *without*
/// `user.mutex` held, since it takes chunk locks.
pub const WorldProbe = struct {
	support: Support = .unknown,
	/// A bouncy block (mushroom caps) is below the feet, within 6 blocks.
	bouncyBelow: bool = false,
};

const Box = main.physics.collision.Box;

/// Standing player box is ±(0.3, 0.3, 0.9) around the position (game.zig).
const bodyExtent = [3]f64{0.3, 0.3, 0.9};
/// Shrunk body for overlap tests, so edge contact and stepping never count.
const coreExtent = [3]f64{0.2, 0.2, 0.6};
/// Path samples between two positions: small vertically so a jump-step up
/// onto a block (up to ~1.25 between samples) never clips its corner.
const pathExtent = [3]f64{0.15, 0.15, 0.2};

fn boxAround(pos: [3]f64, ext: [3]f64) Box {
	return .{
		.min = .{pos[0] - ext[0], pos[1] - ext[1], pos[2] - ext[2]},
		.max = .{pos[0] + ext[0], pos[1] + ext[1], pos[2] + ext[2]},
	};
}

const BoxScan = struct { solid: bool, maxBounce: f32 };

/// Whether `box` overlaps any colliding block's collision model (strictly, as
/// the client's collision does). null if any block in range is not loaded on
/// the server (unknown terrain).
fn scanBox(box: Box) ?BoxScan {
	const world = main.server.world orelse return null;
	const minX = toI32(box.min[0]) orelse return null;
	const minY = toI32(box.min[1]) orelse return null;
	const minZ = toI32(box.min[2]) orelse return null;
	const maxX = toI32(box.max[0]) orelse return null;
	const maxY = toI32(box.max[1]) orelse return null;
	const maxZ = toI32(box.max[2]) orelse return null;
	var result: BoxScan = .{.solid = false, .maxBounce = 0};
	var x = minX;
	while (x <= maxX) : (x += 1) {
		var y = minY;
		while (y <= maxY) : (y += 1) {
			var z = minZ;
			while (z <= maxZ) : (z += 1) {
				const block = world.getBlock(x, y, z) orelse return null;
				if (!block.collide()) continue;
				const origin = main.vec.Vec3d{@floatFromInt(x), @floatFromInt(y), @floatFromInt(z)};
				for (block.mode().model(block).model().collision) |rel| {
					const blockBox: Box = .{.min = rel.min + origin, .max = rel.max + origin};
					if (blockBox.intersects(box)) {
						result.solid = true;
						result.maxBounce = @max(result.maxBounce, block.bounciness());
					}
				}
			}
		}
	}
	return result;
}

/// Gathers the terrain below a position update (network thread).
pub fn probeWorld(pos: [3]f64) WorldProbe {
	var probe: WorldProbe = .{};
	// Ground: anything solid under the exact body footprint (the client keeps
	// an epsilon gap to walls, so a wall the player touches doesn't count; a
	// player crouched over a ledge edge still does), from a bit below the
	// feet to just above them (crouching).
	const ground = scanBox(.{
		.min = .{pos[0] - bodyExtent[0], pos[1] - bodyExtent[1], pos[2] - bodyExtent[2] - 0.35},
		.max = .{pos[0] + bodyExtent[0], pos[1] + bodyExtent[1], pos[2] - 0.8},
	}) orelse return probe;
	// Bouncy blocks are looked for deeper: at 20 Hz a fast fall can skip the
	// sample right above the cap.
	if (ground.maxBounce > 0) {
		probe.bouncyBelow = true;
	} else if (scanBox(.{
		.min = .{pos[0] - bodyExtent[0], pos[1] - bodyExtent[1], pos[2] - bodyExtent[2] - 6.0},
		.max = .{pos[0] + bodyExtent[0], pos[1] + bodyExtent[1], pos[2] - 0.8},
	})) |deep| {
		probe.bouncyBelow = deep.maxBounce > 0;
	}
	if (ground.solid) {
		probe.support = .ground;
	} else {
		var volume: main.physics.collision.VolumeProperties = .{.density = 0, .maxDensity = 0, .mobileFriction = 0, .terminalVelocity = 0};
		const hitBox: Box = .{.min = .{-bodyExtent[0], -bodyExtent[1], -bodyExtent[2]}, .max = bodyExtent};
		main.physics.calculateVolumeProperties(.server, &volume, pos, hitBox, main.physics.playerAirTerminalVelocity);
		// Water and lava carry the player (only blocks denser than air).
		probe.support = if (volume.maxDensity > main.physics.airDensity*1.5) .fluid else .none;
	}
	return probe;
}

pub const AirVerdict = enum { ok, flight };

/// Tracks one airborne phase (time since leaving the ground) and decides
/// whether the vertical motion is physically possible. Pure: unit-tested.
pub const AirState = struct {
	airborne: bool = false,
	startMs: i64 = 0,
	startZ: f64 = 0,
	peakZ: f64 = 0,
	/// Highest height reachable in this phase with the energy it started with.
	ceilingZ: f64 = 0,
	refMs: i64 = 0,
	refZ: f64 = 0,
	hoverStrikes: u8 = 0,
	lastSupport: Support = .ground,
	/// Ceiling carried over a ground contact with a bouncy block, for a short
	/// while after landing (the rebound), so it can't be banked for later.
	bounceCeilingZ: ?f64 = null,
	bounceUntilMs: i64 = 0,

	pub fn reset(self: *AirState) void {
		self.* = .{};
	}

	/// The client froze the player for `ms` (its physics doesn't run while the
	/// chunk at the player isn't loaded yet). Frozen time isn't airtime.
	pub fn pause(self: *AirState, ms: i64) void {
		self.startMs += ms;
		self.refMs += ms;
		if (self.bounceUntilMs != 0) self.bounceUntilMs += ms;
	}

	fn launch(self: *AirState, z: f64, now: i64, ceilingZ: f64) void {
		self.airborne = true;
		self.startMs = now;
		self.startZ = z;
		self.peakZ = z;
		self.ceilingZ = @max(ceilingZ, z);
		self.refMs = now;
		self.refZ = z;
		self.hoverStrikes = 0;
	}

	pub fn step(self: *AirState, support: Support, bouncyBelow: bool, z: f64, now: i64) AirVerdict {
		if (support != .none) {
			var carried: ?f64 = null;
			var until: i64 = 0;
			if (bouncyBelow and self.airborne) {
				carried = @max(self.peakZ, self.ceilingZ);
				until = now + 500;
			} else if (bouncyBelow and now <= self.bounceUntilMs) {
				carried = self.bounceCeilingZ;
				until = self.bounceUntilMs;
			}
			self.reset();
			self.lastSupport = if (support == .unknown) .ground else support;
			self.bounceCeilingZ = carried;
			self.bounceUntilMs = until;
			return .ok;
		}
		if (!self.airborne) {
			const v0: f64 = if (self.lastSupport == .fluid) fluidExitVelocity else jumpVelocity;
			const bounce = if (now <= self.bounceUntilMs) self.bounceCeilingZ orelse z else z;
			self.launch(z, now, @max(z + v0*v0/(2*gravity), bounce));
			return .ok;
		}
		self.peakZ = @max(self.peakZ, z);
		if (bouncyBelow) {
			// Bounce between two samples: a cap (bounciness <= 1) can send the
			// player back up at most to where the fall started. Restart the
			// phase clock but keep that ceiling.
			self.launch(z, now, @max(self.ceilingZ, self.peakZ));
			return .ok;
		}
		// Can't rise above what the take-off energy allows.
		if (z > self.ceilingZ + 1.0) return .flight;
		// Some time after the apex the player must be falling. Checked over
		// 0.5 s windows; two failing windows in a row so one lag burst can't
		// trip it. A real fall descends 5+ blocks per window by then (and
		// faster the longer it lasts), so long falls are never affected.
		const t = @as(f64, @floatFromInt(now - self.startMs))/1000.0;
		const timeToApex = @sqrt(2*@max(self.ceilingZ - self.startZ, 0)/gravity);
		if (now - self.refMs >= 500) {
			const descent = self.refZ - z;
			if (t >= timeToApex + 0.6 and descent < 2.5) {
				self.hoverStrikes +|= 1;
				if (self.hoverStrikes >= 2) return .flight;
			} else {
				self.hoverStrikes = 0;
			}
			self.refMs = now;
			self.refZ = z;
		}
		return .ok;
	}
};

/// Forget all movement history and trust `pos` (server teleports, gamemode
/// changes, exempt players). Caller holds `user.mutex`.
pub fn resetMovementState(user: *main.server.User, pos: [3]f64, now: i64) void {
	user.acLastGood = pos;
	user.acLastGoodTime = now;
	user.acMoveBudget = moveBurst;
	user.acFallBudget = fallBurst;
	user.acAir.reset();
	user.acSetbackPos = null;
	user.acGroundPos = null;
	user.acNoclipReset = true;
}

fn isExempt(user: *main.server.User) bool {
	return movementMode() == .off or user.isLocal or user.anticheatStaff or user.gamemode.load(.monotonic) == .creative;
}

/// Sends the player back to `target` and ignores their positions until the
/// client reports being there. Caller holds `user.mutex`. Returns whether the
/// reported position `pos` is accepted.
/// In log mode nothing happens to the player: the would-be setback is logged
/// as a review-only suspect and `pos` becomes the new baseline (v1 behaviour).
fn setback(user: *main.server.User, target: [3]f64, pos: [3]f64, now: i64, detail: []const u8) bool {
	if (movementMode() != .enforce) {
		var buf: [200]u8 = undefined;
		suspect(user, .movement, std.fmt.bufPrint(&buf, "{s} (log only)", .{detail}) catch detail);
		resetMovementState(user, pos, now);
		return true;
	}
	user.acSetbackPos = target;
	user.acSetbackSentMs = now;
	user.acSetbackStartMs = now;
	user.acLastGood = target;
	user.acLastGoodTime = now;
	// Empty, not refilled: otherwise a speed hack that keeps getting set back
	// would get a fresh 12 block burst each time.
	user.acMoveBudget = 0;
	user.acFallBudget = fallBurst;
	user.acAir.reset();
	user.acNoclipReset = true;
	user.acInSetback = true;
	main.network.protocols.genericUpdate.sendTPCoordinates(user.conn, target);
	user.acInSetback = false;
	note(user, .movement, detail);
	if (now - user.acSetbackWindowStart > 60_000) {
		user.acSetbackWindowStart = now;
		user.acSetbacks = 0;
	}
	user.acSetbacks += 1;
	const prof = user.player();
	if (user.acSetbacks > maxSetbacksPerMinute and !prof.pendingKick) {
		prof.pendingKick = true;
		note(user, .movement, "repeated illegal movement: kicking");
	}
	return false;
}

/// Distance allowed for one packet: the banked part (capped at `burst`) plus
/// `rate` times the time since the last accepted packet. Pure: unit-tested.
pub fn allowance(banked: f64, burst: f64, dt: f64, rate: f64) f64 {
	return @min(banked, burst) + dt*rate;
}

fn distance(a: [3]f64, b: [3]f64) f64 {
	const d = [3]f64{a[0] - b[0], a[1] - b[1], a[2] - b[2]};
	return @sqrt(d[0]*d[0] + d[1]*d[1] + d[2]*d[2]);
}

/// Server-authoritative movement validation (network thread). Returns true if
/// the position is accepted. Caller holds `user.mutex`.
pub fn validateMovement(user: *main.server.User, pos: [3]f64, now: i64, probe: WorldProbe) bool {
	if (isExempt(user)) {
		resetMovementState(user, pos, now);
		return true;
	}
	if (user.acSetbackPos) |target| {
		// Accept again once the client has applied the teleport. Budgets are
		// kept (see `setback`); they refill from the setback time.
		if (distance(pos, target) <= 2.0) {
			user.acSetbackPos = null;
			user.acLastGood = pos;
			user.acAir.reset();
			return true;
		}
		if (now - user.acSetbackSentMs > 1000) {
			user.acSetbackSentMs = now;
			main.network.protocols.genericUpdate.sendTPCoordinates(user.conn, target);
		}
		// A client that keeps ignoring the setback is modified (a real one
		// applies it within a round trip).
		if (now - user.acSetbackStartMs > 15_000 and !user.player().pendingKick) {
			user.player().pendingKick = true;
			note(user, .movement, "ignoring movement setback: kicking");
		}
		return false;
	}
	const last = user.acLastGood orelse {
		resetMovementState(user, pos, now);
		return true;
	};
	var buf: [160]u8 = undefined;
	const elapsedMs = @max(now - user.acLastGoodTime, 0);
	const dt = @as(f64, @floatFromInt(elapsedMs))/1000.0;
	const dx = pos[0] - last[0];
	const dy = pos[1] - last[1];
	const dz = pos[2] - last[2];

	// Frozen: the client doesn't run physics while the chunk at the player
	// isn't loaded yet (physics.calculateMotion), e.g. after joining or a
	// teleport, and keeps sending the exact same position. Nothing to judge;
	// the frozen time just doesn't count as airtime.
	if (dx == 0 and dy == 0 and dz == 0) {
		user.acAir.pause(elapsedMs);
		user.acMoveBudget = @min(moveBurst, user.acMoveBudget + dt*survivalMoveSpeed);
		user.acFallBudget = @min(fallBurst, user.acFallBudget + dt*maxFallSpeed);
		user.acLastGoodTime = now;
		return true;
	}

	// Speed / teleport: horizontal travel (and rising not explained by a
	// jump or bounce) is paid from an allowance: what was banked (capped)
	// plus sprint-speed-and-slack times the time since the last packet.
	// Falling has its own allowance at terminal velocity. The current gap is
	// always fully credited, so lag or dropped packets don't trip it.
	const moveAllowance = allowance(user.acMoveBudget, moveBurst, @min(dt, maxMoveGapSeconds), survivalMoveSpeed);
	const fallAllowance = allowance(user.acFallBudget, fallBurst, dt, maxFallSpeed);
	// Rising within the current jump/bounce's energy ceiling is physics, not
	// speed (a big mushroom bounce rises ~40 b/s); the flight check owns it.
	const rise = if (user.acAir.airborne and pos[2] <= user.acAir.ceilingZ + 1.0) 0 else @max(dz, 0);
	const travel = @sqrt(dx*dx + dy*dy + rise*rise);
	const fall = @max(-dz, 0);
	if (travel > moveAllowance) {
		const detail = std.fmt.bufPrint(&buf, "moved {d:.1} blocks in {d:.2}s at {d:.0},{d:.0},{d:.0}", .{travel, dt, pos[0], pos[1], pos[2]}) catch "too fast";
		return setback(user, last, pos, now, detail);
	}
	if (fall > fallAllowance) {
		const detail = std.fmt.bufPrint(&buf, "dropped {d:.1} blocks in {d:.2}s at {d:.0},{d:.0},{d:.0}", .{fall, dt, pos[0], pos[1], pos[2]}) catch "fell too fast";
		return setback(user, last, pos, now, detail);
	}

	// Flight: rising too high or not falling while airborne.
	if (user.acAir.step(probe.support, probe.bouncyBelow, pos[2], now) == .flight) {
		const detail = std.fmt.bufPrint(&buf, "flying at {d:.0},{d:.0},{d:.0}", .{pos[0], pos[1], pos[2]}) catch "flight";
		// Back to the ground they left, if it's nearby; else the last spot.
		var target = last;
		if (user.acGroundPos) |g| {
			if (distance(g, pos) < 64) target = g;
		}
		return setback(user, target, pos, now, detail);
	}

	user.acMoveBudget = moveAllowance - travel;
	user.acFallBudget = fallAllowance - fall;
	user.acLastGood = pos;
	user.acLastGoodTime = now;
	if (probe.support == .ground) user.acGroundPos = pos;
	return true;
}

/// Noclip / ghost check (server thread, once per tick, after this player's
/// queued commands - including block breaks - have been executed). Flags a
/// player whose body is inside solid blocks, or whose path from their last
/// clean position crosses solid blocks, for `noclipTicks` ticks in a row.
/// Must be called without `user.mutex` held.
pub fn checkNoclipTick(user: *main.server.User) void {
	user.mutex.lock();
	const pos = user.acLastGood;
	if (user.acNoclipReset or isExempt(user) or user.acSetbackPos != null or user.teleportGraceUntil > nowMilliseconds() or teleportPending(user)) {
		user.acNoclipReset = false;
		user.acNoclipSafePos = null;
		user.acNoclipStrikes = 0;
		user.mutex.unlock();
		return;
	}
	const safe = user.acNoclipSafePos;
	user.mutex.unlock();
	const p = pos orelse return;

	// World reads without our mutex (they take chunk locks).
	const body = scanBox(boxAround(p, coreExtent)) orelse return;
	var crossed = false;
	var safeNowInside = false;
	if (safe) |s| {
		safeNowInside = if (scanBox(boxAround(s, coreExtent))) |r| r.solid else true;
		const d = [3]f64{p[0] - s[0], p[1] - s[1], p[2] - s[2]};
		const dist = @sqrt(d[0]*d[0] + d[1]*d[1] + d[2]*d[2]);
		// Samples every 0.3 blocks so thin walls can't be skipped.
		const steps: u32 = @intFromFloat(@min(40.0, @ceil(dist/0.3)));
		var i: u32 = 1;
		while (i < steps) : (i += 1) {
			const t = @as(f64, @floatFromInt(i))/@as(f64, @floatFromInt(steps));
			const q = [3]f64{s[0] + d[0]*t, s[1] + d[1]*t, s[2] + d[2]*t};
			if (scanBox(boxAround(q, pathExtent))) |r| {
				if (r.solid) {
					crossed = true;
					break;
				}
			}
		}
	}

	user.mutex.lock();
	defer user.mutex.unlock();
	// A setback/reset happened meanwhile on the network thread: start over.
	if (user.acNoclipReset or user.acSetbackPos != null) return;
	if (!body.solid and !crossed) {
		user.acNoclipSafePos = p;
		user.acNoclipStrikes = 0;
		return;
	}
	// No clean reference, or the world changed under the reference spot (a
	// block was placed onto the player): can't judge, wait until they're out.
	if (safe == null or safeNowInside) {
		user.acNoclipSafePos = null;
		user.acNoclipStrikes = 0;
		return;
	}
	user.acNoclipStrikes +|= 1;
	if (user.acNoclipStrikes < noclipTicks) return;
	user.acNoclipStrikes = 0;
	var buf: [160]u8 = undefined;
	const detail = std.fmt.bufPrint(&buf, "moved through blocks at {d:.0},{d:.0},{d:.0}", .{p[0], p[1], p[2]}) catch "noclip";
	_ = setback(user, safe.?, p, nowMilliseconds(), detail);
}
// --- ASHFRAME CUSTOM (Anticheat v2: server-authoritative movement) ---

// --- ASHFRAME CUSTOM (Anticheat v2: break-speed budget) ---
// Fast mine, nuker and creative-spoof instant break all send block breaks
// faster than the tool allows. Each break costs (most of) the time the client
// itself would need for it (same formula as renderer.zig breakBlock), paid
// from a per-player budget that refills in real time. Scales with the tool,
// so god-tier pickaxes are fine; the burst absorbs lag batching.

/// Fraction of the real break time charged per block (client frame/tick slack).
pub const mineCostFactor: f64 = 0.7;
/// Seconds of mining that can be banked. Sized for lag: breaks queued during
/// a ~5 s network stall arrive together (5 s * mineCostFactor = 3.5 s). A
/// nuker gets ~10 extra blocks once, then is held to the tool's real rate.
pub const mineBurst: f64 = 4.0;
/// Rejected breaks per minute before the player is kicked.
pub const maxMiningRejectsPerMinute: u32 = 60;

/// Seconds a legitimate client needs to break `block` with `stack`.
pub fn breakSeconds(block: main.blocks.Block, stack: main.items.ItemStack) f64 {
	var damage: f32 = main.game.Player.defaultBlockDamage;
	var swingTime: f32 = 0.5;
	if (stack.item == .proceduralItem) {
		const tool = stack.item.proceduralItem;
		damage = tool.getBlockDamage(block);
		const swingSpeed = tool.getProperty(.swingSpeed);
		if (tool.isEffectiveOn(block) and swingSpeed > 0) swingTime = 1.0/swingSpeed;
	}
	damage -= block.blockResistance();
	// Not breakable with this tool: canBeChangedInto already decides that.
	if (damage <= 0) return 0;
	return block.blockHealth()/damage*swingTime;
}

/// Pays for one block break. Pure budget arithmetic: unit-tested.
pub fn spendMineBudget(budget: *f64, lastMs: *i64, now: i64, cost: f64) bool {
	const dt = @as(f64, @floatFromInt(@max(now - lastMs.*, 0)))/1000.0;
	budget.* = @min(mineBurst, budget.* + dt);
	lastMs.* = now;
	if (cost <= budget.*) {
		budget.* -= cost;
		return true;
	}
	return false;
}

/// Returns true if this break is allowed. Server thread only (command path).
pub fn checkBreak(user: *main.server.User, block: main.blocks.Block, stack: main.items.ItemStack) bool {
	const mode = miningMode();
	if (mode == .off or user.isLocal or user.gamemode.load(.monotonic) == .creative) return true;
	const now = nowMilliseconds();
	const cost = breakSeconds(block, stack)*mineCostFactor;
	if (spendMineBudget(&user.acMineBudget, &user.acMineLastMs, now, cost)) return true;
	var buf: [160]u8 = undefined;
	const detail = std.fmt.bufPrint(&buf, "breaking too fast ({d:.2}s block, budget {d:.2}s)", .{cost/mineCostFactor, user.acMineBudget}) catch "breaking too fast";
	if (mode != .enforce) {
		// Log mode (v1 behaviour): review-only, the break goes through.
		var logBuf: [200]u8 = undefined;
		suspect(user, .mining, std.fmt.bufPrint(&logBuf, "{s} (log only)", .{detail}) catch detail);
		return true;
	}
	note(user, .mining, detail);
	if (now - user.acMineRejectWindowStart > 60_000) {
		user.acMineRejectWindowStart = now;
		user.acMineRejects = 0;
	}
	user.acMineRejects += 1;
	const prof = user.player();
	if (user.acMineRejects > maxMiningRejectsPerMinute and !prof.pendingKick) {
		prof.pendingKick = true;
		note(user, .mining, "repeated fast mining/nuker: kicking");
	}
	return false;
}
// --- ASHFRAME CUSTOM (Anticheat v2: break-speed budget) ---

// --- ASHFRAME CUSTOM (Anticheat test harness) ---
test {
	_ = @import("anticheat_test.zig");
}
// --- ASHFRAME CUSTOM (Anticheat) ---
