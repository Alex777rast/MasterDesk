//! Windows service-owned permanent-password storage.
//!
//! Only the salted verifier is stored, protected with machine-scope DPAPI and a
//! LocalSystem/Administrators-only DACL. Interactive processes receive the verifier
//! through authenticated local IPC for their current lifetime; they never own a
//! second persistent copy.

#![cfg(target_os = "windows")]

use hbb_common::{
    anyhow::{anyhow, Context},
    bail,
    config::{compute_permanent_password_h1, Config},
    ResultType,
};
use serde_derive::{Deserialize, Serialize};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    os::windows::ffi::OsStrExt,
    path::{Path, PathBuf},
    ptr::{null, null_mut},
    sync::{Mutex, OnceLock},
    time::{SystemTime, UNIX_EPOCH},
};
use winapi::{
    shared::minwindef::HLOCAL,
    um::{
        dpapi::{
            CryptProtectData, CryptUnprotectData, CRYPTPROTECT_LOCAL_MACHINE,
            CRYPTPROTECT_UI_FORBIDDEN,
        },
        winbase::{LocalFree, MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH},
        wincrypt::DATA_BLOB,
    },
};

const STORE_VERSION: u32 = 1;
const SALT_LEN: usize = 32;
const H1_HEX_LEN: usize = 64;
const RUNTIME_NONCE_LEN: usize = 32;

#[derive(Debug, Serialize, Deserialize)]
struct RuntimeNonceRecord {
    version: u32,
    boot_epoch_second: u64,
    nonce_hex: String,
}

static RUNTIME_SESSION_NONCE: OnceLock<Vec<u8>> = OnceLock::new();
static RUNTIME_SESSION_NONCE_INIT: Mutex<()> = Mutex::new(());

#[link(name = "kernel32")]
extern "system" {
    fn GetTickCount64() -> u64;
}

#[derive(Debug, Serialize, Deserialize)]
struct ProtectedRecord {
    version: u32,
    protected_hex: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct MachinePasswordPayload {
    pub h1_hex: String,
    pub salt: String,
}

impl MachinePasswordPayload {
    pub fn from_plain(password: &str) -> Self {
        Self::from_plain_with_salt(password, None)
    }

    fn from_plain_with_salt(password: &str, existing_salt: Option<&str>) -> Self {
        if password.is_empty() {
            return Self::default();
        }
        let salt = existing_salt
            .filter(|salt| !salt.is_empty())
            .map(str::to_owned)
            .unwrap_or_else(|| Config::get_auto_password(SALT_LEN));
        let h1 = compute_permanent_password_h1(password, &salt);
        Self {
            h1_hex: hex::encode(h1),
            salt,
        }
    }

    pub fn h1(&self) -> ResultType<Option<[u8; 32]>> {
        validate_payload(self)?;
        if self.h1_hex.is_empty() {
            return Ok(None);
        }
        let decoded = hex::decode(&self.h1_hex)
            .map_err(|_| anyhow!("Invalid machine permanent password verifier encoding"))?;
        let mut h1 = [0u8; 32];
        h1.copy_from_slice(&decoded);
        Ok(Some(h1))
    }
}

fn validate_payload(payload: &MachinePasswordPayload) -> ResultType<()> {
    if payload.h1_hex.is_empty() {
        if !payload.salt.is_empty() {
            bail!("Machine permanent password has salt without verifier");
        }
        return Ok(());
    }
    if payload.salt.is_empty() || payload.h1_hex.len() != H1_HEX_LEN {
        bail!("Invalid machine permanent password verifier metadata");
    }
    let decoded = hex::decode(&payload.h1_hex)
        .map_err(|_| anyhow!("Invalid machine permanent password verifier encoding"))?;
    if decoded.len() != 32 {
        bail!("Invalid machine permanent password verifier length");
    }
    Ok(())
}

fn store_dir() -> ResultType<PathBuf> {
    let program_data = std::env::var_os("ProgramData")
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("ProgramData is unavailable"))?;
    Ok(PathBuf::from(program_data)
        .join(crate::get_app_name())
        .join("machine"))
}

pub fn store_path() -> ResultType<PathBuf> {
    Ok(store_dir()?.join("permanent-password.json"))
}

pub fn load() -> ResultType<Option<MachinePasswordPayload>> {
    let path = store_path()?;
    let raw = match fs::read(&path) {
        Ok(raw) => raw,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => {
            return Err(anyhow!(
                "Failed to read machine permanent password store '{}': {}",
                path.display(),
                err
            ))
        }
    };
    let record: ProtectedRecord =
        serde_json::from_slice(&raw).context("Invalid machine permanent password store wrapper")?;
    if record.version != STORE_VERSION {
        bail!(
            "Unsupported machine permanent password store version {}",
            record.version
        );
    }
    let protected = hex::decode(&record.protected_hex)
        .context("Invalid machine permanent password DPAPI encoding")?;
    let plain = dpapi_unprotect(&protected)?;
    let payload: MachinePasswordPayload =
        serde_json::from_slice(&plain).context("Invalid machine permanent password payload")?;
    validate_payload(&payload)?;
    Ok(Some(payload))
}

pub fn set_plain(password: &str) -> ResultType<MachinePasswordPayload> {
    // Keep live authentication challenges valid across password changes by
    // retaining the current salt. A first password still receives a random salt.
    let existing = load()?;
    let payload = MachinePasswordPayload::from_plain_with_salt(
        password,
        existing.as_ref().map(|payload| payload.salt.as_str()),
    );
    store(&payload)?;
    Ok(payload)
}

pub fn initialize_if_missing(
    legacy: Option<MachinePasswordPayload>,
) -> ResultType<MachinePasswordPayload> {
    if let Some(current) = load()? {
        return Ok(current);
    }
    let payload = match legacy {
        Some(payload) => {
            validate_payload(&payload)?;
            payload
        }
        None => MachinePasswordPayload::default(),
    };
    store(&payload)?;
    Ok(payload)
}

/// Returns one boot-scoped nonce for the installed service and every child
/// `--server`. It survives a service restart, but a cloned Windows boot receives
/// a new value instead of inheriting a long-lived disk identity.
pub fn runtime_session_nonce() -> ResultType<Vec<u8>> {
    if let Some(nonce) = RUNTIME_SESSION_NONCE.get() {
        return Ok(nonce.clone());
    }

    let _initialization_guard = RUNTIME_SESSION_NONCE_INIT
        .lock()
        .map_err(|_| anyhow!("Machine session nonce initialization lock was poisoned"))?;
    if let Some(nonce) = RUNTIME_SESSION_NONCE.get() {
        return Ok(nonce.clone());
    }

    let boot_epoch_second = current_boot_epoch_second();
    let path = store_dir()?.join("runtime-session.json");
    let loaded = fs::read(&path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<RuntimeNonceRecord>(&bytes).ok())
        .filter(|record| {
            record.version == STORE_VERSION && record.boot_epoch_second == boot_epoch_second
        })
        .and_then(|record| hex::decode(record.nonce_hex).ok())
        .filter(|nonce| nonce.len() == RUNTIME_NONCE_LEN);
    let nonce = match loaded {
        Some(nonce) => nonce,
        None => {
            let nonce = hbb_common::masterdesk_security::random_nonce(RUNTIME_NONCE_LEN);
            let record = RuntimeNonceRecord {
                version: STORE_VERSION,
                boot_epoch_second,
                nonce_hex: hex::encode(&nonce),
            };
            store_machine_secret_file(
                "runtime-session.json",
                ".runtime-session",
                &serde_json::to_vec_pretty(&record)?,
            )?;
            nonce
        }
    };
    let _ = RUNTIME_SESSION_NONCE.set(nonce.clone());
    Ok(nonce)
}

fn current_boot_epoch_second() -> u64 {
    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or_default();
    let uptime_ms = unsafe { GetTickCount64() };
    now_ms.saturating_sub(uptime_ms).saturating_add(500) / 1_000
}

fn store(payload: &MachinePasswordPayload) -> ResultType<()> {
    validate_payload(payload)?;
    let protected = dpapi_protect(&serde_json::to_vec(payload)?)?;
    let record = ProtectedRecord {
        version: STORE_VERSION,
        protected_hex: hex::encode(protected),
    };
    store_machine_secret_file(
        "permanent-password.json",
        ".permanent-password",
        &serde_json::to_vec_pretty(&record)?,
    )
}

fn store_machine_secret_file(
    destination_name: &str,
    temporary_prefix: &str,
    bytes: &[u8],
) -> ResultType<()> {
    let dir = store_dir()?;
    fs::create_dir_all(&dir).with_context(|| {
        format!(
            "Failed to create machine permanent password directory '{}'",
            dir.display()
        )
    })?;
    crate::platform::windows::set_path_permission_for_machine_secret(&dir, true)?;

    let destination = dir.join(destination_name);
    let temporary = dir.join(format!(
        "{}.{}.{}.tmp",
        temporary_prefix,
        std::process::id(),
        hbb_common::rand::random::<u32>()
    ));

    let write_result = (|| -> ResultType<()> {
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)
            .with_context(|| format!("Failed to create temporary machine password store"))?;
        file.write_all(bytes)?;
        file.sync_all()?;
        crate::platform::windows::set_path_permission_for_machine_secret(&temporary, false)?;
        move_file_replace(&temporary, &destination)?;
        crate::platform::windows::set_path_permission_for_machine_secret(&destination, false)?;
        Ok(())
    })();
    if write_result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    write_result
}

fn move_file_replace(source: &Path, destination: &Path) -> ResultType<()> {
    let source_wide: Vec<u16> = source
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let destination_wide: Vec<u16> = destination
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let ok = unsafe {
        MoveFileExW(
            source_wide.as_ptr(),
            destination_wide.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if ok == 0 {
        return Err(anyhow!(
            "Failed to atomically replace machine password store: {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(())
}

fn dpapi_protect(plain: &[u8]) -> ResultType<Vec<u8>> {
    let mut input = DATA_BLOB {
        cbData: plain.len() as u32,
        pbData: plain.as_ptr() as *mut u8,
    };
    let mut output = DATA_BLOB {
        cbData: 0,
        pbData: null_mut(),
    };
    let ok = unsafe {
        CryptProtectData(
            &mut input,
            null(),
            null_mut(),
            null_mut(),
            null_mut(),
            CRYPTPROTECT_LOCAL_MACHINE | CRYPTPROTECT_UI_FORBIDDEN,
            &mut output,
        )
    };
    if ok == 0 {
        bail!("DPAPI failed to protect machine permanent password verifier");
    }
    copy_and_free_blob(output)
}

fn dpapi_unprotect(protected: &[u8]) -> ResultType<Vec<u8>> {
    let mut input = DATA_BLOB {
        cbData: protected.len() as u32,
        pbData: protected.as_ptr() as *mut u8,
    };
    let mut output = DATA_BLOB {
        cbData: 0,
        pbData: null_mut(),
    };
    let ok = unsafe {
        CryptUnprotectData(
            &mut input,
            null_mut(),
            null_mut(),
            null_mut(),
            null_mut(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut output,
        )
    };
    if ok == 0 {
        bail!("DPAPI failed to unprotect machine permanent password verifier");
    }
    copy_and_free_blob(output)
}

fn copy_and_free_blob(output: DATA_BLOB) -> ResultType<Vec<u8>> {
    if output.pbData.is_null() && output.cbData != 0 {
        bail!("DPAPI returned an invalid output buffer");
    }
    let bytes = if output.cbData == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec() }
    };
    if !output.pbData.is_null() {
        unsafe {
            LocalFree(output.pbData as HLOCAL);
        }
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn machine_payload_rejects_incomplete_verifier() {
        assert!(validate_payload(&MachinePasswordPayload {
            h1_hex: "00".repeat(32),
            salt: String::new(),
        })
        .is_err());
        assert!(validate_payload(&MachinePasswordPayload {
            h1_hex: String::new(),
            salt: "orphan".to_owned(),
        })
        .is_err());
    }

    #[test]
    fn machine_payload_plain_password_roundtrip_shape() {
        let payload = MachinePasswordPayload::from_plain("test-only-password");
        assert_eq!(payload.h1().unwrap().unwrap().len(), 32);
        assert_eq!(payload.h1_hex.len(), H1_HEX_LEN);
        assert!(!payload.salt.is_empty());
    }

    #[test]
    fn machine_payload_reuses_existing_salt_for_live_connections() {
        let first = MachinePasswordPayload::from_plain("first-test-password");
        let second =
            MachinePasswordPayload::from_plain_with_salt("second-test-password", Some(&first.salt));
        assert_eq!(second.salt, first.salt);
        assert_ne!(second.h1_hex, first.h1_hex);
    }
}
