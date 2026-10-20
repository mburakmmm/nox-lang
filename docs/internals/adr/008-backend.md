# ADR-MOB-008 Backend

Durum: kabul. Mobil backend LLVM'dir.

## Karar

Dört mobil ad `--backend qbe` ile desteklenmez. `--emit-asm` ve `-g` de bu adlarda reddedilir. Masaüstü `--target` adları QBE yolunda kalır. QBE, aynı ABI fixture'ları geçmeden açılmaz.

## Reddedilen

Mobil `--target`ın sessizce QBE'ye düşmesi. Geri alma: `resolveRelease` içindeki mobil dalı silmek.
