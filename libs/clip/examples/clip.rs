#[cfg(target_os = "windows")]
use clip::{set_text, get_text, has_text};

#[cfg(target_os = "windows")]
fn test_clip() {
    let text = "Hello, World!";
    set_text(text).unwrap();

    let (get, text) = get_text().unwrap();
    println!("get: {}, text: {}", get, text);

    let has = has_text();
    println!("has: {}", has);
}

fn main() {
    #[cfg(target_os = "windows")]
    test_clip();
}
