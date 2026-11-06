#[cfg(not(any(target_os = "android", target_os = "ios")))]
use crate::clipboard::{update_clipboard, ClipboardSide};
use hbb_common::{message_proto::*, ResultType};
use std::collections::HashMap;
use std::sync::Mutex;

lazy_static::lazy_static! {
    static ref SCREENSHOT: Mutex<Screenshot> = Default::default();
}

const WALLPAPER_PREVIEW_SID_PREFIX: &str = "wallpaper-preview:";

pub fn wallpaper_preview_request_sid(sid: &str) -> String {
    format!("{WALLPAPER_PREVIEW_SID_PREFIX}{sid}")
}

pub fn wallpaper_preview_response_session_id(sid: &str) -> Option<&str> {
    sid.strip_prefix(WALLPAPER_PREVIEW_SID_PREFIX)
        .filter(|sid| !sid.is_empty())
}

pub enum ScreenshotAction {
    SaveAs(String),
    CopyToClipboard,
    Discard,
}

impl Default for ScreenshotAction {
    fn default() -> Self {
        Self::Discard
    }
}

impl From<&str> for ScreenshotAction {
    fn from(value: &str) -> Self {
        match value.chars().next() {
            Some('0') => {
                if let Some((pos, _)) = value.char_indices().nth(2) {
                    let substring = &value[pos..];
                    Self::SaveAs(substring.to_string())
                } else {
                    Self::default()
                }
            }
            Some('1') => Self::CopyToClipboard,
            Some('2') => Self::default(),
            _ => Self::default(),
        }
    }
}

impl Into<String> for ScreenshotAction {
    fn into(self) -> String {
        match self {
            Self::SaveAs(p) => format!("0:{p}"),
            Self::CopyToClipboard => "1".to_owned(),
            Self::Discard => "2".to_owned(),
        }
    }
}

#[derive(Default)]
pub struct Screenshot {
    data: HashMap<String, bytes::Bytes>,
}

impl Screenshot {
    fn set_screenshot(&mut self, sid: String, data: bytes::Bytes) {
        self.data.insert(sid, data);
    }

    fn handle_screenshot(&mut self, sid: &str, action: String) -> String {
        let Some(data) = self.data.remove(sid) else {
            return "No cached screenshot".to_owned();
        };
        match Self::handle_screenshot_(data, action) {
            Ok(()) => "".to_owned(),
            Err(e) => e.to_string(),
        }
    }

    fn handle_screenshot_(data: bytes::Bytes, action: String) -> ResultType<()> {
        match ScreenshotAction::from(&action as &str) {
            ScreenshotAction::SaveAs(p) => {
                std::fs::write(p, data)?;
            }
            ScreenshotAction::CopyToClipboard => {
                #[cfg(not(any(target_os = "android", target_os = "ios")))]
                {
                    let clips = vec![Clipboard {
                        compress: false,
                        content: data,
                        format: ClipboardFormat::ImagePng.into(),
                        ..Default::default()
                    }];
                    update_clipboard(clips, ClipboardSide::Client);
                }
            }
            ScreenshotAction::Discard => {}
        }
        Ok(())
    }
}

pub fn set_screenshot(sid: String, data: bytes::Bytes) {
    SCREENSHOT.lock().unwrap().set_screenshot(sid, data);
}

pub fn handle_screenshot(action: String) -> String {
    handle_screenshot_for("", action)
}

pub fn handle_screenshot_for(sid: &str, action: String) -> String {
    SCREENSHOT.lock().unwrap().handle_screenshot(sid, action)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn screenshot_cache_is_scoped_by_session() {
        let mut screenshots = Screenshot::default();
        screenshots.set_screenshot("one".to_owned(), bytes::Bytes::from_static(b"one"));
        screenshots.set_screenshot("two".to_owned(), bytes::Bytes::from_static(b"two"));

        assert_eq!(screenshots.handle_screenshot("one", "2".to_owned()), "");
        assert_eq!(
            screenshots.handle_screenshot("one", "2".to_owned()),
            "No cached screenshot"
        );
        assert_eq!(screenshots.handle_screenshot("two", "2".to_owned()), "");
    }

    #[test]
    fn wallpaper_preview_sid_is_explicit_and_round_trips() {
        let request_sid = wallpaper_preview_request_sid("session-id");
        assert_eq!(request_sid, "wallpaper-preview:session-id");
        assert_eq!(
            wallpaper_preview_response_session_id(&request_sid),
            Some("session-id")
        );
        assert_eq!(wallpaper_preview_response_session_id("session-id"), None);
        assert_eq!(
            wallpaper_preview_response_session_id(WALLPAPER_PREVIEW_SID_PREFIX),
            None
        );
    }
}
