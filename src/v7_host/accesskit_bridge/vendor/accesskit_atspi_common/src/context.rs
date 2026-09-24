// Copyright 2023 The AccessKit Authors. All rights reserved.
// Licensed under the Apache License, Version 2.0 (found in
// the LICENSE-APACHE file) or the MIT license (found in
// the LICENSE-MIT file), at your option.

use accesskit::{ActionHandler, ActionRequest, NodeId, TreeId};
use accesskit_consumer::Tree;
use std::fmt::{Debug, Formatter};
use std::sync::{Arc, Mutex, RwLock, RwLockReadGuard, RwLockWriteGuard};

use crate::WindowBounds;

/// This is an implementation detail of `accesskit_unix`, required for robust
/// state transitions with minimal overhead.
pub trait ActionHandlerNoMut {
    fn do_action(&self, request: ActionRequest);
}

/// This is an implementation detail of `accesskit_unix`, required for robust
/// state transitions with minimal overhead.
pub struct ActionHandlerWrapper<H: ActionHandler + Send>(Mutex<H>);

impl<H: 'static + ActionHandler + Send> ActionHandlerWrapper<H> {
    pub fn new(inner: H) -> Self {
        Self(Mutex::new(inner))
    }
}

impl<H: ActionHandler + Send> ActionHandlerNoMut for ActionHandlerWrapper<H> {
    fn do_action(&self, request: ActionRequest) {
        self.0.lock().unwrap().do_action(request)
    }
}

/// One positioned range edit, in the units the PLATFORM counts in.
///
/// The replacement is BORROWED for the synchronous call only. The handler
/// copies the bytes into the host queue before it returns, so nothing is
/// allocated to carry them: a `Box<str>` would die at the end of a call whose
/// bytes the host has already deep-copied.
#[derive(Debug, PartialEq, Eq)]
pub struct EditableTextRequest<'a> {
    pub target_tree: TreeId,
    pub target_node: NodeId,
    /// Inclusive Unicode-scalar index, resolved by the host against the LIVE
    /// model value, never against the frozen published character table.
    pub start: usize,
    /// Exclusive Unicode-scalar index. `start > end` refuses.
    pub end: usize,
    /// Replacement UTF-8. Empty is a delete; `start == end` is an insert.
    pub replacement: &'a str,
}

/// The sibling of [`ActionHandlerNoMut`] for the standard
/// `org.a11y.atspi.EditableText` methods, whose positioned range no
/// `accesskit::ActionData` variant can express.
///
/// `&self`, so no `Mutex` wrapper is needed here, unlike
/// `ActionHandlerWrapper`, which exists only because
/// `accesskit::ActionHandler::do_action` is `&mut self`.
pub trait EditableTextHandlerNoMut {
    /// Returns the host queue's ACCEPTANCE, not proof the model changed: the
    /// host applies the edit later, on its own thread.
    fn do_editable_text(&self, request: EditableTextRequest<'_>) -> bool;
}

pub(crate) struct Context {
    pub(crate) app_context: Arc<RwLock<AppContext>>,
    /// The positioned-edit handler. `None` is a genuine absence, not a
    /// refusal to be flattened into `false`: the node raises
    /// `Error::Unsupported` and the client sees `NotSupported`.
    pub(crate) editable_text_handler: Option<Arc<dyn EditableTextHandlerNoMut + Send + Sync>>,
    pub(crate) tree: RwLock<Tree>,
    pub(crate) action_handler: Arc<dyn ActionHandlerNoMut + Send + Sync>,
    pub(crate) root_window_bounds: RwLock<WindowBounds>,
}

impl Debug for Context {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Context")
            .field("app_context", &self.app_context)
            .field("tree", &self.tree)
            .field("action_handler", &"ActionHandler")
            .field(
                "editable_text_handler",
                &self
                    .editable_text_handler
                    .as_ref()
                    .map(|_| "EditableTextHandler"),
            )
            .field("root_window_bounds", &self.root_window_bounds)
            .finish()
    }
}

impl Context {
    pub(crate) fn new(
        app_context: &Arc<RwLock<AppContext>>,
        tree: Tree,
        action_handler: Arc<dyn ActionHandlerNoMut + Send + Sync>,
        editable_text_handler: Option<Arc<dyn EditableTextHandlerNoMut + Send + Sync>>,
        root_window_bounds: WindowBounds,
    ) -> Arc<Self> {
        Arc::new(Self {
            app_context: Arc::clone(app_context),
            tree: RwLock::new(tree),
            action_handler,
            editable_text_handler,
            root_window_bounds: RwLock::new(root_window_bounds),
        })
    }

    pub(crate) fn read_tree(&self) -> RwLockReadGuard<'_, Tree> {
        self.tree.read().unwrap()
    }

    pub(crate) fn read_root_window_bounds(&self) -> RwLockReadGuard<'_, WindowBounds> {
        self.root_window_bounds.read().unwrap()
    }

    pub fn do_action(&self, request: ActionRequest) {
        self.action_handler.do_action(request);
    }

    /// Returns the host queue's acceptance, or `None` when no handler was
    /// installed at all.
    pub(crate) fn do_editable_text(&self, request: EditableTextRequest<'_>) -> Option<bool> {
        Some(self.editable_text_handler.as_ref()?.do_editable_text(request))
    }

    pub(crate) fn read_app_context(&self) -> RwLockReadGuard<'_, AppContext> {
        self.app_context.read().unwrap()
    }

    pub(crate) fn write_app_context(&self) -> RwLockWriteGuard<'_, AppContext> {
        self.app_context.write().unwrap()
    }
}

#[derive(Debug)]
pub struct AppContext {
    pub(crate) name: Option<String>,
    pub(crate) toolkit_name: Option<String>,
    pub(crate) toolkit_version: Option<String>,
    pub(crate) id: Option<i32>,
    pub(crate) adapters: Vec<(usize, Arc<Context>)>,
}

impl AppContext {
    pub fn new(name: Option<String>) -> Arc<RwLock<Self>> {
        Arc::new(RwLock::new(Self {
            name,
            toolkit_name: None,
            toolkit_version: None,
            id: None,
            adapters: Vec::new(),
        }))
    }

    pub(crate) fn adapter_index(&self, id: usize) -> Result<usize, usize> {
        self.adapters.binary_search_by(|adapter| adapter.0.cmp(&id))
    }

    pub(crate) fn push_adapter(&mut self, id: usize, context: &Arc<Context>) {
        self.adapters.push((id, Arc::clone(context)));
    }

    pub(crate) fn remove_adapter(&mut self, id: usize) {
        if let Ok(index) = self.adapter_index(id) {
            self.adapters.remove(index);
        }
    }
}
