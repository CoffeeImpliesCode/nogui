// Copyright 2022 The AccessKit Authors. All rights reserved.
// Licensed under the Apache License, Version 2.0 (found in
// the LICENSE-APACHE file) or the MIT license (found in
// the LICENSE-MIT file), at your option.

use std::fmt;

#[derive(Debug)]
pub enum Error {
    Defunct,
    UnsupportedInterface,
    /// The object exists and offers the interface, but nothing on this adapter
    /// implements the call. Distinct from [`Error::UnsupportedInterface`],
    /// which means the NODE does not offer the interface at all and is
    /// answered with `UnknownObject`.
    Unsupported,
    TooManyChildren,
    IndexOutOfRange,
    TooManyCharacters,
    UnsupportedTextGranularity,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Defunct => "defunct",
            Self::UnsupportedInterface => "unsupported interface",
            Self::Unsupported => "unsupported",
            Self::TooManyChildren => "too many children",
            Self::IndexOutOfRange => "index out of range",
            Self::TooManyCharacters => "too many characters",
            Self::UnsupportedTextGranularity => "unsupported text granularity",
        })
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;
