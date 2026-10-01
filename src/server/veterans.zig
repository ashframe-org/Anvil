const std = @import("std");

const main = @import("main");
const User = main.server.User;

// --- ASHFRAME CUSTOM (Season veterans) ---
// One-time grants of [S0]-[S3] titles from saves/veterans.zig.zon.
// S2/S3-era accounts match by public key (strong); S0/S1-era names match by
// cleaned name (weak — color codes stripped, same rule as the roster audit).
// Granting is idempotent (title bits); nothing here auto-selects display.

const NameEntry = struct {
	name: []const u8,
	seasons: u8, // bit s set = played season s
};
const KeyEntry = struct {
	key: []const u8,
	seasons: u8,
};

var names: main.ListManaged(NameEntry) = undefined;
var keys: main.ListManaged(KeyEntry) = undefined;
// Uncertain names: matching players are asked once to verify via
// forum/DM instead of being granted outright.
var limbo: main.ListManaged([]const u8) = undefined;
var loaded: bool = false;

fn isHex(c: u8) bool {
	return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isHex6(s: []const u8) bool {
	if (s.len < 6) return false;
	for (s[0..6]) |c| {
		if (!isHex(c)) return false;
	}
	return true;
}

/// Shared name cleaner, also used by the chat filter's ban/unban name
/// normalisation so both systems agree on what a decorated name strips to.
/// Strips §#rrggbb and #rrggbb color sequences plus `*`/`~` markdown, trims
/// surrounding whitespace and collapses internal runs (" Sleepy  Evergreen"
/// and "Sleepy Evergreen" are the same player).
/// `_` is kept: underscores are legitimate name characters (Kitty_Katster).
/// Engine-faithful name cleaner (mirrors graphics.zig Parser): emits exactly
/// what the renderer shows. `**`/`*` dropped, `~~` dropped but lone `~`
/// kept, `__` dropped but lone `_` kept, `\X` emits X, `#` consumes itself +
/// the next 6 codepoints, `§` consumed alone. Spaces collapse/trim.
/// Verified 0-mismatch against all 509 real season names (S0-S4+SMP).
pub fn appendCleaned(out: *main.ListManaged(u8), name: []const u8) void {
	var i: usize = 0;
	var hashLeft: u8 = 0;
	while (i < name.len) {
		if (hashLeft > 0) {
			i += utf8Len(name, i);
			hashLeft -= 1;
			continue;
		}
		const c = name[i];
		switch (c) {
			'*' => {
				if (i + 1 < name.len and name[i + 1] == '*') i += 2 else i += 1;
			},
			'_' => {
				if (i + 1 < name.len and name[i + 1] == '_') {
					i += 2;
				} else {
					appendSpace(out, '_');
					i += 1;
				}
			},
			'~' => {
				if (i + 1 < name.len and name[i + 1] == '~') {
					i += 2;
				} else {
					appendSpace(out, '~');
					i += 1;
				}
			},
			'\\' => {
				if (i + 1 < name.len) {
					const l = utf8Len(name, i + 1);
					var k: usize = 0;
					while (k < l) : (k += 1) appendSpace(out, name[i + 1 + k]);
					i += 1 + l;
				} else {
					i += 1;
				}
			},
			'#' => {
				hashLeft = 6;
				i += 1;
			},
			0xC2 => {
				if (i + 1 < name.len and name[i + 1] == 0xA7) i += 2 else {
					appendSpace(out, c);
					i += 1;
				}
			},
			' ' => {
				appendSpace(out, ' ');
				i += 1;
			},
			else => {
				out.append(c);
				i += 1;
			},
		}
	}
	while (out.items.len != 0 and out.items[out.items.len - 1] == ' ') {
		_ = out.pop();
	}
}

/// Appends a byte, collapsing ASCII-space runs and dropping leading spaces
/// (trailing trimmed by the caller above). Non-space bytes pass through.
fn appendSpace(out: *main.ListManaged(u8), c: u8) void {
	if (c == ' ' and (out.items.len == 0 or out.items[out.items.len - 1] == ' ')) return;
	out.append(c);
}

/// Length in bytes of the UTF-8 codepoint at name[i] (1..4).
/// Shared with shops (visible-length truncation at codepoint boundaries).
pub fn utf8Len(name: []const u8, i: usize) usize {
	if (i >= name.len) return 0;
	const c = name[i];
	if (c < 0x80) return 1;
	if (c < 0xC2) return 1;
	if (c < 0xE0) return 2;
	if (c < 0xF0) return 3;
	if (c < 0xF5) return 4;
	return 1;
}

fn eqlFold(a: []const u8, b: []const u8) bool {
	if (a.len != b.len) return false;
	for (a, b) |x, y| {
		if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
	}
	return true;
}

/// Strips leading/trailing underscores for the second match pass below.
/// Internal underscores are significant ("Kitty_Katster" keeps its own).
fn stripEdgeUnderscores(s: []const u8) []const u8 {
	var a = s;
	while (a.len != 0 and a[0] == '_') a = a[1..];
	while (a.len != 0 and a[a.len - 1] == '_') a = a[0 .. a.len - 1];
	return a;
}

/// Cleans a roster entry on the fly and compares against an already-cleaned
/// live name. Also reused by `/unban` to match stored player-file names.
/// Falls back to ignoring edge underscores ("__Hazel__" vs "Hazel"), but
/// never matches empty strings (so "_" and "__" stay distinct non-matches).
pub fn rosterMatch(rawEntry: []const u8, cleanedLive: []const u8) bool {
	var cleanedEntry = main.ListManaged(u8).init(main.stackAllocator);
	defer cleanedEntry.deinit();
	appendCleaned(&cleanedEntry, rawEntry);
	if (std.mem.eql(u8, cleanedEntry.items, cleanedLive) or eqlFold(cleanedEntry.items, cleanedLive)) return true;
	const a = stripEdgeUnderscores(cleanedEntry.items);
	const b = stripEdgeUnderscores(cleanedLive);
	if (a.len == 0 or b.len == 0) return false;
	return eqlFold(a, b);
}

pub fn load() void {
	if (loaded) return;
	loaded = true;
	names = main.ListManaged(NameEntry).init(main.globalAllocator);
	keys = main.ListManaged(KeyEntry).init(main.globalAllocator);
	limbo = main.ListManaged([]const u8).init(main.globalAllocator);
	const zon = main.files.cubyzDir().readToZon(main.stackAllocator, "saves/veterans.zig.zon") catch return;
	defer zon.deinit(main.stackAllocator);
	for (zon.getChild("names").toSlice()) |entry| {
		const name = entry.get([]const u8, "name") orelse continue;
		var mask: u8 = 0;
		for (entry.getChild("seasons").toSlice()) |s| {
			const season = s.as(u8) orelse continue;
			if (season < 8) mask |= @as(u8, 1) << @intCast(season);
		}
		if (mask == 0) continue;
		names.append(.{ .name = main.globalAllocator.dupe(u8, name), .seasons = mask });
	}
	for (zon.getChild("keys").toSlice()) |entry| {
		const key = entry.get([]const u8, "key") orelse continue;
		var mask: u8 = 0;
		for (entry.getChild("seasons").toSlice()) |s| {
			const season = s.as(u8) orelse continue;
			if (season < 8) mask |= @as(u8, 1) << @intCast(season);
		}
		if (mask == 0) continue;
		keys.append(.{ .key = main.globalAllocator.dupe(u8, key), .seasons = mask });
	}
	for (zon.getChild("limbo").toSlice()) |entry| {
		const name = entry.as([]const u8) orelse continue;
		if (name.len == 0) continue;
		limbo.append(main.globalAllocator.dupe(u8, name));
	}
}

fn seasonTitleIndex(season: u3) ?usize {
	const ids = [_][]const u8{ "s0", "s1", "s2", "s3" };
	return main.server.titles.indexOf(ids[season]);
}

/// Accounts that must never receive veteran badges: service/bot accounts whose
/// names can coincidentally collide with roster entries (the Discord relay
/// joined as "Discord", which matched a real veteran's row). Compared against
/// the cleaned name, case-insensitively.
const excludedNames = [_][]const u8{ "discord", "cctv" };

fn isExcluded(cleanedName: []const u8) bool {
	for (excludedNames) |ex| {
		if (eqlFold(ex, cleanedName)) return true;
	}
	return false;
}

/// Grants any veteran seasons matching this player: the UNION of all key
/// matches and all name matches. Key-only-then-name used to let a key entry
/// shadow name entries (a player whose key row lacked S1 never got it via
/// their name row). Union only ever adds bits, never removes. Safe to call
/// on every join: already-set bits are skipped silently.
pub fn grant(user: *User) void {
	load();
	const prof = user.player();
	// Service/bot accounts are never veterans, even if a name matches.
	{
		var cleaned = main.ListManaged(u8).init(main.stackAllocator);
		defer cleaned.deinit();
		appendCleaned(&cleaned, user.name);
		if (isExcluded(cleaned.items)) return;
	}
	var mask: u8 = 0;
	if (user.newKeyString) |key| {
		for (keys.items) |entry| {
			if (std.mem.eql(u8, entry.key, key)) {
				mask |= entry.seasons;
			}
		}
	}
	{
		var cleaned = main.ListManaged(u8).init(main.stackAllocator);
		defer cleaned.deinit();
		appendCleaned(&cleaned, user.name);
		for (names.items) |entry| {
			if (rosterMatch(entry.name, cleaned.items)) {
				mask |= entry.seasons;
			}
		}
	}
	if (mask == 0) {
		// Possible-but-unconfirmed veteran: point at verification, once ever.
		if (!prof.veteranLimboNotified) {
			var cleaned = main.ListManaged(u8).init(main.stackAllocator);
			defer cleaned.deinit();
			appendCleaned(&cleaned, user.name);
			for (limbo.items) |candidate| {
				if (rosterMatch(candidate, cleaned.items)) {
					prof.veteranLimboNotified = true;
					user.sendMessage("#e6e6e6Your name matches an old-season record. #8a8a8aIf that was you, contact staff on the forum or Discord to claim your veteran badge.", .{});
					break;
				}
			}
		}
		return;
	}
	_ = applyToUser(user, mask, false);
}

/// Grants the seasons in `mask` to `user` now (if online), and tells them.
/// `announce` prefixes a different message for a manual (admin) grant.
/// Returns how many new badges were actually added.
fn applyToUser(user: *User, mask: u8, manual: bool) u8 {
	const prof = user.player();
	var msg = main.ListManaged(u8).init(main.stackAllocator);
	defer msg.deinit();
	if (manual) {
		msg.appendSlice("#00ff00You were granted the veteran badge(s):");
	} else {
		msg.appendSlice("#00ff00Veteran status recognised:");
	}
	var grantedAny: u8 = 0;
	var s: u3 = 0;
	while (s < 4) : (s += 1) {
		if (mask & (@as(u8, 1) << s) == 0) continue;
		const idx = seasonTitleIndex(s) orelse continue;
		if (main.server.titles.isUnlocked(prof, idx)) continue;
		prof.titles |= @as(u64, 1) << @intCast(idx);
		msg.appendSlice(" #cfcfcf[S");
		msg.append(@as(u8, '0') + s);
		msg.append(']');
		grantedAny += 1;
	}
	if (grantedAny > 0) {
		msg.appendSlice("#00ff00 — it now shows automatically in front of your name in chat.");
		user.sendMessage("{s}", .{msg.items});
	}
	return grantedAny;
}

/// Live admin revoke: clears `season` from matching roster entries (name
/// and/or key; entries emptied entirely are dropped), clears the title bit
/// live if the target is online, and clears the persisted bit in offline
/// player files. Saves. Returns how many places were actually changed.
pub fn revoke(user: ?*User, name: []const u8, key: ?[]const u8, season: u3) u8 {
	load();
	const clearMask = ~(@as(u8, 1) << season);
	var changed: u8 = 0;
	var cleaned = main.ListManaged(u8).init(main.stackAllocator);
	defer cleaned.deinit();
	appendCleaned(&cleaned, name);
	var i: usize = 0;
	while (i < names.items.len) {
		if (rosterMatch(names.items[i].name, cleaned.items)) {
			names.items[i].seasons &= clearMask;
			if (names.items[i].seasons == 0) {
				main.globalAllocator.free(names.items[i].name);
				_ = names.swapRemove(i);
				changed += 1;
				continue;
			}
			changed += 1;
		}
		i += 1;
	}
	if (key) |k| {
		var j: usize = 0;
		while (j < keys.items.len) {
			if (std.mem.eql(u8, keys.items[j].key, k)) {
				keys.items[j].seasons &= clearMask;
				if (keys.items[j].seasons == 0) {
					main.globalAllocator.free(keys.items[j].key);
					_ = keys.swapRemove(j);
					changed += 1;
					continue;
				}
				changed += 1;
			}
			j += 1;
		}
	}
	if (seasonTitleIndex(season)) |idx| {
		const bit = @as(u64, 1) << @intCast(idx);
		if (user) |u| {
			if (u.player().titles & bit != 0) {
				u.player().titles &= ~bit;
				main.server.refreshPlayerNametag(u);
				changed += 1;
			}
		}
		clearOfflineTitleBit(cleaned.items, bit);
	}
	if (changed > 0) save();
	return changed;
}

/// Clears a season title bit in offline player files matching `cleanedName`.
/// Same scan pattern as the unban strikes reset: read-only unless the bit is
/// actually set, so files are never rewritten needlessly.
fn clearOfflineTitleBit(cleanedName: []const u8, bit: u64) void {
	const world = main.server.world orelse return;
	const dirPath = main.stackAllocator.print("saves/{s}/players", .{world.path});
	defer main.stackAllocator.free(dirPath);
	var playerDir = main.files.cubyzDir().openIterableDir(dirPath) catch return;
	defer playerDir.close();
	var iterator = playerDir.iterate();
	while (iterator.next(main.io) catch return) |file| {
		if (file.kind != .file or !std.mem.endsWith(u8, file.name, ".zon")) continue;
		var zon = playerDir.readToZon(main.stackAllocator, file.name) catch continue;
		defer zon.deinit(main.stackAllocator);
		const storedName = zon.get([]const u8, "name") orelse continue;
		if (!rosterMatch(storedName, cleanedName)) continue;
		const entity = zon.getChild("entity");
		const titles = entity.get(u64, "titles") orelse continue;
		if (titles & bit == 0) continue;
		entity.put("titles", titles & ~bit);
		playerDir.writeZon(file.name, zon) catch |err| {
			std.log.err("Could not clear season badge in player file {s}: {s}", .{ file.name, @errorName(err) });
			continue;
		};
		std.log.info("Cleared season badge in player file {s} ({s})", .{ file.name, storedName });
	}
}

/// Live admin grant: adds (or updates) a key entry, saves, and applies the
/// badge to the target immediately if they are online.
pub fn grantKey(user: ?*User, key: []const u8, season: u3) void {
	load();
	const mask: u8 = @as(u8, 1) << season;
	for (keys.items) |*entry| {
		if (std.mem.eql(u8, entry.key, key)) {
			entry.seasons |= mask;
			if (user) |u| _ = applyToUser(u, entry.seasons, true);
			save();
			return;
		}
	}
	keys.append(.{.key = main.globalAllocator.dupe(u8, key), .seasons = mask});
	if (user) |u| _ = applyToUser(u, mask, true);
	save();
}

/// Live admin grant by cleaned name (for keyless/old accounts).
pub fn grantName(user: ?*User, name: []const u8, season: u3) void {
	load();
	var cleaned = main.ListManaged(u8).init(main.stackAllocator);
	defer cleaned.deinit();
	appendCleaned(&cleaned, name);
	const mask: u8 = @as(u8, 1) << season;
	for (names.items) |*entry| {
		if (rosterMatch(entry.name, cleaned.items)) {
			entry.seasons |= mask;
			if (user) |u| _ = applyToUser(u, entry.seasons, true);
			save();
			return;
		}
	}
	names.append(.{.name = main.globalAllocator.dupe(u8, cleaned.items), .seasons = mask});
	if (user) |u| _ = applyToUser(u, mask, true);
	save();
}

pub fn addLimbo(name: []const u8) bool {
	load();
	for (limbo.items) |entry| {
		if (eqlFold(entry, name)) return false;
	}
	limbo.append(main.globalAllocator.dupe(u8, name));
	save();
	return true;
}

/// Appends each set season bit (0-7) of `mask` to `arr` as ints.
/// NOTE: the counter must NOT be u3 — `while (s < 8)` with a u3 never
/// terminates and `s += 1` traps on 7+1 (this crashed every save()).
fn appendSeasonBits(arr: *main.ZonElement, mask: u8) void {
	var s: u8 = 0;
	while (s < 8) : (s += 1) {
		if (mask & (@as(u8, 1) << @intCast(s)) != 0) arr.array.append(.{.int = s});
	}
}

fn save() void {
	var zon = main.ZonElement.initObject(main.stackAllocator);
	defer zon.deinit(main.stackAllocator);
	var nameArr = main.ZonElement.initArray(main.stackAllocator);
	for (names.items) |e| {
		var o = main.ZonElement.initObject(main.stackAllocator);
		o.put("name", e.name);
		var seasons = main.ZonElement.initArray(main.stackAllocator);
		appendSeasonBits(&seasons, e.seasons);
		o.put("seasons", seasons);
		nameArr.array.append(o);
	}
	zon.put("names", nameArr);
	var keyArr = main.ZonElement.initArray(main.stackAllocator);
	for (keys.items) |e| {
		var o = main.ZonElement.initObject(main.stackAllocator);
		o.put("key", e.key);
		var seasons = main.ZonElement.initArray(main.stackAllocator);
		appendSeasonBits(&seasons, e.seasons);
		o.put("seasons", seasons);
		keyArr.array.append(o);
	}
	zon.put("keys", keyArr);
	var limboArr = main.ZonElement.initArray(main.stackAllocator);
	for (limbo.items) |n| limboArr.array.append(.{.string = n});
	zon.put("limbo", limboArr);
	main.files.cubyzDir().writeZon("saves/veterans.zig.zon", zon) catch |err| {
		std.log.err("Could not save veterans data: {s}", .{@errorName(err)});
	};
}
// --- ASHFRAME CUSTOM (Season veterans) ---

test "veteran cleaner trims and collapses spaces" {
	const t = main.heap.testingAllocator;
	{
		var out = main.ListManaged(u8).init(t);
		defer out.deinit();
		appendCleaned(&out, " Sleepy  Evergreen ");
		try std.testing.expectEqualStrings("Sleepy Evergreen", out.items);
	}
	{
		var out = main.ListManaged(u8).init(t);
		defer out.deinit();
		appendCleaned(&out, "#ff77ff__Hazel__ **:3**");
		// Engine-faithful: #code dropped, __ dropped (underline toggle),
		// ** dropped (bold toggle).
		try std.testing.expectEqualStrings("Hazel :3", out.items);
	}
	{
		var out = main.ListManaged(u8).init(t);
		defer out.deinit();
		appendCleaned(&out, "Kitty_Katster");
		try std.testing.expectEqualStrings("Kitty_Katster", out.items);
	}
}

test "veteran rosterMatch underscore fallback" {
	var a = main.ListManaged(u8).init(main.stackAllocator);
	defer a.deinit();
	appendCleaned(&a, "Hazel :3");
	// Live name matches directly.
	try std.testing.expect(rosterMatch("Hazel :3", a.items));
	// Decorated roster variants match via cleaner + underscore fallback.
	try std.testing.expect(rosterMatch("_MrGun_", a.items) == false); // different name entirely
	var c = main.ListManaged(u8).init(main.stackAllocator);
	defer c.deinit();
	appendCleaned(&c, "MrGun");
	try std.testing.expect(rosterMatch("_MrGun_", c.items));
	try std.testing.expect(rosterMatch("Rivvien", c.items) == false);
	var d = main.ListManaged(u8).init(main.stackAllocator);
	defer d.deinit();
	appendCleaned(&d, "Rivvien");
	try std.testing.expect(rosterMatch("_Rivvien_", d.items));
	// Internal underscores stay significant.
	var b = main.ListManaged(u8).init(main.stackAllocator);
	defer b.deinit();
	appendCleaned(&b, "Kitty_Katster");
	try std.testing.expect(rosterMatch("Kitty_Katster", b.items));
	try std.testing.expect(!rosterMatch("KittyKatster", b.items));
	// Degenerate all-underscore names never match.
	try std.testing.expect(!rosterMatch("___", a.items));
}

test "veteran roster backslash names parse" {
	// A name ending in a backslash must be escaped (\\) in the roster file,
	// or the closing quote is swallowed and parsing derails into following
	// rows (killed a whole roster load once). Regression test.
	const case_ = ".{\n\t.names = .{\n\t\t.{.name = \"\\\\VESSEL\\\\\", .seasons = .{2}},\n\t\t.{.name = \"plain\", .seasons = .{1}},\n\t},\n}";
	var zon = main.ZonElement.parseFromString(main.stackAllocator, null, case_);
	defer zon.deinit(main.stackAllocator);
	const nameList = zon.getChild("names").toSlice();
	try std.testing.expect(nameList.len == 2);
	try std.testing.expectEqualStrings("\\VESSEL\\", nameList[0].get([]const u8, "name").?);
	try std.testing.expectEqualStrings("plain", nameList[1].get([]const u8, "name").?);
}

test "veteran bot accounts never match the roster" {
	try std.testing.expect(isExcluded("Discord"));
	try std.testing.expect(isExcluded("discord"));
	try std.testing.expect(isExcluded("CCTV"));
	try std.testing.expect(isExcluded("cctv"));
	try std.testing.expect(!isExcluded("DiscordUser"));
	try std.testing.expect(!isExcluded("iNiKKo"));
}

test "veteran season bits iterate the full mask without overflow" {
	// Regression: the old `var s: u3` counter with `while (s < 8)` never
	// terminated and trapped on 7+1, crashing every save() (all /veteran
	// mutations). Masks touching bit 7 prove full-range termination.
	const cases = [_]struct { mask: u8, want: []const u8 }{
		.{ .mask = 0x00, .want = &.{} },
		.{ .mask = 0x01, .want = &.{0} },
		.{ .mask = 0b00001111, .want = &.{ 0, 1, 2, 3 } },
		.{ .mask = 0x80, .want = &.{7} },
		.{ .mask = 0xFF, .want = &.{ 0, 1, 2, 3, 4, 5, 6, 7 } },
		.{ .mask = 0b10100101, .want = &.{ 0, 2, 5, 7 } },
	};
	for (cases) |c| {
		var arr = main.ZonElement.initArray(main.stackAllocator);
		defer arr.deinit(main.stackAllocator);
		appendSeasonBits(&arr, c.mask);
		try std.testing.expectEqual(c.want.len, arr.array.items.len);
		for (c.want, 0..) |want, i| {
			try std.testing.expectEqual(want, arr.array.items[i].as(u8).?);
		}
	}
}
