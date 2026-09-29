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
