{
  "permissions": {
    "allow": []
  },
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/north-star.sh" }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "if": "Bash(git commit*)", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/ship-check.sh" }
        ]
      }
    ]
  }
}
