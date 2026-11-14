//! v2.1.142: işçi başına ilerleme damgası — `runtime/async_rt/pool_monitor` (havuzun izleyicisi) bir işçinin AYNI fiber'da uzun süre takılı kalıp kalmadığını (bloklayan FFI/sistem çağrısı ya da
//! uzun hesap) buradan görür. Her işçinin damgası KENDİ önbellek hattındadır (yanlış paylaşım yok); yazmalar gevşek atomiktir (fiber geçişi başına iki mağaza).

const std = @import("std");

pub const SlotStat = struct {
    /// Bu işçinin başlattığı fiber sayısı (her `resume_`te artar).
    tick: std.atomic.Value(u32) align(64) = .init(0),
    /// Şu an bir fiber çalıştırıyor mu?
    busy: std.atomic.Value(bool) = .init(false),
};
