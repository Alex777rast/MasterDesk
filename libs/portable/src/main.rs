#![windows_subsystem = "windows"]

use std::{
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

use bin_reader::BinaryReader;

pub mod bin_reader;
#[cfg(windows)]
mod ui;

#[cfg(windows)]
const APP_METADATA: &[u8] = include_bytes!("../app_metadata.toml");
#[cfg(not(windows))]
const APP_METADATA: &[u8] = &[];
const APP_METADATA_CONFIG: &str = "meta.toml";
const META_LINE_PREFIX_TIMESTAMP: &str = "timestamp = ";
const APP_PREFIX: &str = "MasterDesk";
#[cfg(windows)]
const LEGACY_APP_PREFIX: &str = "rustdesk";
#[cfg(windows)]
const MASTERDESK_BUILD_MARKER: &str = "# MasterDesk self-hosted Windows build";
const APPNAME_RUNTIME_ENV_KEY: &str = "RUSTDESK_APPNAME";
#[cfg(windows)]
const SET_FOREGROUND_WINDOW_ENV_KEY: &str = "SET_FOREGROUND_WINDOW";

fn embedded_timestamp() -> u64 {
    let Ok(app_metadata) = std::str::from_utf8(APP_METADATA) else {
        return 0;
    };
    for line in app_metadata.lines() {
        if line.starts_with(META_LINE_PREFIX_TIMESTAMP) {
            if let Ok(stored_ts) = line.replace(META_LINE_PREFIX_TIMESTAMP, "").parse::<u64>() {
                return stored_ts;
            }
        }
    }
    0
}

fn is_timestamp_matches(dir: &Path, ts: u64) -> bool {
    if ts == 0 {
        return true;
    }

    if let Ok(content) = std::fs::read_to_string(dir.join(APP_METADATA_CONFIG)) {
        for line in content.lines() {
            if line.starts_with(META_LINE_PREFIX_TIMESTAMP) {
                if let Ok(stored_ts) = line.replace(META_LINE_PREFIX_TIMESTAMP, "").parse::<u64>() {
                    return ts == stored_ts;
                }
            }
        }
    }
    false
}

fn write_meta(dir: &Path, ts: u64) {
    let meta_file = dir.join(APP_METADATA_CONFIG);
    if ts != 0 {
        let content = format!("{}{}", META_LINE_PREFIX_TIMESTAMP, ts);
        // Ignore is ok here
        let _ = std::fs::write(meta_file, content);
    }
}

#[cfg(windows)]
fn is_masterdesk_payload(dir: &Path) -> bool {
    std::fs::read_to_string(dir.join("CUSTOM_BUILD.md"))
        .map(|content| content.starts_with(MASTERDESK_BUILD_MARKER))
        .unwrap_or(false)
}

#[cfg(windows)]
fn is_masterdesk_legacy_cache(root: &Path) -> bool {
    if is_masterdesk_payload(root) {
        return true;
    }
    let Ok(entries) = std::fs::read_dir(root) else {
        return false;
    };
    let mut found_build = false;
    for entry in entries.flatten() {
        let Ok(file_type) = entry.file_type() else {
            return false;
        };
        let file_name = entry.file_name().to_string_lossy().to_string();
        if !file_type.is_dir() || !file_name.starts_with("build-") {
            return false;
        }
        if !is_masterdesk_payload(&entry.path()) {
            return false;
        }
        found_build = true;
    }
    found_build
}

#[cfg(windows)]
fn branded_payload_name(name: &str) -> Option<&'static str> {
    match name.to_ascii_lowercase().as_str() {
        "rustdesk.exe" => Some("MasterDesk.exe"),
        "librustdesk.dll" => Some("libmasterdesk.dll"),
        "runtimebroker_rustdesk.exe" => Some("RuntimeBroker_MasterDesk.exe"),
        _ => None,
    }
}

#[cfg(windows)]
fn available_branded_payload_path(path: &Path, branded_name: &str) -> Option<PathBuf> {
    let direct = path.with_file_name(branded_name);
    if !direct.exists() {
        return Some(direct);
    }

    let branded = Path::new(branded_name);
    let stem = branded.file_stem()?.to_string_lossy();
    let extension = branded.extension().map(|value| value.to_string_lossy());
    (1..=1000).find_map(|index| {
        let name = match &extension {
            Some(extension) => format!("{stem}_legacy_{index}.{extension}"),
            None => format!("{stem}_legacy_{index}"),
        };
        let candidate = path.with_file_name(name);
        (!candidate.exists()).then_some(candidate)
    })
}

#[cfg(windows)]
fn rename_legacy_payload_files(root: &Path) {
    let mut directories = vec![root.to_path_buf()];
    while let Some(directory) = directories.pop() {
        let Ok(entries) = std::fs::read_dir(&directory) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(metadata) = std::fs::symlink_metadata(&path) else {
                continue;
            };
            if metadata.file_type().is_symlink() {
                continue;
            }
            if metadata.is_dir() {
                directories.push(path);
                continue;
            }
            let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
                continue;
            };
            let Some(branded_name) = branded_payload_name(name) else {
                continue;
            };
            if let Some(target) = available_branded_payload_path(&path, branded_name) {
                let _ = std::fs::rename(path, target);
            }
        }
    }
}

#[cfg(windows)]
fn migrate_legacy_masterdesk_cache(data_local_dir: &Path, branded_root: &Path) {
    let legacy_root = data_local_dir.join(LEGACY_APP_PREFIX);
    if !legacy_root.exists() || !is_masterdesk_legacy_cache(&legacy_root) {
        return;
    }

    let destination = if branded_root.exists() {
        let timestamp = embedded_timestamp();
        branded_root.join(format!("legacy-cache-{timestamp}"))
    } else {
        branded_root.to_path_buf()
    };
    if destination.exists() {
        return;
    }
    if let Some(parent) = destination.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if std::fs::rename(&legacy_root, &destination).is_ok() {
        rename_legacy_payload_files(&destination);
    }
}

fn is_setup_executable(name: &str) -> bool {
    let name = Path::new(name)
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .to_lowercase();
    name.ends_with("install.exe")
}

fn setup(
    reader: BinaryReader,
    dir: Option<PathBuf>,
    clear: bool,
    _args: &Vec<String>,
    _ui: &mut bool,
) -> Option<PathBuf> {
    let ts = embedded_timestamp();
    let dir = if let Some(dir) = dir {
        dir
    } else {
        // home dir
        if let Some(dir) = dirs::data_local_dir() {
            let root = dir.join(APP_PREFIX);
            #[cfg(windows)]
            migrate_legacy_masterdesk_cache(&dir, &root);
            if ts == 0 {
                root
            } else {
                // A shared extraction directory can retain an older DLL when
                // that DLL is still mapped by another portable process.
                // Isolate every generated package by its embedded timestamp
                // so a new beta can never launch an old cached payload.
                root.join(format!("build-{ts}"))
            }
        } else {
            eprintln!("not found data local dir");
            return None;
        }
    };

    if clear || !is_timestamp_matches(&dir, ts) {
        #[cfg(windows)]
        if _args.is_empty() {
            *_ui = true;
            ui::setup();
        }
        std::fs::remove_dir_all(&dir).ok();
    }
    for file in reader.files.iter() {
        file.write_to_file(&dir);
    }
    write_meta(&dir, ts);
    #[cfg(windows)]
    win::copy_runtime_broker(&dir);
    #[cfg(linux)]
    reader.configure_permission(&dir);
    Some(dir.join(&reader.exe))
}

fn use_null_stdio() -> bool {
    #[cfg(windows)]
    {
        // When running in CMD on Windows 7, using Stdio::inherit() with spawn returns an "invalid handle" error.
        // Since using Stdio::null() didn’t cause any issues, and determining whether the program is launched from CMD or by double-clicking would require calling more APIs during startup, we also use Stdio::null() when launched by double-clicking on Windows 7.
        let is_windows_7 = is_windows_7();
        println!("is windows7: {}", is_windows_7);
        return is_windows_7;
    }
    #[cfg(not(windows))]
    false
}

#[cfg(windows)]
fn is_windows_7() -> bool {
    use windows::Wdk::System::SystemServices::RtlGetVersion;
    use windows::Win32::System::SystemInformation::OSVERSIONINFOW;

    unsafe {
        let mut version_info = OSVERSIONINFOW::default();
        version_info.dwOSVersionInfoSize = std::mem::size_of::<OSVERSIONINFOW>() as u32;

        if RtlGetVersion(&mut version_info).is_ok() {
            // Windows 7 is version 6.1
            println!(
                "Windows version: {}.{}",
                version_info.dwMajorVersion, version_info.dwMinorVersion
            );
            return version_info.dwMajorVersion == 6 && version_info.dwMinorVersion == 1;
        }
    }
    false
}

fn execute(path: PathBuf, args: Vec<String>, _ui: bool) {
    println!("executing {}", path.display());
    // setup env
    let exe = std::env::current_exe().unwrap_or_default();
    let exe_name = exe.file_name().unwrap_or_default();
    // run executable
    let mut cmd = Command::new(path);
    cmd.args(args);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(winapi::um::winbase::CREATE_NO_WINDOW);
        if _ui {
            cmd.env(SET_FOREGROUND_WINDOW_ENV_KEY, "1");
        }
    }

    cmd.env(APPNAME_RUNTIME_ENV_KEY, exe_name);
    if use_null_stdio() {
        cmd.stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
    } else {
        cmd.stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit());
    }
    let _child = cmd.spawn();

    #[cfg(windows)]
    if _ui {
        match _child {
            Ok(child) => unsafe {
                winapi::um::winuser::AllowSetForegroundWindow(child.id() as u32);
            },
            Err(e) => {
                eprintln!("{:?}", e);
            }
        }
    }
}

fn main() {
    let mut args = Vec::new();
    let mut arg_exe = Default::default();
    let mut i = 0;
    for arg in std::env::args() {
        if i == 0 {
            arg_exe = arg.clone();
        } else {
            args.push(arg);
        }
        i += 1;
    }
    let click_setup = args.is_empty() && is_setup_executable(&arg_exe);
    #[cfg(windows)]
    let quick_support = args.is_empty() && win::is_quick_support_exe(&arg_exe);
    #[cfg(not(windows))]
    let quick_support = false;

    let mut ui = false;
    let reader = BinaryReader::default();
    if let Some(exe) = setup(
        reader,
        None,
        click_setup || args.contains(&"--silent-install".to_owned()),
        &args,
        &mut ui,
    ) {
        if click_setup {
            args = vec!["--install".to_owned()];
        } else if quick_support {
            args = vec!["--quick_support".to_owned()];
        }
        execute(exe, args, ui);
    }
}

#[cfg(test)]
mod tests {
    #[cfg(windows)]
    use super::{
        available_branded_payload_path, branded_payload_name, migrate_legacy_masterdesk_cache,
        MASTERDESK_BUILD_MARKER,
    };
    use super::{embedded_timestamp, is_setup_executable};

    #[test]
    fn masterdesk_release_runs_portable_by_default() {
        assert!(!is_setup_executable(
            r"C:\Users\User\Downloads\MasterDesk-1.4.9-RDS-x86_64.exe"
        ));
        assert!(is_setup_executable("rustdesk-1.4.9-install.exe"));
        assert!(!is_setup_executable("MasterDesk.exe"));
        assert!(!is_setup_executable("rustdesk.exe"));
    }

    #[test]
    fn generated_package_has_versioned_extraction_timestamp() {
        assert!(embedded_timestamp() > 0);
    }

    #[cfg(windows)]
    #[test]
    fn legacy_payload_names_are_rebranded_without_touching_other_files() {
        assert_eq!(branded_payload_name("rustdesk.exe"), Some("MasterDesk.exe"));
        assert_eq!(
            branded_payload_name("librustdesk.dll"),
            Some("libmasterdesk.dll")
        );
        assert_eq!(
            branded_payload_name("RuntimeBroker_rustdesk.exe"),
            Some("RuntimeBroker_MasterDesk.exe")
        );
        assert_eq!(branded_payload_name("rustdesk.toml"), None);
    }

    #[cfg(windows)]
    #[test]
    fn legacy_payload_collision_gets_a_unique_branded_name() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "masterdesk-portable-name-collision-{}-{unique}",
            std::process::id()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let legacy = root.join("rustdesk.exe");
        std::fs::write(&legacy, b"legacy").unwrap();
        std::fs::write(root.join("MasterDesk.exe"), b"current").unwrap();

        let target = available_branded_payload_path(&legacy, "MasterDesk.exe").unwrap();
        assert_eq!(target.file_name().unwrap(), "MasterDesk_legacy_1.exe");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn legacy_masterdesk_cache_is_moved_and_rebranded() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let data_local = std::env::temp_dir().join(format!(
            "masterdesk-portable-cache-migration-{}-{unique}",
            std::process::id()
        ));
        let legacy_root = data_local.join("rustdesk");
        std::fs::create_dir_all(&legacy_root).unwrap();
        std::fs::write(
            legacy_root.join("CUSTOM_BUILD.md"),
            format!("{MASTERDESK_BUILD_MARKER}\n"),
        )
        .unwrap();
        std::fs::write(legacy_root.join("rustdesk.exe"), b"runner").unwrap();
        std::fs::write(legacy_root.join("librustdesk.dll"), b"library").unwrap();
        std::fs::write(legacy_root.join("RuntimeBroker_rustdesk.exe"), b"broker").unwrap();

        let branded_root = data_local.join("MasterDesk");
        migrate_legacy_masterdesk_cache(&data_local, &branded_root);

        assert!(!legacy_root.exists());
        assert_eq!(
            std::fs::read(branded_root.join("MasterDesk.exe")).unwrap(),
            b"runner"
        );
        assert_eq!(
            std::fs::read(branded_root.join("libmasterdesk.dll")).unwrap(),
            b"library"
        );
        assert_eq!(
            std::fs::read(branded_root.join("RuntimeBroker_MasterDesk.exe")).unwrap(),
            b"broker"
        );
        std::fs::remove_dir_all(data_local).unwrap();
    }
}

#[cfg(windows)]
mod win {
    use std::{fs, os::windows::process::CommandExt, path::Path, process::Command};

    // Used for privacy mode(magnifier impl).
    pub const RUNTIME_BROKER_EXE: &'static str = "C:\\Windows\\System32\\RuntimeBroker.exe";
    pub const WIN_TOPMOST_INJECTED_PROCESS_EXE: &'static str = "RuntimeBroker_MasterDesk.exe";

    pub(super) fn copy_runtime_broker(dir: &Path) {
        let src = RUNTIME_BROKER_EXE;
        let tgt = WIN_TOPMOST_INJECTED_PROCESS_EXE;
        let target_file = dir.join(tgt);
        if target_file.exists() {
            if let (Ok(src_file), Ok(tgt_file)) = (fs::read(src), fs::read(&target_file)) {
                let src_md5 = format!("{:x}", md5::compute(&src_file));
                let tgt_md5 = format!("{:x}", md5::compute(&tgt_file));
                if src_md5 == tgt_md5 {
                    return;
                }
            }
        }
        let _allow_err = Command::new("taskkill")
            .args(&["/F", "/IM", WIN_TOPMOST_INJECTED_PROCESS_EXE])
            .creation_flags(winapi::um::winbase::CREATE_NO_WINDOW)
            .output();
        let _allow_err = std::fs::copy(src, &format!("{}\\{}", dir.to_string_lossy(), tgt));
    }

    /// Check if the executable is a Quick Support version.
    /// Note: This function must be kept in sync with `src/core_main.rs`.
    #[inline]
    pub(super) fn is_quick_support_exe(exe: &str) -> bool {
        let exe = exe.to_lowercase();
        exe.contains("-qs-") || exe.contains("-qs.exe") || exe.contains("_qs.exe")
    }
}
