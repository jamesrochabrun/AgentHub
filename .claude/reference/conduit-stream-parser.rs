// Reference implementation from https://github.com/conduit-cli/conduit
// File: src/agent/stream.rs
// This shows the JSONL event types and parsing

use serde::Deserialize;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::ChildStdout;
use tokio::sync::mpsc;

/// Generic JSONL stream parser
pub struct JsonlStreamParser;

impl JsonlStreamParser {
    /// Parse JSONL from stdout and send to channel
    pub async fn parse_stream<T>(stdout: ChildStdout, tx: mpsc::Sender<T>) -> Result<(), AgentError>
    where
        T: for<'de> Deserialize<'de> + Send + 'static,
    {
        let reader = BufReader::new(stdout);
        let mut lines = reader.lines();

        while let Some(line) = lines.next_line().await? {
            if line.trim().is_empty() {
                continue;
            }

            match serde_json::from_str::<T>(&line) {
                Ok(event) => {
                    if tx.send(event).await.is_err() {
                        // Receiver dropped, exit gracefully
                        break;
                    }
                }
                Err(e) => {
                    tracing::warn!("Failed to parse JSONL line: {e}. Line: {line}");
                    // Continue processing - don't fail on single parse error
                }
            }
        }

        Ok(())
    }
}

// ============================================================================
// Claude Code specific JSONL events (raw from CLI)
// ============================================================================

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type")]
pub enum ClaudeRawEvent {
    #[serde(rename = "system")]
    System(ClaudeSystemEvent),

    #[serde(rename = "assistant")]
    Assistant(ClaudeAssistantEvent),

    #[serde(rename = "tool_use")]
    ToolUse(ClaudeToolUseEvent),

    #[serde(rename = "tool_result")]
    ToolResult(ClaudeToolResultEvent),

    /// User events contain tool results from Claude Code CLI
    #[serde(rename = "user")]
    User(ClaudeUserEvent),

    /// Control requests (permission checks, hooks) from Claude Code CLI
    #[serde(rename = "control_request")]
    ControlRequest(ClaudeControlRequestEvent),

    #[serde(rename = "result")]
    Result(ClaudeResultEvent),

    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ClaudeSystemEvent {
    pub subtype: Option<String>,
    pub session_id: Option<String>,
    pub model: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ClaudeAssistantEvent {
    /// Nested message object (new format)
    pub message: Option<ClaudeMessageObject>,
    /// Direct text (older format)
    pub text: Option<String>,
    /// Session ID
    pub session_id: Option<String>,
    /// Error type (e.g., "authentication_failed")
    pub error: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ClaudeMessageObject {
    pub model: Option<String>,
    pub id: Option<String>,
    pub role: Option<String>,
    pub content: Option<Vec<ClaudeContentBlock>>,
    pub stop_reason: Option<String>,
    pub usage: Option<ClaudeUsage>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type")]
pub enum ClaudeContentBlock {
    #[serde(rename = "text")]
    Text { text: String },
    #[serde(rename = "tool_use")]
    ToolUse {
        id: String,
        name: String,
        input: serde_json::Value,
    },
    #[serde(other)]
    Other,
}

impl ClaudeAssistantEvent {
    /// Extract the text content from this event
    pub fn extract_text(&self) -> Option<String> {
        // Try new format first (message.content[].text)
        if let Some(ref msg) = self.message {
            if let Some(ref content) = msg.content {
                let texts: Vec<String> = content
                    .iter()
                    .filter_map(|block| match block {
                        ClaudeContentBlock::Text { text } => Some(text.clone()),
                        _ => None,
                    })
                    .collect();
                if !texts.is_empty() {
                    return Some(texts.join("\n"));
                }
            }
        }
        // Fall back to direct text field
        self.text.clone()
    }

    /// Extract tool_use blocks from this event's content
    pub fn extract_tool_uses(&self) -> Vec<ExtractedToolUse> {
        if let Some(ref msg) = self.message {
            if let Some(ref content) = msg.content {
                return content
                    .iter()
                    .filter_map(|block| match block {
                        ClaudeContentBlock::ToolUse { id, name, input } => Some(ExtractedToolUse {
                            id: id.clone(),
                            name: name.clone(),
                            input: input.clone(),
                        }),
                        _ => None,
                    })
                    .collect();
            }
        }
        Vec::new()
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct ClaudeToolUseEvent {
    pub tool: Option<String>,
    pub name: Option<String>,
    pub id: Option<String>,
    #[serde(default)]
    pub arguments: serde_json::Value,
    #[serde(default)]
    pub input: serde_json::Value,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ClaudeToolResultEvent {
    pub tool_use_id: Option<String>,
    pub content: Option<String>,
    pub is_error: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ClaudeControlRequestEvent {
    pub request_id: String,
    pub request: ClaudeControlRequestType,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "subtype", rename_all = "snake_case")]
pub enum ClaudeControlRequestType {
    CanUseTool {
        tool_name: String,
        input: serde_json::Value,
        #[serde(default)]
        tool_use_id: Option<String>,
    },
    HookCallback {
        callback_id: String,
        input: serde_json::Value,
    },
}

#[derive(Debug, Clone, Deserialize)]
pub struct ClaudeResultEvent {
    pub result: Option<String>,
    pub output: Option<String>,
    pub is_error: Option<bool>,
    pub error: Option<String>,
    pub session_id: Option<String>,
    pub usage: Option<ClaudeUsage>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ClaudeUsage {
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
}

// ============================================================================
// Swift Translation Guide
// ============================================================================
//
// The Rust enums and structs above translate to Swift as:
//
// enum ClaudeEventType: String, Codable {
//     case system
//     case assistant
//     case toolUse = "tool_use"
//     case toolResult = "tool_result"
//     case user
//     case controlRequest = "control_request"
//     case result
// }
//
// struct ClaudeEvent: Codable {
//     let type: ClaudeEventType
//     // Use @dynamicMemberLookup or separate structs per type
// }
//
// For tagged unions in Swift, use:
// - A wrapper struct with `type` field
// - Separate decode based on type value
// - Or use a custom Decodable implementation
