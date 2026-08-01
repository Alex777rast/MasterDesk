//! Defaults for the self-hosted community build.
//!
//! These values are deliberately compiled into the client instead of being
//! inferred from the executable file name or copied into a user profile.  As a
//! result, a clean portable launch and an installed service use the same
//! settings.

use hbb_common::config::{self, keys};
use std::collections::HashMap;

pub const APP_NAME: &str = "MasterDesk";
pub const ID_SERVER: &str = "desk.masteronline.space";
pub const RELAY_SERVER: &str = "desk.masteronline.space";
/// Accept both the public hostname and its current IPv4 address in the
/// socket-level VPN bypass. The visible ID/relay settings always use DNS.
pub const DIRECT_SERVER_TARGETS: &str = "desk.masteronline.space,176.123.167.146";
pub const SERVER_PUBLIC_KEY: &str = "oxdGP9iGMJ1gA3gmyAyjUNmgNAx6F4kD6Z3sLRjY7G4=";
pub const DEFAULT_CODEC: &str = "vp9";
pub const DEFAULT_IMAGE_QUALITY: &str = "best";
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
        // Do not replace this fork with an official RustDesk binary.  A custom
        // update channel can be added when branded releases are introduced.
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
        (keys::OPTION_ENABLE_CHECK_UPDATE.to_owned(), "N".to_owned()),
        (keys::OPTION_ENABLE_UDP_PUNCH.to_owned(), "Y".to_owned()),
        ("input-source".to_owned(), DEFAULT_INPUT_SOURCE.to_owned()),
        (
            keys::OPTION_ALLOW_MONITOR_SWITCH_MAIN_TOOLBAR.to_owned(),
            "Y".to_owned(),
        ),
    ])
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
    }

    #[test]
    fn bundled_direct_server_targets_match_domain_and_ipv4() {
        apply();
        assert!(hbb_common::direct_server::is_target(ID_SERVER));
        assert!(hbb_common::direct_server::is_target(
            "DESK.MASTERONLINE.SPACE:21116"
        ));
        assert!(hbb_common::direct_server::is_target(
            "176.123.167.146:21117"
        ));
        assert!(!hbb_common::direct_server::is_target("example.com:21116"));
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
