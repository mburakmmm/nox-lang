use sha2::{Digest, Sha256};

fn to_hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{:02x}", b));
    }
    s
}

fn churn(n: i64) -> i64 {
    let mut total: i64 = 0;
    for i in 0..n {
        let mut hasher = Sha256::new();
        hasher.update(format!("hello world {}", i));
        let hex = to_hex(&hasher.finalize());
        total += hex.len() as i64;
    }
    total
}

fn main() {
    println!("{}", churn(10000));
}
