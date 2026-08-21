//! Defaults for the self-hosted community build.
//!
//! These values are deliberately compiled into the client instead of being
//! inferred from the executable file name or copied into a user profile.  As a
//! result, a clean portable launch and an installed service use the same
//! settings.

use hbb_common::config::{self, keys};
use std::collections::HashMap;

pub const APP_NAME: &str = "MasterDesk";
pub const ID_SERVER: &str = "hbbs.masterdesk.online";
pub const RELAY_SERVER: &str = "hbbr.masterdesk.online";
pub const WINDOWS_UPDATE_ASSET_NAME: &str = "MasterDesk-1.4.9-RDS-x86_64.exe";
/// Branded release sequence. Keep the upstream protocol version in
/// `src/version.rs` unchanged so peer feature negotiation remains compatible.
pub const UPDATE_VERSION: &str = "1.4.9-10";
/// Per-candidate identity injected by `scripts/Build-CustomWindows.ps1`.
/// Direct developer builds retain an explicit numeric fallback, but every
/// distributed/test EXE must be created through the script.
pub const BUILD_BETA_NUMBER: &str = match option_env!("MASTERDESK_BUILD_BETA_NUMBER") {
    Some(value) => value,
    None => "0",
};
pub const CUSTOM_BUILD_DATE: &str = match option_env!("MASTERDESK_BUILD_DATE") {
    Some(value) => value,
    None => crate::BUILD_DATE,
};

pub fn build_display_version() -> String {
    format!("{UPDATE_VERSION} beta {BUILD_BETA_NUMBER}")
}

fn split_build_version(value: &str) -> (&str, u64) {
    let trimmed = value.trim();
    let lower = trimmed.to_ascii_lowercase();
    if let Some(index) = lower.find(" beta ") {
        let beta = trimmed[index + 6..].trim().parse::<u64>().unwrap_or(0);
        (&trimmed[..index], beta)
    } else {
        (trimmed, 0)
    }
}

pub fn installed_build_is_older(installed_version: &str, installed_date: &str) -> bool {
    let current_version = build_display_version();
    let (current_base, current_beta) = split_build_version(&current_version);
    let (installed_base, installed_beta) = split_build_version(installed_version);
    let current_base = hbb_common::get_version_number(current_base);
    let installed_base = hbb_common::get_version_number(installed_base);

    if current_base != installed_base {
        return current_base > installed_base;
    }
    if current_beta != installed_beta {
        return current_beta > installed_beta;
    }
    CUSTOM_BUILD_DATE > installed_date.trim()
}
/// Accept both the public hostname and its current IPv4 address in the
/// socket-level VPN bypass. The visible ID/relay/API settings always use DNS.
pub const DIRECT_SERVER_TARGETS: &str =
    "hbbs.masterdesk.online,hbbr.masterdesk.online,api.masterdesk.online,176.123.167.146";
pub const DEFAULT_CODEC: &str = "vp9";
pub const DEFAULT_IMAGE_QUALITY: &str = "balanced";
pub const DEFAULT_VIEW_STYLE: &str = "adaptive";
/// Offer both password authentication and the local Accept/Cancel prompt.
pub const DEFAULT_APPROVE_MODE: &str = "password-click";
// Windows-to-Windows control must preserve physical key semantics. Unicode
// translation is useful for text entry, but applications such as Total
// Commander and TestDisk react to scan-code key events rather than inserted
// characters.
pub const DEFAULT_KEYBOARD_MODE: &str = "map";
pub const DEFAULT_INPUT_SOURCE: &str = "Input source 1";
/// Allow an unelevated member of the local Administrators group to use the
/// installed server's main IPC channel from another Windows RDP session.
///
/// The IPC accept path still requires the peer to be the exact same
/// executable. This restores the local admin GUI on multi-session RDS hosts
/// without exposing machine-wide settings or passwords to standard users.
pub const ALLOW_RDS_ADMIN_CROSS_SESSION_IPC: bool = true;

// These public connection parameters cannot be made secret from an administrator
// of the client computer, but keeping their plain representation out of the
// executable prevents accidental disclosure through the settings UI, exported
// configuration, user TOML and a basic strings scan.
const INTERNAL_VALUE_MASK: &[u8] = &[
    0x31, 0x7c, 0xa5, 0x19, 0xd3, 0x62, 0x4e, 0x88, 0x07, 0xf1, 0x55,
];
const OBFUSCATED_API_SERVER: &[u8] = &[
    0x59, 0x08, 0xd1, 0x69, 0xa0, 0x58, 0x61, 0xa7, 0x66, 0x81, 0x3c, 0x1f, 0x11, 0xc4, 0x6a, 0xa7,
    0x07, 0x3c, 0xec, 0x62, 0x82, 0x3e, 0x1f, 0x13, 0xcb, 0x75, 0xba, 0x0c, 0x2b,
];
const OBFUSCATED_UPDATE_MANIFEST_URL: &[u8] = &[
    0x59, 0x08, 0xd1, 0x69, 0xa0, 0x58, 0x61, 0xa7, 0x66, 0x81, 0x3c, 0x1f, 0x11, 0xc4, 0x6a, 0xa7,
    0x07, 0x3c, 0xec, 0x62, 0x82, 0x3e, 0x1f, 0x13, 0xcb, 0x75, 0xba, 0x0c, 0x2b, 0xa7, 0x6a, 0x90,
    0x26, 0x45, 0x19, 0xd7, 0x7d, 0xb6, 0x11, 0x25, 0xa7, 0x71, 0x94, 0x27, 0x42, 0x15, 0xca, 0x77,
    0xfc, 0x0e, 0x2f, 0xfc, 0x62, 0x82, 0x21,
];
const OBFUSCATED_SERVER_PUBLIC_KEY: &[u8] = &[
    0x5e, 0x04, 0xc1, 0x5e, 0x83, 0x5b, 0x27, 0xcf, 0x4a, 0xbb, 0x64, 0x56, 0x3d, 0x96, 0x7e, 0xbe,
    0x1b, 0x0f, 0xf1, 0x6d, 0xa4, 0x1b, 0x5c, 0x1b, 0xeb, 0x58, 0xab, 0x54, 0x08, 0xbc, 0x6c, 0xb5,
    0x63, 0x6b, 0x4f, 0xd6, 0x55, 0x81, 0x08, 0x17, 0xbf, 0x40, 0xc5, 0x68,
];

fn decode_internal_value(value: &[u8]) -> String {
    let decoded = value
        .iter()
        .enumerate()
        .map(|(index, byte)| byte ^ INTERNAL_VALUE_MASK[index % INTERNAL_VALUE_MASK.len()])
        .collect::<Vec<_>>();
    String::from_utf8(decoded).unwrap_or_default()
}

pub fn internal_api_server() -> String {
    decode_internal_value(OBFUSCATED_API_SERVER)
}

pub fn update_manifest_url() -> String {
    decode_internal_value(OBFUSCATED_UPDATE_MANIFEST_URL)
}

pub fn internal_server_public_key() -> String {
    decode_internal_value(OBFUSCATED_SERVER_PUBLIC_KEY)
}

pub fn is_protected_network_option(key: &str) -> bool {
    matches!(key, keys::OPTION_API_SERVER | keys::OPTION_KEY)
}

fn server_settings() -> HashMap<String, String> {
    HashMap::from([
        (
            keys::OPTION_CUSTOM_RENDEZVOUS_SERVER.to_owned(),
            ID_SERVER.to_owned(),
        ),
        (
            keys::OPTION_RELAY_SERVER.to_owned(),
            RELAY_SERVER.to_owned(),
        ),
        (
            keys::OPTION_ALLOW_REMOTE_CONFIG_MODIFICATION.to_owned(),
            "Y".to_owned(),
        ),
        (
            keys::OPTION_APPROVE_MODE.to_owned(),
            DEFAULT_APPROVE_MODE.to_owned(),
        ),
        (
            keys::OPTION_FORCE_DIRECT_SERVER.to_owned(),
            DIRECT_SERVER_TARGETS.to_owned(),
        ),
        (keys::OPTION_ENABLE_BLOCK_INPUT.to_owned(), "N".to_owned()),
        (keys::OPTION_ENABLE_PRIVACY_MODE.to_owned(), "N".to_owned()),
        (keys::OPTION_ENABLE_CAMERA.to_owned(), "N".to_owned()),
        (keys::OPTION_ENABLE_TUNNEL.to_owned(), "N".to_owned()),
        // Background installation remains disabled. Interactive updates from
        // the main window verify the published SHA-256 before execution.
        (keys::OPTION_ALLOW_AUTO_UPDATE.to_owned(), "N".to_owned()),
    ])
}

fn display_settings() -> HashMap<String, String> {
    HashMap::from([
        (
            keys::OPTION_CODEC_PREFERENCE.to_owned(),
            DEFAULT_CODEC.to_owned(),
        ),
        (
            keys::OPTION_IMAGE_QUALITY.to_owned(),
            DEFAULT_IMAGE_QUALITY.to_owned(),
        ),
        (
            keys::OPTION_VIEW_STYLE.to_owned(),
            DEFAULT_VIEW_STYLE.to_owned(),
        ),
        (
            keys::OPTION_SHOW_MONITORS_TOOLBAR.to_owned(),
            "Y".to_owned(),
        ),
        (
            keys::OPTION_USE_ALL_MY_DISPLAYS_FOR_THE_REMOTE_SESSION.to_owned(),
            "Y".to_owned(),
        ),
    ])
}

fn local_settings() -> HashMap<String, String> {
    HashMap::from([
        (keys::OPTION_ENABLE_CHECK_UPDATE.to_owned(), "Y".to_owned()),
        (keys::OPTION_ENABLE_UDP_PUNCH.to_owned(), "Y".to_owned()),
        ("input-source".to_owned(), DEFAULT_INPUT_SOURCE.to_owned()),
        (
            keys::OPTION_ALLOW_MONITOR_SWITCH_MAIN_TOOLBAR.to_owned(),
            "Y".to_owned(),
        ),
    ])
}

const PREVIOUS_ID_SERVER_HOSTS: &[&str] = &[
    "desk.masteronline.space",
    "hbbs.masteronline.space",
    "176.123.167.146",
];
const PREVIOUS_RELAY_SERVER_HOSTS: &[&str] = &[
    "desk.masteronline.space",
    "hbbr.masteronline.space",
    "176.123.167.146",
];
const PREVIOUS_API_SERVER_HOSTS: &[&str] = &[
    "desk.masteronline.space",
    "api.masteronline.space",
    "176.123.167.146",
];

fn endpoint_host(value: &str) -> String {
    let value = value.trim();
    let value = value
        .split_once("://")
        .map(|(_, authority)| authority)
        .unwrap_or(value);
    value
        .split(['/', '?', '#'])
        .next()
        .unwrap_or_default()
        .split(':')
        .next()
        .unwrap_or_default()
        .trim_end_matches('.')
        .to_ascii_lowercase()
}

fn is_previous_endpoint(value: &str, previous_hosts: &[&str]) -> bool {
    let host = endpoint_host(value);
    previous_hosts.iter().any(|previous| host == *previous)
}

fn migrate_previous_endpoint(key: &str, value: &str, previous_hosts: &[&str]) {
    if is_previous_endpoint(&config::Config::get_option(key), previous_hosts) {
        config::Config::set_option(key.to_owned(), value.to_owned());
    }
}

fn is_previous_direct_server_targets(value: &str) -> bool {
    let mut hosts = value
        .split(',')
        .map(endpoint_host)
        .filter(|host| !host.is_empty())
        .collect::<Vec<_>>();
    hosts.sort();
    hosts.dedup();

    [
        vec!["176.123.167.146"],
        vec!["176.123.167.146", "desk.masteronline.space"],
        vec![
            "176.123.167.146",
            "api.masteronline.space",
            "hbbr.masteronline.space",
            "hbbs.masteronline.space",
        ],
    ]
    .into_iter()
    .any(|previous| hosts == previous)
}

fn migrate_previous_network_settings() {
    migrate_previous_endpoint(
        keys::OPTION_CUSTOM_RENDEZVOUS_SERVER,
        ID_SERVER,
        PREVIOUS_ID_SERVER_HOSTS,
    );
    migrate_previous_endpoint(
        keys::OPTION_RELAY_SERVER,
        RELAY_SERVER,
        PREVIOUS_RELAY_SERVER_HOSTS,
    );
    migrate_previous_endpoint(
        keys::OPTION_API_SERVER,
        &internal_api_server(),
        PREVIOUS_API_SERVER_HOSTS,
    );

    let direct_targets = config::Config::get_option(keys::OPTION_FORCE_DIRECT_SERVER);
    if is_previous_direct_server_targets(&direct_targets) {
        config::Config::set_option(
            keys::OPTION_FORCE_DIRECT_SERVER.to_owned(),
            DIRECT_SERVER_TARGETS.to_owned(),
        );
    }
}

pub fn is_newer_update(latest: &str) -> bool {
    hbb_common::get_version_number(latest) > hbb_common::get_version_number(UPDATE_VERSION)
}

/// Apply the fork defaults in every RustDesk process (GUI, service and
/// portable client). Existing user values remain higher priority because these
/// are defaults rather than policy overrides.
pub fn apply() {
    config::DEFAULT_SETTINGS
        .write()
        .unwrap()
        .extend(server_settings());
    config::DEFAULT_DISPLAY_SETTINGS
        .write()
        .unwrap()
        .extend(display_settings());
    config::DEFAULT_LOCAL_SETTINGS
        .write()
        .unwrap()
        .extend(local_settings());
    migrate_previous_network_settings();

    // Purge legacy user-visible copies before applying the fixed internal
    // policy. Config::set_option also removes them when apply() is called more
    // than once and the overwrite policy is already active.
    config::Config::set_option(keys::OPTION_API_SERVER.to_owned(), String::new());
    config::Config::set_option(keys::OPTION_KEY.to_owned(), String::new());
    config::OVERWRITE_SETTINGS.write().unwrap().extend([
        (keys::OPTION_API_SERVER.to_owned(), internal_api_server()),
        (keys::OPTION_KEY.to_owned(), internal_server_public_key()),
        (
            keys::OPTION_ALLOW_INSECURE_TLS_FALLBACK.to_owned(),
            "N".to_owned(),
        ),
        (
            keys::OPTION_FORCE_SECURE_WEBSOCKET.to_owned(),
            "Y".to_owned(),
        ),
    ]);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_identity_has_numeric_beta_and_iso_date() {
        assert!(BUILD_BETA_NUMBER.parse::<u64>().is_ok());
        assert!(build_display_version().ends_with(&format!("beta {BUILD_BETA_NUMBER}")));
        assert!(CUSTOM_BUILD_DATE.len() >= 16);
        assert_eq!(&CUSTOM_BUILD_DATE[4..5], "-");
        assert_eq!(&CUSTOM_BUILD_DATE[7..8], "-");
    }

    #[test]
    fn build_version_parser_distinguishes_beta_sequence() {
        assert_eq!(split_build_version("1.4.9-10"), ("1.4.9-10", 0));
        assert_eq!(split_build_version("1.4.9-10 beta 12"), ("1.4.9-10", 12));
    }

    #[test]
    fn bundled_network_defaults_match_the_deployment() {
        assert_eq!(&*config::APP_NAME.read().unwrap(), APP_NAME);
        let settings = server_settings();
        assert_eq!(
            settings.get(keys::OPTION_CUSTOM_RENDEZVOUS_SERVER),
            Some(&ID_SERVER.to_owned())
        );
        assert_eq!(
            settings.get(keys::OPTION_RELAY_SERVER),
            Some(&RELAY_SERVER.to_owned())
        );
        assert!(!settings.contains_key(keys::OPTION_API_SERVER));
        assert!(!settings.contains_key(keys::OPTION_KEY));
        assert_eq!(
            settings.get(keys::OPTION_FORCE_DIRECT_SERVER),
            Some(&DIRECT_SERVER_TARGETS.to_owned())
        );
        assert_eq!(
            settings.get(keys::OPTION_ALLOW_REMOTE_CONFIG_MODIFICATION),
            Some(&"Y".to_owned())
        );
        assert_eq!(
            settings.get(keys::OPTION_ALLOW_AUTO_UPDATE),
            Some(&"N".to_owned())
        );
    }

    #[test]
    fn bundled_direct_server_targets_match_domain_and_ipv4() {
        apply();
        assert!(hbb_common::direct_server::is_target(ID_SERVER));
        assert!(hbb_common::direct_server::is_target(
            "HBBS.MASTERDESK.ONLINE:21116"
        ));
        assert!(hbb_common::direct_server::is_target(
            "HBBR.MASTERDESK.ONLINE:21117"
        ));
        assert!(hbb_common::direct_server::is_target(
            "API.MASTERDESK.ONLINE:443"
        ));
        assert!(hbb_common::direct_server::is_target(
            "176.123.167.146:21117"
        ));
        assert!(!hbb_common::direct_server::is_target("example.com:21116"));
        assert_eq!(
            hbb_common::direct_server::resolved_target("hbbs.masterdesk.online:21116"),
            Some("176.123.167.146:21116".to_owned())
        );
        assert_eq!(
            hbb_common::direct_server::resolved_target("hbbr.masterdesk.online:21117"),
            Some("176.123.167.146:21117".to_owned())
        );
    }

    #[test]
    fn branded_update_versions_are_compared_independently_from_upstream() {
        assert!(!is_newer_update("1.4.9-2"));
        assert!(!is_newer_update("1.4.9-4"));
        assert!(!is_newer_update("1.4.9-5"));
        assert!(!is_newer_update(UPDATE_VERSION));
        assert!(!is_newer_update("1.4.9-7"));
        assert!(!is_newer_update("1.4.9-8"));
        assert!(!is_newer_update("1.4.9-9"));
        assert!(!is_newer_update("1.4.9-10"));
        assert!(is_newer_update("1.4.9-11"));
        assert!(is_newer_update("1.4.10-1"));
    }

    #[test]
    fn recognizes_only_known_previous_network_endpoints_for_migration() {
        assert!(is_previous_endpoint(
            "desk.masteronline.space",
            PREVIOUS_ID_SERVER_HOSTS
        ));
        assert!(is_previous_endpoint(
            "HBBS.MASTERONLINE.SPACE.:21116",
            PREVIOUS_ID_SERVER_HOSTS
        ));
        assert!(is_previous_endpoint(
            "https://api.masteronline.space/",
            PREVIOUS_API_SERVER_HOSTS
        ));
        assert!(is_previous_endpoint(
            "176.123.167.146:21117",
            PREVIOUS_RELAY_SERVER_HOSTS
        ));
        assert!(!is_previous_endpoint(ID_SERVER, PREVIOUS_ID_SERVER_HOSTS));
        assert!(!is_previous_endpoint(
            "hbbs.customer.example",
            PREVIOUS_ID_SERVER_HOSTS
        ));
        assert!(!is_previous_endpoint(
            "hbbs.masteronline.space.attacker.example",
            PREVIOUS_ID_SERVER_HOSTS
        ));
    }

    #[test]
    fn recognizes_only_previous_direct_target_sets_for_migration() {
        assert!(is_previous_direct_server_targets(
            "desk.masteronline.space,176.123.167.146"
        ));
        assert!(is_previous_direct_server_targets(
            "hbbs.masteronline.space,hbbr.masteronline.space,api.masteronline.space,176.123.167.146"
        ));
        assert!(!is_previous_direct_server_targets(DIRECT_SERVER_TARGETS));
        assert!(!is_previous_direct_server_targets(
            "hbbs.customer.example,176.123.167.146"
        ));
    }

    #[test]
    fn bundled_permission_defaults_match_the_deployment() {
        let settings = server_settings();
        for key in [
            keys::OPTION_ENABLE_BLOCK_INPUT,
            keys::OPTION_ENABLE_PRIVACY_MODE,
            keys::OPTION_ENABLE_CAMERA,
            keys::OPTION_ENABLE_TUNNEL,
        ] {
            assert_eq!(settings.get(key), Some(&"N".to_owned()));
        }
    }

    #[test]
    fn bundled_display_defaults_match_the_deployment() {
        let settings = display_settings();
        assert_eq!(
            settings.get(keys::OPTION_CODEC_PREFERENCE),
            Some(&DEFAULT_CODEC.to_owned())
        );
        assert_eq!(
            settings.get(keys::OPTION_IMAGE_QUALITY),
            Some(&DEFAULT_IMAGE_QUALITY.to_owned())
        );
        assert_eq!(
            settings.get(keys::OPTION_VIEW_STYLE),
            Some(&DEFAULT_VIEW_STYLE.to_owned())
        );
        assert_eq!(
            settings.get(keys::OPTION_SHOW_MONITORS_TOOLBAR),
            Some(&"Y".to_owned())
        );
        assert_eq!(
            settings.get(keys::OPTION_USE_ALL_MY_DISPLAYS_FOR_THE_REMOTE_SESSION),
            Some(&"Y".to_owned())
        );
    }

    #[test]
    fn bundled_local_defaults_match_the_deployment() {
        let settings = local_settings();
        assert_eq!(
            settings.get(keys::OPTION_ENABLE_CHECK_UPDATE),
            Some(&"Y".to_owned())
        );
        assert_eq!(
            settings.get(keys::OPTION_ENABLE_UDP_PUNCH),
            Some(&"Y".to_owned())
        );
        assert_eq!(
            settings.get(keys::OPTION_ALLOW_MONITOR_SWITCH_MAIN_TOOLBAR),
            Some(&"Y".to_owned())
        );
        assert_eq!(
            settings.get("input-source"),
            Some(&DEFAULT_INPUT_SOURCE.to_owned())
        );
    }

    #[test]
    fn bundled_interaction_defaults_match_the_deployment() {
        let settings = server_settings();
        assert_eq!(
            settings.get(keys::OPTION_APPROVE_MODE),
            Some(&DEFAULT_APPROVE_MODE.to_owned())
        );
        assert_eq!(DEFAULT_KEYBOARD_MODE, "map");
    }

    #[test]
    fn clean_profile_resolves_the_bundled_defaults() {
        apply();

        assert_eq!(
            config::Config::get_option(keys::OPTION_CUSTOM_RENDEZVOUS_SERVER),
            ID_SERVER
        );
        assert_eq!(
            config::Config::get_option(keys::OPTION_RELAY_SERVER),
            RELAY_SERVER
        );
        assert_eq!(
            config::Config::get_option(keys::OPTION_API_SERVER),
            internal_api_server()
        );
        assert_eq!(
            config::Config::get_option(keys::OPTION_KEY),
            internal_server_public_key()
        );
        assert_eq!(
            config::Config::get_option(keys::OPTION_ALLOW_INSECURE_TLS_FALLBACK),
            "N"
        );
        assert_eq!(
            config::Config::get_option(keys::OPTION_FORCE_SECURE_WEBSOCKET),
            "Y"
        );
        config::Config::set_option(keys::OPTION_ALLOW_WEBSOCKET.to_owned(), "Y".to_owned());
        assert_eq!(
            hbb_common::websocket::check_ws("hbbs.masterdesk.online:21116"),
            "wss://hbbs.masterdesk.online/ws/id"
        );
        assert_eq!(
            hbb_common::websocket::check_ws("hbbr.masterdesk.online:21117"),
            "wss://hbbr.masterdesk.online/ws/relay"
        );
        config::Config::set_option(keys::OPTION_ALLOW_WEBSOCKET.to_owned(), String::new());
        assert_eq!(
            config::Config::get_option(keys::OPTION_FORCE_DIRECT_SERVER),
            DIRECT_SERVER_TARGETS
        );
        assert_eq!(
            config::Config::get_option(keys::OPTION_ALLOW_REMOTE_CONFIG_MODIFICATION),
            "Y"
        );
        assert_eq!(
            config::Config::get_option(keys::OPTION_APPROVE_MODE),
            DEFAULT_APPROVE_MODE
        );
        assert!(config::option2bool(
            keys::OPTION_ENABLE_CHECK_UPDATE,
            &config::LocalConfig::get_option(keys::OPTION_ENABLE_CHECK_UPDATE),
        ));
        assert!(!config::option2bool(
            keys::OPTION_ALLOW_AUTO_UPDATE,
            &config::Config::get_option(keys::OPTION_ALLOW_AUTO_UPDATE),
        ));
        for key in [
            keys::OPTION_ENABLE_BLOCK_INPUT,
            keys::OPTION_ENABLE_PRIVACY_MODE,
            keys::OPTION_ENABLE_CAMERA,
            keys::OPTION_ENABLE_TUNNEL,
        ] {
            assert!(!config::option2bool(key, &config::Config::get_option(key)));
        }

        let display = config::UserDefaultConfig::default();
        assert_eq!(display.get(keys::OPTION_CODEC_PREFERENCE), DEFAULT_CODEC);
        assert_eq!(
            display.get(keys::OPTION_IMAGE_QUALITY),
            DEFAULT_IMAGE_QUALITY
        );
        assert_eq!(display.get(keys::OPTION_VIEW_STYLE), DEFAULT_VIEW_STYLE);
        assert_eq!(display.get(keys::OPTION_SHOW_MONITORS_TOOLBAR), "Y");
        assert_eq!(
            display.get(keys::OPTION_USE_ALL_MY_DISPLAYS_FOR_THE_REMOTE_SESSION),
            "Y"
        );
        for key in [
            keys::OPTION_ENABLE_UDP_PUNCH,
            keys::OPTION_ALLOW_MONITOR_SWITCH_MAIN_TOOLBAR,
        ] {
            assert!(config::option2bool(
                key,
                &config::LocalConfig::get_option(key)
            ));
        }
        assert_eq!(
            config::LocalConfig::get_option("input-source"),
            DEFAULT_INPUT_SOURCE
        );
    }
}
