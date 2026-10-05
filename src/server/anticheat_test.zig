const std = @import("std");

const main = @import("main");

const anticheat = main.server.anticheat;
const command = main.server.command;

// --- ASHFRAME CUSTOM (Anticheat test harness) ---
// A scripted "cheat" suite. Each case feeds a hostile input to the anticheat /
// validation layer and records what was sent, the result, and whether it was
// blocked. Run with:
//
//   zig build test -Doptimize=ReleaseSafe
//   tools/run_anticheat_tests.sh          (writes tools/anticheat-test-report.txt)
//
// Scope: the validation/deserialization layer directly. The network wire is not
// simulated and cases that need a live server/user must be tested by hand (see
// the exploit catalogue in the README).

fn report(name: []const u8, sent: []const u8, result: []const u8, blocked: bool, pass: bool) !void {
	std.debug.print("[cheat-test] {s:<42} sent={s:<22} result={s:<20} {s:<8} {s}\n", .{
		name, sent, result, if (blocked) "BLOCKED" else "ALLOWED", if (pass) "PASS" else "FAIL <<<",
	});
	try std.testing.expect(pass);
}

/// For boolean validators: `accepted` is what the validator returned, so the
/// server "blocked" the input when it did not accept it.
fn check(name: []const u8, sent: []const u8, accepted: bool, expectAccepted: bool) !void {
	try report(name, sent, if (accepted) "accepted" else "rejected", !accepted, accepted == expectAccepted);
}

test "cheat: malformed position is rejected" {
	const nan = std.math.nan(f64);
	const inf = std.math.inf(f64);
	try check("position NaN x", "nan,0,0", anticheat.validPosition(.{ nan, 0, 0 }), false);
	try check("position Inf z", "0,0,inf", anticheat.validPosition(.{ 0, 0, inf }), false);
	try check("position x beyond 1e9", "2e9,0,0", anticheat.validPosition(.{ 2e9, 0, 0 }), false);
	try check("position vertical beyond 1e5", "0,0,2e5", anticheat.validPosition(.{ 0, 0, 2e5 }), false);
	try check("position normal", "10,-5,64", anticheat.validPosition(.{ 10, -5, 64 }), true);
}

test "cheat: malformed velocity is rejected" {
	const nan = std.math.nan(f64);
	try check("velocity NaN", "nan,0,0", anticheat.validVelocity(.{ nan, 0, 0 }), false);
	try check("velocity 2e6 (>1e6)", "2e6,0,0", anticheat.validVelocity(.{ 2e6, 0, 0 }), false);
	try check("velocity normal", "128,-3,0", anticheat.validVelocity(.{ 128, -3, 0 }), true);
}

test "cheat: malformed rotation is rejected" {
	const nan = std.math.nan(f32);
	const inf = std.math.inf(f32);
	try check("rotation NaN", "nan,0,0", anticheat.validRotation(.{ nan, 0, 0 }), false);
	try check("rotation Inf", "0,inf,0", anticheat.validRotation(.{ 0, inf, 0 }), false);
	try check("rotation normal", "0.5,0,1", anticheat.validRotation(.{ 0.5, 0, 1 }), true);
}

test "cheat: checked float->int conversion" {
	try std.testing.expect(anticheat.toI32(std.math.nan(f64)) == null);
	try std.testing.expect(anticheat.toI32(1e10) == null);
	try std.testing.expectEqual(@as(?i32, 5), anticheat.toI32(5.9));
	try std.testing.expectEqual(@as(?i32, -6), anticheat.toI32(-5.9));
	try report("toI32 nan/1e10/5.9/-5.9", "nan,1e10,5.9,-5.9", "null,null,5,-6", true, true);
}

test "cheat: token bucket limits bursts" {
	var bucket: anticheat.TokenBucket = .{ .tokens = 3, .capacity = 3, .refillPerSec = 0 };
	const firstThree = bucket.allow(0) and bucket.allow(0) and bucket.allow(0);
	const fourth = bucket.allow(0);
	try report("rate limit burst (4 at once)", "capacity=3 refill=0", if (fourth) "4 allowed" else "4th rejected", true, firstThree and !fourth);
}

test "cheat: reach radius" {
	const near = anticheat.withinReach(.{ 0, 0, 0 }, .{ 4, 0, 0 }, anticheat.reachRadius);
	const far = anticheat.withinReach(.{ 0, 0, 0 }, .{ 100, 0, 0 }, anticheat.reachRadius);
	try report("reach 4 blocks", "dist 4", if (near) "in reach" else "out of reach", true, near);
	try report("reach 100 blocks", "dist 100", if (far) "in reach" else "out of reach", true, !far);
}

test "cheat: command coordinates validated and clamped" {
	{
		const r = command.resolveCoordinates(.{ .absolute = std.math.nan(f64) }, .{ .absolute = 0 }, .{ .absolute = 0 }, .server);
		const rejected = blk: {
			_ = r catch |e| break :blk e == error.InvalidArg;
			break :blk false;
		};
		try report("cmd coord NaN x", "nan,0,0", if (rejected) "error.InvalidArg" else "accepted", true, rejected);
	}
	{
		const p = command.resolveCoordinates(.{ .absolute = 1e12 }, .{ .absolute = 0 }, .{ .absolute = 1e12 }, .server) catch unreachable;
		const clamped = p[0] == anticheat.maxHorizontal and p[2] == anticheat.maxVertical;
		try report("cmd coord huge", "1e12,0,1e12", "clamped to anticheat bounds", false, clamped);
	}
	{
		const r = command.resolveRotation(.{ .absolute = 0 }, .{ .absolute = std.math.nan(f32) }, .server);
		const rejected = blk: {
			_ = r catch |e| break :blk e == error.InvalidArg;
			break :blk false;
		};
		try report("cmd pitch NaN", "yaw=0 pitch=nan", if (rejected) "error.InvalidArg" else "accepted", true, rejected);
	}
	{
		const rot = command.resolveRotation(.{ .absolute = 100 }, .{ .absolute = 100 }, .server) catch unreachable;
		const clamped = @abs(rot[2]) <= std.math.pi/2.0;
		try report("cmd pitch huge", "yaw=100 pitch=100", "clamped", false, clamped);
	}
}

test "cheat: crafted blueprint header rejected" {
	// Header layout (big-endian, see utils.BinaryReader): version u16,
	// compression enum(u16), paletteBytes u32, paletteCount u32, w/d/h u16.
	const header = struct {
		fn make(version: u16, paletteBytes: u32, paletteCount: u32, w: u16, d: u16, h: u16) [18]u8 {
			var buf: [18]u8 = undefined;
			std.mem.writeInt(u16, buf[0..2], version, .big);
			std.mem.writeInt(u16, buf[2..4], 0, .big); // deflate
			std.mem.writeInt(u32, buf[4..8], paletteBytes, .big);
			std.mem.writeInt(u32, buf[8..12], paletteCount, .big);
			std.mem.writeInt(u16, buf[12..14], w, .big);
			std.mem.writeInt(u16, buf[14..16], d, .big);
			std.mem.writeInt(u16, buf[16..18], h, .big);
			return buf;
		}
		fn rejected(buf: *const [18]u8) bool {
			_ = main.blueprint.Blueprint.load(main.heap.testingAllocator, buf) catch |e| return e == error.InvalidBlueprint;
			return false;
		}
	};
	const hugeDims = header.make(1, 0, 0, 0xFFFF, 0xFFFF, 0xFFFF);
	try report("blueprint 65535^3 dims", "w=d=h=65535", "error.InvalidBlueprint", true, header.rejected(&hugeDims));
	const hugePalette = header.make(1, 0, 100_000, 1, 1, 1);
	try report("blueprint palette count 100000", "palette=100000", "error.InvalidBlueprint", true, header.rejected(&hugePalette));
}

test "cheat: chat filter word boundaries" {
	const slur = main.server.chatfilter.findBad("you are a faggot") != null;
	const notFalsePositive = main.server.chatfilter.findBad("this skyscraper is tall") != null;
	const clean = main.server.chatfilter.findBad("good morning everyone") != null;
	try report("chatfilter slur", "faggot", if (slur) "matched" else "clean", true, slur);
	try report("chatfilter 'kys' inside 'skyscraper'", "skyscraper", if (notFalsePositive) "matched" else "clean", false, !notFalsePositive);
	try report("chatfilter clean text", "good morning everyone", if (clean) "matched" else "clean", false, !clean);
}

test "cheat: chat filter numbers are not slurs" {
	// Regression: "900k" leet-normalised to "gook" (9->g, 0->o) and struck an
	// innocent player. Pure-number tokens must never match.
	const num1 = main.server.chatfilter.findBad("i have 900k orbs") != null;
	try report("chatfilter '900k' clean", "900k", if (num1) "matched" else "clean", false, !num1);
	const num2 = main.server.chatfilter.findBad("selling 10m stone") != null;
	try report("chatfilter '10m' clean", "10m", if (num2) "matched" else "clean", false, !num2);
	const num3 = main.server.chatfilter.findBad("80085") != null;
	try report("chatfilter '80085' clean", "80085", if (num3) "matched" else "clean", false, !num3);
	// Real leet evasions still match: mixed letter+digit tokens are mapped.
	const evade1 = main.server.chatfilter.findBad("you g00k") != null;
	try report("chatfilter 'g00k' matched", "g00k", if (evade1) "matched" else "clean", true, evade1);
	const evade2 = main.server.chatfilter.findBad("you are a f4g") != null;
	try report("chatfilter 'f4g' matched", "f4g", if (evade2) "matched" else "clean", true, evade2);
	const real = main.server.chatfilter.findBad("you are a gook") != null;
	try report("chatfilter plain 'gook' matched", "gook", if (real) "matched" else "clean", true, real);
}

test "cheat: chat filter phrases respect word boundaries" {
	// Regression: "lon(g as the)re" matched "gas the" on the space-stripped
	// text and struck the Discord relay bot into a ban.
	const innocent = main.server.chatfilter.findBad("derperu: As long as there is money to be made") != null;
	try report("chatfilter 'long as there' clean", "long as there", if (innocent) "matched" else "clean", false, !innocent);
	const phrase = main.server.chatfilter.findBad("gas the lot of them") != null;
	try report("chatfilter phrase matched", "gas the", if (phrase) "matched" else "clean", true, phrase);
	const glued = main.server.chatfilter.findBad("just killYourself") != null;
	try report("chatfilter glued phrase matched", "killYourself", if (glued) "matched" else "clean", true, glued);
	const spelled = main.server.chatfilter.findBad("k i l l y o u r s e l f") != null;
	try report("chatfilter spelled-out phrase matched", "k i l l ...", if (spelled) "matched" else "clean", true, spelled);
}

test "cheat: relay bot can't be struck or banned" {
	const botKey = "ed25519:tXajORkxhbvHEcysimVBh12MG3Wq8M+VJ9jitttwGU8=";
	const protectedBot = main.server.chatfilter.isProtected(botKey);
	try report("relay bot key is protected", "Discord", if (protectedBot) "protected" else "not protected", true, protectedBot);
	// isBanned returns before consulting the list, so name bans can't stick either.
	const banned = main.server.chatfilter.isBanned("Discord", botKey);
	try report("protected key never banned", "Discord", if (banned) "banned" else "not banned", false, !banned);
	const other = main.server.chatfilter.isProtected("ed25519:someoneElse=");
	try report("other keys not protected", "someoneElse", if (other) "protected" else "not protected", false, !other);
}

test "cheat: only Argon or vanilla 0.4.1 may join" {
	const cases = [_]struct { name: []const u8, argon: bool, protected: bool, version: []const u8, allow: bool }{
		.{ .name = "vanilla 0.4.1", .argon = false, .protected = false, .version = "0.4.1", .allow = true },
		.{ .name = "vanilla 0.4.1-dev", .argon = false, .protected = false, .version = "0.4.1-dev", .allow = true },
		.{ .name = "argon on any version", .argon = true, .protected = false, .version = "0.4.1-dev", .allow = true },
		.{ .name = "relay bot on 0.4.0", .argon = false, .protected = true, .version = "0.4.0", .allow = true },
		.{ .name = "vanilla 0.5.0-dev", .argon = false, .protected = false, .version = "0.5.0-dev", .allow = false },
		.{ .name = "vanilla 0.5.0", .argon = false, .protected = false, .version = "0.5.0", .allow = false },
		.{ .name = "vanilla 0.4.0", .argon = false, .protected = false, .version = "0.4.0", .allow = false },
	};
	for (cases) |case| {
		const ok = main.server.User.clientAllowed(case.argon, case.protected, case.version);
		try report(case.name, case.version, if (ok) "allowed" else "refused", !case.allow, ok == case.allow);
	}
}

test "cheat: ban lookup with no bans" {
	const banned = main.server.chatfilter.isBanned("CleanPlayer", null);
	try report("ban lookup (empty list)", "CleanPlayer", if (banned) "banned" else "not banned", false, !banned);
}

test "cheat: decorated ban round-trips through plain unban" {
	// Regression: `#rrggbb` hex digits used to leak into stored ban names, so
	// the ban enforced but `/unban <plain>` reported "no ban found".
	const decorated = "#d1f1ffx#8cc2e9d#5192d5o#2660bdk#2056b7u#192c9cx";
	main.server.chatfilter.ban(decorated, null, false);
	const bannedPlain = main.server.chatfilter.isBanned("xdokux", null);
	try report("decorated ban matches plain name", "xdokux", if (bannedPlain) "banned" else "not banned", true, bannedPlain);
	const unbanned = main.server.chatfilter.unban("xdokux");
	try report("plain unban clears decorated ban", "xdokux", if (unbanned) "unbanned" else "not found", true, unbanned);
	const gone = !main.server.chatfilter.isBanned("xdokux", null);
	try report("decorated ban gone after unban", "xdokux", if (gone) "clear" else "still banned", true, gone);
	main.server.chatfilter.resetForTests();
	main.server.report.resetForTests();
}

test "cheat: chat filter leetspeak and color noise" {
	const leet = main.server.chatfilter.findBad("you are a f4g") != null;
	try report("chatfilter leet f4g", "f4g", if (leet) "matched" else "clean", true, leet);
	const leetLong = main.server.chatfilter.findBad("n1gger") != null;
	try report("chatfilter leet n1gger", "n1gger", if (leetLong) "matched" else "clean", true, leetLong);
	const colorNoise = main.server.chatfilter.findBad("#fff hello there") != null;
	try report("chatfilter color noise clean", "#fff hello", if (colorNoise) "matched" else "clean", false, !colorNoise);
}

test "cheat: flight pattern predicate" {
	// Fly/ghost envelope: fast horizontal, not falling.
	try check("flight hover 32,0", "32,0", anticheat.isFlightLike(32.0, 0.0), true);
	try check("flight ghost 128,0", "128,0", anticheat.isFlightLike(128.0, 0.0), true);
	try check("flight ascend 20,10", "20,10", anticheat.isFlightLike(20.0, 10.0), true);
	// Legit: sprint (~8), walk, jump arcs, freefall (~-90).
	try check("sprint 8,0", "8,0", anticheat.isFlightLike(8.0, 0.0), false);
	try check("walk 4.5,0", "4.5,0", anticheat.isFlightLike(4.5, 0.0), false);
	try check("fall 5,-90", "5,-90", anticheat.isFlightLike(5.0, -90.0), false);
	try check("fast fall drift 20,-50", "20,-50", anticheat.isFlightLike(20.0, -50.0), false);
	try check("idle 0,0", "0,0", anticheat.isFlightLike(0.0, 0.0), false);
}

// --- ASHFRAME CUSTOM (Anticheat v2 cases) ---
// Mirrors the public cheat client's features: flight / ghost (hovering, rising),
// reach slider, fast mine / nuker. Each case also checks the matching legit
// behaviour stays allowed.

/// Feeds an airborne trajectory z(t) to AirState at 20 Hz; true if flagged.
fn flagsFlight(launchSupport: anticheat.Support, bouncy: bool, durationMs: i64, comptime zAt: fn (f64) f64) bool {
	var air: anticheat.AirState = .{};
	_ = air.step(launchSupport, false, zAt(0), 0);
	var now: i64 = 50;
	while (now <= durationMs) : (now += 50) {
		const t = @as(f64, @floatFromInt(now))/1000.0;
		if (air.step(.none, bouncy, zAt(t), now) == .flight) return true;
	}
	return false;
}

fn jumpArc(t: f64) f64 {
	return 64 + anticheat.jumpVelocity*t - 0.5*anticheat.gravity*t*t;
}
fn hover(t: f64) f64 {
	_ = t;
	return 64;
}
fn flyUp(t: f64) f64 {
	return 64 + 6*t;
}
fn slowFall(t: f64) f64 {
	return 64 - 1.5*t;
}
fn glide(t: f64) f64 {
	return 64 - 4*t;
}
fn cliffFall(t: f64) f64 {
	return 64 - 0.5*anticheat.gravity*t*t;
}
/// Falls 30 blocks onto a mushroom cap (top at z=34, bounciness 1), rebounds
/// back up near the start height and falls again. The cap is only "below" the
/// player within the probe's 6 block scan. `groundSample` puts one sample on
/// the cap itself. True if flagged.
fn bounceFlagged(groundSample: bool) bool {
	var air: anticheat.AirState = .{};
	_ = air.step(.ground, false, 64, 0);
	const fallTime = @sqrt(2*30/anticheat.gravity);
	const v = anticheat.gravity*fallTime;
	var now: i64 = 50;
	while (now <= 5000) : (now += 50) {
		const t = @as(f64, @floatFromInt(now))/1000.0;
		const z = if (t < fallTime) 64 - 0.5*anticheat.gravity*t*t else blk: {
			const r = t - fallTime;
			break :blk 34 + v*r - 0.5*anticheat.gravity*r*r;
		};
		const nearCap = z - 34 < 6;
		const support: anticheat.Support = if (groundSample and z - 34 < 2.5) .ground else .none;
		if (air.step(support, nearCap, @max(z, 34), now) == .flight) return true;
	}
	return false;
}

test "cheat: flight / ghost hover is caught" {
	try check("hover in place 3s", "z const", !flagsFlight(.ground, false, 3000, hover), false);
	try check("fly upward 6 b/s", "z += 6/s", !flagsFlight(.ground, false, 3000, flyUp), false);
	try check("slow-fall 1.5 b/s", "z -= 1.5/s", !flagsFlight(.ground, false, 3000, slowFall), false);
	try check("glide 4 b/s", "z -= 4/s", !flagsFlight(.ground, false, 3000, glide), false);
	try check("swim out of water", "parabola", !flagsFlight(.fluid, false, 550, jumpArc), true);
	try check("normal jump", "parabola", !flagsFlight(.ground, false, 550, jumpArc), true);
	try check("fall off a cliff 3s", "freefall", !flagsFlight(.ground, false, 3000, cliffFall), true);
	try check("30 block mushroom bounce", "rebound", !bounceFlagged(false), true);
	try check("bounce w/ sample on cap", "rebound", !bounceFlagged(true), true);
}

test "cheat: reach slider is caught" {
	const pos = [3]f64{ 0.5, 0.5, 0.9 };
	try check("reach 6 (legit max)", "6 blocks", anticheat.eyeToBlockDistance(pos, .{ 6, 0, 1 }) <= anticheat.eyeReach, true);
	try check("reach 10 (cheat slider)", "10 blocks", anticheat.eyeToBlockDistance(pos, .{ 10, 0, 1 }) <= anticheat.eyeReach, false);
	try check("reach 256 (cheat max)", "256 blocks", anticheat.eyeToBlockDistance(pos, .{ 256, 0, 1 }) <= anticheat.eyeReach, false);
}

/// Breaks `count` blocks needing `blockSeconds` each at `interval` ms apart and
/// returns how many the budget accepted.
fn minedBlocks(count: u32, blockSeconds: f64, intervalMs: i64) u32 {
	var budget: f64 = anticheat.mineBurst;
	var last: i64 = 0;
	var accepted: u32 = 0;
	var now: i64 = 0;
	for (0..count) |_| {
		now += intervalMs;
		if (anticheat.spendMineBudget(&budget, &last, now, blockSeconds*anticheat.mineCostFactor)) accepted += 1;
	}
	return accepted;
}

test "cheat: fast mine / nuker is throttled" {
	// 0.5 s blocks mined back to back at legit speed for 30 s: all accepted.
	try check("legit mining 60x0.5s", "1 per 500ms", minedBlocks(60, 0.5, 500) == 60, true);
	// Fast mine 10x: 300 attempts in 15 s; only legit rate plus one burst
	// (15 s / 0.35 s + 4 s / 0.35 s, about 54) gets through.
	try check("fast mine 10x", "1 per 50ms", minedBlocks(300, 0.5, 50) <= 60, true);
	// Nuker 3x3 at once every 0.5 s for 15 s: 270 attempts.
	try check("nuker 3x3", "9 per 500ms", minedBlocks(270, 0.5, 500/9) <= 60, true);
	// Lag batch: 4 legit breaks arriving together after a 2 s stall.
	var budget: f64 = 0;
	var last: i64 = 0;
	var ok = true;
	var now: i64 = 2000;
	for (0..2) |_| {
		ok = ok and anticheat.spendMineBudget(&budget, &last, now, 0.5*anticheat.mineCostFactor);
		now += 1;
	}
	try check("lag batch 2 blocks", "2 in 1ms", ok, true);
}

// --- Normal gameplay that must never be flagged ---

test "legit: frozen mid-air while terrain loads, then falls" {
	// After joining / a teleport the client holds the player still (no
	// physics until the chunk loads) and repeats the same position.
	var air: anticheat.AirState = .{};
	_ = air.step(.none, false, 200, 0);
	var flagged = false;
	var now: i64 = 0;
	for (0..200) |_| { // 10 s frozen
		now += 50;
		air.pause(50);
	}
	const t0 = now;
	while (now - t0 <= 4000) : (now += 50) {
		const t = @as(f64, @floatFromInt(now - t0))/1000.0;
		if (air.step(.none, false, 200 - @min(0.5*anticheat.gravity*t*t, 90*t), now) == .flight) flagged = true;
	}
	try check("frozen 10s then 4s fall", "pause+freefall", !flagged, true);
}

/// Simulates `durationMs` of movement at `speed` blocks/s with position packets
/// every `intervalMs`, through the allowance; true if any packet is rejected.
fn allowanceRejects(burst: f64, rate: f64, maxGap: f64, speed: f64, intervalMs: i64, durationMs: i64) bool {
	var bank = burst;
	var now: i64 = 0;
	while (now < durationMs) {
		now += intervalMs;
		const dt = @as(f64, @floatFromInt(intervalMs))/1000.0;
		const allowed = anticheat.allowance(bank, burst, @min(dt, maxGap), rate);
		const moved = speed*dt;
		if (moved > allowed) return true;
		bank = allowed - moved;
	}
	return false;
}

test "legit: long falls and lag never trip the allowances" {
	const fb = anticheat.fallBurst;
	const fr = anticheat.maxFallSpeed;
	const mb = anticheat.moveBurst;
	const mr = anticheat.survivalMoveSpeed;
	const gap = anticheat.maxMoveGapSeconds;
	try check("60s fall at terminal velocity", "90 b/s, 50ms", !allowanceRejects(fb, fr, 1e9, 90, 50, 60_000), true);
	try check("terminal fall, 1s packet gaps", "90 b/s, 1000ms", !allowanceRejects(fb, fr, 1e9, 90, 1000, 20_000), true);
	try check("sprint 8 b/s for 5 min", "8 b/s, 50ms", !allowanceRejects(mb, mr, gap, 8, 50, 300_000), true);
	try check("sprint, 2s packet loss", "8 b/s, 2000ms", !allowanceRejects(mb, mr, gap, 8, 2000, 20_000), true);
	try check("speed hack 20 b/s", "20 b/s, 50ms", !allowanceRejects(mb, mr, gap, 20, 50, 10_000), false);
	try check("teleport 40 blocks", "800 b/s, 50ms", !allowanceRejects(mb, mr, gap, 800, 50, 50), false);
}

test "legit: very fast pickaxe is never throttled" {
	// A god-tier tool: 0.03 s per block, mined back to back for a minute.
	try check("god pickaxe 0.03s/block", "1 per 30ms", minedBlocks(2000, 0.03, 30) == 2000, true);
	// Instant-break blocks (0 s) are free.
	try check("instant-break blocks", "1 per 16ms", minedBlocks(3000, 0, 16) == 3000, true);
}
// --- ASHFRAME CUSTOM (Anticheat v2 cases) ---

// --- Normal gameplay added for the log-mode rollout (vanilla players) ---

test "legit: queued breaks after a network stall" {
	// Mining 0.5 s blocks at full speed, then a 5 s stall: the 10 breaks the
	// client did meanwhile arrive together. None may be rejected.
	var budget: f64 = anticheat.mineBurst;
	var last: i64 = 0;
	var now: i64 = 0;
	var ok = true;
	for (0..20) |_| {
		now += 500;
		ok = ok and anticheat.spendMineBudget(&budget, &last, now, 0.5*anticheat.mineCostFactor);
	}
	now += 5000;
	for (0..10) |_| {
		ok = ok and anticheat.spendMineBudget(&budget, &last, now, 0.5*anticheat.mineCostFactor);
		now += 1;
	}
	try check("5s stall, 10 queued breaks", "10 in 10ms", ok, true);
}

test "legit: sprinting through packet loss" {
	const mb = anticheat.moveBurst;
	const mr = anticheat.survivalMoveSpeed;
	const gap = anticheat.maxMoveGapSeconds;
	try check("sprint, 5s packet loss", "8 b/s, 5000ms", !allowanceRejects(mb, mr, gap, 8, 5000, 60_000), true);
	try check("sprint, 3s packet loss", "8 b/s, 3000ms", !allowanceRejects(mb, mr, gap, 8, 3000, 60_000), true);
}

test "legit: teleports never judge stale positions" {
	const old = [3]f64{ 100, 100, 64 };
	const dest = [3]f64{ 5000, -3000, 80 };
	// The client sends a few positions from before it applied the teleport.
	const stale = anticheat.teleportDecision(dest, 0, old, 200, false);
	try check("stale pos (log mode) accepted, not baseline", "old spot", stale == .staleAccept, true);
	const staleEnf = anticheat.teleportDecision(dest, 0, old, 200, true);
	try check("stale pos (enforce) dropped, no setback", "old spot", staleEnf == .staleDrop, true);
	// It arrives: that becomes the new baseline (the old /spawn bug reset the
	// baseline to the stale position and then set the player back to it).
	const arrived = anticheat.teleportDecision(dest, 0, .{ 5000.5, -3000, 79.2 }, 400, true);
	try check("arrival at destination", "dest", arrived == .arrived, true);
	// A client that never reports the destination is let go after the timeout.
	const timeout = anticheat.teleportDecision(dest, 0, old, anticheat.teleportArrivalTimeoutMs + 1, true);
	try check("slow client after timeout", "old spot", timeout == .arrived, true);
	// After arrival, walking on from the destination is normal movement.
	const step = anticheat.allowance(anticheat.moveBurst, anticheat.moveBurst, 0.05, anticheat.survivalMoveSpeed);
	try check("first step after teleport", "0.4 blocks", 0.4 <= step, true);
}

/// Jumps up onto a block the server learns about `lagMs` after the player
/// lands on it (block placement is a server-thread command, positions arrive
/// on the network thread), `count` times in a row. True if flagged.
fn pillarFlagged(count: usize, lagMs: i64) bool {
	var air: anticheat.AirState = .{};
	var now: i64 = 0;
	var z: f64 = 64;
	_ = air.step(.ground, false, z, now);
	for (0..count) |_| {
		const base = z;
		var t: i64 = 50;
		// Jump arc until landing one block higher (~0.45 s).
		while (true) : (t += 50) {
			const s = @as(f64, @floatFromInt(t))/1000.0;
			const h = base + anticheat.jumpVelocity*s - 0.5*anticheat.gravity*s*s;
			if (s > 0.2 and h <= base + 1) break;
			if (air.step(.none, false, h, now + t) == .flight) return true;
		}
		z = base + 1;
		// Standing on the new block before the server has it.
		var w: i64 = 0;
		while (w < lagMs) : (w += 50) {
			if (air.step(.none, false, z, now + t + w) == .flight) return true;
		}
		now += t + lagMs;
		_ = air.step(.ground, false, z, now);
	}
	return false;
}

test "legit: pillaring up with block-placement lag" {
	try check("pillar 20 blocks, 100ms lag", "jump+place", !pillarFlagged(20, 100), true);
	try check("pillar 20 blocks, 400ms lag", "jump+place", !pillarFlagged(20, 400), true);
}

test "legit: sprint-jumping for a minute" {
	var air: anticheat.AirState = .{};
	var flagged = false;
	var now: i64 = 0;
	_ = air.step(.ground, false, 64, now);
	for (0..100) |_| {
		var t: i64 = 50;
		while (t < 580) : (t += 50) {
			const s = @as(f64, @floatFromInt(t))/1000.0;
			const h = 64 + anticheat.jumpVelocity*s - 0.5*anticheat.gravity*s*s;
			if (air.step(.none, false, @max(h, 64), now + t) == .flight) flagged = true;
		}
		now += 600;
		_ = air.step(.ground, false, 64, now);
	}
	try check("100 sprint-jumps", "parabolas", !flagged, true);
	const mb = anticheat.moveBurst;
	try check("sprint-jump speed 8 b/s", "8 b/s, 50ms", !allowanceRejects(mb, anticheat.survivalMoveSpeed, anticheat.maxMoveGapSeconds, 8, 50, 60_000), true);
}
// --- ASHFRAME CUSTOM (Anticheat v2 cases) ---
