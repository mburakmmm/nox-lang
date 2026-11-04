//! v2.0.135: `noxc install/upgrade/refresh/fetch/update/add` için kullanıcıya dönük ilerleme çıktısı.
//!
//! Eskiden bu komutlar sessizce çalışıp tek satırlık bir sonuç basıyordu: indirmenin ne kadar sürdüğü, `git clone`un mu yoksa derlemenin mi
//! beklendiği anlaşılmıyordu. Burada iki küçük bileşen var:
//!   * `Step`: `==> Building foo ...` yazar, iş bitince AYNI satırın sonuna ` done (4.5s)` ekler. Ne bitmeden çıktı bozulur, ne de ek satır gerekir.
//!   * `Download`: indirme için `[=====>    ] 52%  10.3 MB / 19.8 MB  4.1 MB/s  eta 2s` çubuğu.
//! Çıktı stderr'e gider (CLI'nin tüm mesajları gibi). `live` (stderr bir TTY ve ANSI destekliyor) DEĞİLSE çubuk çizilmez; yalnızca
//! başlangıç ve bitiş satırları basılır (CI günlükleri imleç hareketiyle dolmaz). Hiçbir bileşen küresel durum tutmaz: `Reporter` değer olarak taşınır.

const std = @import("std");
const Io = std.Io;

const KB: u64 = 1024;
const MB: u64 = KB * 1024;
const GB: u64 = MB * 1024;

/// Çubuğun yeniden çizilme aralığı (TTY'de titremeyi önler).
const REDRAW_INTERVAL_NS: i96 = 100 * std.time.ns_per_ms;

/// Adım ya da indirme bitene kadar "done (0.0s)" gürültüsünü bastırma eşiği.
const SHOW_DURATION_NS: i96 = 100 * std.time.ns_per_ms;

pub const Reporter = struct {
    io: Io,
    /// stderr bir TTY ve ANSI kaçış dizilerini destekliyorsa `true` (canlı çubuk çizilir).
    live: bool,

    /// `==> <mesaj> ...` yazar (satırı AÇIK bırakır); `Step.done()`/`Step.fail()` kapatır.
    pub fn begin(self: Reporter, comptime fmt: []const u8, args: anytype) Step {
        std.debug.print("==> " ++ fmt ++ " ...", args);
        return .{ .r = self, .start_ns = nowNs(self.io) };
    }

    /// Süresiz tek satırlık bilgi: `==> <mesaj>`.
    pub fn info(self: Reporter, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        std.debug.print("==> " ++ fmt ++ "\n", args);
    }
};

pub const Step = struct {
    r: Reporter,
    start_ns: i96,

    pub fn done(self: Step) void {
        var buf: [32]u8 = undefined;
        const elapsed = nowNs(self.r.io) - self.start_ns;
        if (elapsed >= SHOW_DURATION_NS) {
            std.debug.print(" done ({s})\n", .{formatDuration(&buf, elapsed)});
        } else {
            std.debug.print(" done\n", .{});
        }
    }

    /// Satırı `done` yerine kendi sonucuyla kapatır (ör. `up to date`).
    pub fn doneAs(self: Step, text: []const u8) void {
        _ = self;
        std.debug.print(" {s}\n", .{text});
    }

    /// Adım başarısız: satırı kapatır; hata mesajını çağıran yazar.
    pub fn fail(self: Step) void {
        _ = self;
        std.debug.print(" failed\n", .{});
    }
};

pub const Download = struct {
    r: Reporter,
    total: ?u64,
    received: u64 = 0,
    start_ns: i96,
    last_draw_ns: i96 = 0,
    drew: bool = false,

    /// `==> Downloading <etiket> (19.8 MB)` yazar. `total` bilinmiyorsa (Content-Length yok) boyut gösterilmez.
    pub fn start(r: Reporter, label: []const u8, total: ?u64) Download {
        var buf: [32]u8 = undefined;
        if (total) |t| {
            std.debug.print("==> Downloading {s} ({s})\n", .{ label, formatBytes(&buf, t) });
        } else {
            std.debug.print("==> Downloading {s}\n", .{label});
        }
        const now = nowNs(r.io);
        return .{ .r = r, .total = total, .start_ns = now };
    }

    pub fn advance(self: *Download, n: u64) void {
        self.received += n;
        if (!self.r.live) return;
        const now = nowNs(self.r.io);
        if (self.drew and now - self.last_draw_ns < REDRAW_INTERVAL_NS) return;
        self.last_draw_ns = now;
        self.drew = true;
        var buf: [160]u8 = undefined;
        const line = renderBar(&buf, self.received, self.total, now - self.start_ns, 24);
        std.debug.print("\r\x1b[2K    {s}", .{line});
    }

    /// Canlı çubuğu siler (hata ya da yeniden deneme öncesi); özet satırı basmaz.
    pub fn abort(self: *Download) void {
        self.clearLive();
    }

    /// Canlı çubuğu siler ve `19.8 MB in 4.8s (4.1 MB/s)` özetini basar.
    pub fn finish(self: *Download) void {
        self.clearLive();
        var b1: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        var b3: [40]u8 = undefined;
        const elapsed = nowNs(self.r.io) - self.start_ns;
        std.debug.print("    {s} in {s} ({s})\n", .{ formatBytes(&b1, self.received), formatDuration(&b2, elapsed), formatRate(&b3, self.received, elapsed) });
    }

    fn clearLive(self: *Download) void {
        if (self.drew) {
            std.debug.print("\r\x1b[2K", .{});
            self.drew = false;
        }
    }
};

fn nowNs(io: Io) i96 {
    return Io.Timestamp.now(io, .awake).nanoseconds;
}

/// `1536` -> "1.5 KB". Okunabilirlik için en yakın birim, bir ondalık basamak.
pub fn formatBytes(buf: []u8, n: u64) []const u8 {
    const f: f64 = @floatFromInt(n);
    const r = if (n >= GB)
        std.fmt.bufPrint(buf, "{d:.1} GB", .{f / @as(f64, @floatFromInt(GB))})
    else if (n >= MB)
        std.fmt.bufPrint(buf, "{d:.1} MB", .{f / @as(f64, @floatFromInt(MB))})
    else if (n >= KB)
        std.fmt.bufPrint(buf, "{d:.1} KB", .{f / @as(f64, @floatFromInt(KB))})
    else
        std.fmt.bufPrint(buf, "{d} B", .{n});
    return r catch "?";
}

/// Nanosaniye -> "4.8s" ya da "1m 05s".
pub fn formatDuration(buf: []u8, ns: i96) []const u8 {
    const clamped: i96 = if (ns < 0) 0 else ns;
    const secs_f: f64 = @as(f64, @floatFromInt(clamped)) / @as(f64, std.time.ns_per_s);
    if (secs_f < 60.0) return std.fmt.bufPrint(buf, "{d:.1}s", .{secs_f}) catch "?";
    const total: u64 = @intFromFloat(secs_f);
    return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ total / 60, total % 60 }) catch "?";
}

/// Ortalama hız: "4.1 MB/s". Süre sıfırsa "-".
pub fn formatRate(buf: []u8, bytes: u64, elapsed_ns: i96) []const u8 {
    if (elapsed_ns <= 0) return "-";
    const per_s: f64 = @as(f64, @floatFromInt(bytes)) / (@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_s));
    var inner: [32]u8 = undefined;
    const size = formatBytes(&inner, @intFromFloat(per_s));
    return std.fmt.bufPrint(buf, "{s}/s", .{size}) catch "?";
}

/// Tek satırlık çubuk: toplam biliniyorsa `[=====>    ]  52%  10.3 MB / 19.8 MB  4.1 MB/s  eta 2s`,
/// bilinmiyorsa `10.3 MB  4.1 MB/s`. Saf bir işlevdir (zamanı dışarıdan alır), bu yüzden birim testlidir.
pub fn renderBar(buf: []u8, received: u64, total: ?u64, elapsed_ns: i96, width: usize) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    var b3: [40]u8 = undefined;
    // İlk 250 ms'de ortalama hız anlamsızdır (ilk karede "4.8 GB/s" görünürdü).
    const rate = if (elapsed_ns < 250 * std.time.ns_per_ms) "-" else formatRate(&b3, received, elapsed_ns);
    if (total) |t| {
        if (t > 0) {
            const frac: f64 = @min(1.0, @as(f64, @floatFromInt(received)) / @as(f64, @floatFromInt(t)));
            const filled: usize = @intFromFloat(frac * @as(f64, @floatFromInt(width)));
            w.writeByte('[') catch {};
            var i: usize = 0;
            while (i < width) : (i += 1) {
                const ch: u8 = if (i < filled) '=' else if (i == filled and received < t) '>' else ' ';
                w.writeByte(ch) catch {};
            }
            w.print("] {d:>3}%  {s} / {s}  {s}", .{ @as(u32, @intFromFloat(frac * 100.0)), formatBytes(&b1, received), formatBytes(&b2, t), rate }) catch {};
            // ETA yalnızca yeterli örnek varsa (ilk yarım saniye ortalaması yanıltıcıdır).
            if (elapsed_ns >= 500 * std.time.ns_per_ms and received > 0 and received < t) {
                const remaining: f64 = @floatFromInt(t - received);
                const per_s: f64 = @as(f64, @floatFromInt(received)) / (@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_s));
                if (per_s > 0) {
                    var b4: [32]u8 = undefined;
                    const eta_ns: i96 = @intFromFloat(remaining / per_s * @as(f64, std.time.ns_per_s));
                    w.print("  eta {s}", .{formatDuration(&b4, eta_ns)}) catch {};
                }
            }
            return w.buffered();
        }
    }
    w.print("{s}  {s}", .{ formatBytes(&b1, received), rate }) catch {};
    return w.buffered();
}

test "formatBytes: birimler ve ondalik" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", formatBytes(&buf, 0));
    try std.testing.expectEqualStrings("1023 B", formatBytes(&buf, 1023));
    try std.testing.expectEqualStrings("1.5 KB", formatBytes(&buf, 1536));
    try std.testing.expectEqualStrings("19.8 MB", formatBytes(&buf, 20_761_805));
    try std.testing.expectEqualStrings("2.0 GB", formatBytes(&buf, 2 * GB));
}

test "formatDuration: saniye ve dakika" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0.0s", formatDuration(&buf, 0));
    try std.testing.expectEqualStrings("4.8s", formatDuration(&buf, 4_800 * std.time.ns_per_ms));
    try std.testing.expectEqualStrings("1m 05s", formatDuration(&buf, 65 * std.time.ns_per_s));
    try std.testing.expectEqualStrings("0.0s", formatDuration(&buf, -5));
}

test "formatRate: ortalama hiz ve sifir sure" {
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("-", formatRate(&buf, 100, 0));
    try std.testing.expectEqualStrings("2.0 MB/s", formatRate(&buf, 4 * MB, 2 * std.time.ns_per_s));
}

test "renderBar: toplam biliniyorsa yuzde, boyut, hiz ve ETA" {
    var buf: [160]u8 = undefined;
    const line = renderBar(&buf, 10 * MB, 20 * MB, 5 * std.time.ns_per_s, 20);
    try std.testing.expectEqualStrings("[==========>         ]  50%  10.0 MB / 20.0 MB  2.0 MB/s  eta 5.0s", line);
}

test "renderBar: ilk yarim saniyede ETA yok, tamamlaninca ok isareti yok" {
    var buf: [160]u8 = undefined;
    const early = renderBar(&buf, MB, 100 * MB, 100 * std.time.ns_per_ms, 10);
    try std.testing.expect(std.mem.indexOf(u8, early, "eta") == null);
    var buf2: [160]u8 = undefined;
    const full = renderBar(&buf2, 10 * MB, 10 * MB, 2 * std.time.ns_per_s, 10);
    try std.testing.expectEqualStrings("[==========] 100%  10.0 MB / 10.0 MB  5.0 MB/s", full);
}

test "renderBar: ilk 250 ms'de hiz gosterilmez" {
    var buf: [160]u8 = undefined;
    const line = renderBar(&buf, 64 * KB, 12 * MB, 1 * std.time.ns_per_ms, 10);
    try std.testing.expectEqualStrings("[>         ]   0%  64.0 KB / 12.0 MB  -", line);
}

test "renderBar: toplam bilinmiyorsa yalniz boyut ve hiz" {
    var buf: [160]u8 = undefined;
    const line = renderBar(&buf, 3 * MB, null, 3 * std.time.ns_per_s, 20);
    try std.testing.expectEqualStrings("3.0 MB  1.0 MB/s", line);
}
