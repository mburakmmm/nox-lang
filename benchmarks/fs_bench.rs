use std::fs;

fn churn(n: i64) -> i64 {
    let payload = "0123456789".repeat(200);
    fs::write("/tmp/nox_bench_fs_scratch_rust2.txt", &payload).unwrap();
    let mut total: i64 = 0;
    for _ in 0..n {
        let content = fs::read_to_string("/tmp/nox_bench_fs_scratch_rust2.txt").unwrap();
        total += content.len() as i64;
    }
    total
}

fn main() {
    println!("{}", churn(20000));
}
