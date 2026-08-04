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
pub const API_SERVER: &str = "https://api.masterdesk.online";
pub const UPDATE_MANIFEST_URL: &str = "https://api.masterdesk.online/masterdesk/version/latest";
pub const WINDOWS_UPDATE_ASSET_NAME: &str = "MasterDesk-1.4.9-RDS-x86_64.exe";
/// Branded release sequence. Keep the upstream protocol version in
/// `src/version.rs` unchanged so peer feature negotiation remains compatible.
pub const UPDATE_VERSION: &str = "1.4.9-6";
/// Accept both the public hostname and its current IPv4 address in the
/// socket-level VPN bypass. The visible ID/relay/API settings always use DNS.
pub const DIRECT_SERVER_TARGETS: &str =
    "hbbs.masterdesk.online,hbbr.masterdesk.online,api.masterdesk.online,176.123.167.146";
pub const SERVER_PUBLIC_KEY: &str = "oxdGP9iGMJ1gA3gmyAyjUNmgNAx6F4kD6Z3sLRjY7G4=";
pub const DEFAULT_CODEC: &str = "vp9";
pub const DEFAULT_IMAGE_QUALITY: &str = "balanced";
pub const DEFAULT_VIEW_STYLE: &str = "adaptive";
/// Offer both password authentication and the local Accept/Cancel prompt.
pub const DEFAULT_APPROVE_MODE: &str = "password-click";
pub const DEFAULT_KEYBOARD_MODE: &str = "translate";
pub const DEFAULT_INPUT_SOURCE: &str = "Input source 1";
/// Allow an unelevated member of the local Administrators group to use the
/// installed server's main IPC channel from another Windows RDP session.
///
/// The IPC accept path still requires the peer to be the exact same
/// executable. This restores the local admin GUI on multi-session RDS hosts
/// without exposing machine-wide settings or passwords to standard users.
pub const ALLOW_RDS_ADMIN_CROSS_SESSION_IPC: bool = true;

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
        (keys::OPTION_API_SERVER.to_owned(), API_SERVER.to_owned()),
        (keys::OPTION_KEY.to_owned(), SERVER_PUBLIC_KEY.to_owned()),
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
        API_SERVER,
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
}

#[cfg(test)]
mod tests {
    use super::*;

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
        assert_eq!(
            settings.get(keys::OPTION_API_SERVER),
            Some(&API_SERVER.to_owned())
        );
        assert_eq!(
            settings.get(keys::OPTION_KEY),
            Some(&SERVER_PUBLIC_KEY.to_owned())
        );
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
    }

    #[test]
    fn branded_update_versions_are_compared_independently_from_upstream() {
        assert!(!is_newer_update("1.4.9-2"));
        assert!(!is_newer_update("1.4.9-4"));
        assert!(!is_newer_update("1.4.9-5"));
        assert!(!is_newer_update(UPDATE_VERSION));
        assert!(is_newer_update("1.4.9-7"));
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
        assert_eq!(DEFAULT_KEYBOARD_MODE, "translate");
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
            API_SERVER
        );
        assert_eq!(
            config::Config::get_option(keys::OPTION_KEY),
            SERVER_PUBLIC_KEY
        );
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
