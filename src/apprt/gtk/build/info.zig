const builtin = @import("builtin");

/// Linux fork identity. The embedded resource prefix remains upstream so
/// existing templates and stylesheets keep their resource references.
pub const display_name = "GhosnTTy";
pub const base_application_id = "com.ghosntty.GhosnTTy";

/// GTK application ID
pub const application_id = switch (builtin.mode) {
    .debug, .safe => base_application_id ++ "-debug",
    .fast, .small => base_application_id,
};

pub const resource_path = "/com/mitchellh/ghostty";

/// GTK object path
pub const object_path = switch (builtin.mode) {
    .debug, .safe => "/com/ghosntty/GhosnTTy_debug",
    .fast, .small => "/com/ghosntty/GhosnTTy",
};
