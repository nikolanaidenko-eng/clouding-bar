//! Clouding Bar's core, shared by the Windows app and its hook: the
//! protocol (docs/protocol.md), sessions and limits, Claude's requests and
//! their answers, and connecting to Claude Code. No UI here.

pub mod protocol;
pub mod requests;
pub mod setup;
pub mod store;
pub mod transcript;
