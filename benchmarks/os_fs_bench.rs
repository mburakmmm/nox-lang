use std::env;
use std::fs;

fn build_payload(n: i64) -> String {
    let mut out = String::new();
    for _ in 0..n {
        out.push_str("0123456789");
    }
    out
}

fn churn(n: i64) -> i64 {
    let mut total: i64 = 0;
    for _ in 0..n {
        total += env::args().count() as i64;
    }
    let payload = build_payload(1000);
    fs::write("/tmp/nox_bench_fs_scratch_rust.txt", &payload).unwrap();
    let content = fs::read_to_string("/tmp/nox_bench_fs_scratch_rust.txt").unwrap();
    total + content.len() as i64
}

fn main() {
    println!("{}", churn(20000));
}
