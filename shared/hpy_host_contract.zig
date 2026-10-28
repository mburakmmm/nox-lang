//! `nox-hpy-host-v1` — aHPy'nin dondurduğu tüketici sözleşmesinin Nox
//! kopyası. Anlam `tests/compat/hpy_host/` altındaki pinli şema ve
//! politikadan gelir; bu dosya onu yeniden tasarlamaz.
//!
//! Yetenekler ABI bitidir. Bir güvenlik kumbarası değildir (AGENTS.md §9.5).
//! `owned` / `borrowed` kullanıcı sözdizimine çıkmaz; manifestteki sahiplik
//! alanları yalnızca üretici metadata'sıdır.

const std = @import("std");
const builtin = @import("builtin");

pub const profile = "nox-hpy-host-v1";
pub const hpy_abi = "universal";
pub const hpy_version = "0.9";
pub const ahpy_commit = "1eb0abc7b7198ea589daeb0e0f747cefb78a1df0";
pub const noxc_version = "2.0.56";
pub const nox_commit = "00a855c6a83f1edb22f181514358a9bf4cb3eac9";

pub const required_capabilities = [_][]const u8{
    "call-positional",
    "error-take",
    "extension-object",
    "module-close",
    "module-open",
    "object-close",
};

pub const optional_capabilities = [_][]const u8{
    "bytes",
    "call-keywords",
    "hpy-debug",
    "hpy-trace",
};

pub const targets = [_][]const u8{
    "linux-aarch64",
    "linux-x86_64",
    "macos-aarch64",
    "macos-x86_64",
    "windows-x86_64",
};

/// v1 yalnızca bu beş 64-bit üçlüyü yükler. 32-bit ELF/Mach-O/PE imajı
/// init'ten önce düşer. Liste, demet ve sözlük bu profilde yoktur.
pub const pointer_bits: u16 = 64;
pub const containers_in_v1 = false;

pub const Code = enum {
    ownership,
    integrity,
    schema,
    capability,
    name,
    target,
    call,
    type_unsupported,

    pub fn label(self: Code) []const u8 {
        return switch (self) {
            .ownership => "AHPY_NOX001",
            .integrity => "AHPY_NOX002",
            .schema => "AHPY_NOX003",
            .capability => "AHPY_NOX004",
            .name => "AHPY_NOX005",
            .target => "AHPY_NOX006",
            .call => "AHPY_NOX007",
            .type_unsupported => "AHPY_NOX008",
        };
    }
};

pub const Reject = struct {
    code: Code,
    message: []const u8,
};

pub const Parameter = struct {
    name: []const u8,
    kind: []const u8,
    call_kind: []const u8,
    ownership: []const u8,
};

pub const Result = struct {
    kind: []const u8,
    ownership: []const u8,
};

pub const Export = struct {
    kind: []const u8,
    name: []const u8,
    parameters: []Parameter,
    result: Result,
};

pub const Artifact = struct {
    target: []const u8,
    path: []const u8,
    sha256: []const u8,
    size: i64,
};

pub const Manifest = struct {
    schema_version: i64,
    package: struct {
        name: []const u8,
        version: []const u8,
    },
    producer: struct {
        ahpy_version: []const u8,
        cython_base: []const u8,
        source_digest: []const u8,
        compiler_options_digest: []const u8,
    },
    host: struct {
        profile: []const u8,
        hpy_abi: []const u8,
        hpy_version: []const u8,
        required_capabilities: [][]const u8,
    },
    module: struct {
        name: []const u8,
        init_symbol: []const u8,
    },
    exports: []Export,
    artifacts: []Artifact,
};

pub const Accepted = struct {
    arena: *std.heap.ArenaAllocator,
    value: Manifest,
    artifact_index: usize,

    pub fn deinit(self: *Accepted) void {
        const arena = self.arena;
        const parent = arena.child_allocator;
        arena.deinit();
        parent.destroy(arena);
    }

    pub fn manifest(self: Accepted) Manifest {
        return self.value;
    }

    pub fn artifact(self: Accepted) Artifact {
        return self.value.artifacts[self.artifact_index];
    }
};

pub fn hostTarget() []const u8 {
    return switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .aarch64 => "linux-aarch64",
            .x86_64 => "linux-x86_64",
            else => "unsupported",
        },
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => "macos-aarch64",
            .x86_64 => "macos-x86_64",
            else => "unsupported",
        },
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => "windows-x86_64",
            else => "unsupported",
        },
        else => "unsupported",
    };
}

pub fn hasRequiredCapability(name: []const u8) bool {
    for (required_capabilities) |cap| {
        if (std.mem.eql(u8, cap, name)) return true;
    }
    return false;
}

pub fn validateText(allocator: std.mem.Allocator, text: []const u8, target: []const u8) union(enum) { ok: Accepted, reject: Reject } {
    const holder = allocator.create(std.heap.ArenaAllocator) catch {
        return .{ .reject = .{ .code = .schema, .message = "nox-hpy.json yapısal olarak şemaya uymuyor" } };
    };
    holder.* = std.heap.ArenaAllocator.init(allocator);
    const value = parseManifest(holder.allocator(), text) catch {
        holder.deinit();
        allocator.destroy(holder);
        return .{ .reject = .{ .code = .schema, .message = "nox-hpy.json yapısal olarak şemaya uymuyor" } };
    };
    var accepted: Accepted = .{ .arena = holder, .value = value, .artifact_index = 0 };
    if (semantic(accepted.manifest(), target)) |rej| {
        accepted.deinit();
        return .{ .reject = rej };
    }
    accepted.artifact_index = artifactIndex(accepted.manifest(), target) orelse {
        accepted.deinit();
        return .{ .reject = .{ .code = .target, .message = "bu hedef için artefakt yok" } };
    };
    return .{ .ok = accepted };
}

const ParseError = error{ Bad, OutOfMemory };

const Parser = struct {
    text: []const u8,
    i: usize,
    arena: std.mem.Allocator,

    fn skip(self: *Parser) void {
        while (self.i < self.text.len) {
            switch (self.text[self.i]) {
                ' ', '\t', '\n', '\r' => self.i += 1,
                else => return,
            }
        }
    }

    fn peek(self: *Parser) ?u8 {
        if (self.i >= self.text.len) return null;
        return self.text[self.i];
    }

    fn eat(self: *Parser, c: u8) bool {
        if (self.peek() != c) return false;
        self.i += 1;
        return true;
    }

    fn expect(self: *Parser, c: u8) ParseError!void {
        if (!self.eat(c)) return error.Bad;
    }

    fn parseI64(self: *Parser) ParseError!i64 {
        self.skip();
        const neg = self.eat('-');
        const start = self.i;
        if (self.peek() == null or !digit(self.peek().?)) return error.Bad;
        if (self.text[start] == '0' and start + 1 < self.text.len and digit(self.text[start + 1])) return error.Bad;
        var n: i64 = 0;
        while (self.peek()) |c| {
            if (!digit(c)) break;
            const d: i64 = c - '0';
            if (n > @divTrunc(std.math.maxInt(i64) - d, 10)) return error.Bad;
            n = n * 10 + d;
            self.i += 1;
        }
        if (self.i == start) return error.Bad;
        if (self.peek()) |c| {
            if (c == '.' or c == 'e' or c == 'E') return error.Bad;
        }
        if (!neg) return n;
        if (n == 0) return 0;
        return -n;
    }

    fn parseString(self: *Parser) ParseError![]const u8 {
        self.skip();
        try self.expect('"');
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        while (self.peek()) |c| {
            if (c == '"') {
                self.i += 1;
                return buf.toOwnedSlice(self.arena);
            }
            if (c == '\\') {
                self.i += 1;
                const esc = self.peek() orelse return error.Bad;
                self.i += 1;
                switch (esc) {
                    '"', '\\', '/' => try buf.append(self.arena, esc),
                    'b' => try buf.append(self.arena, 0x08),
                    'f' => try buf.append(self.arena, 0x0c),
                    'n' => try buf.append(self.arena, '\n'),
                    'r' => try buf.append(self.arena, '\r'),
                    't' => try buf.append(self.arena, '\t'),
                    'u' => try self.appendUnicode(&buf),
                    else => return error.Bad,
                }
                continue;
            }
            if (c < 0x20) return error.Bad;
            try buf.append(self.arena, c);
            self.i += 1;
        }
        return error.Bad;
    }

    fn appendUnicode(self: *Parser, buf: *std.ArrayListUnmanaged(u8)) ParseError!void {
        const cp = try self.hex4();
        const full: u21 = if (cp >= 0xD800 and cp <= 0xDBFF) blk: {
            if (!self.eat('\\') or !self.eat('u')) return error.Bad;
            const low = try self.hex4();
            if (low < 0xDC00 or low > 0xDFFF) return error.Bad;
            break :blk @intCast(0x10000 + ((@as(u21, cp) - 0xD800) << 10) + (@as(u21, low) - 0xDC00));
        } else if (cp >= 0xDC00 and cp <= 0xDFFF) {
            return error.Bad;
        } else @intCast(cp);
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(full, &tmp) catch return error.Bad;
        try buf.appendSlice(self.arena, tmp[0..n]);
    }

    fn hex4(self: *Parser) ParseError!u16 {
        var n: u16 = 0;
        var k: usize = 0;
        while (k < 4) : (k += 1) {
            const c = self.peek() orelse return error.Bad;
            const d: u16 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return error.Bad,
            };
            n = (n << 4) | d;
            self.i += 1;
        }
        return n;
    }

    fn parseStringList(self: *Parser) ParseError![][]const u8 {
        self.skip();
        try self.expect('[');
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        self.skip();
        if (self.eat(']')) return list.toOwnedSlice(self.arena);
        while (true) {
            try list.append(self.arena, try self.parseString());
            self.skip();
            if (self.eat(']')) return list.toOwnedSlice(self.arena);
            try self.expect(',');
        }
    }

    fn parseManifest(self: *Parser) ParseError!Manifest {
        self.skip();
        try self.expect('{');
        var seen = [_]bool{false} ** 7;
        var schema_version: i64 = 0;
        var package: @FieldType(Manifest, "package") = .{ .name = "", .version = "" };
        var producer: @FieldType(Manifest, "producer") = .{ .ahpy_version = "", .cython_base = "", .source_digest = "", .compiler_options_digest = "" };
        var host: @FieldType(Manifest, "host") = .{ .profile = "", .hpy_abi = "", .hpy_version = "", .required_capabilities = &.{} };
        var module: @FieldType(Manifest, "module") = .{ .name = "", .init_symbol = "" };
        var exports: []Export = &.{};
        var artifacts: []Artifact = &.{};
        self.skip();
        if (!self.eat('}')) {
            while (true) {
                const field = try self.parseString();
                self.skip();
                try self.expect(':');
                const idx: ?usize = if (std.mem.eql(u8, field, "schema_version")) 0 else if (std.mem.eql(u8, field, "package")) 1 else if (std.mem.eql(u8, field, "producer")) 2 else if (std.mem.eql(u8, field, "host")) 3 else if (std.mem.eql(u8, field, "module")) 4 else if (std.mem.eql(u8, field, "exports")) 5 else if (std.mem.eql(u8, field, "artifacts")) 6 else null;
                const slot = idx orelse return error.Bad;
                if (seen[slot]) return error.Bad;
                seen[slot] = true;
                switch (slot) {
                    0 => schema_version = try self.parseI64(),
                    1 => package = try self.parsePackage(),
                    2 => producer = try self.parseProducer(),
                    3 => host = try self.parseHost(),
                    4 => module = try self.parseModule(),
                    5 => exports = try self.parseExports(),
                    6 => artifacts = try self.parseArtifacts(),
                    else => unreachable,
                }
                self.skip();
                if (self.eat('}')) break;
                try self.expect(',');
            }
        }
        for (seen) |ok| if (!ok) return error.Bad;
        self.skip();
        if (self.i != self.text.len) return error.Bad;
        return .{
            .schema_version = schema_version,
            .package = package,
            .producer = producer,
            .host = host,
            .module = module,
            .exports = exports,
            .artifacts = artifacts,
        };
    }

    fn parsePackage(self: *Parser) ParseError!@FieldType(Manifest, "package") {
        self.skip();
        try self.expect('{');
        var seen = [_]bool{false} ** 2;
        var name: []const u8 = "";
        var version: []const u8 = "";
        try self.fillTwo("name", "version", &seen, &name, &version);
        if (!seen[0] or !seen[1]) return error.Bad;
        return .{ .name = name, .version = version };
    }

    fn parseProducer(self: *Parser) ParseError!@FieldType(Manifest, "producer") {
        self.skip();
        try self.expect('{');
        var seen = [_]bool{false} ** 4;
        var ahpy_version: []const u8 = "";
        var cython_base: []const u8 = "";
        var source_digest: []const u8 = "";
        var compiler_options_digest: []const u8 = "";
        self.skip();
        if (!self.eat('}')) {
            while (true) {
                const key = try self.fieldKey();
                const idx: ?usize = field4(key, "ahpy_version", "cython_base", "source_digest", "compiler_options_digest");
                const slot = idx orelse return error.Bad;
                if (seen[slot]) return error.Bad;
                seen[slot] = true;
                const value = try self.parseString();
                switch (slot) {
                    0 => ahpy_version = value,
                    1 => cython_base = value,
                    2 => source_digest = value,
                    3 => compiler_options_digest = value,
                    else => unreachable,
                }
                if (try self.endObject()) break;
            }
        }
        for (seen) |ok| if (!ok) return error.Bad;
        return .{ .ahpy_version = ahpy_version, .cython_base = cython_base, .source_digest = source_digest, .compiler_options_digest = compiler_options_digest };
    }

    fn parseHost(self: *Parser) ParseError!@FieldType(Manifest, "host") {
        self.skip();
        try self.expect('{');
        var seen = [_]bool{false} ** 4;
        var profile_s: []const u8 = "";
        var abi: []const u8 = "";
        var version: []const u8 = "";
        var caps: [][]const u8 = &.{};
        self.skip();
        if (!self.eat('}')) {
            while (true) {
                const key = try self.fieldKey();
                const idx: ?usize = field4(key, "profile", "hpy_abi", "hpy_version", "required_capabilities");
                const slot = idx orelse return error.Bad;
                if (seen[slot]) return error.Bad;
                seen[slot] = true;
                switch (slot) {
                    0 => profile_s = try self.parseString(),
                    1 => abi = try self.parseString(),
                    2 => version = try self.parseString(),
                    3 => caps = try self.parseStringList(),
                    else => unreachable,
                }
                if (try self.endObject()) break;
            }
        }
        for (seen) |ok| if (!ok) return error.Bad;
        return .{ .profile = profile_s, .hpy_abi = abi, .hpy_version = version, .required_capabilities = caps };
    }

    fn parseModule(self: *Parser) ParseError!@FieldType(Manifest, "module") {
        self.skip();
        try self.expect('{');
        var seen = [_]bool{false} ** 2;
        var name: []const u8 = "";
        var init_symbol: []const u8 = "";
        try self.fillTwo("name", "init_symbol", &seen, &name, &init_symbol);
        if (!seen[0] or !seen[1]) return error.Bad;
        return .{ .name = name, .init_symbol = init_symbol };
    }

    fn parseExports(self: *Parser) ParseError![]Export {
        self.skip();
        try self.expect('[');
        var list: std.ArrayListUnmanaged(Export) = .empty;
        self.skip();
        if (self.eat(']')) return list.toOwnedSlice(self.arena);
        while (true) {
            try list.append(self.arena, try self.parseExport());
            self.skip();
            if (self.eat(']')) return list.toOwnedSlice(self.arena);
            try self.expect(',');
        }
    }

    fn parseExport(self: *Parser) ParseError!Export {
        self.skip();
        try self.expect('{');
        var seen = [_]bool{false} ** 4;
        var kind: []const u8 = "";
        var name: []const u8 = "";
        var parameters: []Parameter = &.{};
        var result: Result = .{ .kind = "", .ownership = "" };
        self.skip();
        if (!self.eat('}')) {
            while (true) {
                const key = try self.fieldKey();
                const idx: ?usize = field4(key, "kind", "name", "parameters", "result");
                const slot = idx orelse return error.Bad;
                if (seen[slot]) return error.Bad;
                seen[slot] = true;
                switch (slot) {
                    0 => kind = try self.parseString(),
                    1 => name = try self.parseString(),
                    2 => parameters = try self.parseParameters(),
                    3 => result = try self.parseResult(),
                    else => unreachable,
                }
                if (try self.endObject()) break;
            }
        }
        for (seen) |ok| if (!ok) return error.Bad;
        return .{ .kind = kind, .name = name, .parameters = parameters, .result = result };
    }

    fn parseParameters(self: *Parser) ParseError![]Parameter {
        self.skip();
        try self.expect('[');
        var list: std.ArrayListUnmanaged(Parameter) = .empty;
        self.skip();
        if (self.eat(']')) return list.toOwnedSlice(self.arena);
        while (true) {
            try list.append(self.arena, try self.parseParameter());
            self.skip();
            if (self.eat(']')) return list.toOwnedSlice(self.arena);
            try self.expect(',');
        }
    }

    fn parseParameter(self: *Parser) ParseError!Parameter {
        self.skip();
        try self.expect('{');
        var seen = [_]bool{false} ** 4;
        var name: []const u8 = "";
        var kind: []const u8 = "";
        var call_kind: []const u8 = "";
        var ownership: []const u8 = "";
        self.skip();
        if (!self.eat('}')) {
            while (true) {
                const key = try self.fieldKey();
                const idx: ?usize = field4(key, "name", "kind", "call_kind", "ownership");
                const slot = idx orelse return error.Bad;
                if (seen[slot]) return error.Bad;
                seen[slot] = true;
                const value = try self.parseString();
                switch (slot) {
                    0 => name = value,
                    1 => kind = value,
                    2 => call_kind = value,
                    3 => ownership = value,
                    else => unreachable,
                }
                if (try self.endObject()) break;
            }
        }
        for (seen) |ok| if (!ok) return error.Bad;
        return .{ .name = name, .kind = kind, .call_kind = call_kind, .ownership = ownership };
    }

    fn parseResult(self: *Parser) ParseError!Result {
        self.skip();
        try self.expect('{');
        var seen = [_]bool{false} ** 2;
        var kind: []const u8 = "";
        var ownership: []const u8 = "";
        try self.fillTwo("kind", "ownership", &seen, &kind, &ownership);
        if (!seen[0] or !seen[1]) return error.Bad;
        return .{ .kind = kind, .ownership = ownership };
    }

    fn parseArtifacts(self: *Parser) ParseError![]Artifact {
        self.skip();
        try self.expect('[');
        var list: std.ArrayListUnmanaged(Artifact) = .empty;
        self.skip();
        if (self.eat(']')) return list.toOwnedSlice(self.arena);
        while (true) {
            try list.append(self.arena, try self.parseArtifact());
            self.skip();
            if (self.eat(']')) return list.toOwnedSlice(self.arena);
            try self.expect(',');
        }
    }

    fn parseArtifact(self: *Parser) ParseError!Artifact {
        self.skip();
        try self.expect('{');
        var seen = [_]bool{false} ** 4;
        var target: []const u8 = "";
        var path: []const u8 = "";
        var sha256: []const u8 = "";
        var size: i64 = 0;
        self.skip();
        if (!self.eat('}')) {
            while (true) {
                const key = try self.fieldKey();
                const idx: ?usize = field4(key, "target", "path", "sha256", "size");
                const slot = idx orelse return error.Bad;
                if (seen[slot]) return error.Bad;
                seen[slot] = true;
                switch (slot) {
                    0 => target = try self.parseString(),
                    1 => path = try self.parseString(),
                    2 => sha256 = try self.parseString(),
                    3 => size = try self.parseI64(),
                    else => unreachable,
                }
                if (try self.endObject()) break;
            }
        }
        for (seen) |ok| if (!ok) return error.Bad;
        return .{ .target = target, .path = path, .sha256 = sha256, .size = size };
    }

    fn fillTwo(self: *Parser, a: []const u8, b: []const u8, seen: *[2]bool, left: *[]const u8, right: *[]const u8) ParseError!void {
        self.skip();
        if (self.eat('}')) return;
        while (true) {
            const key = try self.fieldKey();
            const slot: usize = if (std.mem.eql(u8, key, a)) 0 else if (std.mem.eql(u8, key, b)) 1 else return error.Bad;
            if (seen[slot]) return error.Bad;
            seen[slot] = true;
            const value = try self.parseString();
            if (slot == 0) left.* = value else right.* = value;
            if (try self.endObject()) return;
        }
    }

    fn fieldKey(self: *Parser) ParseError![]const u8 {
        const name = try self.parseString();
        self.skip();
        try self.expect(':');
        return name;
    }

    fn endObject(self: *Parser) ParseError!bool {
        self.skip();
        if (self.eat('}')) return true;
        try self.expect(',');
        return false;
    }
};

fn digit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn field4(key: []const u8, a: []const u8, b: []const u8, c: []const u8, d: []const u8) ?usize {
    if (std.mem.eql(u8, key, a)) return 0;
    if (std.mem.eql(u8, key, b)) return 1;
    if (std.mem.eql(u8, key, c)) return 2;
    if (std.mem.eql(u8, key, d)) return 3;
    return null;
}

fn parseManifest(allocator: std.mem.Allocator, text: []const u8) ParseError!Manifest {
    var parser: Parser = .{ .text = text, .i = 0, .arena = allocator };
    return parser.parseManifest();
}

fn semantic(m: Manifest, target: []const u8) ?Reject {
    if (m.schema_version != 1) return .{ .code = .schema, .message = "schema_version 1 olmak zorunda" };
    if (!packageNameOk(m.package.name) or m.package.version.len == 0) return .{ .code = .schema, .message = "paket adı veya sürümü geçersiz" };
    if (!std.mem.eql(u8, m.host.profile, profile)) return .{ .code = .schema, .message = "profil nox-hpy-host-v1 değil" };
    if (!std.mem.eql(u8, m.host.hpy_abi, hpy_abi) or !std.mem.eql(u8, m.host.hpy_version, hpy_version)) {
        return .{ .code = .schema, .message = "HPy ABI veya sürümü uyuşmuyor" };
    }
    if (!hexLen(m.producer.cython_base, 40) or !hexLen(m.producer.source_digest, 64) or !hexLen(m.producer.compiler_options_digest, 64)) {
        return .{ .code = .schema, .message = "üretici özeti geçersiz" };
    }
    if (m.producer.ahpy_version.len == 0) return .{ .code = .schema, .message = "ahpy_version boş" };
    if (capabilities(m.host.required_capabilities)) |rej| return rej;
    if (!moduleNameOk(m.module.name) or !initSymbolOk(m.module.init_symbol)) return .{ .code = .schema, .message = "modül adı veya init sembolü geçersiz" };
    if (m.artifacts.len == 0) return .{ .code = .schema, .message = "artefakt listesi boş" };
    var seen_target = [_]bool{false} ** targets.len;
    for (m.artifacts) |art| {
        const idx = targetIndex(art.target) orelse return .{ .code = .target, .message = "bilinmeyen hedef" };
        if (seen_target[idx]) return .{ .code = .integrity, .message = "aynı hedef iki kez kayıtlı" };
        seen_target[idx] = true;
        if (pathRejected(art.path)) return .{ .code = .integrity, .message = "artefakt yolu paket kökünün dışına çıkıyor" };
        if (!std.mem.endsWith(u8, art.path, ".hpy0")) return .{ .code = .integrity, .message = "artefakt .hpy0 ile bitmiyor" };
        if (!hexLen(art.sha256, 64) or art.size < 1) return .{ .code = .integrity, .message = "artefakt özeti veya boyutu geçersiz" };
    }
    for (m.exports) |exp| {
        if (exportRejected(exp, m.host.required_capabilities)) |rej| return rej;
    }
    _ = target;
    return null;
}

fn capabilities(list: []const []const u8) ?Reject {
    for (required_capabilities) |need| {
        if (!contains(list, need)) return .{ .code = .capability, .message = "zorunlu yetenek eksik" };
    }
    for (list, 0..) |cap, i| {
        if (!hasRequiredCapability(cap) and !contains(&optional_capabilities, cap)) {
            return .{ .code = .schema, .message = "bilinmeyen yetenek" };
        }
        for (list[0..i]) |prev| {
            if (std.mem.eql(u8, prev, cap)) return .{ .code = .schema, .message = "yetenek yineleniyor" };
        }
    }
    return null;
}

fn exportRejected(exp: Export, caps: []const []const u8) ?Reject {
    if (!std.mem.eql(u8, exp.kind, "constructor") and !std.mem.eql(u8, exp.kind, "method") and !std.mem.eql(u8, exp.kind, "module-function")) {
        return .{ .code = .call, .message = "çağrı biçimi v1 paket yolunda yok" };
    }
    if (exp.name.len == 0) return .{ .code = .schema, .message = "dışa aktarma adı boş" };
    const bytes_ok = contains(caps, "bytes");
    const kw_ok = contains(caps, "call-keywords");
    for (exp.parameters) |p| {
        if (p.name.len == 0 or std.mem.indexOfScalar(u8, p.name, '*') != null) {
            return .{ .code = .call, .message = "değişken argüman veya boş parametre adı" };
        }
        if (kindRejected(p.kind, bytes_ok)) |rej| return rej;
        if (!std.mem.eql(u8, p.call_kind, "positional-only")) {
            if (!kw_ok) return .{ .code = .call, .message = "anahtarlı çağrı yeteneği yok" };
            if (!std.mem.eql(u8, p.call_kind, "keyword-only") and !std.mem.eql(u8, p.call_kind, "positional-or-keyword")) {
                return .{ .code = .call, .message = "çağrı biçimi desteklenmiyor" };
            }
        }
        if (ownershipRejected(p.kind, p.ownership, false)) |rej| return rej;
    }
    if (kindRejected(exp.result.kind, bytes_ok)) |rej| return rej;
    if (ownershipRejected(exp.result.kind, exp.result.ownership, true)) |rej| return rej;
    return null;
}

fn kindRejected(kind: []const u8, bytes_ok: bool) ?Reject {
    if (std.mem.eql(u8, kind, "bytes")) {
        if (!bytes_ok) return .{ .code = .capability, .message = "bytes yeteneği yok" };
        return null;
    }
    const ok = [_][]const u8{ "none", "void", "bool", "int64", "float64", "unicode", "opaque-object" };
    if (!contains(&ok, kind)) return .{ .code = .type_unsupported, .message = "tip v1 paket yolunda yok" };
    return null;
}

fn ownershipRejected(kind: []const u8, ownership: []const u8, is_result: bool) ?Reject {
    const object = std.mem.eql(u8, kind, "opaque-object");
    if (is_result) {
        if (object) {
            if (!std.mem.eql(u8, ownership, "owned")) return .{ .code = .ownership, .message = "opak sonuç owned olmalı" };
        } else if (!std.mem.eql(u8, ownership, "value")) {
            return .{ .code = .ownership, .message = "skaler sonuç value olmalı" };
        }
        return null;
    }
    if (object) {
        if (!std.mem.eql(u8, ownership, "borrowed")) return .{ .code = .ownership, .message = "opak parametre borrowed olmalı" };
    } else if (!std.mem.eql(u8, ownership, "value")) {
        return .{ .code = .ownership, .message = "skaler parametre value olmalı" };
    }
    return null;
}

pub fn callAllowed(m: Manifest, name: []const u8, result_kind: []const u8, argc: usize, keyword: bool) ?Reject {
    const kw_ok = contains(m.host.required_capabilities, "call-keywords");
    if (keyword and !kw_ok) {
        return .{ .code = .call, .message = "anahtarlı çağrı yeteneği yok" };
    }
    for (m.exports) |exp| {
        if (!std.mem.eql(u8, exp.name, name)) continue;
        if (!std.mem.eql(u8, exp.result.kind, result_kind)) {
            return .{ .code = .type_unsupported, .message = "dönüş tipi manifestteki dışa aktarmayla uyuşmuyor" };
        }
        if (exp.parameters.len != argc) return .{ .code = .call, .message = "argüman sayısı manifestle uyuşmuyor" };
        for (exp.parameters) |p| {
            const kw_param = std.mem.eql(u8, p.call_kind, "keyword-only");
            const either = std.mem.eql(u8, p.call_kind, "positional-or-keyword");
            const positional = std.mem.eql(u8, p.call_kind, "positional-only");
            if (kw_param and !keyword) {
                return .{ .code = .call, .message = "yalnızca anahtarlı parametre konumsal girişten geçemez" };
            }
            if (keyword and positional) {
                return .{ .code = .call, .message = "konumsal parametre anahtarlı girişten geçemez" };
            }
            if (!kw_param and !either and !positional) {
                return .{ .code = .call, .message = "çağrı biçimi desteklenmiyor" };
            }
            if (std.mem.eql(u8, p.kind, "list") or std.mem.eql(u8, p.kind, "dict") or std.mem.eql(u8, p.kind, "tuple")) {
                return .{ .code = .type_unsupported, .message = "kap paket yolunda yok" };
            }
        }
        return null;
    }
    return .{ .code = .schema, .message = "dışa aktarma manifestte yok" };
}

pub fn keywordArgOk(m: Manifest, name: []const u8, key: []const u8) bool {
    for (m.exports) |exp| {
        if (!std.mem.eql(u8, exp.name, name)) continue;
        for (exp.parameters) |p| {
            if (!std.mem.eql(u8, p.name, key)) continue;
            return !std.mem.eql(u8, p.call_kind, "positional-only");
        }
        return false;
    }
    return false;
}

/// İmaj, seçilen hedefin 64-bit biçimi değilse init'ten önce reddedilir.
pub fn imageRejected(target: []const u8, bytes: []const u8) bool {
    if (targetIndex(target) == null or bytes.len < 64) return true;
    if (std.mem.startsWith(u8, bytes, "\x7fELF")) {
        if (!std.mem.startsWith(u8, target, "linux-") or bytes[4] != 2) return true;
        const machine = std.mem.readInt(u16, bytes[18..20], .little);
        const want: u16 = if (std.mem.endsWith(u8, target, "aarch64")) 183 else 62;
        return machine != want;
    }
    const magic = std.mem.readInt(u32, bytes[0..4], .little);
    if (magic == 0xFEEDFACE or magic == 0xCEFAEDFE) return true;
    if (magic == 0xFEEDFACF) {
        if (!std.mem.startsWith(u8, target, "macos-")) return true;
        const cpu = std.mem.readInt(u32, bytes[4..8], .little);
        const want: u32 = if (std.mem.endsWith(u8, target, "aarch64")) 0x0100000C else 0x01000007;
        return cpu != want;
    }
    if (bytes[0] == 'M' and bytes[1] == 'Z') {
        if (!std.mem.eql(u8, target, "windows-x86_64")) return true;
        const lfanew = std.mem.readInt(u32, bytes[0x3C..0x40], .little);
        if (lfanew > bytes.len - 6) return true;
        const off: usize = @intCast(lfanew);
        if (!std.mem.eql(u8, bytes[off..][0..4], "PE\x00\x00")) return true;
        const machine = std.mem.readInt(u16, bytes[off + 4 ..][0..2], .little);
        if (machine != 0x8664) return true;
        if (off + 24 + 2 > bytes.len) return true;
        const pe32_plus = std.mem.readInt(u16, bytes[off + 24 ..][0..2], .little);
        return pe32_plus != 0x20b;
    }
    return true;
}

pub fn unicodeOk(bytes: []const u8) bool {
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == 0) return false;
        if (i + 2 < bytes.len and bytes[i] == 0xED and bytes[i + 1] >= 0xA0 and bytes[i + 1] <= 0xBF) return false;
        i += 1;
    }
    return true;
}

pub fn floatOk(v: f64) bool {
    return std.math.isFinite(v);
}

pub fn pathRejected(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or path[0] == '\\') return true;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return true;
    var it = std.mem.splitScalar(u8, path, '/');
    var parts: usize = 0;
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return true;
        parts += 1;
    }
    return parts == 0;
}

/// Paket kökü mutlak olabilir. `..`, `.` ve boş bileşen yine de reddedilir.
pub fn rootRejected(path: []const u8) bool {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, '\\') != null) return true;
    if (std.mem.eql(u8, path, ".")) return false;
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return true;
        parts += 1;
    }
    return parts == 0;
}

pub fn digestMatches(bytes: []const u8, expected_hex: []const u8, expected_size: i64) bool {
    if (expected_size < 0 or bytes.len != @as(usize, @intCast(expected_size))) return false;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var hex_buf: [64]u8 = undefined;
    const actual = hexEncode(&hex_buf, &digest);
    return std.mem.eql(u8, actual, expected_hex);
}

pub fn moduleConflict(module_a: []const u8, id_a: []const u8, module_b: []const u8, id_b: []const u8) bool {
    if (module_a.len == 0 or module_b.len == 0) return false;
    if (!std.mem.eql(u8, module_a, module_b)) return false;
    return !std.mem.eql(u8, id_a, id_b);
}

pub fn evidenceAgrees(pin_version: []const u8, running_version: []const u8, pin_commit: []const u8, evidence_commit: []const u8) bool {
    if (!std.mem.eql(u8, pin_version, running_version)) return false;
    if (!std.mem.eql(u8, pin_commit, evidence_commit)) return false;
    return pin_commit.len == 40 and hexLen(pin_commit, 40);
}

fn artifactIndex(m: Manifest, target: []const u8) ?usize {
    for (m.artifacts, 0..) |art, i| {
        if (std.mem.eql(u8, art.target, target)) return i;
    }
    return null;
}

fn targetIndex(name: []const u8) ?usize {
    for (targets, 0..) |t, i| {
        if (std.mem.eql(u8, t, name)) return i;
    }
    return null;
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

fn packageNameOk(name: []const u8) bool {
    if (name.len == 0 or name[0] < 'a' or name[0] > 'z') return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn moduleNameOk(name: []const u8) bool {
    if (name.len == 0) return false;
    var start = true;
    for (name) |c| {
        if (c == '.') {
            start = true;
            continue;
        }
        const ident = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_' or (!start and c >= '0' and c <= '9');
        if (!ident) return false;
        start = false;
    }
    return !start and name[0] != '.';
}

fn initSymbolOk(name: []const u8) bool {
    const prefix = "HPyInit_";
    if (!std.mem.startsWith(u8, name, prefix) or name.len == prefix.len) return false;
    for (name[prefix.len..], 0..) |c, i| {
        const ident = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_' or (i != 0 and c >= '0' and c <= '9');
        if (!ident) return false;
    }
    return true;
}

fn hexLen(text: []const u8, n: usize) bool {
    if (text.len != n) return false;
    for (text) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!ok) return false;
    }
    return true;
}

fn hexEncode(buf: *[64]u8, digest: *const [32]u8) []const u8 {
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        buf[i * 2] = hex_chars[byte >> 4];
        buf[i * 2 + 1] = hex_chars[byte & 0xF];
    }
    return buf;
}

const posix = struct {
    extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
    extern "c" fn openat(dirfd: c_int, path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
};

fn nofollow() c_int {
    return switch (builtin.os.tag) {
        .macos, .ios, .watchos, .tvos => 0x100,
        // aarch64 Linux (glibc ve musl) 0x8000 kullanır. x86_64 ve riscv64
        // asm-generic değeridir: 0x20000.
        .linux => switch (builtin.cpu.arch) {
            .aarch64, .aarch64_be => 0x8000,
            else => 0x20000,
        },
        else => 0,
    };
}

fn directoryFlag() c_int {
    return switch (builtin.os.tag) {
        .macos, .ios, .watchos, .tvos => 0x100000,
        .linux => switch (builtin.cpu.arch) {
            .aarch64, .aarch64_be => 0x4000,
            else => 0x10000,
        },
        else => 0,
    };
}

fn readWindowsPackageFile(allocator: std.mem.Allocator, root: [*:0]const u8, rel: []const u8, max: usize) ![]u8 {
    const w = std.os.windows;
    const nt = w.ntdll;
    var wide: std.ArrayListUnmanaged(u16) = .empty;
    defer wide.deinit(allocator);
    const root_text = std.mem.span(root);
    try appendNtPrefix(allocator, &wide, root_text);
    var parent = try ntOpen(wide.items, null, true);
    var it = std.mem.splitScalar(u8, rel, '/');
    var pending: ?[]const u8 = null;
    while (it.next()) |part| {
        if (pending) |prev| {
            const next = ntOpenChild(allocator, parent, prev, true) catch {
                _ = nt.NtClose(parent);
                return error.RejectedPath;
            };
            _ = nt.NtClose(parent);
            parent = next;
        }
        pending = part;
    }
    const last = pending orelse {
        _ = nt.NtClose(parent);
        return error.RejectedPath;
    };
    const file = ntOpenChild(allocator, parent, last, false) catch {
        _ = nt.NtClose(parent);
        return error.RejectedPath;
    };
    _ = nt.NtClose(parent);
    defer _ = nt.NtClose(file);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        var ios: w.IO_STATUS_BLOCK = undefined;
        const status = nt.NtReadFile(file, null, null, null, &ios, &buf, buf.len, null, null);
        if (status == .END_OF_FILE) break;
        if (status != .SUCCESS) return error.RejectedPath;
        const n: usize = @intCast(ios.Information);
        if (n == 0) break;
        if (out.items.len + n > max) return error.RejectedPath;
        try out.appendSlice(allocator, buf[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

extern "kernel32" fn GetCurrentDirectoryW(n: u32, buf: [*]u16) callconv(.winapi) u32;

fn kernel32_get_cwd(buf: [*]u16, n: usize) u32 {
    return GetCurrentDirectoryW(@intCast(n), buf);
}

fn appendNtPrefix(allocator: std.mem.Allocator, wide: *std.ArrayListUnmanaged(u16), text: []const u8) !void {
    const prefix = [_]u16{ '\\', '?', '?', '\\' };
    try wide.appendSlice(allocator, &prefix);
    if (windowsAbsolute(text)) {
        try appendUtf16(allocator, wide, text);
        return;
    }
    var cwd: [4096]u16 = undefined;
    const n = kernel32_get_cwd(&cwd, cwd.len);
    if (n == 0 or n >= cwd.len) return error.RejectedPath;
    try wide.appendSlice(allocator, cwd[0..n]);
    if (std.mem.eql(u8, text, ".")) return;
    if (n > 0 and cwd[n - 1] != '\\') try wide.append(allocator, '\\');
    try appendUtf16(allocator, wide, text);
}

fn windowsAbsolute(text: []const u8) bool {
    if (text.len >= 3 and text[1] == ':' and (text[2] == '\\' or text[2] == '/')) {
        const c = text[0];
        if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) return true;
    }
    return text.len >= 2 and text[0] == '\\' and text[1] == '\\';
}

fn appendUtf16(allocator: std.mem.Allocator, wide: *std.ArrayListUnmanaged(u16), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '/') {
            try wide.append(allocator, '\\');
            i += 1;
            continue;
        }
        if (c < 0x80) {
            try wide.append(allocator, c);
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch return error.RejectedPath;
        if (i + len > text.len) return error.RejectedPath;
        const cp = std.unicode.utf8Decode(text[i..][0..len]) catch return error.RejectedPath;
        var tmp: [2]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&tmp, text[i..][0..len]) catch return error.RejectedPath;
        _ = cp;
        try wide.appendSlice(allocator, tmp[0..n]);
        i += len;
    }
}

fn ntOpen(name: []const u16, parent: ?std.os.windows.HANDLE, directory: bool) !std.os.windows.HANDLE {
    return ntOpenNamed(name, parent, directory);
}

fn ntOpenChild(allocator: std.mem.Allocator, parent: std.os.windows.HANDLE, part: []const u8, directory: bool) !std.os.windows.HANDLE {
    var wide: std.ArrayListUnmanaged(u16) = .empty;
    defer wide.deinit(allocator);
    try appendUtf16(allocator, &wide, part);
    return ntOpenNamed(wide.items, parent, directory);
}

fn ntOpenNamed(name: []const u16, parent: ?std.os.windows.HANDLE, directory: bool) !std.os.windows.HANDLE {
    const w = std.os.windows;
    var unicode = w.UNICODE_STRING.init(name);
    var attr = w.OBJECT.ATTRIBUTES{
        .RootDirectory = parent,
        .ObjectName = &unicode,
        .Attributes = .{ .CASE_INSENSITIVE = true },
    };
    var ios: w.IO_STATUS_BLOCK = undefined;
    var handle: w.HANDLE = undefined;
    const access = w.ACCESS_MASK.Specific.File.GENERIC_READ;
    const mode: w.FILE.MODE = .{
        .DIRECTORY_FILE = directory,
        .NON_DIRECTORY_FILE = !directory,
        .OPEN_REPARSE_POINT = true,
        .IO = .SYNCHRONOUS_NONALERT,
    };
    const status = w.ntdll.NtCreateFile(&handle, access, &attr, &ios, null, .{}, .{ .READ = true }, .OPEN, mode, null, 0);
    if (status != .SUCCESS) return error.RejectedPath;
    return handle;
}

/// Paket köküne göre yolu, `..` ve sembolik bağ izlemeden okur.
/// Sözlük bileşeni bir sembolik bağsa açılış başarısız olur.
fn posixHost() bool {
    return switch (builtin.os.tag) {
        .linux, .macos, .ios, .watchos, .tvos => true,
        else => false,
    };
}

pub fn readPackageFile(allocator: std.mem.Allocator, root: [*:0]const u8, rel: []const u8, max: usize) ![]u8 {
    if (rootRejected(std.mem.span(root)) or pathRejected(rel)) return error.RejectedPath;
    if (comptime posixHost()) return readPosixPackageFile(allocator, root, rel, max);
    if (comptime builtin.os.tag == .windows) return readWindowsPackageFile(allocator, root, rel, max);
    return error.RejectedPath;
}

fn readPosixPackageFile(allocator: std.mem.Allocator, root: [*:0]const u8, rel: []const u8, max: usize) ![]u8 {
    const root_fd = posix.open(root, 0 | directoryFlag() | nofollow(), 0);
    if (root_fd < 0) return error.RejectedPath;
    var dir_fd = root_fd;
    errdefer _ = posix.close(dir_fd);
    var it = std.mem.splitScalar(u8, rel, '/');
    var pending: ?[]const u8 = null;
    while (it.next()) |part| {
        if (pending) |prev| {
            var name_buf: [256]u8 = undefined;
            if (prev.len >= name_buf.len) return error.RejectedPath;
            @memcpy(name_buf[0..prev.len], prev);
            name_buf[prev.len] = 0;
            const next = posix.openat(dir_fd, @ptrCast(&name_buf), 0 | directoryFlag() | nofollow(), 0);
            if (next < 0) return error.RejectedPath;
            _ = posix.close(dir_fd);
            dir_fd = next;
        }
        pending = part;
    }
    const last = pending orelse return error.RejectedPath;
    var name_buf: [256]u8 = undefined;
    if (last.len >= name_buf.len) return error.RejectedPath;
    @memcpy(name_buf[0..last.len], last);
    name_buf[last.len] = 0;
    const file_fd = posix.openat(dir_fd, @ptrCast(&name_buf), nofollow(), 0);
    _ = posix.close(dir_fd);
    dir_fd = -1;
    if (file_fd < 0) return error.RejectedPath;
    defer _ = posix.close(file_fd);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = posix.read(file_fd, &buf, buf.len);
        if (n < 0) return error.RejectedPath;
        if (n == 0) break;
        if (out.items.len + @as(usize, @intCast(n)) > max) return error.RejectedPath;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return out.toOwnedSlice(allocator);
}

pub fn policyAgrees(text: []const u8) bool {
    if (std.mem.indexOf(u8, text, "profile = \"nox-hpy-host-v1\"") == null) return false;
    if (std.mem.indexOf(u8, text, "reverse_direction_supported = false") == null) return false;
    if (std.mem.indexOf(u8, text, "hpy_abi = \"universal\"") == null) return false;
    if (std.mem.indexOf(u8, text, "hpy_version = \"0.9\"") == null) return false;
    if (std.mem.indexOf(u8, text, "artifact_selection = \"exact-target\"") == null) return false;
    for (required_capabilities) |cap| {
        if (std.mem.indexOf(u8, text, cap) == null) return false;
    }
    for (targets) |t| {
        if (std.mem.indexOf(u8, text, t) == null) return false;
    }
    const codes = [_][]const u8{ "AHPY_NOX001", "AHPY_NOX002", "AHPY_NOX003", "AHPY_NOX004", "AHPY_NOX005", "AHPY_NOX006", "AHPY_NOX007", "AHPY_NOX008" };
    for (codes) |code| {
        if (std.mem.indexOf(u8, text, code) == null) return false;
    }
    return true;
}

fn expectCode(allocator: std.mem.Allocator, text: []const u8, target: []const u8, code: Code) !void {
    var decision = validateText(allocator, text, target);
    switch (decision) {
        .ok => |*accepted| {
            accepted.deinit();
            return error.ExpectedReject;
        },
        .reject => |rej| try std.testing.expectEqual(code, rej.code),
    }
}

fn readRepoFile(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const root = try allocator.dupeZ(u8, ".");
    defer allocator.free(root);
    return readPackageFile(allocator, root, rel, 1024 * 1024);
}

test "profil sabiti pinli politikayla aynı" {
    if (builtin.os.tag == .windows) return;
    const allocator = std.testing.allocator;
    const policy = try readRepoFile(allocator, "tests/compat/hpy_host/nox-integration-policy.toml");
    defer allocator.free(policy);
    try std.testing.expect(policyAgrees(policy));
    const schema = try readRepoFile(allocator, "tests/compat/hpy_host/nox-hpy-package.schema.json");
    defer allocator.free(schema);
    try std.testing.expect(std.mem.indexOf(u8, schema, profile) != null);
    const pin = try readRepoFile(allocator, "tests/compat/hpy_host/PIN");
    defer allocator.free(pin);
    try std.testing.expect(std.mem.indexOf(u8, pin, ahpy_commit) != null);
    try std.testing.expect(std.mem.indexOf(u8, pin, nox_commit) != null);
    const zon = try readRepoFile(allocator, "build.zig.zon");
    defer allocator.free(zon);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".version = \"" ++ noxc_version ++ "\"") != null);
    try std.testing.expect(evidenceAgrees(noxc_version, noxc_version, nox_commit, nox_commit));
    try std.testing.expect(!evidenceAgrees("2.0.9", noxc_version, nox_commit, nox_commit));
    try std.testing.expect(!evidenceAgrees(noxc_version, noxc_version, nox_commit, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
}

test "bozuk sürüm, yanlış hedef ve eksik yetenek initten önce düşer" {
    if (builtin.os.tag == .windows) return;
    const allocator = std.testing.allocator;
    const base = try readRepoFile(allocator, "tests/compat/hpy_host/nox-hpy.json");
    defer allocator.free(base);
    var ok = validateText(allocator, base, "linux-x86_64");
    switch (ok) {
        .ok => |*accepted| {
            defer accepted.deinit();
            try std.testing.expectEqualStrings("artifacts/sample-linux-x86_64.hpy0", accepted.artifact().path);
            try std.testing.expect(callAllowed(accepted.manifest(), "answer", "int64", 0, false) == null);
            try std.testing.expect(callAllowed(accepted.manifest(), "answer", "list", 0, false) != null);
        },
        .reject => return error.ExpectedAccept,
    }
    const bad_profile = std.mem.replaceOwned(u8, allocator, base, "\"nox-hpy-host-v1\"", "\"other\"") catch return error.OutOfMemory;
    defer allocator.free(bad_profile);
    try expectCode(allocator, bad_profile, "linux-x86_64", .schema);
    const missing_cap = std.mem.replaceOwned(u8, allocator, base, "\"module-close\",\n", "") catch return error.OutOfMemory;
    defer allocator.free(missing_cap);
    try expectCode(allocator, missing_cap, "linux-x86_64", .capability);
    try expectCode(allocator, base, "freebsd-x86_64", .target);
}

test "yol, hash, bytes ve anahtarlı çağrı initten önce düşer" {
    try std.testing.expect(pathRejected("../x.hpy0"));
    try std.testing.expect(pathRejected("/tmp/x.hpy0"));
    try std.testing.expect(!pathRejected("artifacts/sample.hpy0"));
    try std.testing.expect(rootRejected("tests/compat/hpy_host/../hpy_host"));
    try std.testing.expect(!rootRejected("/tmp/pkg"));
    try std.testing.expect(!rootRejected("."));
    try std.testing.expect(!rootRejected("tests/compat/hpy_host"));
    try std.testing.expect(!unicodeOk("a\x00b"));
    try std.testing.expect(!unicodeOk("\xED\xA0\x80"));
    try std.testing.expect(unicodeOk("Tema"));
    try std.testing.expect(!floatOk(std.math.nan(f64)));
    try std.testing.expect(floatOk(1.5));
    const bytes = "nox-hpy-host-v1\n";
    try std.testing.expect(digestMatches(bytes, "3ee098f3b2b8fa68a11159a97857f64f1108de5e1a96a873ddeed8c90a34a945", 16));
    try std.testing.expect(!digestMatches(bytes, "3ee098f3b2b8fa68a11159a97857f64f1108de5e1a96a873ddeed8c90a34a945", 15));
    try std.testing.expect(moduleConflict("sampleext", "aaa", "sampleext", "bbb"));
    try std.testing.expect(!moduleConflict("sampleext", "aaa", "sampleext", "aaa"));
    try std.testing.expect(!moduleConflict("sampleext", "aaa", "other", "bbb"));

    if (builtin.os.tag == .windows) return;
    const allocator = std.testing.allocator;
    const base = try readRepoFile(allocator, "tests/compat/hpy_host/nox-hpy.json");
    defer allocator.free(base);
    const no_opt = std.mem.replaceOwned(u8, allocator, base, ",\n      \"bytes\",\n      \"call-keywords\"\n", "") catch return error.OutOfMemory;
    defer allocator.free(no_opt);
    const with_bytes = std.mem.replaceOwned(u8, allocator, no_opt, "\"parameters\": []", "\"parameters\": [{\"name\": \"b\", \"kind\": \"bytes\", \"call_kind\": \"positional-only\", \"ownership\": \"value\"}]") catch return error.OutOfMemory;
    defer allocator.free(with_bytes);
    try expectCode(allocator, with_bytes, "linux-x86_64", .capability);
    const with_kw = std.mem.replaceOwned(u8, allocator, no_opt, "\"parameters\": []", "\"parameters\": [{\"name\": \"k\", \"kind\": \"int64\", \"call_kind\": \"keyword-only\", \"ownership\": \"value\"}]") catch return error.OutOfMemory;
    defer allocator.free(with_kw);
    try expectCode(allocator, with_kw, "linux-x86_64", .call);
    var ok_caps = validateText(allocator, base, "linux-x86_64");
    switch (ok_caps) {
        .ok => |*accepted| {
            defer accepted.deinit();
            const m = accepted.manifest();
            try std.testing.expect(callAllowed(m, "echo_bytes", "bytes", 1, false) == null);
            try std.testing.expect(callAllowed(m, "twice", "int64", 1, true) == null);
            try std.testing.expect(callAllowed(m, "twice", "int64", 1, false) != null);
            try std.testing.expect(keywordArgOk(m, "twice", "n"));
            try std.testing.expect(!keywordArgOk(m, "twice", "x"));
        },
        .reject => return error.ExpectedAccept,
    }
    var elf = [_]u8{0} ** 64;
    elf[0] = 0x7f;
    elf[1] = 'E';
    elf[2] = 'L';
    elf[3] = 'F';
    elf[4] = 1;
    try std.testing.expect(imageRejected("linux-x86_64", &elf));
    elf[4] = 2;
    std.mem.writeInt(u16, elf[18..20], 62, .little);
    try std.testing.expect(!imageRejected("linux-x86_64", &elf));
    try std.testing.expect(imageRejected("linux-aarch64", &elf));
    try std.testing.expect(imageRejected("macos-aarch64", &elf));
    var macho = [_]u8{0} ** 64;
    std.mem.writeInt(u32, macho[0..4], 0xFEEDFACE, .little);
    try std.testing.expect(imageRejected("macos-aarch64", &macho));
    std.mem.writeInt(u32, macho[0..4], 0xFEEDFACF, .little);
    std.mem.writeInt(u32, macho[4..8], 0x0100000C, .little);
    try std.testing.expect(!imageRejected("macos-aarch64", &macho));
    try std.testing.expect(imageRejected("linux-aarch64", &macho));
    const with_list = std.mem.replaceOwned(u8, allocator, base, "\"kind\": \"int64\"", "\"kind\": \"list\"") catch return error.OutOfMemory;
    defer allocator.free(with_list);
    try expectCode(allocator, with_list, "linux-x86_64", .type_unsupported);
}

test "her hedef imajı kendi dosyasıyla eşleşir" {
    if (builtin.os.tag == .windows) return;
    const allocator = std.testing.allocator;
    const text = try readRepoFile(allocator, "tests/compat/hpy_host/nox-hpy.json");
    defer allocator.free(text);
    for (targets) |name| {
        const decision = validateText(allocator, text, name);
        var accepted = switch (decision) {
            .ok => |acc| acc,
            .reject => return error.UnexpectedReject,
        };
        defer accepted.deinit();
        const rel = try std.fmt.allocPrint(allocator, "tests/compat/hpy_host/{s}", .{accepted.artifact().path});
        defer allocator.free(rel);
        const bytes = try readRepoFile(allocator, rel);
        defer allocator.free(bytes);
        try std.testing.expect(digestMatches(bytes, accepted.artifact().sha256, accepted.artifact().size));
        try std.testing.expect(!imageRejected(name, bytes));
    }
}

test "pinli artefakt hash'i paket kökünden okunur" {
    if (builtin.os.tag == .windows) return;
    const allocator = std.testing.allocator;
    const bytes = try readRepoFile(allocator, "tests/compat/hpy_host/artifacts/sample.hpy0");
    defer allocator.free(bytes);
    try std.testing.expect(digestMatches(bytes, "da7f2ea97527ff91a70b7f5f542ba7d9189e0d0ffb4352487d2e3bb36141db2e", 50552));
    try std.testing.expect(!imageRejected("macos-aarch64", bytes));
    try std.testing.expect(imageRejected("linux-x86_64", bytes));
    try std.testing.expect(imageRejected("windows-x86_64", bytes));
    const root = try allocator.dupeZ(u8, "tests/compat/hpy_host");
    defer allocator.free(root);
    try std.testing.expectError(error.RejectedPath, readPackageFile(allocator, root, "../sample.hpy0", 1024));
}
