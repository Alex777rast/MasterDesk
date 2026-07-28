//! Defaults for the self-hosted community build.
//!
//! These values are deliberately compiled into the client instead of being
//! inferred from the executable file name or copied into a user profile.  As a
//! result, a clean portable launch and an installed service use the same
//! settings.

use hbb_common::config::{self, keys};
use std::collections::HashMap;

pub const ID_SERVER: &str = "176.123.167.146";
pub const RELAY_SERVER: &str = "176.123.167.146";
pub const SERVER_PUBLIC_KEY: &str = "oxdGP9iGMJ1gA3gmyAyjUNmgNAx6F4kD6Z3sLRjY7G4=";
pub const DEFAULT_CODEC: &str = "vp9";
pub const DEFAULT_IMAGE_QUALITY: &str = "best";

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
    ])
}

fn local_settings() -> HashMap<String, String> {
    HashMap::from([(keys::OPTION_ENABLE_CHECK_UPDATE.to_owned(), "N".to_owned())])
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
    }

    #[test]
    fn bundled_display_defaults_are_vp9_and_best() {
        let settings = display_settings();
        assert_eq!(
            settings.get(keys::OPTION_CODEC_PREFERENCE),
            Some(&DEFAULT_CODEC.to_owned())
        );
        assert_eq!(
            settings.get(keys::OPTION_IMAGE_QUALITY),
            Some(&DEFAULT_IMAGE_QUALITY.to_owned())
        );
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

        let display = config::UserDefaultConfig::default();
        assert_eq!(display.get(keys::OPTION_CODEC_PREFERENCE), DEFAULT_CODEC);
        assert_eq!(
            display.get(keys::OPTION_IMAGE_QUALITY),
            DEFAULT_IMAGE_QUALITY
        );
    }
}
