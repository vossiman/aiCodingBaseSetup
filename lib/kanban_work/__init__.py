"""Native Kanban work-session lifecycle adapters."""

from .adapters import AdapterResult, ClaudeCodexAdapter, adapt_claude_codex
from .events import EventIngestor, ingest_event
from .queue import LifecycleQueue
from .schema import BridgeError, qualified_client_version
from .store import Execution, NativeIdentity, QueueRow, Store
from .transport import SubprocessTransport

__all__ = [
    "AdapterResult", "BridgeError", "ClaudeCodexAdapter", "EventIngestor", "Execution",
    "LifecycleQueue", "NativeIdentity", "QueueRow", "Store", "SubprocessTransport",
    "adapt_claude_codex", "ingest_event", "qualified_client_version",
]
