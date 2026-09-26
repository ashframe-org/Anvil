const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const User = main.server.User;
const shops = main.server.shops;

pub const description = "Turn a chest + sign into a shop.";
pub const usage =
	\\/shop sell <amount> <item> for <amount> <item>
	\\/shop buy <amount> <item> for <amount> <item>
;

pub const Args = union(enum) {
	@"/shop <action> <amount> <item> for <priceAmount> <priceItem>": struct {
		action: enum { sell, buy },
		amount: u16,
		item: []const u8,
		@"for": ?enum { @"for" },
		priceAmount: u16,
		priceItem: []const u8,
	},
};

pub fn execute(args: Args, source: Source) void {
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	switch (args) {
		.@"/shop <action> <amount> <item> for <priceAmount> <priceItem>" => |p| {
			const mode: shops.Mode = if (p.action == .sell) .sell else .buy;
			setup(source.user, source, mode, p.amount, p.item, p.priceAmount, p.priceItem);
		},
	}
}

fn setup(user: *User, source: Source, mode: shops.Mode, amount: u16, goodsStr: []const u8, priceAmount: u16, priceStr: []const u8) void {
	const goods = shops.resolveItem(goodsStr) orelse {
		source.sendMessage("#e6312cUnknown item \"{s}\".", .{goodsStr});
		return;
	};
	const price = shops.resolveItem(priceStr) orelse {
		source.sendMessage("#e6312cUnknown item \"{s}\".", .{priceStr});
		return;
	};

	const target = shops.lookAtBlock(user, 6.0) orelse {
		source.sendMessage("#e6312cLook at a chest (or its sign) to set up a shop.", .{});
		return;
	};
	const world = main.server.world orelse return;
	const targetBlock = world.getBlock(target[0], target[1], target[2]) orelse return;

	var chest: main.vec.Vec3i = undefined;
	var sign: main.vec.Vec3i = undefined;
	if (shops.isChestBlock(targetBlock)) {
		chest = target;
		sign = shops.findNeighborSign(target) orelse {
			source.sendMessage("#e6312cPlace a sign on the chest first.", .{});
			return;
		};
	} else if (shops.isSignBlock(targetBlock)) {
		sign = target;
		chest = shops.findNeighborChest(target) orelse {
			source.sendMessage("#e6312cPlace this sign on a chest.", .{});
			return;
		};
	} else {
		source.sendMessage("#e6312cLook at a chest (or its sign) to set up a shop.", .{});
		return;
	}

	if (!main.server.claims.canBuild(user, sign[0], sign[2], sign[1])) {
		source.sendMessage("#e6312cYou can't set up a shop here.", .{});
		return;
	}

	// --- ASHFRAME CUSTOM (Anticheat: shop ownership) ---
	// Refuse to take over a chest that already holds someone else's shop.
	if (shops.chestOwnedByOther(user, chest)) {
		main.server.anticheat.note(user, .protocol, "tried to rebind an existing shop chest");
		source.sendMessage("#e6312cThat chest already belongs to someone else's shop.", .{});
		return;
	}
	// --- ASHFRAME CUSTOM (Anticheat) ---

	var nameBuf: [shops.maxNameLen]u8 = undefined;
	const ownerName = shops.signName(user.name, &nameBuf);
	var buf: [256]u8 = undefined;
	const text = shops.formatSignText(mode, amount, goods, priceAmount, price, ownerName, &buf) catch {
		source.sendMessage("#e6312cCould not build the sign text.", .{});
		return;
	};
	if (!shops.writeSign(sign, text)) {
		source.sendMessage("#e6312cCould not write the sign.", .{});
		return;
	}
	main.network.protocols.blockEntityUpdate.sendServerDataUpdateToClients(sign);
	_ = shops.create(user, chest, sign, mode, goods, amount, price, priceAmount);
	const verb = if (mode == .sell) "selling" else "buying";
	source.sendMessage("#00ff00Shop created: #cfcfcf{s} #e6312c{d} {s}#cfcfcf for #e6312c{d} {s}#cfcfcf.", .{verb, amount, goods.name(), priceAmount, price.name()});
}
