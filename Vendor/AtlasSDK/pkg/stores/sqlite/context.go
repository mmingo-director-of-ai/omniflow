// Package sqlite provides SQLite-backed implementations of the Atlas store interfaces.
package sqlite

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/stores"
)

const contextStoreType = "sqlite-context"

// ContextStore implements stores.ContextStore backed by SQLite via modernc.org/sqlite.
type ContextStore struct {
	db  *sql.DB
	url string
}

// NewContextStore creates a ContextStore for the given database URL.
// The URL is a file path (or ":memory:" for in-memory databases).
func NewContextStore(config stores.StoreConfig) (stores.ContextStore, error) {
	url := config.URL
	if url == "" {
		url = ":memory:"
	}
	return &ContextStore{url: url}, nil
}

// Init opens the database connection and creates tables.
func (s *ContextStore) Init(ctx context.Context) error {
	db, err := sql.Open("sqlite", s.url)
	if err != nil {
		return &stores.StoreError{Message: err.Error(), StoreType: contextStoreType, Operation: "init"}
	}
	if s.url == ":memory:" {
		db.SetMaxOpenConns(1)
	}

	// Enable WAL mode and foreign keys.
	for _, pragma := range []string{
		"PRAGMA journal_mode=WAL",
		"PRAGMA foreign_keys=ON",
	} {
		if _, err := db.ExecContext(ctx, pragma); err != nil {
			db.Close()
			return &stores.StoreError{Message: err.Error(), StoreType: contextStoreType, Operation: "init"}
		}
	}

	schema := `
		CREATE TABLE IF NOT EXISTS context_sessions (
			session_id   TEXT PRIMARY KEY,
			created_at   INTEGER NOT NULL,
			label        TEXT NOT NULL DEFAULT '',
			agent_id     TEXT NOT NULL DEFAULT '',
			user_id      TEXT NOT NULL DEFAULT '',
			ttl          INTEGER NOT NULL DEFAULT 0
		);

		CREATE TABLE IF NOT EXISTS context_messages (
			id           INTEGER PRIMARY KEY AUTOINCREMENT,
			session_id   TEXT NOT NULL REFERENCES context_sessions(session_id) ON DELETE CASCADE,
			role         TEXT NOT NULL,
			content      TEXT NOT NULL,
			name         TEXT NOT NULL DEFAULT '',
			tool_call_id TEXT NOT NULL DEFAULT '',
			tool_calls   TEXT NOT NULL DEFAULT '[]',
			created_at   INTEGER NOT NULL
		);

		CREATE INDEX IF NOT EXISTS idx_messages_session ON context_messages(session_id, id);

		CREATE TABLE IF NOT EXISTS context_summaries (
			session_id    TEXT PRIMARY KEY REFERENCES context_sessions(session_id) ON DELETE CASCADE,
			summary       TEXT NOT NULL,
			up_to_index   INTEGER NOT NULL,
			updated_at    INTEGER NOT NULL
		);
	`

	if _, err := db.ExecContext(ctx, schema); err != nil {
		db.Close()
		return &stores.StoreError{Message: err.Error(), StoreType: contextStoreType, Operation: "init"}
	}

	s.db = db
	return nil
}

// Close closes the database connection.
func (s *ContextStore) Close(_ context.Context) error {
	if s.db != nil {
		return s.db.Close()
	}
	return nil
}

// CreateSession creates a new context session.
func (s *ContextStore) CreateSession(ctx context.Context, sessionID string, metadata *stores.SessionMetadata) error {
	meta := stores.SessionMetadata{}
	if metadata != nil {
		meta = *metadata
	}
	if meta.CreatedAt == 0 {
		meta.CreatedAt = time.Now().UnixMilli()
	}

	_, err := s.db.ExecContext(ctx,
		`INSERT INTO context_sessions (session_id, created_at, label, agent_id, user_id, ttl)
		 VALUES (?, ?, ?, ?, ?, ?)`,
		sessionID, meta.CreatedAt, meta.Label, meta.AgentID, meta.UserID, meta.TTL,
	)
	if err != nil {
		return stores.NewSessionStoreError(err.Error(), contextStoreType, "createSession", sessionID)
	}
	return nil
}

// DestroySession deletes a session and all its messages and summaries (via CASCADE).
func (s *ContextStore) DestroySession(ctx context.Context, sessionID string) error {
	res, err := s.db.ExecContext(ctx, `DELETE FROM context_sessions WHERE session_id = ?`, sessionID)
	if err != nil {
		return stores.NewSessionStoreError(err.Error(), contextStoreType, "destroySession", sessionID)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return stores.NewSessionStoreError("session not found", contextStoreType, "destroySession", sessionID)
	}
	return nil
}

// Append adds a single message to a session.
func (s *ContextStore) Append(ctx context.Context, sessionID string, message stores.Message) error {
	toolCallsJSON, err := json.Marshal(message.ToolCalls)
	if err != nil {
		toolCallsJSON = []byte("[]")
	}

	_, err = s.db.ExecContext(ctx,
		`INSERT INTO context_messages (session_id, role, content, name, tool_call_id, tool_calls, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?)`,
		sessionID, message.Role, message.Content, message.Name, message.ToolCallID, string(toolCallsJSON), time.Now().UnixMilli(),
	)
	if err != nil {
		return stores.NewSessionStoreError(err.Error(), contextStoreType, "append", sessionID)
	}
	return nil
}

// AppendBatch adds multiple messages to a session in batches.
func (s *ContextStore) AppendBatch(ctx context.Context, sessionID string, messages []stores.Message, maxBatchSize int) error {
	if len(messages) == 0 {
		return nil
	}
	if maxBatchSize <= 0 {
		maxBatchSize = 100
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return stores.NewSessionStoreError(err.Error(), contextStoreType, "appendBatch", sessionID)
	}
	defer tx.Rollback()

	stmt, err := tx.PrepareContext(ctx,
		`INSERT INTO context_messages (session_id, role, content, name, tool_call_id, tool_calls, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return stores.NewSessionStoreError(err.Error(), contextStoreType, "appendBatch", sessionID)
	}
	defer stmt.Close()

	now := time.Now().UnixMilli()
	for i, msg := range messages {
		toolCallsJSON, _ := json.Marshal(msg.ToolCalls)
		if _, err := stmt.ExecContext(ctx, sessionID, msg.Role, msg.Content, msg.Name, msg.ToolCallID, string(toolCallsJSON), now+int64(i)); err != nil {
			return stores.NewSessionStoreError(err.Error(), contextStoreType, "appendBatch", sessionID)
		}
	}

	if err := tx.Commit(); err != nil {
		return stores.NewSessionStoreError(err.Error(), contextStoreType, "appendBatch", sessionID)
	}
	return nil
}

// GetMessages retrieves messages for a session with optional limit/offset.
func (s *ContextStore) GetMessages(ctx context.Context, sessionID string, opts *stores.GetMessagesOpts) ([]stores.Message, error) {
	query := `SELECT role, content, name, tool_call_id, tool_calls FROM context_messages WHERE session_id = ? ORDER BY id ASC`
	args := []interface{}{sessionID}

	if opts != nil {
		if opts.Limit > 0 {
			query += " LIMIT ?"
			args = append(args, opts.Limit)
		}
		if opts.Offset > 0 {
			query += " OFFSET ?"
			args = append(args, opts.Offset)
		}
	}

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, stores.NewSessionStoreError(err.Error(), contextStoreType, "getMessages", sessionID)
	}
	defer rows.Close()

	var messages []stores.Message
	for rows.Next() {
		var msg stores.Message
		var toolCallsJSON string
		if err := rows.Scan(&msg.Role, &msg.Content, &msg.Name, &msg.ToolCallID, &toolCallsJSON); err != nil {
			return nil, stores.NewSessionStoreError(err.Error(), contextStoreType, "getMessages", sessionID)
		}
		if toolCallsJSON != "" && toolCallsJSON != "[]" {
			json.Unmarshal([]byte(toolCallsJSON), &msg.ToolCalls)
		}
		messages = append(messages, msg)
	}
	if err := rows.Err(); err != nil {
		return nil, stores.NewSessionStoreError(err.Error(), contextStoreType, "getMessages", sessionID)
	}
	return messages, nil
}

// GetMessageCount returns the number of messages in a session.
func (s *ContextStore) GetMessageCount(ctx context.Context, sessionID string) (int, error) {
	var count int
	err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM context_messages WHERE session_id = ?`, sessionID,
	).Scan(&count)
	if err != nil {
		return 0, stores.NewSessionStoreError(err.Error(), contextStoreType, "getMessageCount", sessionID)
	}
	return count, nil
}

// GetWindow returns a token-budgeted context window for a session.
// It uses a simple heuristic of ~4 characters per token.
func (s *ContextStore) GetWindow(ctx context.Context, sessionID string, maxTokens int) (*stores.ContextWindow, error) {
	summary, err := s.GetSummary(ctx, sessionID)
	if err != nil {
		return nil, err
	}

	allMessages, err := s.GetMessages(ctx, sessionID, nil)
	if err != nil {
		return nil, err
	}

	totalMessages := len(allMessages)

	// Walk messages from newest to oldest until we exceed the token budget.
	tokenBudget := maxTokens
	if summary != nil {
		tokenBudget -= estimateTokens(*summary)
	}

	var windowed []stores.Message
	estimatedTokensUsed := 0
	for i := len(allMessages) - 1; i >= 0; i-- {
		msgTokens := estimateTokens(allMessages[i].Content)
		if estimatedTokensUsed+msgTokens > tokenBudget && len(windowed) > 0 {
			break
		}
		windowed = append([]stores.Message{allMessages[i]}, windowed...)
		estimatedTokensUsed += msgTokens
	}

	if summary != nil {
		estimatedTokensUsed += estimateTokens(*summary)
	}

	return &stores.ContextWindow{
		Summary:          summary,
		Messages:         windowed,
		TotalMessages:    totalMessages,
		WindowedMessages: len(windowed),
		EstimatedTokens:  estimatedTokensUsed,
	}, nil
}

// Search does a simple substring search across messages in a session.
func (s *ContextStore) Search(ctx context.Context, sessionID string, query string, limit int) ([]stores.Message, error) {
	if limit <= 0 {
		limit = 10
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT role, content, name, tool_call_id, tool_calls
		 FROM context_messages
		 WHERE session_id = ? AND content LIKE ?
		 ORDER BY id DESC LIMIT ?`,
		sessionID, "%"+query+"%", limit,
	)
	if err != nil {
		return nil, stores.NewSessionStoreError(err.Error(), contextStoreType, "search", sessionID)
	}
	defer rows.Close()

	var messages []stores.Message
	for rows.Next() {
		var msg stores.Message
		var toolCallsJSON string
		if err := rows.Scan(&msg.Role, &msg.Content, &msg.Name, &msg.ToolCallID, &toolCallsJSON); err != nil {
			return nil, stores.NewSessionStoreError(err.Error(), contextStoreType, "search", sessionID)
		}
		if toolCallsJSON != "" && toolCallsJSON != "[]" {
			json.Unmarshal([]byte(toolCallsJSON), &msg.ToolCalls)
		}
		messages = append(messages, msg)
	}
	return messages, rows.Err()
}

// Summarize stores a summary for a session up to the given message index.
func (s *ContextStore) Summarize(ctx context.Context, sessionID string, upToIndex int) (string, error) {
	// Build a summary from the first N messages.
	msgs, err := s.GetMessages(ctx, sessionID, &stores.GetMessagesOpts{Limit: upToIndex})
	if err != nil {
		return "", err
	}

	if len(msgs) == 0 {
		return "", stores.NewSessionStoreError("no messages to summarize", contextStoreType, "summarize", sessionID)
	}

	// Build a simple concatenated summary (a real implementation would use an LLM).
	var parts []string
	for _, m := range msgs {
		parts = append(parts, fmt.Sprintf("[%s]: %s", m.Role, truncate(m.Content, 100)))
	}
	summary := strings.Join(parts, "\n")

	_, err = s.db.ExecContext(ctx,
		`INSERT INTO context_summaries (session_id, summary, up_to_index, updated_at)
		 VALUES (?, ?, ?, ?)
		 ON CONFLICT(session_id) DO UPDATE SET summary = excluded.summary, up_to_index = excluded.up_to_index, updated_at = excluded.updated_at`,
		sessionID, summary, upToIndex, time.Now().UnixMilli(),
	)
	if err != nil {
		return "", stores.NewSessionStoreError(err.Error(), contextStoreType, "summarize", sessionID)
	}
	return summary, nil
}

// GetSummary retrieves the stored summary for a session, or nil if none exists.
func (s *ContextStore) GetSummary(ctx context.Context, sessionID string) (*string, error) {
	var summary string
	err := s.db.QueryRowContext(ctx,
		`SELECT summary FROM context_summaries WHERE session_id = ?`, sessionID,
	).Scan(&summary)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, stores.NewSessionStoreError(err.Error(), contextStoreType, "getSummary", sessionID)
	}
	return &summary, nil
}

// estimateTokens uses a rough heuristic of ~4 characters per token.
func estimateTokens(text string) int {
	return len(text) / 4
}

// truncate shortens a string to at most maxLen characters.
func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen] + "..."
}
