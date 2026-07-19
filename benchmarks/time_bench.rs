use std::time::{SystemTime, UNIX_EPOCH};

fn churn(n: i64) -> i64 {
    let mut total: i64 = 0;
    for _ in 0..n {
        let t = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as i64;
        if t > 0 {
            total += 1;
        }
    }
    total
}

fn main() {
    println!("{}", churn(200000));
}
