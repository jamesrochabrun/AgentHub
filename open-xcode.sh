#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$SCRIPT_DIR/app/AgentHub.xcodeproj"

if [ -d "$PROJECT" ]; then
    echo "Opening $PROJECT..."
    open -a Xcode "$PROJECT"
else
    echo "Error: Project not found at $PROJECT"
    exit 1
fi
