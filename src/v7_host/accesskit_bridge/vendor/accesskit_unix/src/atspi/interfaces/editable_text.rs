// LOCAL PATCH - nogui positioned edits. `insert_text` and `delete_text` are the
// published standard AT-SPI members with their real signatures (`isi=>b` and
// `ii=>b`), and they now reach the host. `copy_text`, `cut_text` and
// `paste_text` are unchanged and still raise `NotSupported`.
//
// The handler is NOT stored here. `PlatformNode` already holds the adapter's
// `Context`, which owns the handler the same way every other `PlatformNode`
// method reaches it, so this interface stays the published one-field tuple.
// Copyright 2026 The AccessKit Authors. All rights reserved.
// Licensed under the Apache License, Version 2.0 (found in
// the LICENSE-APACHE file) or the MIT license (found in
// the LICENSE-MIT file), at your option.

use accesskit_atspi_common::PlatformNode;
use crate::util::UNSUPPORTED_EDIT;
use zbus::{fdo, interface};

fn unsupported() -> fdo::Error {
    fdo::Error::NotSupported(UNSUPPORTED_EDIT.into())
}

pub(crate) struct EditableTextInterface(PlatformNode);

impl EditableTextInterface {
    pub fn new(node: PlatformNode) -> Self {
        Self(node)
    }

    fn map_error(&self) -> impl '_ + FnOnce(accesskit_atspi_common::Error) -> fdo::Error {
        |error| crate::util::map_error_from_node(&self.0, error)
    }
}

#[interface(name = "org.a11y.atspi.EditableText")]
impl EditableTextInterface {
    fn set_text_contents(&self, new_contents: &str) -> fdo::Result<bool> {
        self.0
            .set_text_contents(new_contents)
            .map_err(self.map_error())
    }

    /// LOCAL PATCH - nogui positioned edits. `length` is a BYTE upper bound:
    /// the node takes the whole string when the bound runs past its end, and
    /// refuses outright when the bound cuts a multi-byte scalar in half.
    /// `position` is a LIVE scalar index resolved by the host against its own
    /// model, so no check here can consult the published character table.
    fn insert_text(&self, position: i32, text: &str, length: i32) -> fdo::Result<bool> {
        self.0
            .insert_text(position, text, length)
            .map_err(self.map_error())
    }

    fn copy_text(&self, _start_pos: i32, _end_pos: i32) -> fdo::Result<()> {
        Err(unsupported())
    }

    fn cut_text(&self, _start_pos: i32, _end_pos: i32) -> fdo::Result<bool> {
        Err(unsupported())
    }

    fn delete_text(&self, start_pos: i32, end_pos: i32) -> fdo::Result<bool> {
        self.0.delete_text(start_pos, end_pos).map_err(self.map_error())
    }

    fn paste_text(&self, _position: i32) -> fdo::Result<bool> {
        Err(unsupported())
    }
}
