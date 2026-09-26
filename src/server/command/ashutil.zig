const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const User = main.server.User;

/// Strips Cubyz color codes (§#rrggbb) from a name so fuzzy matching works on the visible text.
pub fn cleanColorCodes(allocator: std.mem.Allocator, name: []const u8) []const u8 {
	var result: std.ArrayList(u8) = .empty;
	errdefer result.deinit(allocator);

	var i: usize = 0;
	while (i < name.len) {
		if (std.mem.startsWith(u8, name[i..], "§")) {
			i += 1;
			if (i < name.len and name[i] == '#') {
				i += 7;
			}
			continue;
		}
		result.append(allocator, name[i]) catch {};
		i += 1;
	}
	return result.toOwnedSlice(allocator) catch name;
}

/// Resolves a `@<playerIndex>` or fuzzy/partial player-name string to an online user.
/// Name matching ignores color codes and case; an ambiguous partial match (more than
/// one player) returns null rather than guessing.
pub fn findTargetByNameOrIndex(targetStr: []const u8) ?*User {
	if (std.ascii.startsWithIgnoreCase(targetStr, "@")) {
		const cleanIndexStr = std.mem.trim(u8, targetStr[1..], &std.ascii.whitespace);
		const index = std.fmt.parseInt(usize, cleanIndexStr, 10) catch return null;
		return main.server.getUserByIndex(index);
	}

	const userList = main.server.getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);

	const cleanTarget = cleanColorCodes(main.stackAllocator.allocator, targetStr);
	defer main.stackAllocator.allocator.free(cleanTarget);

	// Pass 1: exact name match (ignoring color codes/case).
	for (userList) |u| {
		const cleanUserName = cleanColorCodes(main.stackAllocator.allocator, u.name);
		defer main.stackAllocator.allocator.free(cleanUserName);

		if (std.ascii.eqlIgnoreCase(cleanUserName, cleanTarget)) return u;
	}

	// Pass 2: unique substring match.
	var result: ?*User = null;
	var partialMatches: usize = 0;
	for (userList) |u| {
		const cleanUserName = cleanColorCodes(main.stackAllocator.allocator, u.name);
		defer main.stackAllocator.allocator.free(cleanUserName);

		if (std.ascii.indexOfIgnoreCase(cleanUserName, cleanTarget) != null) {
			partialMatches += 1;
			result = u;
		}
	}
	if (partialMatches != 1) return null;
	return result;
}

// --- ASHFRAME CUSTOM (Teleport costs) ---
/// Teleport fuel.
pub const orbIds = [_][]const u8{"ashframe:amber_orb"};
const orbName = "Orb";

pub fn nowSeconds() i64 {
	return @intCast(@divTrunc(main.timestamp().toNanoseconds(), 1000000000));
}

fn isOrb(item: main.items.Item) bool {
	if (item != .baseItem) return false;
	for (orbIds) |id| {
		if (item.baseItem == main.items.BaseItemIndex.fromId(id)) return true;
	}
	return false;
}

/// Removes `amount` orbs from the player's inventory.
/// Returns false (and explains) when they don't have enough.
pub fn chargeOrbs(user: *User, source: Source, amount: u16) bool {
	const inv = main.items.Inventory.server.getInventoryFromSource(.{.playerInventory = user.id}) orelse {
		source.sendMessage("#e6312cCould not find your inventory.", .{});
		return false;
	};

	var total: u32 = 0;
	for (inv._items) |stack| {
		if (isOrb(stack.item)) total += stack.amount;
	}
	if (total < amount) {
		source.sendMessage("#e6312cThat costs {d} {s}s, but you don't have enough.", .{ amount, orbName });
		return false;
	}

	// Running the fills with a null source makes the server treat them as
	// authoritative edits, so the changes are synced to the client's inventory.
	var remaining: u16 = amount;
	for (inv._items, 0..) |stack, i| {
		if (remaining == 0) break;
		if (!isOrb(stack.item)) continue;
		const take = @min(remaining, stack.amount);
		if (stack.amount > take) {
			main.sync.server.executeCommand(.{.fillFromCreative = .{
				.dest = .{.inv = inv, .slot = @intCast(i)},
				.item = stack.item,
				.amount = stack.amount - take,
			}}, null);
		} else {
			main.sync.server.executeCommand(.{.fillFromCreative = .{
				.dest = .{.inv = inv, .slot = @intCast(i)},
				.item = .null,
			}}, null);
		}
		remaining -= take;
	}
	source.sendMessage("#8a8a8a(-{d} {s})", .{ amount, orbName });
	return true;
}

/// Gives `amount` orbs to the player.
pub fn giveOrbs(user: *User, amount: u16) void {
	const base = main.items.BaseItemIndex.fromId("ashframe:amber_orb") orelse return;
	var stack = main.items.ItemStack{ .item = .{.baseItem = base}, .amount = amount };
	main.items.Inventory.server.tryCollectingToPlayerInventory(user, &stack);
}

/// Gives back `amount` of a named item (undo a `chargeItem`).
pub fn refundItem(user: *User, itemId: []const u8, amount: u16) void {
	const base = main.items.BaseItemIndex.fromId(itemId) orelse return;
	var stack = main.items.ItemStack{ .item = .{.baseItem = base}, .amount = amount };
	main.items.Inventory.server.tryCollectingToPlayerInventory(user, &stack);
	// If the inventory was full, drop the remainder so the refund isn't lost.
	if (stack.amount > 0) {
		if (main.server.world) |world| {
			world.drop(stack, user.player().pos, main.random.nextFloatVectorSigned(3, &main.seed), 0.1);
		}
	}
}

/// Human-readable name of an item id (falls back to the id itself).
pub fn itemDisplayName(itemId: []const u8) []const u8 {
	const base = main.items.BaseItemIndex.fromId(itemId) orelse return itemId;
	return base.name();
}

/// Removes `amount` of a named item from the player's inventory.
pub fn chargeItem(user: *User, source: Source, itemId: []const u8, display: []const u8, amount: u16) bool {
	const base = main.items.BaseItemIndex.fromId(itemId) orelse {
		source.sendMessage("#e6312cItem {s} is unavailable.", .{display});
		return false;
	};
	const inv = main.items.Inventory.server.getInventoryFromSource(.{.playerInventory = user.id}) orelse {
		source.sendMessage("#e6312cCould not find your inventory.", .{});
		return false;
	};
	var total: u32 = 0;
	for (inv._items) |stack| {
		if (stack.item == .baseItem and stack.item.baseItem == base) total += stack.amount;
	}
	if (total < amount) {
		source.sendMessage("#e6312cThat costs {d} {s}, but you don't have enough.", .{ amount, display });
		return false;
	}
	var remaining: u16 = amount;
	for (inv._items, 0..) |stack, i| {
		if (remaining == 0) break;
		if (!(stack.item == .baseItem and stack.item.baseItem == base)) continue;
		const take = @min(remaining, stack.amount);
		if (stack.amount > take) {
			main.sync.server.executeCommand(.{.fillFromCreative = .{
				.dest = .{.inv = inv, .slot = @intCast(i)},
				.item = stack.item,
				.amount = stack.amount - take,
			}}, null);
		} else {
			main.sync.server.executeCommand(.{.fillFromCreative = .{
				.dest = .{.inv = inv, .slot = @intCast(i)},
				.item = .null,
			}}, null);
		}
		remaining -= take;
	}
	source.sendMessage("#8a8a8a(-{d} {s})", .{ amount, display });
	return true;
}

/// Moves the player to `dest`, remembering the previous spot for /back.
pub fn teleportTo(user: *User, dest: main.vec.Vec3d) void {
	const prof = user.player();
	prof.back_pos = prof.pos;
	prof.pos = dest;
	main.server.anticheat.expectTeleport(user);
	main.network.protocols.genericUpdate.sendTPCoordinates(user.conn, dest);
}

// --- ASHFRAME CUSTOM (Did-you-mean suggestions) ---
fn editDistance(a: []const u8, b: []const u8) usize {
	var prev: [65]usize = undefined;
	var curr: [65]usize = undefined;
	const n = @min(a.len, 64);
	const m = @min(b.len, 64);
	var j: usize = 0;
	while (j <= m) : (j += 1) prev[j] = j;
	var i: usize = 1;
	while (i <= n) : (i += 1) {
		curr[0] = i;
		var k: usize = 1;
		while (k <= m) : (k += 1) {
			const cost: usize = if (std.ascii.toLower(a[i - 1]) == std.ascii.toLower(b[k - 1])) 0 else 1;
			curr[k] = @min(prev[k] + 1, @min(curr[k - 1] + 1, prev[k - 1] + cost));
		}
		@memcpy(prev[0 .. m + 1], curr[0 .. m + 1]);
	}
	return prev[m];
}

/// Lower score is better. Exact/prefix/substring matches outrank fuzzy ones.
fn matchScore(input: []const u8, name: []const u8) ?usize {
	if (input.len == 0 or name.len == 0) return null;
	if (std.ascii.eqlIgnoreCase(input, name)) return 0;
	if (std.ascii.startsWithIgnoreCase(name, input)) return 1;
	if (std.ascii.indexOfIgnoreCase(name, input) != null) return 2;
	const d = editDistance(input, name);
	const threshold = @max(2, input.len / 3);
	if (d <= threshold) return d + 3;
	return null;
}

/// Closest permitted command name, for "did you mean" suggestions.
pub fn suggestCommand(input_: []const u8, source: Source) ?[]const u8 {
	var input = input_;
	if (input.len > 0 and input[0] == '/') input = input[1..];
	if (input.len == 0) return null;
	var best: ?[]const u8 = null;
	var bestScore: usize = std.math.maxInt(usize);
	var it = main.server.command.commands.keyIterator();
	while (it.next()) |key| {
		const cmd = main.server.command.commands.get(key.*) orelse continue;
		if (!source.hasPermission(cmd.permissionPath)) continue;
		if (matchScore(input, key.*)) |s| {
			if (s < bestScore) {
				bestScore = s;
				best = key.*;
			}
		}
	}
	return best;
}

/// Closest title display name the player is allowed to know about
/// (unlocked titles plus non-secret ones, so locked secrets never leak).
pub fn suggestTitle(input: []const u8, prof: *main.server.Entity) ?[]const u8 {
	if (input.len == 0) return null;
	var best: ?[]const u8 = null;
	var bestScore: usize = std.math.maxInt(usize);
	for (main.server.titles.all, 0..) |title, i| {
		if (title.secret and !main.server.titles.isUnlocked(prof, i)) continue;
		if (matchScore(input, title.id)) |s| {
			if (s < bestScore) {
				bestScore = s;
				best = title.display;
			}
		}
		if (matchScore(input, title.display)) |s| {
			if (s < bestScore) {
				bestScore = s;
				best = title.display;
			}
		}
	}
	return best;
}
// --- ASHFRAME CUSTOM (Did-you-mean suggestions) ---

// --- ASHFRAME CUSTOM (Teleport costs) ---
/// Sends a teleport request to `target` and starts their response timer.
pub fn sendTpaRequest(user: *User, target: *User) void {
	target.player().tpa_request_from = user.playerIndex;
	target.player().tpa_request_time = nowSeconds();
	user.sendMessage("#cfcfcfTeleport request sent to #e6312c{s}#cfcfcf.", .{target.name});
	target.sendMessage("#e6312c{s} #cfcfcfwants to teleport to you. Type #e6312c/tpaccept #cfcfcfto accept. #8a8a8a(expires in {d}s)", .{user.name, main.server.Entity.teleportRequestTimeoutSeconds});
}
// --- ASHFRAME CUSTOM (Teleport costs) ---
