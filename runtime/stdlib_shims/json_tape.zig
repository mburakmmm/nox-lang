//! 2.2 aşama 3 (bkz. `project/json-bant-tasarimi-2026-11.md`): `nox.json` için bant (tape) tabanlı, TEK GEÇİŞLİ ayrıştırıcı.
//!
//! `build` girdiyi bir kez tarar (doğrulama + bant yazımı aynı geçişte) ve değişmez bir "belge bloğu" üretir:
//!
//!   [başlık 24 B: n_entries u32, n_table u32, strs_len u32, 0, cid i64 (JsonValue sınıf kimliği; bilinmiyorsa -1)]
//!   [n_entries x Entry (16 B)] [n_table x u32 çocuk tablosu] [strs: çözülmüş dize/sayı-metni baytları]
//!
//! Blok, `json.zig` tarafından bir Nox `str` nesnesi olarak (ARC'li, ikili içerikli) tutulur: `JsonValue` düğümleri belgeye bir `str` alanıyla
//! başvurur, böylece yaşam süresi/atomik sayaç sıradan ARC ile gelir (özel yıkıcı yok) ve blok sonradan HİÇ değişmez (iş parçacığı güvenli).
//!
//! Doğrulama kuralları `json.zig`nin `FastJson`ı ile BİREBİR aynıdır (RFC 8259 dilbilgisi, UTF-8/vekil çifti doğrulaması, `MAX_JSON_NESTING_DEPTH`
//! derinlik sınırı, yinelenen anahtar = hata); sayı sınıflandırması `numberLeaf` ile aynıdır (`s` metni: büyük tamsayı tam metni ya da tamsayı değerli
//! ondalığın `repr` metni).

const std = @import("std");
const str_mod = @import("../str.zig");

pub const Entry = extern struct {
    kind: u8,
    flags: u8 = 0,
    _pad: u16 = 0,
    len: u32 = 0,
    val: u64 = 0,
};

pub const K_NULL: u8 = 0;
pub const K_BOOL: u8 = 1;
pub const K_NUMBER: u8 = 2;
pub const K_STRING: u8 = 3;
pub const K_ARRAY: u8 = 4;
pub const K_OBJECT: u8 = 5;
/// Nesne anahtarı (kind `K_STRING` ile aynı alanlar; ayrı kind yalnızca hata ayıklamayı kolaylaştırır).
pub const K_KEY: u8 = 6;
/// Sayı girdisinden hemen SONRA gelen, `s` metnini (strs ofseti/uzunluğu) taşıyan yardımcı kayıt; sayı `flags & F_TEXT` ise.
pub const K_TEXT: u8 = 7;

pub const F_TEXT: u8 = 1;

pub const MAX_DEPTH: usize = 32;

pub const HEADER_SIZE: usize = 24;

/// Konteyner girdisinin `val` alanı: düşük 32 bit = bitiş girdisi indeksi (bu konteynerin alt ağacından SONRAKİ ilk girdi), yüksek 32 bit = çocuk tablosu başlangıcı.
pub inline fn packContainer(end_idx: u32, table_off: u32) u64 {
    return @as(u64, end_idx) | (@as(u64, table_off) << 32);
}
pub inline fn containerEnd(e: Entry) u32 {
    return @truncate(e.val);
}
pub inline fn containerTable(e: Entry) u32 {
    return @truncate(e.val >> 32);
}

/// Bir belge bloğunun salt-okunur görünümü.
pub const View = struct {
    entries: []align(1) const Entry,
    table: []align(1) const u32,
    strs: []const u8,
    cid: i64,

    pub fn fromBlob(blob: []const u8) View {
        const n_entries = std.mem.readInt(u32, blob[0..4], .little);
        const n_table = std.mem.readInt(u32, blob[4..8], .little);
        const strs_len = std.mem.readInt(u32, blob[8..12], .little);
        const ents_bytes = HEADER_SIZE;
        const tab_off = ents_bytes + @as(usize, n_entries) * @sizeOf(Entry);
        const strs_off = tab_off + @as(usize, n_table) * 4;
        // Blok `str` yükü olarak bayt hizasızdır: `Entry`/`u32` dilimleri hizasız okunur (yazım `@memcpy` ile yapıldı, okuma `align(1)`).
        return .{
            .entries = @as([*]align(1) const Entry, @ptrCast(blob.ptr + ents_bytes))[0..n_entries],
            .table = @as([*]align(1) const u32, @ptrCast(blob.ptr + tab_off))[0..n_table],
            .strs = blob[strs_off..][0..strs_len],
            .cid = std.mem.readInt(i64, blob[16..24], .little),
        };
    }

    pub inline fn str(self: View, e: Entry) []const u8 {
        return self.strs[@intCast(e.val)..][0..e.len];
    }

    /// Sayı girdisinin `s` metni (yoksa boş).
    pub inline fn numberText(self: View, idx: u32) []const u8 {
        const e = self.entries[idx];
        if (e.flags & F_TEXT == 0) return "";
        return self.str(self.entries[idx + 1]);
    }

    /// Konteynerin `i`. çocuğunun girdi indeksi: dizide elemanın, nesnede ANAHTAR girdisinin indeksi (değer = +1).
    pub inline fn child(self: View, idx: u32, i: usize) u32 {
        return self.table[containerTable(self.entries[idx]) + i];
    }

    /// `idx` girdisinin (skaler ya da konteyner) alt ağacından sonraki ilk girdinin indeksi.
    pub inline fn skip(self: View, idx: u32) u32 {
        const e = self.entries[idx];
        return switch (e.kind) {
            K_ARRAY, K_OBJECT => containerEnd(e),
            K_NUMBER => if (e.flags & F_TEXT != 0) idx + 2 else idx + 1,
            else => idx + 1,
        };
    }
};

/// `build` çıktısı: bölümler çağıranın allocator'ında; `blobSize`/`writeBlob` ile tek bloğa serileştirilir.
pub const Built = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    table: std.ArrayListUnmanaged(u32) = .empty,
    strs: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *Built, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.table.deinit(allocator);
        self.strs.deinit(allocator);
    }

    pub fn blobSize(self: *const Built) usize {
        return HEADER_SIZE + self.entries.items.len * @sizeOf(Entry) + self.table.items.len * 4 + self.strs.items.len;
    }

    /// `dst.len >= blobSize()`.
    pub fn writeBlob(self: *const Built, dst: []u8, cid: i64) void {
        std.mem.writeInt(u32, dst[0..4], @intCast(self.entries.items.len), .little);
        std.mem.writeInt(u32, dst[4..8], @intCast(self.table.items.len), .little);
        std.mem.writeInt(u32, dst[8..12], @intCast(self.strs.items.len), .little);
        std.mem.writeInt(u32, dst[12..16], 0, .little);
        std.mem.writeInt(i64, dst[16..24], cid, .little);
        var off: usize = HEADER_SIZE;
        const eb = std.mem.sliceAsBytes(self.entries.items);
        @memcpy(dst[off..][0..eb.len], eb);
        off += eb.len;
        const tb = std.mem.sliceAsBytes(self.table.items);
        @memcpy(dst[off..][0..tb.len], tb);
        off += tb.len;
        @memcpy(dst[off..][0..self.strs.items.len], self.strs.items);
    }
};

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    a: std.mem.Allocator,
    b: *Built,
    /// Açık konteynerlerin çocuk girdi indeksleri (yığın); konteyner kapanınca `table`a kopyalanır.
    kids: std.ArrayListUnmanaged(u32) = .empty,

    const Err = error{ Invalid, OutOfMemory };

    fn ws(self: *Parser) void {
        while (self.i < self.s.len) : (self.i += 1) {
            switch (self.s[self.i]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn lit(self: *Parser, word: []const u8) bool {
        if (self.s.len - self.i < word.len or !std.mem.eql(u8, self.s[self.i..][0..word.len], word)) return false;
        self.i += word.len;
        return true;
    }

    fn hex4(self: *const Parser, at: usize) ?u16 {
        if (at + 4 > self.s.len) return null;
        var v: u16 = 0;
        for (self.s[at..][0..4]) |c| {
            const d: u16 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return null,
            };
            v = (v << 4) | d;
        }
        return v;
    }

    /// `self.i` açılış tırnağında. Dizeyi doğrular ve ÇÖZÜLMÜŞ baytları `strs`e ekler; `out_off`/`out_len` strs içindeki aralık. Başarıda `self.i` kapanıştan sonra.
    fn string(self: *Parser, out_off: *u64, out_len: *u32) Err!void {
        self.i += 1;
        const start_len = self.b.strs.items.len;
        const s = self.s;
        // hızlı tarama: kaçışsız ve ASCII bölüm
        var j = self.i;
        while (j < s.len) : (j += 1) {
            const c = s[j];
            if (c == '"' or c == '\\' or c < 0x20 or c >= 0x80) break;
        }
        if (j < s.len and s[j] == '"') {
            // tamamı kaçışsız ASCII: tek kopya
            try self.b.strs.appendSlice(self.a, s[self.i..j]);
            self.i = j + 1;
            out_off.* = start_len;
            out_len.* = @intCast(self.b.strs.items.len - start_len);
            return;
        }
        // yavaş yol: kaçışlar / UTF-8
        try self.b.strs.appendSlice(self.a, s[self.i..j]);
        self.i = j;
        while (self.i < s.len) {
            const c = s[self.i];
            if (c == '"') {
                self.i += 1;
                out_off.* = start_len;
                out_len.* = @intCast(self.b.strs.items.len - start_len);
                return;
            }
            if (c < 0x20) return error.Invalid;
            if (c == '\\') {
                if (self.i + 1 >= s.len) return error.Invalid;
                switch (s[self.i + 1]) {
                    '"' => try self.b.strs.append(self.a, '"'),
                    '\\' => try self.b.strs.append(self.a, '\\'),
                    '/' => try self.b.strs.append(self.a, '/'),
                    'b' => try self.b.strs.append(self.a, 0x08),
                    'f' => try self.b.strs.append(self.a, 0x0C),
                    'n' => try self.b.strs.append(self.a, '\n'),
                    'r' => try self.b.strs.append(self.a, '\r'),
                    't' => try self.b.strs.append(self.a, '\t'),
                    'u' => {
                        const hi = self.hex4(self.i + 2) orelse return error.Invalid;
                        self.i += 6;
                        var cp: u21 = hi;
                        if (hi >= 0xD800 and hi <= 0xDBFF) {
                            if (self.i + 1 >= s.len or s[self.i] != '\\' or s[self.i + 1] != 'u') return error.Invalid;
                            const lo = self.hex4(self.i + 2) orelse return error.Invalid;
                            if (lo < 0xDC00 or lo > 0xDFFF) return error.Invalid;
                            self.i += 6;
                            cp = 0x10000 + ((@as(u21, hi) - 0xD800) << 10) + (@as(u21, lo) - 0xDC00);
                        } else if (hi >= 0xDC00 and hi <= 0xDFFF) {
                            return error.Invalid;
                        }
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &buf) catch return error.Invalid;
                        try self.b.strs.appendSlice(self.a, buf[0..n]);
                        continue;
                    },
                    else => return error.Invalid,
                }
                self.i += 2;
                continue;
            }
            if (c < 0x80) {
                // kaçışsız ASCII çalışmayı toplu kopyala
                var k = self.i + 1;
                while (k < s.len) : (k += 1) {
                    const d = s[k];
                    if (d == '"' or d == '\\' or d < 0x20 or d >= 0x80) break;
                }
                try self.b.strs.appendSlice(self.a, s[self.i..k]);
                self.i = k;
                continue;
            }
            const n = std.unicode.utf8ByteSequenceLength(c) catch return error.Invalid;
            if (self.i + n > s.len) return error.Invalid;
            _ = std.unicode.utf8Decode(s[self.i..][0..n]) catch return error.Invalid;
            try self.b.strs.appendSlice(self.a, s[self.i..][0..n]);
            self.i += n;
        }
        return error.Invalid;
    }

    fn numberToken(self: *Parser) Err![]const u8 {
        var i = self.i;
        const s = self.s;
        const start = i;
        if (i < s.len and s[i] == '-') i += 1;
        if (i >= s.len) return error.Invalid;
        if (s[i] == '0') {
            i += 1;
        } else if (s[i] >= '1' and s[i] <= '9') {
            while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        } else return error.Invalid;
        if (i < s.len and s[i] == '.') {
            i += 1;
            const d0 = i;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
            if (i == d0) return error.Invalid;
        }
        if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
            i += 1;
            if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
            const d0 = i;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
            if (i == d0) return error.Invalid;
        }
        self.i = i;
        return s[start..i];
    }

    fn isPlainBigInteger(s: []const u8) bool {
        var digits = s;
        if (digits.len > 0 and digits[0] == '-') digits = digits[1..];
        if (digits.len < 16) return false;
        for (digits) |c| if (c < '0' or c > '9') return false;
        return true;
    }

    /// `json.zig`nin `numberLeaf`i ile aynı sınıflandırma; metin gerekiyorsa sayı girdisinin ardına `K_TEXT` kaydı yazar.
    fn number(self: *Parser) Err!void {
        const tok = try self.numberToken();
        var n: f64 = 0;
        var text: ?[]const u8 = null;
        var fbuf: [64]u8 = undefined;
        var ibuf: [24]u8 = undefined;
        const integer_like = !std.mem.eql(u8, tok, "-0") and std.mem.indexOfAny(u8, tok, ".eE") == null;
        if (!integer_like) {
            const f = std.fmt.parseFloat(f64, tok) catch 0.0;
            n = f;
            if (std.math.isFinite(f)) {
                if (!std.mem.eql(u8, tok, "-0") and f < 1000000000000000.0 and f > -1000000000000000.0) {
                    const iv: i64 = @intFromFloat(f);
                    if (@as(f64, @floatFromInt(iv)) == f) text = str_mod.formatFloatRepr(&fbuf, f);
                }
            } else if (isPlainBigInteger(tok)) text = tok;
        } else if (std.fmt.parseInt(i64, tok, 10)) |iv| {
            n = @floatFromInt(iv);
            if (iv >= (1 << 53) or iv <= -(1 << 53)) text = std.fmt.bufPrint(&ibuf, "{d}", .{iv}) catch null;
        } else |_| {
            n = std.fmt.parseFloat(f64, tok) catch 0.0;
            if (isPlainBigInteger(tok)) text = tok;
        }
        const has_text = text != null and text.?.len > 0;
        try self.b.entries.append(self.a, .{ .kind = K_NUMBER, .flags = if (has_text) F_TEXT else 0, .val = @bitCast(n) });
        if (has_text) {
            const off = self.b.strs.items.len;
            try self.b.strs.appendSlice(self.a, text.?);
            try self.b.entries.append(self.a, .{ .kind = K_TEXT, .len = @intCast(text.?.len), .val = off });
        }
    }

    fn hasDuplicate(self: *Parser, key_idxs: []const u32) bool {
        const n = key_idxs.len;
        if (n < 2) return false;
        const view_strs = self.b.strs.items;
        const ents = self.b.entries.items;
        if (n <= 8) {
            for (key_idxs, 0..) |ai, x| {
                const a = ents[ai];
                const ab = view_strs[@intCast(a.val)..][0..a.len];
                for (key_idxs[x + 1 ..]) |bi| {
                    const b = ents[bi];
                    if (std.mem.eql(u8, ab, view_strs[@intCast(b.val)..][0..b.len])) return true;
                }
            }
            return false;
        }
        var cap: usize = 16;
        while (cap < n * 2) cap *= 2;
        const table = self.a.alloc(u32, cap) catch return true;
        defer self.a.free(table);
        @memset(table, std.math.maxInt(u32));
        for (key_idxs, 0..) |ai, x| {
            const a = ents[ai];
            const ab = view_strs[@intCast(a.val)..][0..a.len];
            var pos: usize = @intCast(std.hash.Wyhash.hash(0, ab) & (cap - 1));
            while (table[pos] != std.math.maxInt(u32)) : (pos = (pos + 1) & (cap - 1)) {
                const o = ents[key_idxs[table[pos]]];
                if (std.mem.eql(u8, ab, view_strs[@intCast(o.val)..][0..o.len])) return true;
            }
            table[pos] = @intCast(x);
        }
        return false;
    }

    fn value(self: *Parser, open_depth: usize) Err!void {
        if (self.i >= self.s.len) return error.Invalid;
        switch (self.s[self.i]) {
            '{' => return self.object(open_depth + 1),
            '[' => return self.array(open_depth + 1),
            '"' => {
                var off: u64 = 0;
                var len: u32 = 0;
                try self.string(&off, &len);
                try self.b.entries.append(self.a, .{ .kind = K_STRING, .len = len, .val = off });
            },
            't' => {
                if (!self.lit("true")) return error.Invalid;
                try self.b.entries.append(self.a, .{ .kind = K_BOOL, .val = 1 });
            },
            'f' => {
                if (!self.lit("false")) return error.Invalid;
                try self.b.entries.append(self.a, .{ .kind = K_BOOL, .val = 0 });
            },
            'n' => {
                if (!self.lit("null")) return error.Invalid;
                try self.b.entries.append(self.a, .{ .kind = K_NULL });
            },
            '-', '0'...'9' => try self.number(),
            else => return error.Invalid,
        }
    }

    fn array(self: *Parser, depth: usize) Err!void {
        if (depth > MAX_DEPTH) return error.Invalid;
        self.i += 1;
        const my = self.b.entries.items.len;
        try self.b.entries.append(self.a, .{ .kind = K_ARRAY });
        const base = self.kids.items.len;
        self.ws();
        if (self.i < self.s.len and self.s[self.i] == ']') {
            self.i += 1;
        } else {
            while (true) {
                self.ws();
                try self.kids.append(self.a, @intCast(self.b.entries.items.len));
                try self.value(depth);
                self.ws();
                if (self.i >= self.s.len) return error.Invalid;
                switch (self.s[self.i]) {
                    ',' => self.i += 1,
                    ']' => {
                        self.i += 1;
                        break;
                    },
                    else => return error.Invalid,
                }
            }
        }
        try self.close(my, base);
    }

    fn object(self: *Parser, depth: usize) Err!void {
        if (depth > MAX_DEPTH) return error.Invalid;
        self.i += 1;
        const my = self.b.entries.items.len;
        try self.b.entries.append(self.a, .{ .kind = K_OBJECT });
        const base = self.kids.items.len;
        self.ws();
        if (self.i < self.s.len and self.s[self.i] == '}') {
            self.i += 1;
        } else {
            while (true) {
                self.ws();
                if (self.i >= self.s.len or self.s[self.i] != '"') return error.Invalid;
                var off: u64 = 0;
                var len: u32 = 0;
                try self.string(&off, &len);
                try self.kids.append(self.a, @intCast(self.b.entries.items.len));
                try self.b.entries.append(self.a, .{ .kind = K_KEY, .len = len, .val = off });
                self.ws();
                if (self.i >= self.s.len or self.s[self.i] != ':') return error.Invalid;
                self.i += 1;
                self.ws();
                try self.value(depth);
                self.ws();
                if (self.i >= self.s.len) return error.Invalid;
                switch (self.s[self.i]) {
                    ',' => self.i += 1,
                    '}' => {
                        self.i += 1;
                        break;
                    },
                    else => return error.Invalid,
                }
            }
            if (self.hasDuplicate(self.kids.items[base..])) return error.Invalid;
        }
        try self.close(my, base);
    }

    /// Konteyneri kapatır: çocuk indekslerini `table`a taşır, `len`/`val`i doldurur.
    fn close(self: *Parser, my: usize, base: usize) Err!void {
        const kids = self.kids.items[base..];
        const table_off: u32 = @intCast(self.b.table.items.len);
        try self.b.table.appendSlice(self.a, kids);
        const e = &self.b.entries.items[my];
        e.len = @intCast(kids.len);
        e.val = packContainer(@intCast(self.b.entries.items.len), table_off);
        self.kids.shrinkRetainingCapacity(base);
    }
};

/// `text`i ayrıştırıp doğrular. Geçersizse `null` (kısmi bant atılır). `a` geçici + sonuç tamponları için kullanılır; çağıran `Built.deinit` çağırır.
pub fn build(a: std.mem.Allocator, text: []const u8, out: *Built) bool {
    out.entries.clearRetainingCapacity();
    out.table.clearRetainingCapacity();
    out.strs.clearRetainingCapacity();
    // yaklaşık ön-ayırma: ~1 girdi / 6 bayt
    out.entries.ensureTotalCapacity(a, text.len / 6 + 8) catch return false;
    out.strs.ensureTotalCapacity(a, text.len / 2 + 16) catch return false;
    var p = Parser{ .s = text, .a = a, .b = out };
    defer p.kids.deinit(a);
    p.ws();
    p.value(0) catch return false;
    p.ws();
    return p.i == text.len;
}

// ---- farksal sınama (referans: std.json.Value ve json.zig'nin FastJson doğrulayıcısı) ----

fn cmpNumber(v: View, idx: u32, ref: std.json.Value) bool {
    const e = v.entries[idx];
    const n: f64 = @bitCast(e.val);
    switch (ref) {
        .integer => |i| return n == @as(f64, @floatFromInt(i)),
        .float => |f| return n == f or (std.math.isNan(n) and std.math.isNan(f)),
        .number_string => return true, // büyük tamsayı: metin ayrıca doğrulanır
        else => return false,
    }
}

fn cmpNode(v: View, idx: u32, ref: std.json.Value) bool {
    const e = v.entries[idx];
    switch (ref) {
        .null => return e.kind == K_NULL,
        .bool => |b| return e.kind == K_BOOL and (e.val != 0) == b,
        .integer, .float, .number_string => return e.kind == K_NUMBER and cmpNumber(v, idx, ref),
        .string => |s| return e.kind == K_STRING and std.mem.eql(u8, v.str(e), s),
        .array => |arr| {
            if (e.kind != K_ARRAY or e.len != arr.items.len) return false;
            for (arr.items, 0..) |item, i| if (!cmpNode(v, v.child(idx, i), item)) return false;
            return true;
        },
        .object => |obj| {
            if (e.kind != K_OBJECT or e.len != obj.count()) return false;
            var it = obj.iterator();
            var i: usize = 0;
            while (it.next()) |kv| : (i += 1) {
                const kidx = v.child(idx, i);
                const ke = v.entries[kidx];
                if (ke.kind != K_KEY or !std.mem.eql(u8, v.str(ke), kv.key_ptr.*)) return false;
                if (!cmpNode(v, kidx + 1, kv.value_ptr.*)) return false;
            }
            return true;
        },
    }
}

fn expectSame(gpa: std.mem.Allocator, text: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var built: Built = .{};
    defer built.deinit(gpa);
    const ok = build(gpa, text, &built);
    // referans: std.json (derinlik sınırı farkı: std.json sınırsız → yalnızca ≤ MAX_DEPTH belgelerde geçerlilik karşılaştırılır)
    const ref = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{}) catch null;
    if (ref == null) {
        try std.testing.expect(!ok);
        return;
    }
    if (!ok) return; // derinlik sınırı / yinelenen anahtar: std.json kabul eder, bant reddeder (kasıtlı)
    const blob = try gpa.alloc(u8, built.blobSize());
    defer gpa.free(blob);
    built.writeBlob(blob, -1);
    const view = View.fromBlob(blob);
    try std.testing.expect(cmpNode(view, 0, ref.?));
}

test "json_tape: geçerli belgeler std.json ile aynı değerleri üretir" {
    const gpa = std.testing.allocator;
    const cases = [_][]const u8{
        "null", "true",    "false",                   "0",                     "-0",                 "1",                                                  "-12",                  "1.5",                                                                                                   "-1.5e3",                                                          "1e2", "123456789012345678", "9007199254740993", "12345678901234567890123",
        "\"\"", "\"abc\"", "\"a\\nb\\t\\\"\\\\\\/\"", "\"\\u00e9\\u20ac\"",    "\"\\ud83d\\ude00\"",
        "\"café\"",
        "\"日本語\"",
        "[]",   "{}",      "[1,2,3]",                 "[[],[[]],[1,[2,[3]]]]", "{\"a\":1}",          "{\"a\":1,\"b\":[true,null,\"x\"],\"c\":{\"d\":{}}}", " \t\r\n [ 1 , 2 ] \n", "{\"k\":\"v\",\"k2\":\"v2\",\"k3\":3,\"k4\":4,\"k5\":5,\"k6\":6,\"k7\":7,\"k8\":8,\"k9\":9,\"k10\":10}", "{\"id\":1,\"name\":\"item_1\",\"tags\":[\"a\",\"b\"],\"v\":1.5}",
    };
    for (cases) |c| try expectSame(gpa, c);
}

test "json_tape: geçersiz belgeler reddedilir (std.json ile aynı karar)" {
    const gpa = std.testing.allocator;
    const cases = [_][]const u8{
        "",          " ",           "{",           "}",                  "[",     "]",                 "[1,]", "[,1]", "{\"a\"}",  "{\"a\":}", "{\"a\":1,}", "{a:1}", "01", "1.", ".5", "1e", "-", "+1", "tru", "nul", "'a'", "\"abc", "\"\\x\"",
        "\"\\u12\"", "\"\\ud800\"", "\"\\udc00\"", "\"\\ud800\\u0041\"", "[1 2]", "{\"a\":1 \"b\":2}", "1 2",  "[1]]", "\"\x01\"", "\"\xff\"", "\"\xc3\"",
    };
    for (cases) |c| try expectSame(gpa, c);
}

test "json_tape: yinelenen anahtar ve derinlik sınırı reddedilir" {
    const gpa = std.testing.allocator;
    var built: Built = .{};
    defer built.deinit(gpa);
    try std.testing.expect(!build(gpa, "{\"a\":1,\"a\":2}", &built));
    try std.testing.expect(!build(gpa, "{\"a\":1,\"b\":2,\"a\":3}", &built));
    try std.testing.expect(build(gpa, "{\"a\":1,\"b\":{\"a\":2}}", &built));
    // büyük nesne (karma tablosu yolu) yinelenen anahtar
    var sb: std.ArrayListUnmanaged(u8) = .empty;
    defer sb.deinit(gpa);
    try sb.append(gpa, '{');
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const piece = try std.fmt.allocPrint(gpa, "\"k{d}\":{d},", .{ i, i });
        defer gpa.free(piece);
        try sb.appendSlice(gpa, piece);
    }
    try sb.appendSlice(gpa, "\"k7\":0}");
    try std.testing.expect(!build(gpa, sb.items, &built));
    // kaçışlı anahtarlar eşleşir: "a" ve "\u0061"
    try std.testing.expect(!build(gpa, "{\"a\":1,\"\\u0061\":2}", &built));
    // derinlik: 32 kat açık sınır, 33 reddedilir
    var deep: std.ArrayListUnmanaged(u8) = .empty;
    defer deep.deinit(gpa);
    var d: usize = 0;
    while (d < MAX_DEPTH) : (d += 1) try deep.append(gpa, '[');
    d = 0;
    while (d < MAX_DEPTH) : (d += 1) try deep.append(gpa, ']');
    try std.testing.expect(build(gpa, deep.items, &built));
    try deep.insert(gpa, 0, '[');
    try deep.append(gpa, ']');
    try std.testing.expect(!build(gpa, deep.items, &built));
}

test "json_tape: sayı sınıflandırma ve metinler numberLeaf ile aynı" {
    const gpa = std.testing.allocator;
    var built: Built = .{};
    defer built.deinit(gpa);
    const Case = struct { tok: []const u8, n: f64, text: []const u8 };
    const cases = [_]Case{
        .{ .tok = "7", .n = 7, .text = "" },
        .{ .tok = "-0", .n = -0.0, .text = "" },
        .{ .tok = "1.0", .n = 1.0, .text = "1.0" },
        .{ .tok = "1e2", .n = 100.0, .text = "100.0" },
        .{ .tok = "2.5", .n = 2.5, .text = "" },
        .{ .tok = "9007199254740993", .n = 9007199254740992.0, .text = "9007199254740993" },
        .{ .tok = "-9007199254740993", .n = -9007199254740992.0, .text = "-9007199254740993" },
        .{ .tok = "12345678901234567890123", .n = 1.2345678901234568e22, .text = "12345678901234567890123" },
        .{ .tok = "1.5e300", .n = 1.5e300, .text = "" },
    };
    for (cases) |c| {
        try std.testing.expect(build(gpa, c.tok, &built));
        const blob = try gpa.alloc(u8, built.blobSize());
        defer gpa.free(blob);
        built.writeBlob(blob, -1);
        const v = View.fromBlob(blob);
        try std.testing.expectEqual(K_NUMBER, v.entries[0].kind);
        try std.testing.expectEqual(@as(u64, @bitCast(c.n)), v.entries[0].val);
        try std.testing.expectEqualStrings(c.text, v.numberText(0));
    }
}

test "json_tape: rastgele bozulmuş belgelerde std.json ile aynı geçerlilik kararı" {
    const gpa = std.testing.allocator;
    const base = "{\"id\":12,\"name\":\"it\\u00e9m \\\"q\\\"\",\"tags\":[\"a\",\"b\",[1,2.5,-3e2]],\"v\":{\"x\":null,\"y\":true,\"z\":false}}";
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    var round: usize = 0;
    while (round < 4000) : (round += 1) {
        @memcpy(buf[0..base.len], base);
        var len: usize = base.len;
        const edits = rnd.intRangeAtMost(usize, 0, 3);
        var e: usize = 0;
        while (e < edits) : (e += 1) {
            switch (rnd.intRangeAtMost(u8, 0, 2)) {
                0 => buf[rnd.intRangeLessThan(usize, 0, len)] = rnd.int(u8),
                1 => {
                    const at = rnd.intRangeLessThan(usize, 0, len);
                    std.mem.copyForwards(u8, buf[at .. len - 1], buf[at + 1 .. len]);
                    len -= 1;
                },
                else => if (len < buf.len - 1) {
                    const at = rnd.intRangeLessThan(usize, 0, len);
                    std.mem.copyBackwards(u8, buf[at + 1 .. len + 1], buf[at..len]);
                    buf[at] = "{}[]\",:\\ 0e-.tnu"[rnd.intRangeLessThan(usize, 0, 16)];
                    len += 1;
                },
            }
        }
        try expectSame(gpa, buf[0..len]);
    }
}

test "json_tape: ölçüm (NOX_JSON_BENCH_FILE ayarlıysa)" {
    const gpa = std.heap.page_allocator;
    const path_z = std.c.getenv("NOX_JSON_BENCH_FILE") orelse return error.SkipZigTest;
    const path = std.mem.span(path_z);
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 28));
    var best: u64 = std.math.maxInt(u64);
    var built: Built = .{};
    var r: usize = 0;
    while (r < 10) : (r += 1) {
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        const ok = build(gpa, text, &built);
        const t1 = std.Io.Clock.Timestamp.now(io, .awake);
        try std.testing.expect(ok);
        const ns: u64 = @intCast(t0.durationTo(t1).raw.nanoseconds);
        if (ns < best) best = ns;
    }
    std.debug.print("json_tape build best: {d:.2} ms ({d} entries, {d} strs bytes)\n", .{ @as(f64, @floatFromInt(best)) / 1e6, built.entries.items.len, built.strs.items.len });
    built.deinit(gpa);
}
