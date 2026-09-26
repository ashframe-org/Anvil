const std = @import("std");

const main = @import("main");
const NeverFailingAllocator = main.heap.NeverFailingAllocator;
const ListManaged = main.ListManaged;
const utils = main.utils;

pub const Options = struct {
	commandName: []const u8,
};

// --- ASHFRAME CUSTOM (RestOfLine argument type) ---
/// Wraps a string field that should consume every remaining token on the command
/// line (space-preserved) instead of just the next single whitespace-delimited
/// token. Must be the last field in the Args struct - resolveStruct special-cases
/// this type instead of treating it like a normal field.
pub const RestOfLine = struct {
	text: []const u8,
};
// --- ASHFRAME CUSTOM (RestOfLine argument type) ---

const ResolveMode = enum {
	parse,
	autocomplete,
};

pub fn Parser(comptime T: type, comptime options: Options) type {
	return struct {
		/// Parse the string `args` according to the schema defined in `T` type parameter of the Parser.
		/// Result is returned from this function as a value of type `T`.
		///
		/// Arguments:
		/// - `arena` - will be used for dynamic allocations of the parsing result returned.
		/// - `args` - unprocessed string containing command arguments without command name.
		/// - `errorMessage` - out parameter used to store and return errors, if any occur.
		pub fn parse(arena: NeverFailingAllocator, args: []const u8, errorMessage: *ListManaged(u8)) error{ParseError}!T {
			return resolve(ResolveMode.parse, arena, args, errorMessage);
		}

		pub fn resolve(
			comptime mode: ResolveMode,
			arena: NeverFailingAllocator,
			args: []const u8,
			errorMessage: *ListManaged(u8),
		) switch (mode) {
			.autocomplete => AutocompleteResult,
			.parse => error{ParseError}!T,
		} {
			switch (@typeInfo(T)) {
				inline .@"struct" => |s| {
					return resolveStruct(mode, s, arena, args, errorMessage);
				},
				inline .@"union" => |u| {
					if (u.tag_type == null) @compileError("Union must have a tag type");
					return switch (mode) {
						.autocomplete => autocompleteUnion(u, arena, args, errorMessage),
						.parse => parseUnion(u, arena, args, errorMessage),
					};
				},
				else => @compileError("Only structs and unions are supported"),
			}
		}

		fn resolveStruct(
			comptime mode: ResolveMode,
			comptime s: std.builtin.Type.Struct,
			arena: NeverFailingAllocator,
			args: []const u8,
			errorMessage: *ListManaged(u8),
		) switch (mode) {
			.autocomplete => AutocompleteResult,
			.parse => error{ParseError}!T,
		} {
			var result: T = undefined;
			var tokens = std.mem.tokenizeScalar(u8, args, ' ');

			var tempErrorMessage: ListManaged(u8) = .init(main.stackAllocator);
			defer tempErrorMessage.deinit();

			var nextArgument: ?[]const u8 = tokens.next();

			inline for (s.fields) |field| {
				// --- ASHFRAME CUSTOM (RestOfLine argument type) ---
				if (field.type == RestOfLine or field.type == ?RestOfLine) {
					// nextArgument already holds the first token of the
					// remainder (consumed by the previous field's trailing
					// tokens.next(), which moved tokens.index past it), so
					// the remainder spans from that token's start to the end
					// of args. Without this the tail alone is always empty and
					// every trailing-text command (/msg, /prefix add, /ban
					// reason) fails to parse. Token slices borrow from args,
					// so this is allocation-free.
					const rest = std.mem.trim(u8, if (nextArgument) |head| args[@intFromPtr(head.ptr) - @intFromPtr(args.ptr) ..] else args[tokens.index..], " ");
					if (field.type == ?RestOfLine) {
						@field(result, field.name) = if (rest.len == 0) null else RestOfLine{.text = rest};
					} else {
						if (rest.len == 0) {
							errorMessage.print("Incorrect usage at <{s}>", .{field.name});
							return error.ParseError;
						}
						@field(result, field.name) = .{.text = rest};
					}
					nextArgument = null;
					continue;
				}
				// --- ASHFRAME CUSTOM (RestOfLine argument type) ---

				const value = resolveArgument(field.type, arena, field.name[0..], nextArgument, &tempErrorMessage);

				if (value == error.ParseError) {
					if (@typeInfo(field.type) == .optional) {
						@field(result, field.name) = null;
						tempErrorMessage.clearRetainingCapacity();
					} else {
						errorMessage.appendSlice(tempErrorMessage.items);
						return error.ParseError;
					}
				} else {
					@field(result, field.name) = value catch unreachable;
					tempErrorMessage.clearRetainingCapacity();
					nextArgument = tokens.next();
				}
			}

			if (nextArgument != null) {
				errorMessage.print("Too many arguments for command, expected {}", .{s.fields.len});
				return error.ParseError;
			}

			return result;
		}

		fn resolveArgument(comptime Field: type, arena: NeverFailingAllocator, name: []const u8, argument: ?[]const u8, errorMessage: *ListManaged(u8)) error{ParseError}!Field {
			const fieldTypeInfo = @typeInfo(Field);
			if (fieldTypeInfo == .optional) {
				if (argument == null) return error.ParseError;
				return resolveArgument(fieldTypeInfo.optional.child, arena, name, argument, errorMessage) catch |err| {
					return err;
				};
			}

			const arg = argument orelse {
				errorMessage.print("Incorrect usage at <{s}>", .{name});
				return error.ParseError;
			};

			if (Field == []const u8) {
				return arg;
			}

			switch (fieldTypeInfo) {
				inline .@"struct", .@"union" => {
					if (!@hasDecl(Field, "parse")) @compileError("Structs / Unions must have a parse function");
					return @field(Field, "parse")(arena, name, arg, errorMessage);
				},
				inline .@"enum" => {
					return std.meta.stringToEnum(Field, arg) orelse {
						const str = main.meta.concatComptime("/", std.meta.fieldNames(Field));
						errorMessage.print("Expected one of {s} for <{s}>, found \"{s}\"", .{str, name, arg});
						return error.ParseError;
					};
				},
				inline .float => |floatInfo| return {
					return std.fmt.parseFloat(std.meta.Float(floatInfo.bits), arg) catch {
						errorMessage.print("Expected a number for <{s}>, found \"{s}\"", .{name, arg});
						return error.ParseError;
					};
				},
				inline .int => |intInfo| {
					return std.fmt.parseInt(@Int(intInfo.signedness, intInfo.bits), arg, 0) catch {
						errorMessage.print("Expected an integer for <{s}>, found \"{s}\"", .{name, arg});
						return error.ParseError;
					};
				},
				inline .bool => {
					return (std.meta.stringToEnum(enum { true, false }, arg) orelse {
						errorMessage.print("Expected either true or false for <{s}>, found \"{s}\"", .{name, arg});
						return error.ParseError;
					}) == .true;
				},
				inline else => |other| @compileError("Unsupported type " ++ @tagName(other)),
			}
		}

		fn parseUnion(comptime u: std.builtin.Type.Union, arena: NeverFailingAllocator, args: []const u8, errorMessage: *ListManaged(u8)) error{ParseError}!T {
			// Report only the first variant's parse error instead of dumping every
			// variant's attempt - much easier to read, and the first-declared
			// variant is typically the most specific/common form of the command.
			var firstError: ?ListManaged(u8) = null;
			defer if (firstError) |*e| e.deinit();

			inline for (u.fields) |field| {
				var tempErrorMessage: ListManaged(u8) = .init(main.stackAllocator);
				const result = Parser(field.type, options).resolve(.parse, arena, args, &tempErrorMessage);
				if (result != error.ParseError) {
					tempErrorMessage.deinit();
					return @unionInit(T, field.name, result catch unreachable);
				}
				if (firstError == null) {
					firstError = tempErrorMessage;
				} else {
					tempErrorMessage.deinit();
				}
			}

			if (firstError) |e| errorMessage.appendSlice(e.items);
			return error.ParseError;
		}

		fn autocompleteUnion(comptime u: std.builtin.Type.Union, arena: NeverFailingAllocator, args: []const u8) AutocompleteResult {
			_ = u;
			_ = arena;
			_ = args;
			return .{};
		}
	};
}

pub const AutocompleteResult = struct {};
// MARK: tests
const Test = struct {
	const OnlyX = Parser(struct { x: f64 }, .{.commandName = ""});

	const @"Union X or XY" = Parser(union(enum) {
		x: struct { x: f64 },
		xy: struct { x: f64, y: f64 },
	}, .{.commandName = ""});

	const @"subCommands foo or bar" = Parser(union(enum) {
		foo: struct { cmd: enum(u1) { foo }, x: f64 },
		bar: struct { cmd: enum(u1) { bar }, x: f64, y: f64 },
	}, .{.commandName = ""});
};

test "no arguments" {
	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const resultOrError = Parser(struct {}, .{.commandName = "foo"}).parse(main.stackAllocator, "", &errors);

	try std.testing.expectEqualStrings("", errors.items);
	_ = try resultOrError;
}

test "bool" {
	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const result = try Parser(struct { a: bool, b: bool }, .{.commandName = "foo"}).parse(main.stackAllocator, "true false", &errors);

	try std.testing.expectEqualStrings("", errors.items);
	try std.testing.expectEqual(result.a, true);
	try std.testing.expectEqual(result.b, false);
}

test "float" {
	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const result = try Test.OnlyX.parse(main.stackAllocator, "33.0", &errors);

	try std.testing.expectEqualStrings("", errors.items);
	try std.testing.expectEqual(result.x, 33.0);
}

test "float negative" {
	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const resultOrError = Test.OnlyX.parse(main.stackAllocator, "foo", &errors);

	try std.testing.expectEqualStrings("Expected a number for <x>, found \"foo\"", errors.items);
	try std.testing.expectError(error.ParseError, resultOrError);
}

test "enum" {
	const ArgParser = Parser(struct {
		cmd: enum(u1) { foo },
	}, .{.commandName = "c"});

	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const result = try ArgParser.parse(main.stackAllocator, "foo", &errors);

	try std.testing.expectEqualStrings("", errors.items);
	try std.testing.expectEqual(result.cmd, .foo);
}

test "float int float" {
	const ArgParser = Parser(struct {
		x: f64,
		y: i32,
		z: f32,
	}, .{.commandName = ""});

	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const result = try ArgParser.parse(main.stackAllocator, "33.0 154 -5654.0", &errors);

	try std.testing.expectEqualStrings("", errors.items);
	try std.testing.expectEqual(result.x, 33.0);
	try std.testing.expectEqual(result.y, 154);
	try std.testing.expectEqual(result.z, -5654.0);
}

test "float int optional float missing" {
	const ArgParser = Parser(struct {
		x: f64,
		y: i32,
		z: ?f32,
	}, .{.commandName = ""});

	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const result = try ArgParser.parse(main.stackAllocator, "33.0 154", &errors);

	try std.testing.expectEqualStrings("", errors.items);
	try std.testing.expectEqual(result.x, 33.0);
	try std.testing.expectEqual(result.y, 154);
	try std.testing.expectEqual(result.z, null);
}

test "two optionals missing" {
	const ArgParser = Parser(struct {
		x: f32,
		y: ?f32,
		z: ?f32,
	}, .{.commandName = ""});

	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const result = try ArgParser.parse(main.stackAllocator, "1.0", &errors);

	try std.testing.expectEqualStrings("", errors.items);
	try std.testing.expectEqual(result.x, 1.0);
	try std.testing.expectEqual(result.y, null);
	try std.testing.expectEqual(result.z, null);
}

test "float int optional float present" {
	const ArgParser = Parser(struct {
		x: f64,
		y: i32,
		z: ?f32,
	}, .{.commandName = ""});

	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const result = try ArgParser.parse(main.stackAllocator, "33.0 154 0.1", &errors);

	try std.testing.expectEqualStrings("", errors.items);
	try std.testing.expectEqual(result.x, 33.0);
	try std.testing.expectEqual(result.y, 154);
	try std.testing.expectEqual(result.z, 0.1);
}

test "optional inbetween" {
	const ArgParser = Parser(struct {
		x: enum { foo },
		y: ?f32,
		z: enum { bar },
	}, .{.commandName = "c"});

	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const result = try ArgParser.parse(main.stackAllocator, "foo bar", &errors);

	try std.testing.expectEqualStrings("", errors.items);
	try std.testing.expectEqual(result.x, .foo);
	try std.testing.expectEqual(result.y, null);
	try std.testing.expectEqual(result.z, .bar);
}

test "x or xy case x" {
	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const result = try Test.@"Union X or XY".parse(main.stackAllocator, "0.9", &errors);

	try std.testing.expectEqualStrings("", errors.items);
	try std.testing.expectEqual(result.x.x, 0.9);
}

test "x or xy case xy" {
	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const result = try Test.@"Union X or XY".parse(main.stackAllocator, "0.9 1.0", &errors);

	try std.testing.expectEqualStrings("", errors.items);
	try std.testing.expectEqual(result.xy.x, 0.9);
	try std.testing.expectEqual(result.xy.y, 1.0);
}

test "x or xy negative empty" {
	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const resultOrError = Test.@"Union X or XY".parse(main.stackAllocator, "", &errors);

	try std.testing.expectEqualStrings(
		\\Incorrect usage at <x>
	, errors.items);
	try std.testing.expectError(error.ParseError, resultOrError);
}

test "x or xy negative too many args" {
	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const resultOrError = Test.@"Union X or XY".parse(main.stackAllocator, "1.0 3.0 5.0", &errors);

	try std.testing.expectEqualStrings(
		\\Too many arguments for command, expected 1
	, errors.items);
	try std.testing.expectError(error.ParseError, resultOrError);
}

test "subCommands foo" {
	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const result = try Test.@"subCommands foo or bar".parse(main.stackAllocator, "foo 1.0", &errors);

	try std.testing.expectEqualStrings("", errors.items);
	try std.testing.expectEqual(result.foo.cmd, .foo);
	try std.testing.expectEqual(result.foo.x, 1.0);
}

test "subCommands bar" {
	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const result = try Test.@"subCommands foo or bar".parse(main.stackAllocator, "bar 2.0 3.0", &errors);

	try std.testing.expectEqualStrings("", errors.items);
	try std.testing.expectEqual(result.bar.cmd, .bar);
	try std.testing.expectEqual(result.bar.x, 2.0);
	try std.testing.expectEqual(result.bar.y, 3.0);
}

// --- ASHFRAME CUSTOM (RestOfLine regression tests) ---
// `/msg @0 test` used to fail with "Incorrect usage at <message>" because the
// trailing tokens.next() of the previous field moved tokens.index past the
// remainder before RestOfLine read it.

test "rest of line single word" {
	const ArgParser = Parser(struct {
		target: []const u8,
		message: RestOfLine,
	}, .{.commandName = ""});

	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const result = try ArgParser.parse(main.stackAllocator, "@0 test", &errors);

	try std.testing.expectEqualStrings("", errors.items);
	try std.testing.expectEqualStrings("@0", result.target);
	try std.testing.expectEqualStrings("test", result.message.text);
}

test "rest of line multi word" {
	const ArgParser = Parser(struct {
		target: []const u8,
		message: RestOfLine,
	}, .{.commandName = ""});

	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const result = try ArgParser.parse(main.stackAllocator, "player hello world", &errors);

	try std.testing.expectEqualStrings("", errors.items);
	try std.testing.expectEqualStrings("player", result.target);
	try std.testing.expectEqualStrings("hello world", result.message.text);
}

test "rest of line empty is an error" {
	const ArgParser = Parser(struct {
		target: []const u8,
		message: RestOfLine,
	}, .{.commandName = ""});

	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const resultOrError = ArgParser.parse(main.stackAllocator, "player", &errors);

	try std.testing.expectError(error.ParseError, resultOrError);
}

test "optional rest of line absent" {
	const ArgParser = Parser(struct {
		target: []const u8,
		reason: ?RestOfLine,
	}, .{.commandName = ""});

	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const result = try ArgParser.parse(main.stackAllocator, "playername", &errors);

	try std.testing.expectEqualStrings("", errors.items);
	try std.testing.expectEqualStrings("playername", result.target);
	try std.testing.expectEqual(result.reason, null);
}

test "optional rest of line present" {
	const ArgParser = Parser(struct {
		target: []const u8,
		reason: ?RestOfLine,
	}, .{.commandName = ""});

	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const result = try ArgParser.parse(main.stackAllocator, "@2 griefing spawn", &errors);

	try std.testing.expectEqualStrings("", errors.items);
	try std.testing.expectEqualStrings("@2", result.target);
	try std.testing.expectEqualStrings("griefing spawn", result.reason.?.text);
}

test "rest of line after rejected optional" {
	const ArgParser = Parser(struct {
		cmd: enum { add },
		index: ?i32,
		text: RestOfLine,
	}, .{.commandName = ""});

	var errors: ListManaged(u8) = .init(main.stackAllocator);
	defer errors.deinit();

	const result = try ArgParser.parse(main.stackAllocator, "add hello world", &errors);

	try std.testing.expectEqualStrings("", errors.items);
	try std.testing.expectEqual(result.cmd, .add);
	try std.testing.expectEqual(result.index, null);
	try std.testing.expectEqualStrings("hello world", result.text.text);
}
// --- ASHFRAME CUSTOM (RestOfLine regression tests) ---
