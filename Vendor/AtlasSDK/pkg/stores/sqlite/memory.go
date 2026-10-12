package sqlite

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/stores"
)

const memoryStoreType = "sqlite-memory"

// MemoryStore implements stores.MemoryStore backed by SQLite via modernc.org/sqlite.
type MemoryStore struct {
	db  *sql.DB
	url string
}

// NewMemoryStore creates a MemoryStore for the given database URL.
func NewMemoryStore(config stores.StoreConfig) (stores.MemoryStore, error) {
	url := config.URL
	if url == "" {
		url = ":memory:"
	}
	return &MemoryStore{url: url}, nil
}

// Init opens the database connection and creates tables.
func (s *MemoryStore) Init(ctx context.Context) error {
	db, err := sql.Open("sqlite", s.url)
	if err != nil {
		return &stores.StoreError{Message: err.Error(), StoreType: memoryStoreType, Operation: "init"}
	}
	if s.url == ":memory:" {
		db.SetMaxOpenConns(1)
	}

	for _, pragma := range []string{
		"PRAGMA journal_mode=WAL",
		"PRAGMA foreign_keys=ON",
	} {
		if _, err := db.ExecContext(ctx, pragma); err != nil {
			db.Close()
			return &stores.StoreError{Message: err.Error(), StoreType: memoryStoreType, Operation: "init"}
		}
	}

	schema := `
		CREATE TABLE IF NOT EXISTS memory_schema_migrations (
			version    INTEGER PRIMARY KEY,
			applied_at INTEGER NOT NULL
		);

		CREATE TABLE IF NOT EXISTS memory_entries (
			id         TEXT PRIMARY KEY,
			content    TEXT NOT NULL,
			level      TEXT NOT NULL,
			source     TEXT NOT NULL DEFAULT '',
			tags       TEXT NOT NULL DEFAULT '[]',
			embedding  TEXT NOT NULL DEFAULT '[]',
			metadata   TEXT NOT NULL DEFAULT '{}',
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL
		);

		CREATE INDEX IF NOT EXISTS idx_memory_level ON memory_entries(level);
	`
	if _, err := db.ExecContext(ctx, schema); err != nil {
		db.Close()
		return &stores.StoreError{Message: err.Error(), StoreType: memoryStoreType, Operation: "init"}
	}
	// Backward-compatible migration for databases created before metadata was
	// part of the portable intelligence contract.
	if _, err := db.ExecContext(ctx, `ALTER TABLE memory_entries ADD COLUMN metadata TEXT NOT NULL DEFAULT '{}'`); err != nil && !strings.Contains(strings.ToLower(err.Error()), "duplicate column") {
		db.Close()
		return &stores.StoreError{Message: err.Error(), StoreType: memoryStoreType, Operation: "migrate"}
	}
	if _, err := db.ExecContext(ctx, `
		CREATE INDEX IF NOT EXISTS idx_memory_tenant_namespace
			ON memory_entries(json_extract(metadata, '$.tenantId'), json_extract(metadata, '$.namespace'));
		CREATE INDEX IF NOT EXISTS idx_memory_expires_at
			ON memory_entries(json_extract(metadata, '$.retention.expiresAt'));
	`); err != nil {
		db.Close()
		return &stores.StoreError{Message: err.Error(), StoreType: memoryStoreType, Operation: "migrate"}
	}
	for _, version := range []int{1, 2, 3} {
		if _, err := db.ExecContext(ctx,
			`INSERT OR IGNORE INTO memory_schema_migrations (version, applied_at) VALUES (?, ?)`,
			version, time.Now().UnixMilli(),
		); err != nil {
			db.Close()
			return &stores.StoreError{Message: err.Error(), StoreType: memoryStoreType, Operation: "migrate"}
		}
	}

	s.db = db
	return nil
}

// Close closes the database connection.
func (s *MemoryStore) Close(_ context.Context) error {
	if s.db != nil {
		return s.db.Close()
	}
	return nil
}

// Save persists a memory entry and returns its generated ID.
func (s *MemoryStore) Save(ctx context.Context, entry stores.StoredMemoryEntry) (string, error) {
	id := entry.ID
	if id == "" {
		id = generateID()
	}
	now := time.Now().UnixMilli()
	createdAt := entry.CreatedAt
	if createdAt == 0 {
		createdAt = now
	}
	updatedAt := entry.UpdatedAt
	if updatedAt == 0 {
		updatedAt = now
	}

	tagsJSON, _ := json.Marshal(entry.Tags)
	embeddingJSON, _ := json.Marshal(entry.Embedding)
	metadataJSON, _ := json.Marshal(entry.Metadata)

	_, err := s.db.ExecContext(ctx,
		`INSERT INTO memory_entries (id, content, level, source, tags, embedding, metadata, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, entry.Content, string(entry.Level), entry.Source,
		string(tagsJSON), string(embeddingJSON), string(metadataJSON), createdAt, updatedAt,
	)
	if err != nil {
		return "", stores.NewStoreError(err.Error(), memoryStoreType, "save")
	}
	return id, nil
}

// Get retrieves a single memory entry by ID.
func (s *MemoryStore) Get(ctx context.Context, id string) (*stores.StoredMemoryEntry, error) {
	var entry stores.StoredMemoryEntry
	var level, tagsJSON, embeddingJSON, metadataJSON string

	err := s.db.QueryRowContext(ctx,
		`SELECT id, content, level, source, tags, embedding, metadata, created_at, updated_at
		 FROM memory_entries WHERE id = ?`, id,
	).Scan(&entry.ID, &entry.Content, &level, &entry.Source,
		&tagsJSON, &embeddingJSON, &metadataJSON, &entry.CreatedAt, &entry.UpdatedAt)

	if err == sql.ErrNoRows {
		return nil, stores.NewStoreError("memory entry not found", memoryStoreType, "get")
	}
	if err != nil {
		return nil, stores.NewStoreError(err.Error(), memoryStoreType, "get")
	}

	entry.Level = stores.MemoryLevel(level)
	json.Unmarshal([]byte(tagsJSON), &entry.Tags)
	json.Unmarshal([]byte(embeddingJSON), &entry.Embedding)
	json.Unmarshal([]byte(metadataJSON), &entry.Metadata)

	return &entry, nil
}

// Update modifies an existing memory entry. Zero-value fields are ignored.
func (s *MemoryStore) Update(ctx context.Context, id string, entry stores.StoredMemoryEntry) error {
	// Build a dynamic update to skip zero-value fields.
	var setClauses []string
	var args []interface{}

	if entry.Content != "" {
		setClauses = append(setClauses, "content = ?")
		args = append(args, entry.Content)
	}
	if entry.Level != "" {
		setClauses = append(setClauses, "level = ?")
		args = append(args, string(entry.Level))
	}
	if entry.Source != "" {
		setClauses = append(setClauses, "source = ?")
		args = append(args, entry.Source)
	}
	if len(entry.Tags) > 0 {
		tagsJSON, _ := json.Marshal(entry.Tags)
		setClauses = append(setClauses, "tags = ?")
		args = append(args, string(tagsJSON))
	}
	if len(entry.Embedding) > 0 {
		embJSON, _ := json.Marshal(entry.Embedding)
		setClauses = append(setClauses, "embedding = ?")
		args = append(args, string(embJSON))
	}
	if entry.Metadata != nil {
		metadataJSON, _ := json.Marshal(entry.Metadata)
		setClauses = append(setClauses, "metadata = ?")
		args = append(args, string(metadataJSON))
	}

	if len(setClauses) == 0 {
		return nil // Nothing to update.
	}

	setClauses = append(setClauses, "updated_at = ?")
	args = append(args, time.Now().UnixMilli())
	args = append(args, id)

	query := fmt.Sprintf("UPDATE memory_entries SET %s WHERE id = ?", strings.Join(setClauses, ", "))
	res, err := s.db.ExecContext(ctx, query, args...)
	if err != nil {
		return stores.NewStoreError(err.Error(), memoryStoreType, "update")
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return stores.NewStoreError("memory entry not found", memoryStoreType, "update")
	}
	return nil
}

// CompareAndSwap updates an entry only while its UpdatedAt version token still
// matches expectedUpdatedAt.
func (s *MemoryStore) CompareAndSwap(ctx context.Context, id string, expectedUpdatedAt int64, entry stores.StoredMemoryEntry) (bool, error) {
	current, err := s.Get(ctx, id)
	if err != nil {
		var storeErr *stores.StoreError
		if errors.As(err, &storeErr) && strings.Contains(storeErr.Message, "not found") {
			return false, nil
		}
		return false, err
	}
	if current.UpdatedAt != expectedUpdatedAt {
		return false, nil
	}
	if entry.UpdatedAt <= expectedUpdatedAt {
		return false, stores.NewStoreError("compare-and-swap updated_at must advance", memoryStoreType, "compareAndSwap")
	}

	updated := *current
	if entry.Content != "" {
		updated.Content = entry.Content
	}
	if entry.Level != "" {
		updated.Level = entry.Level
	}
	if entry.Source != "" {
		updated.Source = entry.Source
	}
	if entry.Tags != nil {
		updated.Tags = entry.Tags
	}
	if entry.Embedding != nil {
		updated.Embedding = entry.Embedding
	}
	if entry.Metadata != nil {
		updated.Metadata = entry.Metadata
	}
	updated.UpdatedAt = entry.UpdatedAt

	tagsJSON, _ := json.Marshal(updated.Tags)
	embeddingJSON, _ := json.Marshal(updated.Embedding)
	metadataJSON, _ := json.Marshal(updated.Metadata)
	result, err := s.db.ExecContext(ctx,
		`UPDATE memory_entries
		 SET content = ?, level = ?, source = ?, tags = ?, embedding = ?, metadata = ?, updated_at = ?
		 WHERE id = ? AND updated_at = ?`,
		updated.Content, string(updated.Level), updated.Source, string(tagsJSON), string(embeddingJSON),
		string(metadataJSON), updated.UpdatedAt, id, expectedUpdatedAt,
	)
	if err != nil {
		return false, stores.NewStoreError(err.Error(), memoryStoreType, "compareAndSwap")
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return false, stores.NewStoreError(err.Error(), memoryStoreType, "compareAndSwap")
	}
	return rows == 1, nil
}

// Delete removes a memory entry by ID.
func (s *MemoryStore) Delete(ctx context.Context, id string) error {
	res, err := s.db.ExecContext(ctx, `DELETE FROM memory_entries WHERE id = ?`, id)
	if err != nil {
		return stores.NewStoreError(err.Error(), memoryStoreType, "delete")
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return stores.NewStoreError("memory entry not found", memoryStoreType, "delete")
	}
	return nil
}

// GetByLevel returns all memory entries at a given level.
func (s *MemoryStore) GetByLevel(ctx context.Context, level stores.MemoryLevel) ([]stores.StoredMemoryEntry, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, content, level, source, tags, embedding, metadata, created_at, updated_at
		 FROM memory_entries WHERE level = ? ORDER BY created_at DESC`, string(level),
	)
	if err != nil {
		return nil, stores.NewStoreError(err.Error(), memoryStoreType, "getByLevel")
	}
	defer rows.Close()
	return scanMemoryEntries(rows)
}

// Search performs a keyword-based search across memory entries.
// It uses SQL LIKE for substring matching and optionally filters by level and tags.
func (s *MemoryStore) Search(ctx context.Context, query string, opts *stores.MemorySearchOptions) ([]stores.MemorySearchResult, error) {
	limit := 10
	var conditions []string
	var args []interface{}

	conditions = append(conditions, "content LIKE ?")
	args = append(args, "%"+query+"%")

	if opts != nil {
		if opts.Level != "" {
			conditions = append(conditions, "level = ?")
			args = append(args, string(opts.Level))
		}
		if opts.Limit > 0 {
			limit = opts.Limit
		}
		if opts.TenantID != "" {
			conditions = append(conditions, "json_extract(metadata, '$.tenantId') = ?")
			args = append(args, opts.TenantID)
		}
		if opts.Namespace != "" {
			conditions = append(conditions, "json_extract(metadata, '$.namespace') = ?")
			args = append(args, opts.Namespace)
		}
	}
	if opts == nil || !opts.IncludeExpired {
		now := time.Now().UnixMilli()
		if opts != nil && opts.Now != 0 {
			now = opts.Now
		}
		conditions = append(conditions, "(COALESCE(json_extract(metadata, '$.retention.legalHold'), 0) = 1 OR json_extract(metadata, '$.retention.expiresAt') IS NULL OR json_extract(metadata, '$.retention.expiresAt') > ?)")
		args = append(args, now)
	}

	where := strings.Join(conditions, " AND ")
	sqlQuery := fmt.Sprintf(
		`SELECT id, content, level, source, tags, embedding, metadata, created_at, updated_at
		 FROM memory_entries WHERE %s ORDER BY updated_at DESC LIMIT ?`, where,
	)
	args = append(args, limit)

	rows, err := s.db.QueryContext(ctx, sqlQuery, args...)
	if err != nil {
		return nil, stores.NewStoreError(err.Error(), memoryStoreType, "search")
	}
	defer rows.Close()

	entries, err := scanMemoryEntries(rows)
	if err != nil {
		return nil, err
	}

	// Apply tag filter in Go (simpler than SQL JSON matching).
	var results []stores.MemorySearchResult
	for _, entry := range entries {
		if opts != nil && len(opts.Tags) > 0 && !hasAnyTag(entry.Tags, opts.Tags) {
			continue
		}
		// Simple relevance: count occurrences.
		score := float64(strings.Count(strings.ToLower(entry.Content), strings.ToLower(query))) / float64(len(entry.Content)+1)
		if opts != nil && opts.Threshold > 0 && score < opts.Threshold {
			continue
		}
		results = append(results, stores.MemorySearchResult{Entry: entry, Score: score})
	}
	return results, nil
}

// LoadAll returns all stored memory entries.
func (s *MemoryStore) LoadAll(ctx context.Context) ([]stores.StoredMemoryEntry, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, content, level, source, tags, embedding, metadata, created_at, updated_at
		 FROM memory_entries ORDER BY created_at DESC`,
	)
	if err != nil {
		return nil, stores.NewStoreError(err.Error(), memoryStoreType, "loadAll")
	}
	defer rows.Close()
	return scanMemoryEntries(rows)
}

// GetSystemPrompt builds a system prompt from all stored memories.
func (s *MemoryStore) GetSystemPrompt(ctx context.Context) (string, error) {
	entries, err := s.LoadAll(ctx)
	if err != nil {
		return "", err
	}
	if len(entries) == 0 {
		return "", nil
	}

	var parts []string
	parts = append(parts, "## Stored Memories\n")
	for _, e := range entries {
		parts = append(parts, fmt.Sprintf("- [%s] %s", e.Level, e.Content))
	}
	return strings.Join(parts, "\n"), nil
}

// scanMemoryEntries scans rows into StoredMemoryEntry slices.
func scanMemoryEntries(rows *sql.Rows) ([]stores.StoredMemoryEntry, error) {
	var entries []stores.StoredMemoryEntry
	for rows.Next() {
		var entry stores.StoredMemoryEntry
		var level, tagsJSON, embeddingJSON, metadataJSON string
		if err := rows.Scan(&entry.ID, &entry.Content, &level, &entry.Source,
			&tagsJSON, &embeddingJSON, &metadataJSON, &entry.CreatedAt, &entry.UpdatedAt); err != nil {
			return nil, stores.NewStoreError(err.Error(), memoryStoreType, "scan")
		}
		entry.Level = stores.MemoryLevel(level)
		json.Unmarshal([]byte(tagsJSON), &entry.Tags)
		json.Unmarshal([]byte(embeddingJSON), &entry.Embedding)
		json.Unmarshal([]byte(metadataJSON), &entry.Metadata)
		entries = append(entries, entry)
	}
	if err := rows.Err(); err != nil {
		return nil, stores.NewStoreError(err.Error(), memoryStoreType, "scan")
	}
	return entries, nil
}

// hasAnyTag checks if the entry has at least one of the required tags.
func hasAnyTag(entryTags, requiredTags []string) bool {
	tagSet := make(map[string]struct{}, len(entryTags))
	for _, t := range entryTags {
		tagSet[t] = struct{}{}
	}
	for _, t := range requiredTags {
		if _, ok := tagSet[t]; ok {
			return true
		}
	}
	return false
}

// generateID creates a simple time-based unique ID.
func generateID() string {
	return fmt.Sprintf("mem_%d", time.Now().UnixNano())
}
