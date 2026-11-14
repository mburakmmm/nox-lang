;; wasi-threads sınama modülü (v2.1.155, TODO 4.6): içe aktarılan PAYLAŞIMLI bellek, `wasi::thread-spawn`, `wasi_thread_start`.
;; Bellek düzeni: [0] sayaç (her iş parçacığı 10000 kez atomik +1), [4] biten iş parçacığı sayısı, [8] hiç uyandırılmayan bekleme adresi, [12] ping-pong bayrağı.
(module
  (import "env" "memory" (memory 1 4 shared))
  (import "wasi" "thread-spawn" (func $spawn (param i32) (result i32)))

  ;; arg == 99: sonsuz `wait` (kimse uyandırmaz: kapanış iptali sınanır). arg == 7: tuzak (unreachable).
  ;; aksi: 10000 atomik artış, sonra bitti sayacını artır ve uyandır.
  (func (export "wasi_thread_start") (param $tid i32) (param $arg i32)
    (local $i i32)
    (if (i32.eq (local.get $arg) (i32.const 99))
      (then
        (drop (memory.atomic.wait32 (i32.const 8) (i32.const 0) (i64.const -1)))
        (return)))
    (if (i32.eq (local.get $arg) (i32.const 7)) (then (unreachable)))
    (loop $l
      (drop (i32.atomic.rmw.add (i32.const 0) (i32.const 1)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (i32.const 10000))))
    (drop (i32.atomic.rmw.add (i32.const 4) (i32.const 1)))
    (drop (memory.atomic.notify (i32.const 4) (i32.const 100))))

  ;; n iş parçacığı başlat (arg = sıra), hepsinin bitmesini `wait` ile bekle, sayacı döndür; spawn hata verirse -1.
  (func (export "run") (param $n i32) (result i32)
    (local $i i32) (local $c i32)
    (block $stop
      (loop $sp
        (br_if $stop (i32.ge_u (local.get $i) (local.get $n)))
        (if (i32.lt_s (call $spawn (local.get $i)) (i32.const 0)) (then (return (i32.const -1))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $sp)))
    (block $done
      (loop $w
        (local.set $c (i32.atomic.load (i32.const 4)))
        (br_if $done (i32.eq (local.get $c) (local.get $n)))
        (drop (memory.atomic.wait32 (i32.const 4) (local.get $c) (i64.const 10000000000)))
        (br $w)))
    (i32.atomic.load (i32.const 0)))

  ;; tek bir iş parçacığı başlat (arg ile) ve hemen dön.
  (func (export "spawn_one") (param $arg i32) (result i32)
    (call $spawn (local.get $arg)))

  (func (export "load0") (result i32) (i32.atomic.load (i32.const 0)))
  (func (export "reset") (i32.atomic.store (i32.const 0) (i32.const 0)) (i32.atomic.store (i32.const 4) (i32.const 0)))
)
