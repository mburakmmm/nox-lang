fn build_haystack(n: i64) -> String {
    let parts: Vec<&str> = vec!["x"; n as usize];
    parts.join("")
}

fn scan_bench(haystack: &str, iterations: i64) -> i64 {
    let mut count: i64 = 0;
    for _ in 0..iterations {
        if haystack.contains("needle") {
            count += 1;
        }
    }
    count
}

fn build_parts(n: i64) -> Vec<String> {
    vec!["word".to_string(); n as usize]
}

fn join_bench(parts: &[String], iterations: i64) -> i64 {
    let mut total: i64 = 0;
    for _ in 0..iterations {
        let joined = parts.join(",");
        total += joined.len() as i64;
    }
    total
}

fn main() {
    let haystack = format!("{}{}", build_haystack(2000), "needle");
    println!("{}", scan_bench(&haystack, 50000));

    let parts = build_parts(3000);
    println!("{}", join_bench(&parts, 500));
}
