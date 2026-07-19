use std::path::Path;

fn churn(n: i64) -> i64 {
    let mut total: i64 = 0;
    for _ in 0..n {
        let p = Path::new("/usr/local/bin").join("nox");
        let p_str = p.to_str().unwrap();
        let b = p.file_name().unwrap().to_str().unwrap();
        let d = p.parent().unwrap().to_str().unwrap();
        let e = Path::new("archive.tar.gz")
            .extension()
            .map(|s| format!(".{}", s.to_str().unwrap()))
            .unwrap_or_default();
        total += p_str.len() as i64 + b.len() as i64 + d.len() as i64 + e.len() as i64;
        if p.is_absolute() {
            total += 1;
        }
    }
    total
}

fn main() {
    println!("{}", churn(100000));
}
