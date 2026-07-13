//! Nox WASM köprüsü testi için GERÇEK bir WASM modülü kaynağı. `zig`in
//! kendisiyle (`wasm32-freestanding` hedefi) derlenir (bkz. build.zig) —
//! WABT/wasmtime gibi ek bir araç gerekmez. `add_two`, `add_one`i İKİ KEZ
//! çağırarak (bkz. runtime/wasm_bridge/interp.zig, `call` talimatı)
//! yorumlayıcının fonksiyonlar arası çağrıyı da doğru yürüttüğünü sınar.

export fn add_one(x: i32) i32 {
    return x + 1;
}

export fn add_two(a: i32, b: i32) i32 {
    return add_one(a) + add_one(b);
}
