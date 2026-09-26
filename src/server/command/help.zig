const std = @import("std");

const main = @import("main");
const NeverFailingAllocator = main.heap.NeverFailingAllocator;
const ListManaged = main.ListManaged;
const command = main.server.command;
const Source = command.Source;

pub const description = "Shows info about all the commands.";
pub const usage = "/help\n/help <command>";

pub const Args = union(enum) {
	@"/help <bobik>": struct { bobik: enum { Bobik, bobik } },
	@"/help <command>": struct { command: Cmd },
	@"/help": struct {},
};

// --- ASHFRAME CUSTOM (Command grouping for /help) ---
/// Names of commands added by this fork, so /help can list them separately
/// from Cubyz's own (default) commands.
const customCommandNames = std.StaticStringMap(void).initComptime(.{
	.{"home", {}},
	.{"add", {}},
	.{"waypoint", {}},
	.{"unban", {}},
	.{"ban", {}},
	.{"bans", {}},
	.{"skyscan", {}},
	.{"sethome", {}},
	.{"delhome", {}},
	.{"homes", {}},
	.{"tpa", {}},
	.{"tpaccept", {}},
	.{"tpdeny", {}},
	.{"back", {}},
	.{"players", {}},
	.{"playtime", {}},
	.{"stats", {}},
	.{"afk", {}},
	.{"prefix", {}},
	.{"msg", {}},
	.{"claim", {}},
	.{"eat", {}},
	.{"titles", {}},
	.{"title", {}},
	.{"shop", {}},
	.{"report", {}},
	.{"ashutil", {}},
});

const Group = enum { default, custom };

fn groupOf(name: []const u8) Group {
	if (customCommandNames.has(name)) return .custom;
	return .default;
}

fn appendGroup(msg: *main.ListManaged(u8), source: Source, group: Group) void {
	var names: main.ListManaged([]const u8) = .init(main.stackAllocator);
	defer names.deinit();

	var iterator = command.commands.valueIterator();
	while (iterator.next()) |cmd| {
		if (!source.hasPermission(cmd.permissionPath)) continue;
		if (groupOf(cmd.name) != group) continue;
		names.append(cmd.name);
	}

	std.mem.sort([]const u8, names.items, {}, struct {
		fn lessThan(_: void, a: []const u8, b: []const u8) bool {
			return std.mem.lessThan(u8, a, b);
		}
	}.lessThan);

	for (names.items) |name| {
		const cmd = command.commands.get(name).?;
		msg.appendSlice("#cfcfcf/");
		msg.appendSlice(cmd.name);
		msg.appendSlice("#8a8a8a: ");
		msg.appendSlice(cmd.description);
		msg.append('\n');
	}
}
// --- ASHFRAME CUSTOM (Command grouping for /help) ---

pub fn execute(args: Args, source: Source) void {
	var msg: main.ListManaged(u8) = .init(main.stackAllocator);
	defer msg.deinit();
	switch (args) {
		.@"/help" => {
			// --- ASHFRAME CUSTOM (Command grouping for /help) ---
			msg.appendSlice("#f2f2f2Default\n");
			appendGroup(&msg, source, .default);
			msg.appendSlice("\n#f2f2f2Custom\n");
			appendGroup(&msg, source, .custom);
			msg.appendSlice("\n#9a9a9aUse /help <command> for usage of a specific command.\n");
			// --- ASHFRAME CUSTOM (Command grouping for /help) ---
		},
		.@"/help <command>" => |params| {
			const cmd = params.command.cmd;

			if (!source.hasPermission(cmd.permissionPath)) {
				source.sendMessage("#e6312cUnrecognized command name.", .{});
				return;
			}

			msg.appendSlice("#cfcfcf/");
			msg.appendSlice(cmd.name);
			msg.appendSlice("#8a8a8a: ");
			msg.appendSlice(cmd.description);
			msg.append('\n');
			msg.appendSlice("#9a9a9a");
			msg.appendSlice(cmd.usage);
			msg.append('\n');
		},
		.@"/help <bobik>" => {
			msg.appendSlice("#cfcfcfEven Bobik can't help you anymore ");
		},
	}
	if (msg.items[msg.items.len - 1] == '\n') _ = msg.pop();
	source.sendMessage("{s}", .{msg.items});
}

const Cmd = struct {
	cmd: command.Command,

	pub fn parse(_: NeverFailingAllocator, name: []const u8, arg: []const u8, errorList: *ListManaged(u8)) error{ParseError}!Cmd {
		return .{
			.cmd = command.commands.get(arg) orelse {
				errorList.print("Unrecognized command name for <{s}>, got {s}", .{name, arg});
				return error.ParseError;
			},
		};
	}
};
