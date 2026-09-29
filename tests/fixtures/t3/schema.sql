CREATE TABLE projection_thread_messages (
  message_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, turn_id TEXT,
  role TEXT NOT NULL, text TEXT NOT NULL, is_streaming INTEGER NOT NULL,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE projection_thread_activities (
  activity_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, turn_id TEXT,
  tone TEXT NOT NULL, kind TEXT NOT NULL, summary TEXT NOT NULL,
  payload_json TEXT NOT NULL, created_at TEXT NOT NULL);
CREATE TABLE projection_thread_sessions (
  thread_id TEXT PRIMARY KEY, status TEXT NOT NULL, provider_name TEXT,
  provider_session_id TEXT, provider_thread_id TEXT, active_turn_id TEXT,
  last_error TEXT, updated_at TEXT NOT NULL);
CREATE TABLE projection_turns (
  row_id INTEGER PRIMARY KEY AUTOINCREMENT, thread_id TEXT NOT NULL, turn_id TEXT,
  pending_message_id TEXT, assistant_message_id TEXT, state TEXT NOT NULL,
  requested_at TEXT NOT NULL, started_at TEXT, completed_at TEXT,
  checkpoint_turn_count INTEGER, checkpoint_ref TEXT, checkpoint_status TEXT,
  checkpoint_files_json TEXT NOT NULL);
CREATE TABLE projection_pending_approvals (
  request_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, turn_id TEXT,
  status TEXT NOT NULL, decision TEXT, created_at TEXT NOT NULL, resolved_at TEXT);
