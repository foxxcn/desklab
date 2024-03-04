#[cfg(target_os = "windows")]
use hbb_common::{libc, ResultType};
#[cfg(target_os = "windows")]
use std::{
    ffi::{CStr, CString},
    os::raw::{c_char, c_int},
};

#[cfg(target_os = "windows")]
pub type BOOL = c_int;

#[cfg(target_os = "windows")]
extern "C" {
    pub(crate) fn _set_text(text: *const c_char) -> BOOL;
    pub(crate) fn _get_text(text: *mut *mut c_char) -> BOOL;
    pub(crate) fn _has_text() -> BOOL;
}

#[cfg(target_os = "windows")]
pub fn set_text(text: &str) -> ResultType<bool> {
    Ok(unsafe { _set_text(CString::new(text)?.as_ptr()) != 0 })
}

#[cfg(target_os = "windows")]
pub fn get_text() -> ResultType<(bool, String)> {
    let mut buffer: *mut c_char = std::ptr::null_mut();
    let result = unsafe { _get_text(&mut buffer) };
    let text = if result != 0 {
        let text = unsafe { CStr::from_ptr(buffer).to_str()?.to_string() };
        unsafe {
            if !buffer.is_null() {
                libc::free(buffer as *mut libc::c_void);
            }
        }
        text
    } else {
        String::new()
    };
    Ok((result != 0, text))
}

#[cfg(target_os = "windows")]
pub fn has_text() -> bool {
    unsafe { _has_text() != 0 }
}
