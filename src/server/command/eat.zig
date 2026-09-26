const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;

pub const description = "Eat an apple to restore a little health.";
pub const usage = "/eat";

pub const Args = union(enum) {
	@"/eat": struct {},
};

const appleHealth: f32 = 3.5;

pub fn execute(args: Args, source: Source) void {
	_ = args;
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	const user = source.user;
	const prof = user.player();

	if (prof.health >= prof.maxHealth) {
		source.sendMessage("#e6312cYou are already at full health.", .{});
		return;
	}

	const apple = main.items.BaseItemIndex.fromId("cubyz:apple") orelse {
		source.sendMessage("#e6312cApples are not available on this server.", .{});
		return;
	};

	const inv = main.items.Inventory.server.getInventoryFromSource(.{.playerInventory = user.id}) orelse {
		source.sendMessage("#e6312cCould not find your inventory.", .{});
		return;
	};

	var appleSlot: ?usize = null;
	for (inv._items, 0..) |stack, slot| {
		if (stack.item == .baseItem and stack.item.baseItem == apple) {
			appleSlot = slot;
			break;
		}
	}
	const slot = appleSlot orelse {
		source.sendMessage("#e6312cYou don't have any apples to eat.", .{});
		return;
	};

	// Consume one apple. Running the fill with a null source makes the server treat it
	// as a creative (authoritative) edit, so the slot is rewritten and the change is
	// synced to the client's inventory.
	if (inv._items[slot].amount > 1) {
		main.sync.server.executeCommand(.{.fillFromCreative = .{
			.dest = .{.inv = inv, .slot = @intCast(slot)},
			.item = .{.baseItem = apple},
			.amount = inv._items[slot].amount - 1,
		}}, null);
	} else {
		main.sync.server.executeCommand(.{.fillFromCreative = .{
			.dest = .{.inv = inv, .slot = @intCast(slot)},
			.item = .null,
		}}, null);
	}

	main.sync.addHealth(appleHealth, .heal, .server, user.id);
	source.sendMessage("#00ff00Apple eaten, restored #cfcfcf3.5 #00ff00health.", .{});

	prof.apples_eaten +|= 1;
	main.server.titles.check(user);
}
