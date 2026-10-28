//! `nox.regex` Zig kabuğu — TODO 8.8: Python `re` alt kümesinin tam bir geri-izlemeli motoru.
//!
//! Mimari: desen → AST (`Parser`) → komut programı (`Compiler`) → açık yığınlı geri-izleme VM'i (`Vm`). Özyineleme metin uzunluğuna
//! bağlı DEĞİLDİR (fiber yığını 256 KiB; bkz. GG.23): geri-izleme durumu yığında (heap) tutulur, adım ve yığın sayısı sınırlıdır.
//! Girdi UTF-8'dir; `.`/sınıflar kod noktası, konumlar BAYT indeksidir.
//!
//! Desteklenenler: literal, `.`, `[...]` (aralık, olumsuz, `\d\w\s` içinde), `* + ? {m} {m,} {m,n} {,n}` (+ tembel `?` soneki),
//! `( )` yakalama, `(?: )`, `(?P<ad> )`/`(?<ad> )`, `|`, `^ $ \A \z \Z \b \B`, `\d \D \w \W \s \S`, `\n \t \r \f \v \0 \xHH \uHHHH`,
//! geri başvuru `\1`-`\99`, ileri bakış `(?= )`/`(?! )`, genel bayraklar `(?i)`/`(?m)`/`(?s)` (desen başında) ve çağrı bayrakları.
//! Desteklenmeyenler: geri bakış `(?<= )`, sahiplenici/atomik gruplar, koşullu desenler, `\p{..}` özellik sınıfları.
//! Güvenlik: toplam VM adımı sınırlıdır; sınır aşılırsa o arama "eşleşme yok" döner (motor hiçbir zaman sonsuz döngüye girmez).

const std = @import("std");
const arc = @import("../alloc/arc.zig");
const str_mod = @import("../str.zig");
const unicode = @import("../unicode.zig");

const LIST_HEADER_SIZE: usize = 16;
const FIELD_SLOT_SIZE: usize = 8;

pub const FLAG_ICASE: i64 = 1;
pub const FLAG_MULTILINE: i64 = 2;
pub const FLAG_DOTALL: i64 = 4;
/// Yalnızca `from` konumunda eşleş (Python `match`).
pub const FLAG_ANCHORED: i64 = 8;
/// Eşleşme metnin sonuna kadar sürmeli (Python `fullmatch`).
pub const FLAG_FULL: i64 = 16;

const MAX_PROGRAM: usize = 50_000;
const MAX_REPEAT: u32 = 1000;
const MAX_STEPS: u64 = 20_000_000;
const MAX_FRAMES: usize = 4_000_000;

// ---------------------------------------------------------------- AST ----

const ClassItem = union(enum) {
    range: struct { lo: u32, hi: u32 },
    digit: bool, // true = olumsuz (\D)
    word: bool,
    space: bool,
};

const Class = struct { negate: bool, items: []const ClassItem };

const Node = union(enum) {
    empty,
    char: u32,
    any,
    class: u32,
    cat: []const *Node,
    alt: []const *Node,
    repeat: struct { node: *Node, min: u32, max: ?u32, greedy: bool },
    group: struct { node: *Node, index: ?u32 },
    bol,
    eol,
    text_start,
    text_end,
    text_end_nl,
    wordb,
    nwordb,
    backref: u32,
    look: struct { node: *Node, negate: bool },
};

const ParseError = error{ Syntax, OutOfMemory };

const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    classes: std.ArrayList(Class) = .empty,
    names: std.ArrayList([]const u8) = .empty, // names[i-1] = i. grubun adı ("" = adsız)
    ngroups: u32 = 0,
    flags: i64 = 0,
    err: []const u8 = "",

    fn fail(self: *Parser, msg: []const u8) ParseError {
        if (self.err.len == 0) self.err = msg;
        return error.Syntax;
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn nextCp(self: *Parser) ParseError!u32 {
        const l = std.unicode.utf8ByteSequenceLength(self.src[self.pos]) catch return self.fail("invalid UTF-8 in pattern");
        if (self.pos + l > self.src.len) return self.fail("invalid UTF-8 in pattern");
        const cp = std.unicode.utf8Decode(self.src[self.pos..][0..l]) catch return self.fail("invalid UTF-8 in pattern");
        self.pos += l;
        return cp;
    }

    fn mk(self: *Parser, n: Node) ParseError!*Node {
        const p = try self.arena.create(Node);
        p.* = n;
        return p;
    }

    fn parseAll(self: *Parser) ParseError!*Node {
        // Desen başındaki genel bayraklar: (?i) (?ms) ...
        while (self.pos + 2 < self.src.len and self.src[self.pos] == '(' and self.src[self.pos + 1] == '?') {
            var j = self.pos + 2;
            var f: i64 = 0;
            while (j < self.src.len and (self.src[j] == 'i' or self.src[j] == 'm' or self.src[j] == 's')) : (j += 1) {
                f |= switch (self.src[j]) {
                    'i' => FLAG_ICASE,
                    'm' => FLAG_MULTILINE,
                    else => FLAG_DOTALL,
                };
            }
            if (j > self.pos + 2 and j < self.src.len and self.src[j] == ')') {
                self.flags |= f;
                self.pos = j + 1;
            } else break;
        }
        const n = try self.parseAlt();
        if (self.pos < self.src.len) return self.fail("unbalanced parenthesis");
        return n;
    }

    fn parseAlt(self: *Parser) ParseError!*Node {
        var branches: std.ArrayList(*Node) = .empty;
        try branches.append(self.arena, try self.parseCat());
        while (self.peek() == '|') {
            self.pos += 1;
            try branches.append(self.arena, try self.parseCat());
        }
        if (branches.items.len == 1) return branches.items[0];
        return self.mk(.{ .alt = try branches.toOwnedSlice(self.arena) });
    }

    fn parseCat(self: *Parser) ParseError!*Node {
        var items: std.ArrayList(*Node) = .empty;
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            var atom = try self.parseAtom();
            atom = try self.parseQuantifiers(atom);
            try items.append(self.arena, atom);
        }
        if (items.items.len == 0) return self.mk(.empty);
        if (items.items.len == 1) return items.items[0];
        return self.mk(.{ .cat = try items.toOwnedSlice(self.arena) });
    }

    fn quantifiable(n: *Node) bool {
        return switch (n.*) {
            .bol, .eol, .text_start, .text_end, .text_end_nl, .wordb, .nwordb, .look => false,
            else => true,
        };
    }

    fn parseBrace(self: *Parser) ?struct { min: u32, max: ?u32, end: usize } {
        // self.src[self.pos] == '{'
        var j = self.pos + 1;
        var min: u32 = 0;
        var have_min = false;
        while (j < self.src.len and std.ascii.isDigit(self.src[j])) : (j += 1) {
            min = std.math.mul(u32, min, 10) catch return null;
            min = std.math.add(u32, min, self.src[j] - '0') catch return null;
            have_min = true;
        }
        if (j >= self.src.len) return null;
        if (self.src[j] == '}') {
            if (!have_min) return null;
            return .{ .min = min, .max = min, .end = j + 1 };
        }
        if (self.src[j] != ',') return null;
        j += 1;
        var max: u32 = 0;
        var have_max = false;
        while (j < self.src.len and std.ascii.isDigit(self.src[j])) : (j += 1) {
            max = std.math.mul(u32, max, 10) catch return null;
            max = std.math.add(u32, max, self.src[j] - '0') catch return null;
            have_max = true;
        }
        if (j >= self.src.len or self.src[j] != '}') return null;
        if (!have_min and !have_max) return null;
        return .{ .min = min, .max = if (have_max) max else null, .end = j + 1 };
    }

    fn parseQuantifiers(self: *Parser, atom_in: *Node) ParseError!*Node {
        var atom = atom_in;
        while (self.peek()) |c| {
            var min: u32 = 0;
            var max: ?u32 = null;
            switch (c) {
                '*' => self.pos += 1,
                '+' => {
                    min = 1;
                    self.pos += 1;
                },
                '?' => {
                    max = 1;
                    self.pos += 1;
                },
                '{' => {
                    const b = self.parseBrace() orelse return atom;
                    min = b.min;
                    max = b.max;
                    self.pos = b.end;
                    if (max) |m| if (min > m) return self.fail("min repeat greater than max repeat");
                    if (min > MAX_REPEAT or (max orelse 0) > MAX_REPEAT) return self.fail("repeat count too large");
                },
                else => return atom,
            }
            if (!quantifiable(atom)) return self.fail("nothing to repeat");
            var greedy = true;
            if (self.peek() == '?') {
                greedy = false;
                self.pos += 1;
            } else if (self.peek() == '+' or self.peek() == '*') {
                return self.fail("multiple repeat");
            }
            atom = try self.mk(.{ .repeat = .{ .node = atom, .min = min, .max = max, .greedy = greedy } });
        }
        return atom;
    }

    fn parseAtom(self: *Parser) ParseError!*Node {
        const c = self.src[self.pos];
        switch (c) {
            '(' => return self.parseGroup(),
            '[' => return self.parseClass(),
            '.' => {
                self.pos += 1;
                return self.mk(.any);
            },
            '^' => {
                self.pos += 1;
                return self.mk(.bol);
            },
            '$' => {
                self.pos += 1;
                return self.mk(.eol);
            },
            '*', '+', '?' => return self.fail("nothing to repeat"),
            '\\' => return self.parseEscape(),
            else => {
                const cp = try self.nextCp();
                return self.mk(.{ .char = cp });
            },
        }
    }

    fn newClass(self: *Parser, negate: bool, items: []const ClassItem) ParseError!*Node {
        try self.classes.append(self.arena, .{ .negate = negate, .items = items });
        return self.mk(.{ .class = @intCast(self.classes.items.len - 1) });
    }

    fn hexVal(self: *Parser, digits: usize) ParseError!u32 {
        if (self.pos + digits > self.src.len) return self.fail("incomplete escape");
        var v: u32 = 0;
        for (self.src[self.pos..][0..digits]) |h| {
            const d = std.fmt.charToDigit(h, 16) catch return self.fail("bad escape (invalid hex digit)");
            v = v * 16 + d;
        }
        self.pos += digits;
        return v;
    }

    /// `\` sonrası; ortak kaçışlar. `in_class`: sınıf içinde `\b` geri silmedir, çapa/geri başvuru yoktur.
    fn escapeChar(self: *Parser) ParseError!?u32 {
        const e = self.src[self.pos];
        switch (e) {
            'n' => {
                self.pos += 1;
                return '\n';
            },
            't' => {
                self.pos += 1;
                return '\t';
            },
            'r' => {
                self.pos += 1;
                return '\r';
            },
            'f' => {
                self.pos += 1;
                return 0x0C;
            },
            'v' => {
                self.pos += 1;
                return 0x0B;
            },
            'a' => {
                self.pos += 1;
                return 0x07;
            },
            'x' => {
                self.pos += 1;
                return try self.hexVal(2);
            },
            'u' => {
                self.pos += 1;
                return try self.hexVal(4);
            },
            'U' => {
                self.pos += 1;
                return try self.hexVal(8);
            },
            else => return null,
        }
    }

    fn parseEscape(self: *Parser) ParseError!*Node {
        self.pos += 1; // '\'
        if (self.pos >= self.src.len) return self.fail("bad escape (end of pattern)");
        const e = self.src[self.pos];
        if (try self.escapeChar()) |cp| return self.mk(.{ .char = cp });
        switch (e) {
            'd', 'D' => {
                self.pos += 1;
                return self.newClass(false, try self.arena.dupe(ClassItem, &.{.{ .digit = e == 'D' }}));
            },
            'w', 'W' => {
                self.pos += 1;
                return self.newClass(false, try self.arena.dupe(ClassItem, &.{.{ .word = e == 'W' }}));
            },
            's', 'S' => {
                self.pos += 1;
                return self.newClass(false, try self.arena.dupe(ClassItem, &.{.{ .space = e == 'S' }}));
            },
            'b' => {
                self.pos += 1;
                return self.mk(.wordb);
            },
            'B' => {
                self.pos += 1;
                return self.mk(.nwordb);
            },
            'A' => {
                self.pos += 1;
                return self.mk(.text_start);
            },
            'z' => {
                self.pos += 1;
                return self.mk(.text_end);
            },
            'Z' => {
                self.pos += 1;
                return self.mk(.text_end_nl);
            },
            '0' => {
                self.pos += 1;
                return self.mk(.{ .char = 0 });
            },
            '1'...'9' => {
                var n: u32 = 0;
                var digits: usize = 0;
                while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos]) and digits < 2) : (self.pos += 1) {
                    n = n * 10 + (self.src[self.pos] - '0');
                    digits += 1;
                }
                // Grup henüz tanımlanmamışsa (ileri başvuru) derleme sonunda doğrulanır.
                return self.mk(.{ .backref = n });
            },
            else => {
                if (std.ascii.isAlphabetic(e)) return self.fail("bad escape");
                const cp = try self.nextCp();
                return self.mk(.{ .char = cp });
            },
        }
    }

    fn parseGroup(self: *Parser) ParseError!*Node {
        self.pos += 1; // '('
        var index: ?u32 = null;
        var look: ?bool = null; // olumsuz mu
        if (self.peek() == '?') {
            self.pos += 1;
            const k = self.peek() orelse return self.fail("unexpected end of pattern");
            switch (k) {
                ':' => self.pos += 1,
                '=' => {
                    self.pos += 1;
                    look = false;
                },
                '!' => {
                    self.pos += 1;
                    look = true;
                },
                'P', '<' => {
                    if (k == 'P') {
                        self.pos += 1;
                        if (self.peek() != '<') return self.fail("unknown extension ?P");
                    } else if (self.pos + 1 < self.src.len and (self.src[self.pos + 1] == '=' or self.src[self.pos + 1] == '!')) {
                        return self.fail("lookbehind is not supported");
                    }
                    self.pos += 1; // '<'
                    const start = self.pos;
                    while (self.pos < self.src.len and self.src[self.pos] != '>') : (self.pos += 1) {}
                    if (self.pos >= self.src.len) return self.fail("missing > in group name");
                    const name = self.src[start..self.pos];
                    self.pos += 1;
                    if (name.len == 0) return self.fail("empty group name");
                    for (self.names.items) |nm| if (std.mem.eql(u8, nm, name)) return self.fail("redefinition of group name");
                    self.ngroups += 1;
                    index = self.ngroups;
                    try self.names.append(self.arena, name);
                },
                else => return self.fail("unknown group extension"),
            }
        } else {
            self.ngroups += 1;
            index = self.ngroups;
            try self.names.append(self.arena, "");
        }
        const inner = try self.parseAlt();
        if (self.peek() != ')') return self.fail("missing ), unterminated subpattern");
        self.pos += 1;
        if (look) |neg| return self.mk(.{ .look = .{ .node = inner, .negate = neg } });
        return self.mk(.{ .group = .{ .node = inner, .index = index } });
    }

    fn parseClass(self: *Parser) ParseError!*Node {
        self.pos += 1; // '['
        var negate = false;
        if (self.peek() == '^') {
            negate = true;
            self.pos += 1;
        }
        var items: std.ArrayList(ClassItem) = .empty;
        var first = true;
        while (true) {
            if (self.pos >= self.src.len) return self.fail("unterminated character set");
            const c = self.src[self.pos];
            if (c == ']' and !first) {
                self.pos += 1;
                break;
            }
            first = false;
            var lo: u32 = undefined;
            if (c == '\\') {
                self.pos += 1;
                if (self.pos >= self.src.len) return self.fail("bad escape (end of pattern)");
                const e = self.src[self.pos];
                if (try self.escapeChar()) |cp| {
                    lo = cp;
                } else switch (e) {
                    'd', 'D' => {
                        self.pos += 1;
                        try items.append(self.arena, .{ .digit = e == 'D' });
                        continue;
                    },
                    'w', 'W' => {
                        self.pos += 1;
                        try items.append(self.arena, .{ .word = e == 'W' });
                        continue;
                    },
                    's', 'S' => {
                        self.pos += 1;
                        try items.append(self.arena, .{ .space = e == 'S' });
                        continue;
                    },
                    'b' => {
                        self.pos += 1;
                        lo = 0x08;
                    },
                    else => {
                        if (std.ascii.isAlphabetic(e) or std.ascii.isDigit(e)) return self.fail("bad escape");
                        lo = try self.nextCp();
                    },
                }
            } else {
                lo = try self.nextCp();
            }
            // Aralık? `a-z` (ama `-]` literal)
            if (self.pos + 1 < self.src.len and self.src[self.pos] == '-' and self.src[self.pos + 1] != ']') {
                self.pos += 1;
                var hi: u32 = undefined;
                if (self.src[self.pos] == '\\') {
                    self.pos += 1;
                    if (self.pos >= self.src.len) return self.fail("bad escape (end of pattern)");
                    if (try self.escapeChar()) |cp| {
                        hi = cp;
                    } else {
                        const e = self.src[self.pos];
                        if (std.ascii.isAlphabetic(e) or std.ascii.isDigit(e)) return self.fail("bad character range");
                        hi = try self.nextCp();
                    }
                } else hi = try self.nextCp();
                if (hi < lo) return self.fail("bad character range");
                try items.append(self.arena, .{ .range = .{ .lo = lo, .hi = hi } });
            } else {
                try items.append(self.arena, .{ .range = .{ .lo = lo, .hi = lo } });
            }
        }
        return self.newClass(negate, try items.toOwnedSlice(self.arena));
    }
};

// ------------------------------------------------------------ program ----

const Op = enum { char, any, class, split, jmp, save, bol, eol, text_start, text_end, text_end_nl, wordb, nwordb, backref, look, look_end, mark, progress, match };

const Inst = struct {
    op: Op,
    x: u32 = 0,
    y: u32 = 0,
    c: u32 = 0,
};

const Program = struct {
    insts: []const Inst,
    classes: []const Class,
    ngroups: u32,
    nslots: u32, // 2*(ngroups+1) + mark sayısı
    names: []const []const u8,
    flags: i64,
};

const Compiler = struct {
    arena: std.mem.Allocator,
    insts: std.ArrayList(Inst) = .empty,
    nmarks: u32 = 0,
    ngroups: u32,
    err: []const u8 = "",

    fn emit(self: *Compiler, inst: Inst) ParseError!u32 {
        if (self.insts.items.len >= MAX_PROGRAM) {
            self.err = "pattern is too large";
            return error.Syntax;
        }
        try self.insts.append(self.arena, inst);
        return @intCast(self.insts.items.len - 1);
    }

    fn pc(self: *Compiler) u32 {
        return @intCast(self.insts.items.len);
    }

    fn canBeEmpty(n: *const Node) bool {
        return switch (n.*) {
            .empty, .bol, .eol, .text_start, .text_end, .text_end_nl, .wordb, .nwordb, .look, .backref => true,
            .char, .any, .class => false,
            .cat => |items| blk: {
                for (items) |i| if (!canBeEmpty(i)) break :blk false;
                break :blk true;
            },
            .alt => |items| blk: {
                for (items) |i| if (canBeEmpty(i)) break :blk true;
                break :blk false;
            },
            .repeat => |r| r.min == 0 or canBeEmpty(r.node),
            .group => |g| canBeEmpty(g.node),
        };
    }

    fn gen(self: *Compiler, n: *const Node) ParseError!void {
        switch (n.*) {
            .empty => {},
            .char => |c| _ = try self.emit(.{ .op = .char, .c = c }),
            .any => _ = try self.emit(.{ .op = .any }),
            .class => |i| _ = try self.emit(.{ .op = .class, .c = i }),
            .bol => _ = try self.emit(.{ .op = .bol }),
            .eol => _ = try self.emit(.{ .op = .eol }),
            .text_start => _ = try self.emit(.{ .op = .text_start }),
            .text_end => _ = try self.emit(.{ .op = .text_end }),
            .text_end_nl => _ = try self.emit(.{ .op = .text_end_nl }),
            .wordb => _ = try self.emit(.{ .op = .wordb }),
            .nwordb => _ = try self.emit(.{ .op = .nwordb }),
            .backref => |k| {
                if (k == 0 or k > self.ngroups) {
                    self.err = "invalid group reference";
                    return error.Syntax;
                }
                _ = try self.emit(.{ .op = .backref, .c = k });
            },
            .cat => |items| for (items) |i| try self.gen(i),
            .alt => |items| {
                // split L1, next; L1: a; jmp END; next: split ...
                var jmps: std.ArrayList(u32) = .empty;
                for (items, 0..) |b, bi| {
                    if (bi + 1 < items.len) {
                        const sp = try self.emit(.{ .op = .split });
                        self.insts.items[sp].x = self.pc();
                        try self.gen(b);
                        try jmps.append(self.arena, try self.emit(.{ .op = .jmp }));
                        self.insts.items[sp].y = self.pc();
                    } else try self.gen(b);
                }
                for (jmps.items) |j| self.insts.items[j].x = self.pc();
            },
            .group => |g| {
                if (g.index) |idx| {
                    _ = try self.emit(.{ .op = .save, .c = idx * 2 });
                    try self.gen(g.node);
                    _ = try self.emit(.{ .op = .save, .c = idx * 2 + 1 });
                } else try self.gen(g.node);
            },
            .look => |l| {
                const lk = try self.emit(.{ .op = .look, .c = @intFromBool(l.negate) });
                try self.gen(l.node);
                _ = try self.emit(.{ .op = .look_end });
                self.insts.items[lk].x = self.pc();
            },
            .repeat => |r| try self.genRepeat(r.node, r.min, r.max, r.greedy),
        }
    }

    fn genRepeat(self: *Compiler, node: *const Node, min: u32, max: ?u32, greedy: bool) ParseError!void {
        var i: u32 = 0;
        while (i < min) : (i += 1) try self.gen(node);
        if (max) |m| {
            // (m - min) isteğe bağlı kopya: split(next, END) x
            var splits: std.ArrayList(u32) = .empty;
            var k: u32 = min;
            while (k < m) : (k += 1) {
                const sp = try self.emit(.{ .op = .split });
                if (greedy) self.insts.items[sp].x = self.pc() else self.insts.items[sp].y = self.pc();
                try splits.append(self.arena, sp);
                try self.gen(node);
            }
            for (splits.items) |sp| {
                if (greedy) self.insts.items[sp].y = self.pc() else self.insts.items[sp].x = self.pc();
            }
        } else {
            // döngü: L1: split(L2, L3); L2: [mark] x [progress] jmp L1; L3:
            const guard = canBeEmpty(node);
            const l1 = try self.emit(.{ .op = .split });
            const l2 = self.pc();
            var slot: u32 = 0;
            if (guard) {
                slot = 2 * (self.ngroups + 1) + self.nmarks;
                self.nmarks += 1;
                _ = try self.emit(.{ .op = .mark, .c = slot });
            }
            try self.gen(node);
            if (guard) _ = try self.emit(.{ .op = .progress, .c = slot });
            const jm = try self.emit(.{ .op = .jmp });
            self.insts.items[jm].x = l1;
            const l3 = self.pc();
            if (greedy) {
                self.insts.items[l1].x = l2;
                self.insts.items[l1].y = l3;
            } else {
                self.insts.items[l1].x = l3;
                self.insts.items[l1].y = l2;
            }
        }
    }
};

fn compile(arena: std.mem.Allocator, pattern: []const u8, err_out: *[]const u8) ?Program {
    var p: Parser = .{ .arena = arena, .src = pattern };
    const root = p.parseAll() catch {
        err_out.* = if (p.err.len > 0) p.err else "out of memory";
        return null;
    };
    var c: Compiler = .{ .arena = arena, .ngroups = p.ngroups };
    const ok = blk: {
        c.gen(root) catch break :blk false;
        _ = c.emit(.{ .op = .match }) catch break :blk false;
        break :blk true;
    };
    if (!ok) {
        err_out.* = if (c.err.len > 0) c.err else "out of memory";
        return null;
    }
    return .{
        .insts = c.insts.items,
        .classes = p.classes.items,
        .ngroups = p.ngroups,
        .nslots = 2 * (p.ngroups + 1) + c.nmarks,
        .names = p.names.items,
        .flags = p.flags,
    };
}

// ------------------------------------------------------------------ VM ----

fn decodeAt(s: []const u8, i: usize) struct { cp: u32, len: usize } {
    const b = s[i];
    if (b < 0x80) return .{ .cp = b, .len = 1 };
    const l = std.unicode.utf8ByteSequenceLength(b) catch return .{ .cp = b, .len = 1 };
    if (i + l > s.len) return .{ .cp = b, .len = 1 };
    const cp = std.unicode.utf8Decode(s[i..][0..l]) catch return .{ .cp = b, .len = 1 };
    return .{ .cp = cp, .len = l };
}

fn prevCpStart(s: []const u8, pos: usize) usize {
    var i = pos - 1;
    while (i > 0 and (s[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

fn isWordCp(cp: u32) bool {
    if (cp < 0x80) return std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_';
    return unicode.isAlpha(cp) or unicode.isDecimal(cp) or unicode.isNumeric(cp);
}

fn isSpaceCp(cp: u32) bool {
    if (cp < 0x80) return std.ascii.isWhitespace(@intCast(cp)) or (cp >= 0x1C and cp <= 0x1F);
    return unicode.isSpace(cp);
}

const Frame = struct {
    kind: enum { branch, restore },
    a: u32, // branch: pc | restore: slot
    b: isize, // branch: pos | restore: eski değer
};

const Vm = struct {
    prog: *const Program,
    text: []const u8,
    flags: i64,
    caps: []isize,
    stack: std.ArrayList(Frame) = .empty,
    alloc: std.mem.Allocator,
    steps: u64 = 0,
    exhausted: bool = false,
    full: bool,

    fn foldCp(cp: u32) u32 {
        return unicode.foldSimple(cp);
    }

    fn classMatches(self: *Vm, ci: u32, cp: u32) bool {
        const cls = self.prog.classes[ci];
        var hit = self.classHas(cls, cp);
        if (!hit and (self.flags & FLAG_ICASE) != 0) {
            hit = self.classHas(cls, foldCp(cp)) or self.classHas(cls, unicode.upperSimple(cp));
        }
        return hit != cls.negate;
    }

    fn classHas(self: *Vm, cls: Class, cp: u32) bool {
        _ = self;
        for (cls.items) |it| {
            switch (it) {
                .range => |r| if (cp >= r.lo and cp <= r.hi) return true,
                .digit => |neg| if (unicode.isDecimal(cp) != neg) return true,
                .word => |neg| if (isWordCp(cp) != neg) return true,
                .space => |neg| if (isSpaceCp(cp) != neg) return true,
            }
        }
        return false;
    }

    fn push(self: *Vm, f: Frame) bool {
        if (self.stack.items.len >= MAX_FRAMES) {
            self.exhausted = true;
            return false;
        }
        self.stack.append(self.alloc, f) catch {
            self.exhausted = true;
            return false;
        };
        return true;
    }

    fn setCap(self: *Vm, slot: u32, val: isize) bool {
        if (!self.push(.{ .kind = .restore, .a = slot, .b = self.caps[slot] })) return false;
        self.caps[slot] = val;
        return true;
    }

    /// `pc`den başlayarak çalıştırır; `base` bu çağrının yığın tabanıdır (iç içe ileri bakış için). Eşleşirse bitiş konumunu döner.
    fn run(self: *Vm, start_pc: u32, start_pos: usize, base: usize, stop_at_look_end: bool) ?usize {
        var pc = start_pc;
        var pos = start_pos;
        while (true) {
            self.steps += 1;
            if (self.steps > MAX_STEPS) {
                self.exhausted = true;
                return null;
            }
            const inst = self.prog.insts[pc];
            var ok = true;
            switch (inst.op) {
                .char => {
                    if (pos < self.text.len) {
                        const d = decodeAt(self.text, pos);
                        const eq = d.cp == inst.c or ((self.flags & FLAG_ICASE) != 0 and foldCp(d.cp) == foldCp(inst.c));
                        if (eq) {
                            pos += d.len;
                            pc += 1;
                        } else ok = false;
                    } else ok = false;
                },
                .any => {
                    if (pos < self.text.len) {
                        const d = decodeAt(self.text, pos);
                        if (d.cp == '\n' and (self.flags & FLAG_DOTALL) == 0) {
                            ok = false;
                        } else {
                            pos += d.len;
                            pc += 1;
                        }
                    } else ok = false;
                },
                .class => {
                    if (pos < self.text.len) {
                        const d = decodeAt(self.text, pos);
                        if (self.classMatches(inst.c, d.cp)) {
                            pos += d.len;
                            pc += 1;
                        } else ok = false;
                    } else ok = false;
                },
                .split => {
                    if (!self.push(.{ .kind = .branch, .a = inst.y, .b = @intCast(pos) })) return null;
                    pc = inst.x;
                },
                .jmp => pc = inst.x,
                .save => {
                    if (!self.setCap(inst.c, @intCast(pos))) return null;
                    pc += 1;
                },
                .mark => {
                    if (!self.setCap(inst.c, @intCast(pos))) return null;
                    pc += 1;
                },
                .progress => {
                    if (self.caps[inst.c] == @as(isize, @intCast(pos))) ok = false else pc += 1;
                },
                .bol => {
                    if (pos == 0 or ((self.flags & FLAG_MULTILINE) != 0 and self.text[pos - 1] == '\n')) pc += 1 else ok = false;
                },
                .eol => {
                    const at_end = pos == self.text.len or (pos + 1 == self.text.len and self.text[pos] == '\n');
                    if (at_end or ((self.flags & FLAG_MULTILINE) != 0 and self.text[pos] == '\n')) pc += 1 else ok = false;
                },
                .text_start => {
                    if (pos == 0) pc += 1 else ok = false;
                },
                .text_end => {
                    if (pos == self.text.len) pc += 1 else ok = false;
                },
                .text_end_nl => {
                    if (pos == self.text.len or (pos + 1 == self.text.len and self.text[pos] == '\n')) pc += 1 else ok = false;
                },
                .wordb, .nwordb => {
                    const before = pos > 0 and isWordCp(decodeAt(self.text, prevCpStart(self.text, pos)).cp);
                    const after = pos < self.text.len and isWordCp(decodeAt(self.text, pos).cp);
                    const at_boundary = before != after;
                    if (at_boundary == (inst.op == .wordb)) pc += 1 else ok = false;
                },
                .backref => {
                    const s = self.caps[inst.c * 2];
                    const e = self.caps[inst.c * 2 + 1];
                    if (s < 0 or e < 0) {
                        ok = false;
                    } else {
                        const sub = self.text[@intCast(s)..@intCast(e)];
                        if (pos + sub.len <= self.text.len and self.sliceEq(sub, self.text[pos..][0..sub.len])) {
                            pos += sub.len;
                            pc += 1;
                        } else ok = false;
                    }
                },
                .look => {
                    // Alt programı kendi yığın tabanıyla çalıştır; sonuç olumlu/olumsuz kuralına göre değerlendirilir.
                    const sub_base = self.stack.items.len;
                    var snapshot: ?[]isize = null;
                    if (self.alloc.alloc(isize, self.caps.len)) |s| {
                        @memcpy(s, self.caps);
                        snapshot = s;
                    } else |_| {
                        self.exhausted = true;
                        return null;
                    }
                    const matched = self.run(pc + 1, pos, sub_base, true) != null;
                    if (self.exhausted) return null;
                    // Alt yığını at (olumlu ya da olumsuz fark etmez), yakalamaları geri yükle.
                    self.stack.shrinkRetainingCapacity(sub_base);
                    const snap = snapshot.?;
                    if (matched and inst.c == 0) {
                        // Olumlu başarı: alt programdaki yakalamalar kalır; geri izleme için geri yükleme çerçeveleri it.
                        for (self.caps, 0..) |v, si| {
                            if (v != snap[si]) {
                                const newv = v;
                                self.caps[si] = snap[si];
                                if (!self.setCap(@intCast(si), newv)) return null;
                            }
                        }
                        pc = inst.x;
                    } else if (!matched and inst.c == 1) {
                        @memcpy(self.caps, snap);
                        pc = inst.x;
                    } else {
                        @memcpy(self.caps, snap);
                        ok = false;
                    }
                    self.alloc.free(snap);
                },
                .look_end => {
                    if (stop_at_look_end) return pos;
                    pc += 1;
                },
                .match => {
                    if (self.full and pos != self.text.len) {
                        ok = false;
                    } else return pos;
                },
            }
            if (!ok) {
                // Geri izle
                var resumed = false;
                while (self.stack.items.len > base) {
                    const f = self.stack.pop().?;
                    switch (f.kind) {
                        .restore => self.caps[f.a] = f.b,
                        .branch => {
                            pc = f.a;
                            pos = @intCast(f.b);
                            resumed = true;
                            break;
                        },
                    }
                }
                if (!resumed) return null;
            }
        }
    }

    fn sliceEq(self: *Vm, a: []const u8, b: []const u8) bool {
        if ((self.flags & FLAG_ICASE) == 0) return std.mem.eql(u8, a, b);
        if (a.len != b.len) {
            return false;
        }
        var i: usize = 0;
        while (i < a.len) {
            const da = decodeAt(a, i);
            const db = decodeAt(b, i);
            if (da.len != db.len or foldCp(da.cp) != foldCp(db.cp)) return false;
            i += da.len;
        }
        return true;
    }
};

/// `text` içinde `from` konumundan başlayarak ilk eşleşmeyi arar; başarıda `caps` (grup 0 dahil) dolar.
fn search(alloc: std.mem.Allocator, prog: *const Program, text: []const u8, from: usize, flags_in: i64, caps: []isize) bool {
    const flags = flags_in | prog.flags;
    var vm: Vm = .{ .prog = prog, .text = text, .flags = flags, .caps = caps, .alloc = alloc, .full = (flags & FLAG_FULL) != 0 };
    defer vm.stack.deinit(alloc);
    var start = from;
    while (start <= text.len) {
        @memset(caps, -1);
        vm.stack.clearRetainingCapacity();
        if (vm.run(0, start, 0, false)) |end| {
            caps[0] = @intCast(start);
            caps[1] = @intCast(end);
            return true;
        }
        if (vm.exhausted or (flags & FLAG_ANCHORED) != 0) return false;
        if (start >= text.len) break;
        start += decodeAt(text, start).len;
    }
    return false;
}

// ------------------------------------------------------------ dışa açık ----

fn buildIntList(rt: ?*anyopaque, vals: []const isize) ?*anyopaque {
    const raw = arc.nox_rc_alloc(rt, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * vals.len) orelse return null;
    const base: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(base)).* = @intCast(vals.len);
    @as(*align(1) i64, @ptrCast(base + 8)).* = @intCast(vals.len);
    for (vals, 0..) |v, i| {
        const slot = base + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i;
        @as(*align(1) i64, @ptrCast(slot)).* = v;
    }
    return @ptrCast(base);
}

fn dupStr(rt: ?*anyopaque, s: []const u8) ?[*:0]u8 {
    const buf = str_mod.nox_str_alloc_buf(rt, s.len) orelse return null;
    @memcpy(buf[0..s.len], s);
    return @ptrCast(buf);
}

/// Geçerli desen için "" , aksi halde hata iletisi.
export fn nox_regex_error_raw(rt: ?*anyopaque, pattern: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var err: []const u8 = "";
    _ = compile(arena.allocator(), str_mod.nox_str_slice(pattern orelse return dupStr(rt, "")), &err);
    return dupStr(rt, err);
}

export fn nox_regex_group_count_raw(pattern: ?[*:0]const u8) callconv(.c) i64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var err: []const u8 = "";
    const prog = compile(arena.allocator(), str_mod.nox_str_slice(pattern orelse return -1), &err) orelse return -1;
    return prog.ngroups;
}

/// Grup adları `\n` ile ayrılmış (adsız grup = boş satır); toplam grup sayısı kadar giriş.
export fn nox_regex_group_names_raw(rt: ?*anyopaque, pattern: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var err: []const u8 = "";
    const prog = compile(arena.allocator(), str_mod.nox_str_slice(pattern orelse return dupStr(rt, "")), &err) orelse return dupStr(rt, "");
    var out: std.ArrayList(u8) = .empty;
    for (prog.names, 0..) |nm, i| {
        if (i > 0) out.append(arena.allocator(), '\n') catch return dupStr(rt, "");
        out.appendSlice(arena.allocator(), nm) catch return dupStr(rt, "");
    }
    return dupStr(rt, out.items);
}

/// `from` (bayt) konumundan başlayarak ardışık, çakışmayan eşleşmeleri düz bir listeye yazar: her eşleşme için `(ngroups+1)*2`
/// değer (`başlangıç, bitiş` çiftleri; eşleşmeyen grup `-1`). `limit <= 0`: sınırsız. Geçersiz desen / eşleşme yok → boş liste.
export fn nox_regex_exec_all_raw(rt: ?*anyopaque, pattern: ?[*:0]const u8, text: ?[*:0]const u8, from: i64, flags: i64, limit: i64) callconv(.c) ?*anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var err: []const u8 = "";
    const prog = compile(a, str_mod.nox_str_slice(pattern orelse return buildIntList(rt, &.{})), &err) orelse return buildIntList(rt, &.{});
    const txt = str_mod.nox_str_slice(text orelse return buildIntList(rt, &.{}));
    const caps = a.alloc(isize, prog.nslots) catch return buildIntList(rt, &.{});
    var out: std.ArrayList(isize) = .empty;
    var pos: usize = if (from < 0) 0 else @intCast(@min(from, @as(i64, @intCast(txt.len))));
    var count: i64 = 0;
    const per = (prog.ngroups + 1) * 2;
    const anchored = (flags & FLAG_ANCHORED) != 0;
    while (pos <= txt.len) {
        if (limit > 0 and count >= limit) break;
        if (!search(a, &prog, txt, pos, flags, caps)) break;
        out.appendSlice(a, caps[0..per]) catch break;
        count += 1;
        if (anchored) break;
        const s: usize = @intCast(caps[0]);
        const e: usize = @intCast(caps[1]);
        if (e == s) {
            if (e >= txt.len) break;
            pos = e + decodeAt(txt, e).len;
        } else pos = e;
    }
    return buildIntList(rt, out.items);
}

/// `text[start..end]` (bayt aralığı) alt dizesi; sınır dışı değerler kırpılır.
export fn nox_regex_slice_raw(rt: ?*anyopaque, text: ?[*:0]const u8, start: i64, end: i64) callconv(.c) ?[*:0]u8 {
    const txt = str_mod.nox_str_slice(text orelse return dupStr(rt, ""));
    const s: usize = @intCast(std.math.clamp(start, 0, @as(i64, @intCast(txt.len))));
    const e: usize = @intCast(std.math.clamp(end, 0, @as(i64, @intCast(txt.len))));
    if (e <= s) return dupStr(rt, "");
    return dupStr(rt, txt[s..e]);
}

fn simpleSearch(pattern: ?[*:0]const u8, text: ?[*:0]const u8) ?isize {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var err: []const u8 = "";
    const prog = compile(a, str_mod.nox_str_slice(pattern orelse return null), &err) orelse return null;
    const txt = str_mod.nox_str_slice(text orelse return null);
    const caps = a.alloc(isize, prog.nslots) catch return null;
    if (!search(a, &prog, txt, 0, 0, caps)) return null;
    return caps[0];
}

/// Eski API (toplam fonksiyon): geçersiz desen / eşleşme yok → 0.
export fn nox_regex_is_match_raw(pattern: ?[*:0]const u8, text: ?[*:0]const u8) callconv(.c) i32 {
    return if (simpleSearch(pattern, text) != null) 1 else 0;
}

/// İlk eşleşmenin 0-tabanlı bayt indeksi, yoksa `-1`.
export fn nox_regex_find_raw(pattern: ?[*:0]const u8, text: ?[*:0]const u8) callconv(.c) i64 {
    return simpleSearch(pattern, text) orelse -1;
}

// ---------------------------------------------------------------- testler ----

fn testSearch(pattern: []const u8, text: []const u8, flags: i64) !?[]const isize {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var err: []const u8 = "";
    const prog = compile(aa, pattern, &err) orelse return error.BadPattern;
    const caps = try aa.alloc(isize, prog.nslots);
    if (!search(aa, &prog, text, 0, flags, caps)) return null;
    const out = try a.alloc(isize, (prog.ngroups + 1) * 2);
    @memcpy(out, caps[0..out.len]);
    return out;
}

fn expectSpan(pattern: []const u8, text: []const u8, s: isize, e: isize) !void {
    const r = (try testSearch(pattern, text, 0)) orelse return error.NoMatch;
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(s, r[0]);
    try std.testing.expectEqual(e, r[1]);
}

fn expectNone(pattern: []const u8, text: []const u8) !void {
    if (try testSearch(pattern, text, 0)) |r| {
        std.testing.allocator.free(r);
        return error.UnexpectedMatch;
    }
}

test "temel: literal . * + ? ve çapalar" {
    try expectSpan("abc", "xabcy", 1, 4);
    try expectSpan("a.c", "abc", 0, 3);
    try expectNone("a.c", "ac");
    try expectSpan("ab*c", "abbbbc", 0, 6);
    try expectSpan("colou?r", "colour", 0, 6);
    try expectSpan("^abc$", "abc", 0, 3);
    try expectNone("^abc$", "xabc");
}

test "gruplar, alternation, sayısal tekrar" {
    try expectSpan("(ab|cd)+e", "xxcdabe", 2, 7);
    try expectSpan("a{2,3}", "aaaa", 0, 3);
    try expectSpan("a{2,3}?", "aaaa", 0, 2);
    try expectSpan("(?:ab){2}", "ababab", 0, 4);
    try expectNone("a{3}", "aa");
    try expectSpan("a|b|c", "zzc", 2, 3);
}

test "kaçış sınıfları ve sınırlar" {
    try expectSpan("\\d+", "ab123c", 2, 5);
    try expectSpan("\\w+", "  foo_1 ", 2, 7);
    try expectSpan("\\bfoo\\b", "a foo b", 2, 5);
    try expectNone("\\bfoo\\b", "afoob");
    try expectSpan("[^\\s]+", "  xy ", 2, 4);
    try expectSpan("[a-c\\d]+", "zz1ab2zz", 2, 6);
}

test "yakalama, geri başvuru, ileri bakış, bayraklar" {
    const r = (try testSearch("(\\w)(\\d)?", "a", 0)).?;
    defer std.testing.allocator.free(r);
    try std.testing.expectEqual(@as(isize, 0), r[2]);
    try std.testing.expectEqual(@as(isize, -1), r[4]);
    try expectSpan("(a+)b\\1", "xaabaay", 1, 6);
    try expectSpan("foo(?=bar)", "foobaz foobar", 7, 10);
    try expectSpan("foo(?!bar)", "foobar foobaz", 7, 10);
    const ic = (try testSearch("HeLLo", "say hello", FLAG_ICASE)).?;
    defer std.testing.allocator.free(ic);
    try std.testing.expectEqual(@as(isize, 4), ic[0]);
    try expectSpan("(?i)straSSE", "Straße straSSE", 8, 15);
}

test "boş eşleşen döngüler sonsuz döngüye girmez" {
    try expectSpan("(a*)*b", "aaab", 0, 4);
    try expectSpan("(a|)*c", "aac", 0, 3);
}

test "Unicode: . ve sınıflar kod noktası" {
    try expectSpan("ç.ğ", "açığ", 1, 7);
    try expectSpan("\\w+", "!!öğrenci!!", 2, 11);
}

test "geçersiz desenler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var err: []const u8 = "";
    try std.testing.expect(compile(arena.allocator(), "(ab", &err) == null);
    try std.testing.expect(compile(arena.allocator(), "*a", &err) == null);
    try std.testing.expect(compile(arena.allocator(), "[a", &err) == null);
    try std.testing.expect(compile(arena.allocator(), "a{3,2}", &err) == null);
    try std.testing.expect(compile(arena.allocator(), "\\1", &err) == null);
    try std.testing.expect(compile(arena.allocator(), "(?<=a)b", &err) == null);
}
