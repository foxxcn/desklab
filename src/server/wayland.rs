use super::*;
use hbb_common::{allow_err, platform::linux::DISTRO};
use scrap::{is_cursor_embedded, set_map_err, Capturer, Display, Frame, TraitCapturer};
use std::io;
use std::process::{Command, Output};

use crate::{
    client::{
        SCRAP_OTHER_VERSION_OR_X11_REQUIRED, SCRAP_UBUNTU_HIGHER_REQUIRED, SCRAP_X11_REQUIRED,
    },
    platform::linux::is_x11,
};

lazy_static::lazy_static! {
    // Up to 24 video services
    static ref CAPTURES: [RwLock<u64>; 24] = [RwLock::new(0); 24]
    static ref LOG_SCRAP_COUNT: Mutex<u32> = Mutex::new(0);
}

pub fn init() {
    set_map_err(map_err_scrap);
}

fn map_err_scrap(err: String) -> io::Error {
    // to-do: Remove the following log
    log::error!("Wayland scrap error {}", &err);

    // to-do: Handle error better, do not restart server
    if err.starts_with("Did not receive a reply") {
        log::error!("Fatal pipewire error, {}", &err);
        std::process::exit(-1);
    }

    if DISTRO.name.to_uppercase() == "Ubuntu".to_uppercase() {
        if DISTRO.version_id < "21".to_owned() {
            io::Error::new(io::ErrorKind::Other, SCRAP_UBUNTU_HIGHER_REQUIRED)
        } else {
            try_log(&err);
            io::Error::new(io::ErrorKind::Other, err)
        }
    } else {
        try_log(&err);
        if err.contains("org.freedesktop.portal")
            || err.contains("pipewire")
            || err.contains("dbus")
        {
            io::Error::new(io::ErrorKind::Other, SCRAP_OTHER_VERSION_OR_X11_REQUIRED)
        } else {
            io::Error::new(io::ErrorKind::Other, SCRAP_X11_REQUIRED)
        }
    }
}

fn try_log(err: &String) {
    let mut lock_count = LOG_SCRAP_COUNT.lock().unwrap();
    if *lock_count >= 1000000 {
        return;
    }
    if *lock_count % 10000 == 0 {
        log::error!("Failed scrap {}", err);
    }
    *lock_count += 1;
}

struct CapturerPtr(*mut Capturer);

impl Clone for CapturerPtr {
    fn clone(&self) -> Self {
        Self(self.0)
    }
}

impl TraitCapturer for CapturerPtr {
    fn frame<'a>(&'a mut self, timeout: Duration) -> io::Result<Frame<'a>> {
        unsafe { (*self.0).frame(timeout) }
    }
}

#[tokio::main(flavor = "current_thread")]
pub(super) async fn ensure_inited(idx: usize) -> ResultType<()> {
    if is_x11() {
        return Ok(());
    }
    if CAPTURES.len() <= idx {
        bail!("Invalid capturer index: {}", idx);
    }

    let Some(addr) = CAPTURES.get(idx) else {
        bail!("Failed to get capturer");
    };

    let mut minx = i32::MAX;
    let mut maxx = i32::MIN;
    let mut miny = i32::MAX;
    let mut maxy = i32::MIN;

    if *addr.read().unwrap() == 0 {
        let mut lock = addr.write().unwrap();
        if *lock == 0 {
            let all = Display::all()?;
            super::display_service::check_update_displays(&all);
            let mut capturers: HashMap<usize, CapturerPtr> = HashMap::new();
            for (i, display) in all.into_iter().enumerate() {
                let (origin, width, height) = (display.origin(), display.width(), display.height());
                if minx > origin.0 {
                    minx = origin.0;
                }
                if maxx < origin.0 + width as i32 {
                    maxx = origin.0 + width as i32;
                }
                if miny > origin.1 {
                    miny = origin.1;
                }
                if maxy < origin.1 + height as i32 {
                    maxy = origin.1 + height as i32;
                }

                if idx == i {
                    log::debug!(
                        "display: {}, origin: {:?}, width={}, height={}",
                        i,
                        &origin,
                        width,
                        height
                    );
                    let capturer = Box::into_raw(Box::new(
                        Capturer::new(display).with_context(|| "Failed to create capturer")?,
                    ));
                    *lock = capturer as _;
                }
            }
        }
    }
    if minx != i32::MAX {
        log::info!(
            "update mouse resolution: ({}, {}), ({}, {})",
            minx,
            maxx,
            miny,
            maxy
        );
        allow_err!(input_service::update_mouse_resolution(minx, maxx, miny, maxy).await);
    }
    Ok(())
}

pub(super) fn is_inited() -> Option<Message> {
    if is_x11() {
        None
    } else {
        for addr in CAPTURES.iter() {
            if *addr.read().unwrap() != 0 {
                return None;
            }
        }

        let mut msg_out = Message::new();
        let res = MessageBox {
            msgtype: "nook-nocancel-hasclose".to_owned(),
            title: "Wayland".to_owned(),
            text: "Please Select the screen to be shared(Operate on the peer side).".to_owned(),
            link: "".to_owned(),
            ..Default::default()
        };
        msg_out.set_message_box(res);
        Some(msg_out)
    }
}

#[inline]
pub(super) async fn get_displays() -> ResultType<Vec<DisplayInfo>> {
    if is_x11() {
        return Ok(Vec::new());
    }

    let all = Display::all()?;
    super::display_service::check_update_displays(&all);
    let mut displays = super::display_service::get_sync_displays();
    for display in displays.iter_mut() {
        display.cursor_embedded = is_cursor_embedded();
    }
    let num = all.len();
    let primary = super::display_service::get_primary_2(&all);
    log::debug!(
        "#displays: {}, primary: {}, cpus: {}/{}",
        num,
        primary,
        num_cpus::get_physical(),
        num_cpus::get(),
    );
    Ok(displays)
}

pub(super) fn get_primary() -> ResultType<usize> {
    let addr = *CAP_DISPLAY_INFO.read().unwrap();
    if addr != 0 {
        let cap_display_info: *const CapDisplayInfo = addr as _;
        unsafe {
            let cap_display_info = &*cap_display_info;
            Ok(cap_display_info.primary)
        }
    } else {
        bail!("Failed to get capturer display info");
    }
}

pub fn clear() {
    if is_x11() {
        return;
    }
    let mut write_lock = CAP_DISPLAY_INFO.write().unwrap();
    if *write_lock != 0 {
        let cap_display_info: *mut CapDisplayInfo = *write_lock as _;
        unsafe {
            for (_, capturer) in &(*cap_display_info).capturers {
                let _box_capturer = Box::from_raw(capturer.0);
            }
            let _box_cap_display_info = Box::from_raw(cap_display_info);
            *write_lock = 0;
        }
    }
}

pub(super) fn get_capturer(idx: usize) -> ResultType<super::video_service::CapturerInfo> {
    if is_x11() {
        bail!("Do not call this function if not wayland");
    }
    let addr = *CAP_DISPLAY_INFO.read().unwrap();
    if addr != 0 {
        let cap_display_info: *const CapDisplayInfo = addr as _;
        unsafe {
            let cap_display_info = &*cap_display_info;
            if idx >= cap_display_info.rects.len() {
                bail!("Invalid capturer index");
            }
            let rect = cap_display_info.rects[idx];
            let Some(capturer) = cap_display_info.capturers.get(&idx) else {
                bail!("Failed to get capturer");
            };
            Ok(super::video_service::CapturerInfo {
                origin: rect.0,
                width: rect.1,
                height: rect.2,
                ndisplay: cap_display_info.num,
                current: idx,
                privacy_mode_id: 0,
                _capturer_privacy_mode_id: 0,
                capturer: Box::new(capturer.clone()),
            })
        }
    } else {
        bail!("Failed to get capturer display info");
    }
}

pub fn common_get_error() -> String {
    if DISTRO.name.to_uppercase() == "Ubuntu".to_uppercase() {
        if DISTRO.version_id < "21".to_owned() {
            return "".to_owned();
        }
    } else {
        // to-do: check other distros
    }
    return "".to_owned();
}
