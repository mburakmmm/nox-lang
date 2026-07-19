fn churn(n: i64) -> i64 {
    let s = "  The Quick Brown Fox Jumps Over The Lazy Dog, again and again!  ";
    let mut total: i64 = 0;
    for _ in 0..n {
        let t = s.trim();
        let u = t.to_uppercase();
        let l = u.to_lowercase();
        let r = l.replace("fox", "cat");
        let parts: Vec<&str> = r.split(' ').collect();
        let joined = parts.join("-");
        total += joined.len() as i64;
        if joined.contains("cat") {
            total += 1;
        }
        if joined.starts_with("the") {
            total += 1;
        }
        if joined.ends_with("!") {
            total += 1;
        }
        total += joined.find("cat").map(|i| i as i64).unwrap_or(-1);
    }
    total
}

fn main() {
    println!("{}", churn(2000));
}
