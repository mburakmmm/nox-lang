use serde_json::Value;

fn build_json(n: i64) -> String {
    let mut out = String::from("[");
    for i in 0..n {
        if i > 0 {
            out.push(',');
        }
        out.push_str(&format!("{{\"id\":{},\"name\":\"item\",\"active\":true}}", i));
    }
    out.push(']');
    out
}

fn decode_encode_once(s: &str) -> i64 {
    let v: Value = serde_json::from_str(s).unwrap();
    let out = serde_json::to_string(&v).unwrap();
    out.len() as i64
}

fn main() {
    let s = build_json(200);
    let mut total: i64 = 0;
    for _ in 0..50 {
        total += decode_encode_once(&s);
    }
    println!("{}", total);
}
