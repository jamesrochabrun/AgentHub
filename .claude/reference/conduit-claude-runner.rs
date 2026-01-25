// Reference implementation from https://github.com/conduit-cli/conduit
// File: src/agent/claude.rs
// This shows how Conduit spawns Claude Code in headless mode with streaming JSON

use std::path::PathBuf;
use std::process::Stdio;

use async_trait::async_trait;
use serde_json::json;
use tokio::process::Command;
use tokio::sync::mpsc;

// Key function: Building the CLI command
fn build_command(&self, config: &AgentStartConfig) -> Command {
    let mut cmd = Command::new(&self.binary_path);

    let use_stream_input = config
        .input_format
        .as_deref()
        .is_some_and(|format| format == "stream-json");

    // Core headless mode flags
    if !use_stream_input {
        cmd.arg("-p"); // Print mode (standalone flag, prompt is positional)
    }
    cmd.arg("--output-format").arg("stream-json");
    cmd.arg("--verbose"); // verbose is now required
                          // Claude process failed (exit status: 1): Error: When
                          // using --print,--output-format=stream-json requires
                          // --verbose
    if use_stream_input {
        cmd.arg("--permission-prompt-tool").arg("stdio");
    }

    // Permission mode (Build vs Plan)
    cmd.arg("--permission-mode")
        .arg(config.agent_mode.as_permission_mode());

    // Allowed tools
    if !config.allowed_tools.is_empty() {
        cmd.arg("--allowedTools")
            .arg(config.allowed_tools.join(","));
    }

    // Resume session if provided
    if let Some(session_id) = &config.resume_session {
        cmd.arg("--resume").arg(session_id.as_str());
    }

    // Model selection
    if let Some(model) = &config.model {
        cmd.arg("--model").arg(model);
    }

    // Working directory
    cmd.current_dir(&config.working_dir);

    // Input format override (e.g. stream-json for structured input)
    if let Some(format) = &config.input_format {
        cmd.arg("--input-format").arg(format);
    }

    // Additional args
    for arg in &config.additional_args {
        cmd.arg(arg);
    }

    // Use "--" to signal end of flags, so prompts starting with "-" (like "- [ ] task")
    // are not interpreted as CLI arguments
    if !use_stream_input && !config.prompt.is_empty() {
        cmd.arg("--").arg(&config.prompt);
    }

    // Stdio setup for JSONL capture / streaming input
    let needs_stdin = config
        .input_format
        .as_deref()
        .is_some_and(|format| format == "stream-json")
        || config.stdin_payload.is_some();
    if needs_stdin {
        cmd.stdin(Stdio::piped());
    } else {
        cmd.stdin(Stdio::null());
    }
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());

    cmd
}

// Key function: Converting raw events to unified types
fn convert_event(raw: ClaudeRawEvent) -> Vec<AgentEvent> {
    match raw {
        ClaudeRawEvent::System(sys) => {
            if sys.subtype.as_deref() == Some("init") {
                sys.session_id
                    .map(|id| {
                        vec![AgentEvent::SessionInit(SessionInitEvent {
                            session_id: SessionId::from_string(id),
                            model: sys.model,
                        })]
                    })
                    .unwrap_or_default()
            } else {
                vec![]
            }
        }
        ClaudeRawEvent::Assistant(assistant) => {
            let mut events = Vec::new();

            // Check for authentication failure or other errors
            if let Some(ref error) = assistant.error {
                if error == "authentication_failed" {
                    return vec![AgentEvent::Error(ErrorEvent {
                        message: "Authentication failed. Please run `claude /login` in your terminal to authenticate.".to_string(),
                        is_fatal: true,
                    })];
                }
                // Handle other error types as fatal errors
                return vec![AgentEvent::Error(ErrorEvent {
                    message: format!("Claude error: {}", error),
                    is_fatal: true,
                })];
            }

            // Extract text content
            let text = assistant.extract_text().unwrap_or_default();
            if !text.is_empty() {
                events.push(AgentEvent::AssistantMessage(AssistantMessageEvent {
                    text,
                    is_final: true,
                }));
            }

            // Extract embedded tool_use blocks
            for tool_use in assistant.extract_tool_uses() {
                events.push(AgentEvent::ToolStarted(ToolStartedEvent {
                    tool_name: tool_use.name,
                    tool_id: tool_use.id,
                    arguments: tool_use.input,
                }));
            }

            events
        }
        ClaudeRawEvent::ToolResult(result) => {
            let tool_id = result.tool_use_id.clone().unwrap_or_default();
            let is_error = result.is_error.unwrap_or(false);
            vec![AgentEvent::ToolCompleted(ToolCompletedEvent {
                tool_id,
                success: !is_error,
                result: if !is_error { result.content.clone() } else { None },
                error: if is_error { result.content } else { None },
            })]
        }
        ClaudeRawEvent::Result(res) => {
            if res.is_error.unwrap_or(false) {
                let detail = res.result.clone().or(res.output.clone()).or(res.error.clone())
                    .unwrap_or_else(|| "Unknown error".to_string());
                return vec![
                    AgentEvent::Error(ErrorEvent {
                        message: format!("Claude error: {}", detail),
                        is_fatal: true,
                    }),
                    AgentEvent::TurnFailed(TurnFailedEvent { error: detail }),
                ];
            }
            // Result event always signals turn completion
            let usage = res.usage.map(|u| TokenUsage {
                input_tokens: u.input_tokens.unwrap_or(0),
                output_tokens: u.output_tokens.unwrap_or(0),
                cached_tokens: 0,
                total_tokens: u.input_tokens.unwrap_or(0) + u.output_tokens.unwrap_or(0),
            }).unwrap_or_default();

            vec![AgentEvent::TurnCompleted(TurnCompletedEvent { usage })]
        }
        ClaudeRawEvent::ControlRequest(_) => vec![],
        ClaudeRawEvent::Unknown => vec![],
    }
}

// Key function: Building control response for tool approval
fn build_control_response_jsonl(
    request_id: &str,
    response_payload: serde_json::Value,
) -> anyhow::Result<String> {
    let payload = json!({
        "type": "control_response",
        "response": {
            "subtype": "success",
            "request_id": request_id,
            "response": response_payload,
        }
    });
    let json = serde_json::to_string(&payload)?;
    Ok(format!("{json}\n"))
}

// Helper: Check if tool requires user interaction
fn is_interactive_tool(tool_name: &str) -> bool {
    matches!(tool_name, "AskUserQuestion" | "ExitPlanMode")
}
