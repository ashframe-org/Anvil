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

pub const Category = enum { protocol, movement, reach, inventory, chat, rate };

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
		.movement, .rate => 1000,
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

// --- Wave-2 enforcement switches (off = log only) ---
// Reach is log-only: the server checks against its own interpolated player
// position, which lags the client by a frame or more, so legitimate
// max-reach interactions trip it regularly. Kept as a review signal only.
pub var enforceReach: bool = false;
// Movement stays log-only: with no server-side physics, rejecting movement
// risks rubber-banding legitimate players on a bad connection.
pub var enforceMovement: bool = false;

/// How far a player may be from a block they interact with. Generous to allow
/// for interpolation/lag (the server-side position trails the client);
/// real reach is ~6 blocks.
pub const reachRadius: f64 = 12.0;

/// Whether `block` (x, z, vertical) is within `radius` of `pos` (x, z, vertical).
pub fn withinReach(pos: [3]f64, block: [3]i32, radius: f64) bool {
	const dx = @as(f64, @floatFromInt(block[0])) - pos[0];
	const dz = @as(f64, @floatFromInt(block[1])) - pos[1];
	const dv = @as(f64, @floatFromInt(block[2])) - pos[2];
	return dx*dx + dz*dz + dv*dv <= radius*radius;
}

/// Reach check for a block interaction. Returns true if the action should be
/// allowed. Out-of-reach is recorded as a review-only suspicion (never
/// enforced, never operator-paged): the server-side position lags the client,
/// so legitimate play trips it.
pub fn checkReach(user: *main.server.User, block: [3]i32) bool {
	const pos = user.player().pos;
	if (withinReach(pos, block, reachRadius)) return true;
	var buf: [160]u8 = undefined;
	const detail = std.fmt.bufPrint(&buf, "block {d},{d},{d} vs pos {d:.1},{d:.1},{d:.1}", .{ block[0], block[1], block[2], pos[0], pos[1], pos[2] }) catch "out of reach";
	suspect(user, .reach, detail);
	return !enforceReach;
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

/// Movement check: logs (and, in wave 2, rejects) speeds a legitimate client
/// can't reach. Returns true if the movement should be accepted.
pub fn checkMovement(user: *main.server.User, pos: [3]f64, vel: [3]f64) bool {
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
	if (user.teleportGraceUntil > now) return true;
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
		if (prof.moveViolationStreak < 3) return !enforceMovement;
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
		return !enforceMovement;
	}
	prof.moveViolationStreak = 0;
	return true;
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
// --- ASHFRAME CUSTOM (Anticheat test harness) ---
test {
	_ = @import("anticheat_test.zig");
}
// --- ASHFRAME CUSTOM (Anticheat) ---
