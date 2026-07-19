use regex::Regex;

// Nox tarafi (nox.regex.is_match/find) pattern'i HER CAGRIDA yeniden
// yorumlar (ayri bir "compile" adimi yok) -- burada ise Rust'in kendi
// deyimiyle (bir kez derle, tekrar tekrar kullan) yazildi. Bu asimetri
// bilinclidir (bkz. nox-teknik-spesifikasyonu.md SS3.67) -- compare/
// dizinindeki C ornekleriyle ayni "o dilin kendi dogal deyimi" ilkesi.
fn churn(n: i64, re_ab: &Regex, re_digits: &Regex, re_lower: &Regex) -> i64 {
    let mut count: i64 = 0;
    for _ in 0..n {
        if re_ab.is_match("aaaaaaaaaab") {
            count += 1;
        }
        if re_digits.find("abc123def456").is_some() {
            count += 1;
        }
        if re_lower.is_match("hello") {
            count += 1;
        }
    }
    count
}

fn main() {
    let re_ab = Regex::new("a*b").unwrap();
    let re_digits = Regex::new("[0-9]+").unwrap();
    let re_lower = Regex::new("^[a-z]+$").unwrap();
    println!("{}", churn(50000, &re_ab, &re_digits, &re_lower));
}
