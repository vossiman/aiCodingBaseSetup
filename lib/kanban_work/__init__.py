"""Native Kanban work-session bridge."""

from .adapters import AdapterResult, ClaudeCodexAdapter, adapt_claude_codex
from .bridge import Bridge, SubprocessTransport
from .events import EventIngestor, ingest_event
from .queue import LifecycleQueue
from .schema import (
    BridgeError,
    READ_TOOLS,
    TOOL_TO_BRIDGE_OPERATION,
    normalize_tool_args,
    qualified_client_version,
)
from .store import Execution, NativeIdentity, Permit, QueueEvent, QueueRow, Store

__all__ = [
    "AdapterResult", "Bridge", "BridgeError", "ClaudeCodexAdapter", "EventIngestor",
    "Execution", "LifecycleQueue",
    "NativeIdentity", "Permit", "QueueEvent", "QueueRow", "READ_TOOLS", "Store",
    "SubprocessTransport", "TOOL_TO_BRIDGE_OPERATION", "ingest_event",
    "adapt_claude_codex", "normalize_tool_args", "qualified_client_version",
]
