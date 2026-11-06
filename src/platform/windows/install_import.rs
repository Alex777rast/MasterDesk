//! Same-machine installer handoff of current-user DPAPI configuration.
//! No plaintext handoff file, machine-wide DPAPI scope or IPC exception.
use super::{current_process_user_sid_string, get_available_sessions, get_user_token, ResultType};
use hbb_common::{anyhow::anyhow, platform::windows::RAIIHandle};
use std::{fs, path::Path};
use winapi::um::{
    securitybaseapi::{ImpersonateLoggedOnUser, RevertToSelf},
    userenv::GetUserProfileDirectoryW,
    winnt::HANDLE,
};

struct SourceUserImpersonation;

impl Drop for SourceUserImpersonation {
    fn drop(&mut self) {
        if unsafe { RevertToSelf() } == 0 {
            // Continuing in an unexpected security context is unsafe, even on
            // an error/unwind path. This short-lived importer must terminate.
            hbb_common::log::error!("Cannot leave installation source-user context");
            std::process::abort();
        }
    }
}

fn source_is_in_profile(source: &Path, profile: &Path) -> bool {
    let source: Vec<_> = source.components().collect();
    let profile: Vec<_> = profile.components().collect();
    source.len() > profile.len()
        && source.iter().zip(profile.iter()).all(|(left, right)| {
            left.as_os_str().to_string_lossy().eq_ignore_ascii_case(
                &right.as_os_str().to_string_lossy(),
            )
        })
}

fn token_profile(token: HANDLE) -> ResultType<std::path::PathBuf> {
    let mut length = 0;
    unsafe { GetUserProfileDirectoryW(token, std::ptr::null_mut(), &mut length) };
    if length == 0 || length > 32768 {
        return Err(anyhow!("Cannot query installation source profile"));
    }
    let mut buffer = vec![0u16; length as usize];
    if unsafe { GetUserProfileDirectoryW(token, buffer.as_mut_ptr(), &mut length) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    let end = buffer.iter().position(|value| *value == 0).unwrap_or(buffer.len());
    Ok(std::path::PathBuf::from(String::from_utf16(&buffer[..end])?))
}

/// The callback is synchronous and read-only. It must not cache account-bound
/// plaintext globally, write files, spawn work or cross an await boundary.
pub(crate) fn read_install_config_as_source_user<T>(
    path: &Path,
    read: impl Fn() -> ResultType<T>,
) -> ResultType<T> {
    let current_error = match read() {
        Ok(config) => return Ok(config),
        Err(error) => error,
    };
    if current_process_user_sid_string()? != "S-1-5-18" {
        return Err(current_error);
    }
    let source = fs::canonicalize(path)?;
    for session in get_available_sessions(false) {
        let token = get_user_token(session.sid, true);
        if token.is_null() {
            continue;
        }
        let token = RAIIHandle(token);
        let profile = match token_profile(token.0).and_then(|path| Ok(fs::canonicalize(path)?)) {
            Ok(profile) => profile,
            Err(_) => continue,
        };
        if !source_is_in_profile(&source, &profile) {
            continue;
        }
        if unsafe { ImpersonateLoggedOnUser(token.0) } == 0 {
            return Err(anyhow!("Cannot enter installation source-user context: {}", std::io::Error::last_os_error()));
        }
        let impersonation = SourceUserImpersonation;
        let result = read();
        drop(impersonation);
        return result;
    }
    Err(anyhow!("Protected installation config requires its logged-on source account: {current_error:#}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_install_import_profile_match_is_component_scoped() {
        let profile = Path::new(r"C:\Users\Alice");
        assert!(source_is_in_profile(Path::new(r"c:\users\alice\AppData\Roaming\MasterDesk\config\MasterDesk.toml"), profile));
        assert!(!source_is_in_profile(Path::new(r"C:\Users\AliceExtra\MasterDesk.toml"), profile));
        assert!(!source_is_in_profile(Path::new(r"C:\Users\Bob\MasterDesk.toml"), profile));
        assert!(!source_is_in_profile(profile, profile));
    }
}
