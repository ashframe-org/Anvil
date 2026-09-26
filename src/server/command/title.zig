const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const titles = main.server.titles;
const ashutil = @import("ashutil.zig");

pub const description = "Wear one of the titles you've unlocked.";
pub const usage =
	\\/title <name>
	\\/title clear
;

pub const Args = union(enum) {
	@"/title clear": struct {action: enum {clear}},
	@"/title <name>": struct {name: []const u8},
};

pub fn execute(args: Args, source: Source) void {
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	const user = source.user;
	const prof = user.player();
	switch (args) {
		.@"/title clear" => {
			if (prof.active_title == null) {
				source.sendMessage("#e6312cYou aren't wearing a title.", .{});
				return;
			}
			prof.active_title = null;
			main.server.refreshPlayerNametag(user);
			source.sendMessage("#cfcfcfYour title has been removed.", .{});
		},
		.@"/title <name>" => |params| {
			const index = titles.indexOf(params.name) orelse {
				if (ashutil.suggestTitle(params.name, prof)) |suggestion| {
					source.sendMessage("#e6312cUnknown title \"#cfcfcf{s}#e6312c\". Did you mean #cfcfcf[{s}]#e6312c?", .{params.name, suggestion});
				} else {
					source.sendMessage("#e6312cUnknown title \"#cfcfcf{s}#e6312c\".", .{params.name});
				}
				return;
			};
			if (!titles.isUnlocked(prof, index)) {
				// Never confirm the existence of a locked secret title.
				if (titles.all[index].secret) {
					source.sendMessage("#e6312cUnknown title \"#cfcfcf{s}#e6312c\".", .{params.name});
				} else {
					source.sendMessage("#e6312cYou haven't unlocked that title yet.", .{});
				}
				return;
			}
			// Season badges show automatically in chat and can never be worn.
			if (titles.isSeasonTitle(index)) {
				source.sendMessage("#e6312cSeason badges show automatically in chat — they can't be worn.", .{});
				return;
			}
			prof.active_title = @intCast(index);
			main.server.refreshPlayerNametag(user);
			source.sendMessage("#00ff00Title set to #cfcfcf[{s}]#00ff00.", .{titles.all[index].display});
		},
	}
}
