const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;

pub const description = "Eat food to restore energy and health.";
pub const usage = "/eat";

pub const Args = union(enum) {
	@"/eat": struct {},
};

pub fn execute(args: Args, source: Source) void {
	_ = args;
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	const user = source.user;
	const prof = user.player();

	const inv = main.items.Inventory.server.getInventoryFromSource(.{.playerInventory = user.id}) orelse {
		source.sendMessage("#e6312cCould not find your inventory.", .{});
		return;
	};

	// Find the first food item (foodValue > 0) in the inventory.
	var foodSlot: ?usize = null;
	var foodItem: ?main.items.BaseItemIndex = null;
	var bestFoodValue: f32 = 0;
	for (inv._items, 0..) |stack, slot| {
		if (stack.item != .baseItem) continue;
		const value = stack.item.baseItem.foodValue();
		if (value > bestFoodValue) {
			bestFoodValue = value;
			foodSlot = slot;
			foodItem = stack.item.baseItem;
		}
	}

	const slot = foodSlot orelse {
		source.sendMessage("#e6312cYou don't have any food to eat.", .{});
		return;
	};
	const item = foodItem.?;

	if (prof.energy >= prof.maxEnergy and prof.health >= prof.maxHealth) {
		source.sendMessage("#e6312cYou are already full.", .{});
		return;
	}

	// Consume one. Running the fill with a null source makes the server treat it
	// as a creative (authoritative) edit, so the slot is rewritten and synced.
	if (inv._items[slot].amount > 1) {
		main.sync.server.executeCommand(.{.fillFromCreative = .{
			.dest = .{.inv = inv, .slot = @intCast(slot)},
			.item = .{.baseItem = item},
			.amount = inv._items[slot].amount - 1,
		}}, null);
	} else {
		main.sync.server.executeCommand(.{.fillFromCreative = .{
			.dest = .{.inv = inv, .slot = @intCast(slot)},
			.item = .null,
		}}, null);
	}

	// Food restores BOTH hunger and health by its food value. Healing is
	// hunger-gated (see hunger.zig); eating is the burst that refills it.
	main.sync.addEnergy(bestFoodValue, .server, user.id);
	main.sync.addHealth(bestFoodValue, .heal, .server, user.id);

	source.sendMessage("#00ff00Ate {s}§#cfcfcf: restored {d} #00ff00energy#cfcfcf and #00ff00{d}#cfcfcf health.", .{item.name(), bestFoodValue, bestFoodValue});

	prof.apples_eaten +|= 1;
	main.server.titles.check(user);
}
