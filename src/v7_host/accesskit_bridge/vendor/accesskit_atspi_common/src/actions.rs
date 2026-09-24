// LOCAL PATCH - nogui W21 named custom actions.
//
// Copyright 2022 The AccessKit Authors. All rights reserved.
// Licensed under the Apache License, Version 2.0 (found in
// the LICENSE-APACHE file) or the MIT license (found in
// the LICENSE-MIT file), at your option.
//
// This file is a local modification of the published `accesskit_atspi_common`
// 0.20.0 crate. It does not exist upstream. AccessKit already carries named
// application actions on `accesskit::Node` (`Node::custom_actions`, and
// `ActionRequest { action: Action::CustomAction, data: Some(ActionData::
// CustomAction(id)) }`), but the 0.20.0 AT-SPI translation layer only ever
// publishes a single `click` action, and its `do_action` sends `Action::Click`
// for index 0 whether or not the node is clickable at all. A host that
// publishes named actions therefore sees them dropped, and a host that
// publishes only named actions sees index 0 mis-dispatched as a click.
//
// Everything here is a pure function of an `accesskit::Node`, so it is
// exercisable without a D-Bus connection. `node.rs` is the only other file
// changed by this patch, and `lib.rs` declares this module.
//
// A `NamedAction` is a borrowed view of the descriptor the host already stores
// on the node, never an owned copy of it. `name()` therefore hands out a `&str`,
// and `PlatformNode::action_name` and `PlatformNode::actions` are the only
// places that pay for an owned `String`, which each of them needs exactly once
// per published name. The dispatch path copies nothing at all: the signed id
// travels as a plain `i32`, so a `do_action` call allocates no name.

use accesskit::{Action, ActionData, CustomAction, Node};

/// One entry of the ordered AT-SPI Action list that this adapter publishes.
///
/// The order is fixed and is the whole contract: `Click` occupies index 0 only
/// when the node is clickable, and every custom action follows it in the order
/// the host declared them. A node with no click therefore publishes its *first*
/// custom action at index 0, which is what an AT-SPI client sees from
/// `n_actions` and `get_action_name` and acts on through `do_action`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum NamedAction<'a> {
    Click,
    Custom(&'a CustomAction),
}

impl<'a> NamedAction<'a> {
    /// The name an AT-SPI client reads back for this action.
    ///
    /// `click` keeps the exact spelling the 0.20.0 adapter already used, so an
    /// existing client sees no change. A custom action is named by the UTF-8
    /// description the host attached to it, borrowed from the node rather than
    /// copied out per call.
    pub(crate) fn name(&self) -> &'a str {
        match self {
            Self::Click => "click",
            Self::Custom(action) => &action.description,
        }
    }

    pub(crate) fn accesskit_action(&self) -> Action {
        match self {
            Self::Click => Action::Click,
            Self::Custom(_) => Action::CustomAction,
        }
    }

    /// `Action::CustomAction` carries its payload in `ActionRequest::data`, so
    /// a custom action reports `Some` here and a click reports `None`.
    pub(crate) fn accesskit_action_data(&self) -> Option<ActionData> {
        match self {
            Self::Click => None,
            Self::Custom(action) => Some(ActionData::CustomAction(action.id)),
        }
    }
}

/// The ordered AT-SPI action list of one node.
///
/// A disabled node publishes nothing. That is a deliberate local rule and not
/// what 0.20.0 does: `is_clickable` reads only the action bitmask, so a
/// disabled-but-clickable node would otherwise still advertise `click`. The
/// bridge states the same rule in the C header ("Hidden and disabled nodes
/// carry no named actions") and hides disabled nodes from mutation here too.
#[derive(Clone, Copy, Debug)]
pub(crate) struct ActionList<'a> {
    click: bool,
    custom: &'a [CustomAction],
}

impl<'a> ActionList<'a> {
    /// `clickable` is the caller's own `NodeRef::is_clickable` answer, which
    /// also walks the parent chain for `child_supports_action`; it is taken as
    /// an argument rather than recomputed here so that this stays a pure
    /// function of the node's own data plus one boolean.
    pub(crate) fn new(node: &'a Node, clickable: bool) -> Self {
        if node.is_disabled() {
            Self {
                click: false,
                custom: &[],
            }
        } else {
            Self {
                click: clickable,
                custom: node.custom_actions(),
            }
        }
    }

    pub(crate) fn len(&self) -> i32 {
        let len = self.custom.len() + usize::from(self.click);
        i32::try_from(len).unwrap_or(i32::MAX)
    }

    pub(crate) fn is_empty(&self) -> bool {
        !self.click && self.custom.is_empty()
    }

    /// The action at `index`, or `None` for any index this node does not
    /// publish. A negative index is not a list position and is refused by the
    /// same conversion that refuses a too-large one, so a caller that gets
    /// `None` has performed no mutation and can report failure without one.
    pub(crate) fn get(&self, index: i32) -> Option<NamedAction<'a>> {
        let index = usize::try_from(index).ok()?;
        if self.click {
            if index == 0 {
                return Some(NamedAction::Click);
            }
            Some(NamedAction::Custom(self.custom.get(index - 1)?))
        } else {
            Some(NamedAction::Custom(self.custom.get(index)?))
        }
    }

    /// The whole list in published order, borrowing every descriptor from the
    /// node. This is the single source for `n_actions`, `get_action_name` and
    /// the `actions` tuple list, so the three cannot drift apart.
    pub(crate) fn iter(&self) -> impl Iterator<Item = NamedAction<'a>> + use<'a> {
        self.click
            .then_some(NamedAction::Click)
            .into_iter()
            .chain(self.custom.iter().map(NamedAction::Custom))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use accesskit::Role;

    fn custom(id: i32, description: &str) -> CustomAction {
        CustomAction {
            id,
            description: description.into(),
        }
    }

    fn node(clickable: bool, disabled: bool, custom_actions: &[CustomAction]) -> Node {
        let mut node = Node::new(Role::Button);
        if clickable {
            node.add_action(Action::Click);
        }
        if disabled {
            node.set_disabled();
        }
        for action in custom_actions {
            node.push_custom_action(action.clone());
        }
        node
    }

    fn names(node: &Node, clickable: bool) -> Vec<&str> {
        ActionList::new(node, clickable)
            .iter()
            .map(|action| action.name())
            .collect()
    }

    fn name_at<'a>(list: &ActionList<'a>, index: i32) -> Option<&'a str> {
        list.get(index).map(|action| action.name())
    }

    fn ids(list: &ActionList<'_>) -> Vec<i32> {
        list.iter()
            .filter_map(|action| match action {
                NamedAction::Click => None,
                NamedAction::Custom(action) => Some(action.id),
            })
            .collect()
    }


    #[test]
    fn non_clickable_node_without_custom_actions_publishes_nothing() {
        let node = node(false, false, &[]);
        let list = ActionList::new(&node, false);
        assert_eq!(list.len(), 0);
        assert_eq!(list.get(0), None);
        assert!(names(&node, false).is_empty());
    }

    #[test]
    fn click_stays_at_index_zero_and_custom_actions_follow_it() {
        let node = node(
            true,
            false,
            &[custom(7, "Add row"), custom(9, "Remove row")],
        );
        let list = ActionList::new(&node, true);
        assert_eq!(list.len(), 3);
        assert_eq!(names(&node, true), vec!["click", "Add row", "Remove row"]);
        assert_eq!(list.get(0), Some(NamedAction::Click));
        assert_eq!(name_at(&list, 1), Some("Add row"));
        assert_eq!(name_at(&list, 2), Some("Remove row"));
        assert_eq!(ids(&list), vec![7, 9]);
    }

    #[test]
    fn custom_only_node_publishes_its_first_action_at_index_zero() {
        let node = node(false, false, &[custom(7, "Add row"), custom(9, "Remove row")]);
        let list = ActionList::new(&node, false);
        assert_eq!(list.len(), 2);
        assert_eq!(names(&node, false), vec!["Add row", "Remove row"]);
        assert_eq!(name_at(&list, 0), Some("Add row"));
        assert_eq!(name_at(&list, 1), Some("Remove row"));
    }


    #[test]
    fn a_nameless_custom_action_still_occupies_its_own_index() {
        let node = node(false, false, &[custom(7, ""), custom(9, "Remove row")]);
        let list = ActionList::new(&node, false);
        assert_eq!(list.len(), 2);
        assert_eq!(name_at(&list, 0), Some(""));
        assert_eq!(name_at(&list, 1), Some("Remove row"));
        assert_eq!(ids(&list), vec![7, 9]);
    }

    #[test]
    fn custom_action_names_survive_non_ascii_text() {
        let node = node(false, false, &[custom(3, " Zeile hinzufügen — 行を追加")]);
        let list = ActionList::new(&node, false);
        assert_eq!(name_at(&list, 0), Some(" Zeile hinzufügen — 行を追加"));
    }

    #[test]
    fn out_of_range_and_negative_indices_are_refused() {
        let mixed = node(true, false, &[custom(7, "Add row")]);
        let list = ActionList::new(&mixed, true);
        assert_eq!(list.len(), 2);
        assert_eq!(list.get(2), None);
        assert_eq!(list.get(i32::MAX), None);
        assert_eq!(list.get(-1), None);
        assert_eq!(list.get(i32::MIN), None);

        let click_only = node(true, false, &[]);
        assert_eq!(ActionList::new(&click_only, true).get(1), None);
    }

    #[test]
    fn disabled_node_publishes_no_action_at_all() {
        for clickable in [true, false] {
            let node = node(clickable, true, &[custom(7, "Add row")]);
            let list = ActionList::new(&node, clickable);
            assert_eq!(list.len(), 0);
            assert_eq!(list.get(0), None);
            assert_eq!(list.get(1), None);
            assert_eq!(list.get(-1), None);
            assert!(names(&node, clickable).is_empty());
        }
    }

    #[test]
    fn every_published_index_resolves_and_the_next_one_does_not() {
        for (clickable, disabled, count) in [
            (true, false, 0),
            (true, false, 1),
            (true, false, 2),
            (false, false, 0),
            (false, false, 1),
            (false, false, 2),
            (true, true, 2),
            (false, true, 2),
        ] {
            let custom_actions: Vec<CustomAction> =
                (0..count).map(|i| custom(i, "action")).collect();
            let node = node(clickable, disabled, &custom_actions);
            let list = ActionList::new(&node, clickable);
            for index in 0..list.len() {
                assert!(list.get(index).is_some(), "index {index} of {list:?}");
            }
            assert_eq!(list.get(list.len()), None);
        }
    }
}
