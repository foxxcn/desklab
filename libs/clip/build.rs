#[cfg(target_os = "windows")]
fn build_dacap_clip_impl() {
    let mut build = cc::Build::new();

    build.cpp(true).files(&[
        "dacap_clip/clip.cpp",
        "dacap_clip/image.cpp",
        "dacap_clip/clip_win.cpp",
        "src/clip.cpp",
    ]);
    build.flag_if_supported("-Wno-return-type-c-linkage");
    build.flag_if_supported("-Wno-invalid-offsetof");
    build.flag_if_supported("-Wno-unused-parameter");

    if build.get_compiler().is_like_msvc() {
        build.define("WIN32", "");
        build.flag("-Z7");
        build.flag("-GR-");
    } else {
        build.flag("-fPIC");
    }

    build.compile("dacap_clip");

    println!("cargo:rerun-if-changed=dacap_clip/clip.cpp");
    println!("cargo:rerun-if-changed=dacap_clip/image.cpp");
    println!("cargo:rerun-if-changed=dacap_clip/clip_win.cpp");
    println!("cargo:rerun-if-changed=src/clip.cpp");
}

fn main() {
    #[cfg(target_os = "windows")]
    build_dacap_clip_impl();
}
