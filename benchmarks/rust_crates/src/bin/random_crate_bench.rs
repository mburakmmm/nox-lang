use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};

fn churn(n: i64) -> i64 {
    let mut rng = StdRng::seed_from_u64(42);
    let mut total: i64 = 0;
    for _ in 0..n {
        total += rng.random_range(0..=1000i64);
    }
    total
}

fn main() {
    println!("{}", churn(1_000_000));
}
