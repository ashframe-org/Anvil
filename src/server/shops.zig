const std = @import("std");

const main = @import("main");
const User = main.server.User;
const Vec3i = main.vec.Vec3i;
const BinaryWriter = main.utils.BinaryWriter;
const Inventory = main.items.Inventory;
const BaseItemIndex = main.items.BaseItemIndex;

// --- ASHFRAME CUSTOM (Sign shops) ---
// A chest with an adjacent sign. The shop is stored server-side in a registry
// keyed by the chest position and bound to the owner's account key, so the sign
// text can't be used to impersonate the owner. The sign is display-only.
//
// The owner opens the chest normally (stock it / collect earnings); anyone else
// right-clicking it trades: they pay the price into the chest and receive the
// goods (or vice versa for a "buy" shop). Buy and sell both supported.

/// Last few chest slots are meant to stay free so payouts always fit. Soft
/// reserve: the owner is warned, and a trade is refused if the chest is full.
pub const reservedSlots: usize = 2;

const signType = main.block_entity.BlockEntityTypes.@"cubyz:sign";

pub const Mode = enum { sell, buy };

const Pair = struct { item: BaseItemIndex, amount: u16 };

const Shop = struct {
	chest: [3]i32, // (x, z, vertical)
	sign: [3]i32,
	owner: []const u8, // account key string (or name for local play)
	mode: Mode,
	goodsItem: u16,
	goodsAmount: u16,
	priceItem: u16,
	priceAmount: u16,
};

var shops: main.ListManaged(Shop) = undefined;
var ready: bool = false;
var lastSave: std.Io.Timestamp = .{.nanoseconds = 0};

const Neighbor = struct { dx: i32, dz: i32, dv: i32 };
/// The five sides a shop sign may sit on (everything except below the chest).
const neighbors = [_]Neighbor{
	.{.dx = 0, .dz = 0, .dv = 1}, // above
	.{.dx = 1, .dz = 0, .dv = 0},
	.{.dx = -1, .dz = 0, .dv = 0},
	.{.dx = 0, .dz = 1, .dv = 0},
	.{.dx = 0, .dz = -1, .dv = 0},
};

fn ensure() void {
	if (!ready) {
		shops = main.ListManaged(Shop).init(main.globalAllocator);
		ready = true;
	}
}

fn eq(p: [3]i32, q: Vec3i) bool {
	return p[0] == q[0] and p[1] == q[1] and p[2] == q[2];
}

/// The stable identity used for shop ownership. Account key where available.
fn ownerId(user: *User) []const u8 {
	return user.newKeyString orelse user.name;
}

fn isOwner(user: *User, shop: *const Shop) bool {
	return std.mem.eql(u8, shop.owner, ownerId(user));
}

pub fn isSignBlock(block: main.blocks.Block) bool {
	const be = block.blockEntity() orelse return false;
	return std.mem.eql(u8, be.id, "cubyz:sign");
}

pub fn isChestBlock(block: main.blocks.Block) bool {
	const be = block.blockEntity() orelse return false;
	return std.mem.eql(u8, be.id, "cubyz:chest");
}

/// The id without its addon/mod namespace, e.g. "cubyz:amber_ore" -> "amber_ore".
pub fn shortId(item: BaseItemIndex) []const u8 {
	const id = item.id();
	if (std.mem.indexOfScalar(u8, id, ':')) |colon| return id[colon + 1 ..];
	return id;
}

/// Resolves an item by full id, by id without its namespace, or by display name.
/// All lookups except the exact full id are case-insensitive, so "amber_ore",
/// "Amber_ore", "cubyz:amber_ore" and "Amber Ore" all work.
pub fn resolveItem(str: []const u8) ?BaseItemIndex {
	if (BaseItemIndex.fromId(str)) |item| return item;
	// Match the part of the id after the namespace.
	var i: u16 = 0;
	while (i < main.items.itemListSize) : (i += 1) {
		const index: BaseItemIndex = @enumFromInt(i);
		if (std.ascii.eqlIgnoreCase(shortId(index), str)) return index;
	}
	// Fall back to the display name.
	i = 0;
	while (i < main.items.itemListSize) : (i += 1) {
		const index: BaseItemIndex = @enumFromInt(i);
		if (std.ascii.eqlIgnoreCase(index.name(), str)) return index;
	}
	return null;
}

/// Max bytes of a player's (visible) name stored on a shop sign, so long names
/// don't overflow the sign.
pub const maxNameLen: usize = 16;

/// Strips Cubyz color codes (§#rrggbb) and truncates to `maxNameLen` bytes at a
/// valid UTF-8 boundary. Writes into `buf` and returns the used slice.
pub fn signName(name: []const u8, buf: *[maxNameLen]u8) []const u8 {
	var len: usize = 0;
	var i: usize = 0;
	while (i < name.len and len < maxNameLen) {
		if (std.mem.startsWith(u8, name[i..], "\u{00a7}")) {
			i += 1;
			if (i < name.len and name[i] == '#') i += 7;
			continue;
		}
		buf[len] = name[i];
		len += 1;
		i += 1;
	}
	while (len > 0 and !std.unicode.utf8ValidateSlice(buf[0..len])) len -= 1;
	return buf[0..len];
}

/// Formats the offer text written onto a shop sign. Line 1 gets its own color so
/// it stands out; the color code is stripped when rendered, so it costs no space.
/// Lines 2-3 are from the customer's point of view (`-` they give, `+` they get),
/// and list the price first, then the goods.
pub fn formatSignText(mode: Mode, amount: u16, goods: BaseItemIndex, priceAmount: u16, price: BaseItemIndex, ownerName: []const u8, buf: []u8) ![]const u8 {
	const modeName = if (mode == .sell) "Sell" else "Buy";
	const priceSign = if (mode == .sell) "-" else "+";
	const goodsSign = if (mode == .sell) "+" else "-";
	return std.fmt.bufPrint(buf, "#ffcc00[Shop] {s}#ffffff\n{s}{d}x {s}\n{s}{d}x {s}\n{s}", .{modeName, priceSign, priceAmount, shortId(price), goodsSign, amount, shortId(goods), ownerName});
}

/// Writes `text` into the sign at `pos` server-side. Returns false if there's
/// no sign there.
pub fn writeSign(pos: Vec3i, text: []const u8) bool {
	const world = main.server.world orelse return false;
	const simChunk = world.getSimulationChunkAndIncreaseRefCount(pos[0], pos[1], pos[2]) orelse return false;
	defer simChunk.decreaseRefCount();
	const ch = simChunk.chunk.load(.monotonic) orelse return false;
	ch.mutex.lock();
	defer ch.mutex.unlock();
	const block = ch.getBlock(pos[0] - ch.super.pos.wx, pos[1] - ch.super.pos.wy, pos[2] - ch.super.pos.wz);
	if (!isSignBlock(block)) return false;
	signType.setText(pos, &ch.super, text);
	// Mark the chunk dirty, otherwise the new sign text isn't written to disk.
	ch.setChanged();
	return true;
}

pub fn findNeighborSign(pos: Vec3i) ?Vec3i {
	const world = main.server.world orelse return null;
	for (neighbors) |n| {
		const p = Vec3i{pos[0] + n.dx, pos[1] + n.dz, pos[2] + n.dv};
		const block = world.getBlock(p[0], p[1], p[2]) orelse continue;
		if (isSignBlock(block)) return p;
	}
	return null;
}

pub fn findNeighborChest(pos: Vec3i) ?Vec3i {
	const world = main.server.world orelse return null;
	for (neighbors) |n| {
		const p = Vec3i{pos[0] + n.dx, pos[1] + n.dz, pos[2] + n.dv};
		const block = world.getBlock(p[0], p[1], p[2]) orelse continue;
		if (isChestBlock(block)) return p;
	}
	return null;
}

/// Simple ray-march from the player's eye along their look direction, returning
/// the first solid block within `maxDist`. World coords are (x, z, vertical).
pub fn lookAtBlock(user: *User, maxDist: f64) ?Vec3i {
	const world = main.server.world orelse return null;
	const prof = user.player();
	const dir = main.vec.rotateZ(main.vec.rotateX(main.vec.Vec3f{0, 1, 0}, -prof.rot[0]), -prof.rot[2]);
	const startX = prof.pos[0];
	const startZ = prof.pos[1];
	const startV = prof.pos[2] + 1.6;
	const dx: f64 = dir[0];
	const dz: f64 = dir[1];
	const dv: f64 = dir[2];
	var t: f64 = 0;
	while (t <= maxDist) : (t += 0.05) {
		const bx = main.server.anticheat.toI32(startX + dx*t) orelse return null;
		const bz = main.server.anticheat.toI32(startZ + dz*t) orelse return null;
		const bv = main.server.anticheat.toI32(startV + dv*t) orelse return null;
		const block = world.getBlock(bx, bz, bv) orelse continue;
		if (block.typ != main.blocks.Block.air.typ) return .{bx, bz, bv};
	}
	return null;
}

fn findAtChest(chest: Vec3i) ?usize {
	ensure();
	for (shops.items, 0..) |*s, i| {
		if (eq(s.chest, chest)) return i;
	}
	return null;
}

fn findAtSign(sign: Vec3i) ?usize {
	ensure();
	for (shops.items, 0..) |*s, i| {
		if (eq(s.sign, sign)) return i;
	}
	return null;
}

/// Creates or replaces the shop for `chest`, binding it to `user`.
/// Creates (or, for the owner, updates) a shop. Returns false if the chest is
/// already another player's shop: rebinding it would let a cheater take over and
/// then break/loot someone else's shop chest.
pub fn create(user: *User, chest: Vec3i, sign: Vec3i, mode: Mode, goods: BaseItemIndex, goodsAmount: u16, price: BaseItemIndex, priceAmount: u16) bool {
	ensure();
	const me = ownerId(user);
	const entry = Shop{
		.chest = .{chest[0], chest[1], chest[2]},
		.sign = .{sign[0], sign[1], sign[2]},
		.owner = undefined,
		.mode = mode,
		.goodsItem = @intFromEnum(goods),
		.goodsAmount = goodsAmount,
		.priceItem = @intFromEnum(price),
		.priceAmount = priceAmount,
	};
	if (findAtChest(chest)) |i| {
		if (!std.mem.eql(u8, shops.items[i].owner, me)) return false;
		main.globalAllocator.free(shops.items[i].owner);
		shops.items[i] = entry;
		shops.items[i].owner = main.globalAllocator.dupe(u8, me);
	} else {
		shops.append(entry);
		shops.items[shops.items.len - 1].owner = main.globalAllocator.dupe(u8, me);
	}
	saveCurrentWorld();
	return true;
}

/// True if `chest` already holds a shop belonging to someone else.
pub fn chestOwnedByOther(user: *User, chest: Vec3i) bool {
	ensure();
	const i = findAtChest(chest) orelse return false;
	return !isOwner(user, &shops.items[i]);
}

/// Removes any shop whose chest or sign is the block at `pos`.
pub fn onBroken(pos: Vec3i, oldBlock: main.blocks.Block) void {
	if (!isChestBlock(oldBlock) and !isSignBlock(oldBlock)) return;
	ensure();
	var i: usize = 0;
	while (i < shops.items.len) {
		if (eq(shops.items[i].chest, pos) or eq(shops.items[i].sign, pos)) {
			main.globalAllocator.free(shops.items[i].owner);
			_ = shops.swapRemove(i);
			continue;
		}
		i += 1;
	}
	saveCurrentWorld();
}

/// True if the sign at `pos` is a shop sign owned by someone other than `user`,
/// in which case a text edit from `user` must be rejected.
pub fn rejectEdit(user: *User, pos: Vec3i) bool {
	const i = findAtSign(pos) orelse return false;
	return !isOwner(user, &shops.items[i]);
}

/// True if `user` may break the block at `pos`. Shop chests and their signs are
/// locked to their owner.
pub fn canBreak(user: *User, pos: Vec3i, oldBlock: main.blocks.Block) bool {
	const i = if (isChestBlock(oldBlock)) findAtChest(pos) else if (isSignBlock(oldBlock)) findAtSign(pos) else return true;
	const idx = i orelse return true;
	return isOwner(user, &shops.items[idx]);
}

fn countItem(inv: Inventory, item: BaseItemIndex) u32 {
	var total: u32 = 0;
	for (inv._items) |stack| {
		if (stack.item == .baseItem and stack.item.baseItem == item) total += stack.amount;
	}
	return total;
}

fn removeItem(inv: Inventory, item: BaseItemIndex, amount: u16) void {
	var remaining = amount;
	for (inv._items, 0..) |stack, i| {
		if (remaining == 0) break;
		if (!(stack.item == .baseItem and stack.item.baseItem == item)) continue;
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
}

fn canAdd(inv: Inventory, item: BaseItemIndex, amount: u16) bool {
	var room: u32 = 0;
	for (inv._items) |stack| {
		if (stack.item == .baseItem and stack.item.baseItem == item) {
			if (stack.amount > item.stackSize()) return true; // corrupt stack; don't underflow
			room += item.stackSize() - stack.amount;
		} else if (stack.item == .null) {
			room += item.stackSize();
		}
	}
	return room >= amount;
}

fn addItem(inv: Inventory, item: BaseItemIndex, amount: u16) void {
	var remaining = amount;
	for (inv._items, 0..) |stack, i| {
		if (remaining == 0) break;
		if (!(stack.item == .baseItem and stack.item.baseItem == item)) continue;
		if (stack.amount >= item.stackSize()) continue;
		const space = item.stackSize() - stack.amount;
		const add = @min(remaining, space);
		main.sync.server.executeCommand(.{.fillFromCreative = .{
			.dest = .{.inv = inv, .slot = @intCast(i)},
			.item = stack.item,
			.amount = stack.amount + add,
		}}, null);
		remaining -= add;
	}
	for (inv._items, 0..) |stack, i| {
		if (remaining == 0) break;
		if (stack.item != .null) continue;
		const add = @min(remaining, item.stackSize());
		main.sync.server.executeCommand(.{.fillFromCreative = .{
			.dest = .{.inv = inv, .slot = @intCast(i)},
			.item = .{.baseItem = item},
			.amount = add,
		}}, null);
		remaining -= add;
	}
}

/// Called when a chest inventory is closed. If it is a shop chest whose payout
/// slots are occupied, warn the owner (so they know before a trade fails).
pub fn onChestClosed(source: main.items.Inventory.Source) void {
	const chest = source.blockInventory;
	const i = findAtChest(chest) orelse return;
	const shop = &shops.items[i];
	const userList = main.server.getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);
	for (userList) |user| {
		if (std.mem.eql(u8, ownerId(user), shop.owner)) {
			warnOwner(user, chest);
			return;
		}
	}
}

fn warnOwner(user: *User, chest: Vec3i) void {
	const inv = Inventory.server.getInventoryFromSource(.{.blockInventory = chest}) orelse return;
	const size = inv.size();
	if (size <= reservedSlots) return;
	var occupied: usize = 0;
	for (size - reservedSlots..size) |i| {
		if (inv._items[i].item != .null) occupied += 1;
	}
	if (occupied > 0) {
		user.sendMessage("#e6312cHeads up: #cfcfcfkeep the last {d} slots of this shop chest free for payouts, or it can't sell.", .{reservedSlots});
	}
}

fn doTrade(user: *User, shop: *const Shop) void {
	const goods: BaseItemIndex = @enumFromInt(shop.goodsItem);
	const price: BaseItemIndex = @enumFromInt(shop.priceItem);

	const playerInv = Inventory.server.getInventoryFromSource(.{.playerInventory = user.id}) orelse {
		user.sendMessage("#e6312cCould not find your inventory.", .{});
		return;
	};
	const chestInv = Inventory.server.getInventoryFromSource(.{.blockInventory = .{shop.chest[0], shop.chest[1], shop.chest[2]}}) orelse {
		user.sendMessage("#e6312cThis shop is unavailable.", .{});
		return;
	};

	// From the customer's point of view: what they hand over and what they get.
	const customerPays: Pair = if (shop.mode == .sell) .{.item = price, .amount = shop.priceAmount} else .{.item = goods, .amount = shop.goodsAmount};
	const customerGets: Pair = if (shop.mode == .sell) .{.item = goods, .amount = shop.goodsAmount} else .{.item = price, .amount = shop.priceAmount};

	if (countItem(chestInv, customerGets.item) < customerGets.amount) {
		if (shop.mode == .sell) {
			user.sendMessage("#e6312cThis shop is out of stock.", .{});
		} else {
			user.sendMessage("#e6312cThis shop can't pay out right now.", .{});
		}
		return;
	}
	if (countItem(playerInv, customerPays.item) < customerPays.amount) {
		user.sendMessage("#e6312cYou need #e6312c{d} {s}#cfcfcf for this.", .{customerPays.amount, customerPays.item.name()});
		return;
	}
	if (!canAdd(chestInv, customerPays.item, customerPays.amount)) {
		user.sendMessage("#e6312cThis shop is full and can't accept the trade right now.", .{});
		return;
	}
	if (!canAdd(playerInv, customerGets.item, customerGets.amount)) {
		user.sendMessage("#e6312cYour inventory is too full to receive the items.", .{});
		return;
	}

	removeItem(playerInv, customerPays.item, customerPays.amount);
	addItem(chestInv, customerPays.item, customerPays.amount);
	removeItem(chestInv, customerGets.item, customerGets.amount);
	addItem(playerInv, customerGets.item, customerGets.amount);

	user.player().shopTrades +|= 1;
	const verb = if (shop.mode == .sell) "Bought" else "Sold";
	user.sendMessage("#00ff00{s} #e6312c{d} {s}#00ff00 for #e6312c{d} {s}#00ff00.", .{verb, shop.goodsAmount, goods.name(), shop.priceAmount, price.name()});
}

/// Called when a player opens a chest. Returns true if the open was intercepted
/// (a non-owner trade attempt), meaning the chest must NOT open.
pub fn handleChestOpen(user: *User, chest: Vec3i) bool {
	const i = findAtChest(chest) orelse return false;
	if (isOwner(user, &shops.items[i])) {
		warnOwner(user, chest);
		return false;
	}
	doTrade(user, &shops.items[i]);
	return true;
}

// --- Persistence ---

fn filePath(allocator: main.heap.NeverFailingAllocator, worldPath: []const u8) []const u8 {
	return allocator.print("saves/{s}/ashframe_shops.zig.zon", .{worldPath});
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
	for (shops.items) |s| main.globalAllocator.free(s.owner);
	shops.clearRetainingCapacity();
	const path = filePath(main.stackAllocator, worldPath);
	defer main.stackAllocator.free(path);
	const zon = main.files.cubyzDir().readToZon(main.stackAllocator, path) catch return;
	defer zon.deinit(main.stackAllocator);
	for (zon.getChild("shops").toSlice()) |entry| {
		const chest = readTriple(entry, "chest") orelse continue;
		const sign = readTriple(entry, "sign") orelse continue;
		const owner = entry.get([]const u8, "owner") orelse continue;
		const modeStr = entry.get([]const u8, "mode") orelse "sell";
		const mode: Mode = if (std.mem.eql(u8, modeStr, "buy")) .buy else .sell;
		const goodsItem = entry.get(u16, "goodsItem") orelse continue;
		const goodsAmount = entry.get(u16, "goodsAmount") orelse continue;
		const priceItem = entry.get(u16, "priceItem") orelse continue;
		const priceAmount = entry.get(u16, "priceAmount") orelse continue;
		// Skip entries whose items no longer exist (e.g. an addon was removed).
		if (goodsItem >= main.items.itemListSize or priceItem >= main.items.itemListSize) continue;
		shops.append(.{
			.chest = chest,
			.sign = sign,
			.owner = main.globalAllocator.dupe(u8, owner),
			.mode = mode,
			.goodsItem = goodsItem,
			.goodsAmount = goodsAmount,
			.priceItem = priceItem,
			.priceAmount = priceAmount,
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
	for (shops.items) |*s| {
		var e = main.ZonElement.initObject(main.stackAllocator);
		var ca = main.ZonElement.initArray(main.stackAllocator);
		for (s.chest) |v| ca.array.append(.{.int = v});
		e.put("chest", ca);
		var sa = main.ZonElement.initArray(main.stackAllocator);
		for (s.sign) |v| sa.array.append(.{.int = v});
		e.put("sign", sa);
		e.put("owner", s.owner);
		e.put("mode", if (s.mode == .buy) "buy" else "sell");
		e.put("goodsItem", s.goodsItem);
		e.put("goodsAmount", s.goodsAmount);
		e.put("priceItem", s.priceItem);
		e.put("priceAmount", s.priceAmount);
		arr.array.append(e);
	}
	zon.put("shops", arr);
	main.files.cubyzDir().writeZon(path, zon) catch |err| {
		std.log.err("Could not save Ashframe shops: {s}", .{@errorName(err)});
	};
}

pub fn autosave(worldPath: []const u8) void {
	const now = main.timestamp();
	if (lastSave.durationTo(now).toSeconds() > 60) {
		lastSave = now;
		save(worldPath);
	}
}
// --- ASHFRAME CUSTOM (Sign shops) ---
