const std = @import("std");
const assert = std.debug.assert;

pub const key_length: u8 = 24;

pub const Request = struct {
    key: [key_length]u8,
};

pub const ParseError = error{
    BadRequest,
    VersionUnsupported,
};

const Seen = struct {
    host: bool = false,
    upgrade: bool = false,
    connection: bool = false,
    key: ?[key_length]u8 = null,
    version: ?[]const u8 = null,
};

pub fn parse(head: []const u8) ParseError!Request {
    assert(head.len > 0);
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    try parseRequestLine(lines.first());

    var seen: Seen = .{};
    while (lines.next()) |line| {
        if (line.len == 0) break;
        try parseHeader(line, &seen);
    }
    if (!seen.host or !seen.upgrade or !seen.connection) return error.BadRequest;
    const key = seen.key orelse return error.BadRequest;
    const version = seen.version orelse return error.BadRequest;
    if (!std.mem.eql(u8, version, "13")) return error.VersionUnsupported;
    return .{ .key = key };
}

fn parseRequestLine(line: []const u8) ParseError!void {
    var parts = std.mem.splitScalar(u8, line, ' ');
    const method = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;
    const version = parts.next() orelse return error.BadRequest;
    if (parts.next() != null) return error.BadRequest;
    if (!std.mem.eql(u8, method, "GET")) return error.BadRequest;
    if (target.len == 0) return error.BadRequest;
    if (!std.mem.eql(u8, version, "HTTP/1.1")) return error.BadRequest;
}

fn parseHeader(line: []const u8, seen: *Seen) ParseError!void {
    assert(line.len > 0);
    const colon = std.mem.findScalar(u8, line, ':') orelse return error.BadRequest;
    const name = line[0..colon];
    const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
    if (std.ascii.eqlIgnoreCase(name, "host")) {
        seen.host = true;
    } else if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
        seen.upgrade = seen.upgrade or std.ascii.eqlIgnoreCase(value, "websocket");
    } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
        seen.connection = seen.connection or hasToken(value, "upgrade");
    } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) {
        seen.key = try validateKey(value);
    } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-version")) {
        seen.version = value;
    }
}

fn hasToken(list: []const u8, token: []const u8) bool {
    assert(token.len > 0);
    var items = std.mem.splitScalar(u8, list, ',');
    while (items.next()) |item| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, item, " \t"), token)) return true;
    }
    return false;
}

fn validateKey(value: []const u8) ParseError![key_length]u8 {
    if (value.len != key_length) return error.BadRequest;
    var decoded: [16]u8 = undefined;
    std.base64.standard.Decoder.decode(&decoded, value) catch return error.BadRequest;
    return value[0..key_length].*;
}

const valid_head =
    "GET /chat HTTP/1.1\r\n" ++
    "Host: server.example.com\r\n" ++
    "Upgrade: websocket\r\n" ++
    "Connection: Upgrade\r\n" ++
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
    "Sec-WebSocket-Version: 13\r\n\r\n";

test "parse accepts the RFC 6455 section 1.3 request" {
    const request = try parse(valid_head);
    try std.testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", &request.key);
}

test "parse accepts mixed case names and a connection token list" {
    const head =
        "GET / HTTP/1.1\r\nHOST: a\r\nupgrade: WebSocket\r\n" ++
        "CONNECTION: keep-alive, Upgrade\r\n" ++
        "sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "SEC-WEBSOCKET-VERSION: 13\r\n\r\n";
    _ = try parse(head);
}

test "parse rejects each malformed request with BadRequest" {
    const cases = [_][]const u8{
        "POST /chat HTTP/1.1\r\n",
        "GET /chat HTTP/1.0\r\n",
        "GET /chat\r\n",
        "GET  /chat HTTP/1.1\r\n",
        "GET /chat HTTP/1.1 x\r\n",
        "GET /chat HTTP/1.1\r\nbroken header\r\n",
        "GET /chat HTTP/1.1\r\n",
    };
    inline for (cases) |prefix| {
        try std.testing.expectError(error.BadRequest, parse(prefix ++ "\r\n"));
    }
}

test "parse rejects a request missing or damaging a required header" {
    const lines = [_][]const u8{
        "Host: a\r\n",
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n",
        "Sec-WebSocket-Version: 13\r\n",
    };
    for (0..lines.len) |skipped| {
        var buffer: [512]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try writer.writeAll("GET / HTTP/1.1\r\n");
        for (lines, 0..) |line, index| {
            if (index != skipped) try writer.writeAll(line);
        }
        try writer.writeAll("\r\n");
        try std.testing.expectError(error.BadRequest, parse(writer.buffered()));
    }
}

test "parse rejects bad upgrade, connection and key values" {
    const triples = [_][3][]const u8{
        .{ "h2c", "Upgrade", "dGhlIHNhbXBsZSBub25jZQ==" },
        .{ "websocket", "keep-alive", "dGhlIHNhbXBsZSBub25jZQ==" },
        .{ "websocket", "Upgrade", "short" },
        .{ "websocket", "Upgrade", "dGhlIHNhbXBsZSBub25jZQ=!" },
        .{ "websocket", "Upgrade", "dGhlIHNhbXBsZSBub25j" },
    };
    for (triples) |triple| {
        var buffer: [512]u8 = undefined;
        const head = try std.fmt.bufPrint(
            &buffer,
            "GET / HTTP/1.1\r\nHost: a\r\nUpgrade: {s}\r\nConnection: {s}\r\n" ++
                "Sec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
            .{ triple[0], triple[1], triple[2] },
        );
        try std.testing.expectError(error.BadRequest, parse(head));
    }
}

test "parse answers a wrong version with VersionUnsupported" {
    const head =
        "GET / HTTP/1.1\r\nHost: a\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 8\r\n\r\n";
    try std.testing.expectError(error.VersionUnsupported, parse(head));
}
