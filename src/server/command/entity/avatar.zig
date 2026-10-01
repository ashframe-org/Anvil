const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const model = main.entity.components.@"cubyz:model";

pub const description = "Lookup, list or change your avatar";
pub const usage =
	\\/avatar
	\\/avatar <entityModel>
	\\/avatar list
;
pub const Args = union(enum) {
	// NOTE: most specific first. parseUnion returns the first variant that
	// parses, and the zero-field bare variant consumes nothing — declared
	// first it shadows everything ("too many arguments, expected 0").
	@"/avatar list": struct { action: enum { list } },
	@"/avatar <entityModel>": struct { entityModel: command.EntityModel },
	@"/avatar": struct {},
};

pub fn execute(args: Args, source: Source) void {
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	const user = source.user;
	switch (args) {
		.@"/avatar <entityModel>" => |params| {
			model.server.put(user.id, .{
				.entityModel = params.entityModel.index,
			});
			user.sendMessage("#00ff00Your entity model was changed to {s}.", .{params.entityModel.index.get().entityModelId});
		},
		.@"/avatar" => {
			if (model.server.get(user.id)) |rc| {
				user.sendMessage("#00ff00You are a {s}", .{rc.entityModel.get().entityModelId});
			} else user.sendMessage("#ff00ffYou are invisible.", .{});
		},
		.@"/avatar list" => {
			var msg = main.ListManaged(u8).init(main.stackAllocator);
			defer msg.deinit();
			msg.appendSlice("#00ff00Avatars (/avatar <id>):");
			// Stock first, then per-addon (skinz: etc.), so players see both
			// namespaces the registry actually holds.
			for ([_]?[]const u8{ "cubyz", null }) |ns| {
				var first = true;
				for (main.entityModel.playerEntityModels.items) |idx| {
					const id = idx.get().entityModelId;
					const colon = std.mem.indexOfScalar(u8, id, ':') orelse continue;
					const matches = if (ns) |n| std.mem.eql(u8, id[0..colon], n) else !std.mem.eql(u8, id[0..colon], "cubyz");
					if (!matches) continue;
					if (first) {
						if (ns == null) msg.appendSlice(" #e6e6e6custom:");
						first = false;
					}
					msg.appendSlice(" #cfcfcf");
					msg.appendSlice(id);
				}
			}
			user.sendMessage("{s}", .{msg.items});
		},
	}
}

test "avatar command arg parsing" {
	const P = main.argparse.Parser(Args, .{.commandName = "avatar"});
	const cases = [_]struct { input: []const u8, expected: std.meta.Tag(Args) }{
		.{ .input = "", .expected = .@"/avatar" },
		.{ .input = "list", .expected = .@"/avatar list" },
		// NOTE: no `<entityModel>` success case: that variant needs the
		// live model registry (getById), which unit tests don't populate.
		// Regression guard for the shadowing bug below asserts the bare
		// variant does NOT claim a one-token input (it consumes nothing,
		// so if tried first every input misroutes to it).
	};
	for (cases) |c| {
		var errors: main.ListManaged(u8) = .init(main.stackAllocator);
		defer errors.deinit();
		const parsed = P.parse(main.stackAllocator, c.input, &errors) catch {
			std.debug.print("[cheat-test] avatar parse FAILED for \"{s}\": {s}\n", .{ c.input, errors.items });
			return error.ParseFailed;
		};
		try std.testing.expectEqual(c.expected, std.meta.activeTag(parsed));
	}
	// parseUnion tries variants in declaration order and the zero-field bare
	// variant consumes nothing: it must stay LAST or it shadows everything
	// ("too many arguments, expected 0" for any input).
	const fields = @typeInfo(Args).@"union".fields;
	try std.testing.expectEqualStrings("/avatar list", fields[0].name);
	try std.testing.expectEqualStrings("/avatar", fields[fields.len - 1].name);
}
