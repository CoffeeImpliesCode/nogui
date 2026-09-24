//! Real font bytes for tests that must load actual faces.
//!
//! The graphics engine embeds no font: a caller hands it bytes. Its own
//! tests still need faces, and `@embedFile` cannot leave its module
//! directory, so the build publishes this file as the anonymous module
//! `v7_frame_test_fonts` and the engine's test blocks read it from there.
//! Nothing but tests import it.

pub const inter: []const u8 = @embedFile("InterVariable.ttf");
pub const fira: []const u8 = @embedFile("FiraCodeNerdFont-Regular.ttf");
