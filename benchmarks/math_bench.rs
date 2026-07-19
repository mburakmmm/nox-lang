fn churn(n: i64) -> f64 {
    let mut total: f64 = 0.0;
    for i in 0..n {
        let x = ((i as f64) + 1.0).sqrt();
        let y = x.powf(2.0);
        let z = y.floor() + y.ceil();
        total += z.max(x.min(y)) + (x - y).abs();
    }
    total
}

fn main() {
    println!("{}", churn(100000));
}
