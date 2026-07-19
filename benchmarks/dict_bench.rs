use std::collections::HashMap;

fn build_and_query(n: i64) -> i64 {
    let mut d: HashMap<i64, i64> = HashMap::new();
    d.insert(0, 0);
    for i in 1..n {
        d.insert(i, i * 2);
    }
    let mut total: i64 = 0;
    for j in 0..n {
        total += d[&j];
    }
    total
}

fn main() {
    println!("{}", build_and_query(5000));
}
