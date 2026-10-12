package stores

import "context"

// SessionMetadata holds session creation metadata.
type SessionMetadata struct {
	CreatedAt int64  `json:"createdAt"`
	Label     string `json:"label,omitempty"`
	AgentID   string `json:"agentId,omitempty"`
	UserID    string `json:"userId,omitempty"`
	TTL       int    `json:"ttl,omitempty"` // seconds, 0 = no expiry
}

// ContextWindow is a token-budgeted view of a session.
type ContextWindow struct {
	Summary          *string   `json:"summary"`
	Messages         []Message `json:"messages"`
	TotalMessages    int       `json:"totalMessages"`
	WindowedMessages int       `json:"windowedMessages"`
	EstimatedTokens  int       `json:"estimatedTokens"`
}

// Message matches the TypeScript SDK Message type.
type Message struct {
	Role       string     `json:"role"`
	Content    string     `json:"content"`
	Name       string     `json:"name,omitempty"`
	ToolCallID string     `json:"toolCallId,omitempty"`
	ToolCalls  []ToolCall `json:"toolCalls,omitempty"`
}

// ToolCall represents a tool invocation within a message.
type ToolCall struct {
	ID        string                 `json:"id,omitempty"`
	Name      string                 `json:"name"`
	Arguments map[string]interface{} `json:"arguments"`
}

// GetMessagesOpts configures message retrieval.
type GetMessagesOpts struct {
	Limit  int
	Offset int
}

// ContextStore manages active conversation state for a session.
type ContextStore interface {
	Init(ctx context.Context) error
	Close(ctx context.Context) error
	CreateSession(ctx context.Context, sessionID string, metadata *SessionMetadata) error
	DestroySession(ctx context.Context, sessionID string) error
	Append(ctx context.Context, sessionID string, message Message) error
	AppendBatch(ctx context.Context, sessionID string, messages []Message, maxBatchSize int) error
	GetMessages(ctx context.Context, sessionID string, opts *GetMessagesOpts) ([]Message, error)
	GetMessageCount(ctx context.Context, sessionID string) (int, error)
	GetWindow(ctx context.Context, sessionID string, maxTokens int) (*ContextWindow, error)
	Search(ctx context.Context, sessionID string, query string, limit int) ([]Message, error)
	Summarize(ctx context.Context, sessionID string, upToIndex int) (string, error)
	GetSummary(ctx context.Context, sessionID string) (*string, error)
}
