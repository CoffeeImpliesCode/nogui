// Copyright 2022 The AccessKit Authors. All rights reserved.
// Licensed under the Apache License, Version 2.0 (found in
// the LICENSE-APACHE file) or the MIT license (found in
// the LICENSE-MIT file), at your option.

use accesskit_atspi_common::{Error as InternalError, PlatformNode};
use zbus::fdo::Error as FdoError;

use crate::atspi::ObjectId;

#[cfg(not(feature = "tokio"))]
pub(crate) fn block_on<F: std::future::Future>(future: F) -> F::Output {
    futures_lite::future::block_on(future)
}

#[cfg(feature = "tokio")]
pub(crate) fn block_on<F: std::future::Future>(future: F) -> F::Output {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_io()
        .enable_time()
        .build()
        .expect("launch of single-threaded tokio runtime");
    runtime.block_on(future)
}

/// The one `NotSupported` message every unimplemented edit answers with, so
/// `copy`/`cut`/`paste` and a missing handler cannot drift apart.
pub(crate) const UNSUPPORTED_EDIT: &str = "editing operation is not supported";

pub(crate) fn map_error(source: ObjectId, error: InternalError) -> FdoError {
    match error {
        InternalError::Defunct | InternalError::UnsupportedInterface => {
            FdoError::UnknownObject(source.path().to_string())
        }
        // LOCAL PATCH - nogui positioned edits. The object exists and offers
        // the interface, so `UnknownObject` would be a lie; nothing implements
        // the call, which is what `NotSupported` says.
        InternalError::Unsupported => FdoError::NotSupported(UNSUPPORTED_EDIT.into()),
        InternalError::TooManyChildren => FdoError::Failed("Too many children.".into()),
        InternalError::IndexOutOfRange => FdoError::Failed("Index is too big.".into()),
        InternalError::TooManyCharacters => FdoError::Failed("Too many characters.".into()),
        InternalError::UnsupportedTextGranularity => {
            FdoError::Failed("Unsupported text granularity.".into())
        }
    }
}

pub(crate) fn map_error_from_node(source: &PlatformNode, error: InternalError) -> FdoError {
    map_error(ObjectId::from(source), error)
}
