// Package conversation provides portable checkpoint and branch contracts.
package conversation

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/intelligence"
	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/internal/canonicaljson"
	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/stores"
)

const ExportVersion = 1
const checkpointSource = "atlas:conversation-checkpoint"
const branchSource = "atlas:conversation-branch"

type Checkpoint struct {
	ID                 string                 `json:"id"`
	SessionID          string                 `json:"sessionId"`
	BranchID           string                 `json:"branchId"`
	ParentCheckpointID string                 `json:"parentCheckpointId,omitempty"`
	Ancestry           []string               `json:"ancestry"`
	Revision           int                    `json:"revision"`
	Messages           []stores.Message       `json:"messages"`
	Summary            *string                `json:"summary"`
	HistoryHash        string                 `json:"historyHash"`
	CreatedAt          int64                  `json:"createdAt"`
	Metadata           map[string]interface{} `json:"metadata,omitempty"`
}

type Branch struct {
	ID               string `json:"id"`
	SessionID        string `json:"sessionId"`
	HeadCheckpointID string `json:"headCheckpointId"`
	Revision         int    `json:"revision"`
	CreatedAt        int64  `json:"createdAt"`
	UpdatedAt        int64  `json:"updatedAt"`
}

type CheckpointOptions struct {
	BranchID                 string
	ParentCheckpointID       string
	ExpectedHeadCheckpointID string
	Metadata                 map[string]interface{}
}

type AuthorizationRequest struct {
	Action       string
	Scope        intelligence.Scope
	SessionID    string
	BranchID     string
	CheckpointID string
}
type Options struct {
	Clock     func() time.Time
	Authorize func(context.Context, AuthorizationRequest) (bool, error)
}
type Export struct {
	SchemaVersion int                `json:"schemaVersion"`
	Scope         intelligence.Scope `json:"scope"`
	Checkpoint    Checkpoint         `json:"checkpoint"`
	Checksum      string             `json:"checksum"`
}

type Manager struct {
	contexts stores.ContextStore
	records  stores.MemoryStore
	opts     Options
}
type ConflictError struct{ Message string }

func (e *ConflictError) Error() string { return e.Message }

func New(contexts stores.ContextStore, records stores.MemoryStore, opts Options) *Manager {
	if opts.Clock == nil {
		opts.Clock = time.Now
	}
	return &Manager{contexts: contexts, records: records, opts: opts}
}

func (m *Manager) Checkpoint(ctx context.Context, scope intelligence.Scope, sessionID string, opts CheckpointOptions) (Checkpoint, error) {
	if err := m.authorize(ctx, AuthorizationRequest{Action: "checkpoint", Scope: scope, SessionID: sessionID, BranchID: opts.BranchID}); err != nil {
		return Checkpoint{}, err
	}
	if _, err := m.atomicRecords(); err != nil {
		return Checkpoint{}, err
	}
	messages, err := m.contexts.GetMessages(ctx, sessionID, nil)
	if err != nil {
		return Checkpoint{}, err
	}
	if err := ValidateHistory(messages); err != nil {
		return Checkpoint{}, err
	}
	summary, err := m.contexts.GetSummary(ctx, sessionID)
	if err != nil {
		return Checkpoint{}, err
	}
	branchID := opts.BranchID
	if branchID == "" {
		branchID = sessionID
	}
	branch, _ := m.GetBranch(ctx, scope, branchID)
	if branch != nil && opts.ExpectedHeadCheckpointID != branch.HeadCheckpointID {
		return Checkpoint{}, &ConflictError{fmt.Sprintf("branch %s moved", branchID)}
	}
	if branch == nil && opts.ExpectedHeadCheckpointID != "" {
		return Checkpoint{}, &ConflictError{"branch does not exist"}
	}
	parentID := opts.ParentCheckpointID
	if parentID == "" && branch != nil {
		parentID = branch.HeadCheckpointID
	}
	var parent *Checkpoint
	if parentID != "" {
		parent, err = m.GetCheckpoint(ctx, scope, parentID)
		if err != nil {
			return Checkpoint{}, err
		}
		if parent == nil {
			return Checkpoint{}, errors.New("parent checkpoint not found")
		}
	}
	ancestry := []string{}
	revision := 1
	if parent != nil {
		ancestry = append(append([]string{}, parent.Ancestry...), parent.ID)
		revision = parent.Revision + 1
	}
	checkpoint := Checkpoint{ID: newID(), SessionID: sessionID, BranchID: branchID, ParentCheckpointID: parentID, Ancestry: ancestry, Revision: revision, Messages: cloneMessages(messages), Summary: summary, HistoryHash: historyHash(messages, summary), CreatedAt: m.opts.Clock().UnixMilli(), Metadata: opts.Metadata}
	if err := m.saveCheckpoint(ctx, scope, checkpoint); err != nil {
		return Checkpoint{}, err
	}
	branchRevision := 1
	created := checkpoint.CreatedAt
	if branch != nil {
		branchRevision = branch.Revision + 1
		created = branch.CreatedAt
	}
	if err := m.setBranch(ctx, scope, Branch{ID: branchID, SessionID: sessionID, HeadCheckpointID: checkpoint.ID, Revision: branchRevision, CreatedAt: created, UpdatedAt: checkpoint.CreatedAt}, branch); err != nil {
		_ = m.records.Delete(ctx, checkpoint.ID)
		return Checkpoint{}, err
	}
	return checkpoint, nil
}

func (m *Manager) Fork(ctx context.Context, scope intelligence.Scope, checkpointID, branchID, sessionID string) (Checkpoint, error) {
	if err := m.authorize(ctx, AuthorizationRequest{Action: "fork", Scope: scope, CheckpointID: checkpointID, BranchID: branchID, SessionID: sessionID}); err != nil {
		return Checkpoint{}, err
	}
	if branch, _ := m.GetBranch(ctx, scope, branchID); branch != nil {
		return Checkpoint{}, &ConflictError{"branch already exists"}
	}
	source, err := m.requireCheckpoint(ctx, scope, checkpointID)
	if err != nil {
		return Checkpoint{}, err
	}
	if err := m.restore(ctx, sessionID, source.Messages, false); err != nil {
		return Checkpoint{}, err
	}
	return m.Checkpoint(ctx, scope, sessionID, CheckpointOptions{BranchID: branchID, ParentCheckpointID: source.ID, Metadata: map[string]interface{}{"forkedFrom": source.BranchID}})
}

func (m *Manager) Resume(ctx context.Context, scope intelligence.Scope, checkpointID, sessionID string, replace bool) ([]stores.Message, *string, error) {
	if err := m.authorize(ctx, AuthorizationRequest{Action: "resume", Scope: scope, CheckpointID: checkpointID, SessionID: sessionID}); err != nil {
		return nil, nil, err
	}
	checkpoint, err := m.requireCheckpoint(ctx, scope, checkpointID)
	if err != nil {
		return nil, nil, err
	}
	if sessionID == "" {
		sessionID = checkpoint.SessionID
	}
	if err := m.restore(ctx, sessionID, checkpoint.Messages, replace); err != nil {
		return nil, nil, err
	}
	return cloneMessages(checkpoint.Messages), checkpoint.Summary, nil
}

// MergeResolver produces validated history for a manual merge.
type MergeResolver func(source Checkpoint, target Checkpoint) ([]stores.Message, error)

func (m *Manager) Merge(ctx context.Context, scope intelligence.Scope, sourceID, targetBranchID, strategy string) (Checkpoint, error) {
	return m.MergeWithResolver(ctx, scope, sourceID, targetBranchID, strategy, nil)
}

// MergeWithResolver supports fast-forward, replace, and host-resolved manual merges.
func (m *Manager) MergeWithResolver(ctx context.Context, scope intelligence.Scope, sourceID, targetBranchID, strategy string, resolver MergeResolver) (Checkpoint, error) {
	if err := m.authorize(ctx, AuthorizationRequest{Action: "merge", Scope: scope, CheckpointID: sourceID, BranchID: targetBranchID}); err != nil {
		return Checkpoint{}, err
	}
	source, err := m.requireCheckpoint(ctx, scope, sourceID)
	if err != nil {
		return Checkpoint{}, err
	}
	branch, err := m.GetBranch(ctx, scope, targetBranchID)
	if err != nil || branch == nil {
		return Checkpoint{}, errors.New("target branch not found")
	}
	target, err := m.requireCheckpoint(ctx, scope, branch.HeadCheckpointID)
	if err != nil {
		return Checkpoint{}, err
	}
	mergedMessages := source.Messages
	if strategy == "" || strategy == "fast-forward" {
		if source.ID != target.ID && !contains(source.Ancestry, target.ID) {
			return Checkpoint{}, &ConflictError{"fast-forward requires target ancestor"}
		}
	} else if strategy == "manual" {
		if resolver == nil {
			return Checkpoint{}, errors.New("manual merge requires a resolver")
		}
		mergedMessages, err = resolver(*source, *target)
		if err != nil {
			return Checkpoint{}, err
		}
		if err := ValidateHistory(mergedMessages); err != nil {
			return Checkpoint{}, err
		}
	} else if strategy != "replace" {
		return Checkpoint{}, errors.New("unsupported merge strategy")
	}
	if err := m.restore(ctx, branch.SessionID, mergedMessages, true); err != nil {
		return Checkpoint{}, err
	}
	return m.Checkpoint(ctx, scope, branch.SessionID, CheckpointOptions{BranchID: targetBranchID, ParentCheckpointID: target.ID, ExpectedHeadCheckpointID: target.ID, Metadata: map[string]interface{}{"mergedFrom": source.ID, "strategy": strategy}})
}

func (m *Manager) Export(ctx context.Context, scope intelligence.Scope, checkpointID string) (Export, error) {
	if err := m.authorize(ctx, AuthorizationRequest{Action: "export", Scope: scope, CheckpointID: checkpointID}); err != nil {
		return Export{}, err
	}
	checkpoint, err := m.requireCheckpoint(ctx, scope, checkpointID)
	if err != nil {
		return Export{}, err
	}
	bundle := Export{SchemaVersion: ExportVersion, Scope: scope, Checkpoint: *checkpoint}
	bundle.Checksum = exportChecksum(bundle)
	return bundle, nil
}
func (m *Manager) Import(ctx context.Context, scope intelligence.Scope, bundle Export) (Checkpoint, error) {
	if err := m.authorize(ctx, AuthorizationRequest{Action: "import", Scope: scope, CheckpointID: bundle.Checkpoint.ID}); err != nil {
		return Checkpoint{}, err
	}
	if bundle.SchemaVersion != ExportVersion || bundle.Checksum != exportChecksum(bundle) {
		return Checkpoint{}, errors.New("conversation export checksum or version mismatch")
	}
	if bundle.Scope.TenantID != scope.TenantID {
		return Checkpoint{}, errors.New("cross-tenant import denied")
	}
	if err := ValidateHistory(bundle.Checkpoint.Messages); err != nil {
		return Checkpoint{}, err
	}
	if historyHash(bundle.Checkpoint.Messages, bundle.Checkpoint.Summary) != bundle.Checkpoint.HistoryHash {
		return Checkpoint{}, errors.New("conversation history hash mismatch")
	}
	if existing, _ := m.GetCheckpoint(ctx, scope, bundle.Checkpoint.ID); existing != nil {
		return Checkpoint{}, &ConflictError{"checkpoint already exists"}
	}
	if err := m.saveCheckpoint(ctx, scope, bundle.Checkpoint); err != nil {
		return Checkpoint{}, err
	}
	return bundle.Checkpoint, nil
}

func (m *Manager) GetCheckpoint(ctx context.Context, scope intelligence.Scope, id string) (*Checkpoint, error) {
	entry, err := m.records.Get(ctx, id)
	if err != nil {
		return nil, nil
	}
	if entry.Source != checkpointSource || !matchesScope(*entry, scope) {
		return nil, nil
	}
	var checkpoint Checkpoint
	if json.Unmarshal([]byte(entry.Content), &checkpoint) != nil {
		return nil, errors.New("malformed checkpoint")
	}
	return &checkpoint, nil
}
func (m *Manager) GetBranch(ctx context.Context, scope intelligence.Scope, id string) (*Branch, error) {
	entry, err := m.records.Get(ctx, branchRecordID(scope, id))
	if err != nil {
		return nil, nil
	}
	if entry.Source != branchSource || !matchesScope(*entry, scope) {
		return nil, nil
	}
	var branch Branch
	if json.Unmarshal([]byte(entry.Content), &branch) != nil {
		return nil, errors.New("malformed branch")
	}
	return &branch, nil
}

func (m *Manager) saveCheckpoint(ctx context.Context, scope intelligence.Scope, checkpoint Checkpoint) error {
	data, _ := json.Marshal(checkpoint)
	_, err := m.records.Save(ctx, stores.StoredMemoryEntry{ID: checkpoint.ID, Content: string(data), Level: stores.MemoryLevelSession, Source: checkpointSource, Tags: []string{"conversation", "checkpoint", checkpoint.BranchID}, CreatedAt: checkpoint.CreatedAt, UpdatedAt: checkpoint.CreatedAt, Metadata: scopeMetadata(scope, "checkpoint")})
	return err
}
func (m *Manager) setBranch(ctx context.Context, scope intelligence.Scope, branch Branch, current *Branch) error {
	id := branchRecordID(scope, branch.ID)
	if current != nil {
		entry, err := m.records.Get(ctx, id)
		if err != nil {
			return &ConflictError{"branch disappeared"}
		}
		var stored Branch
		if err := json.Unmarshal([]byte(entry.Content), &stored); err != nil {
			return errors.New("malformed branch")
		}
		if stored.Revision != current.Revision || current.Revision != branch.Revision-1 {
			return &ConflictError{"branch revision conflict"}
		}
		if branch.UpdatedAt <= entry.UpdatedAt {
			branch.UpdatedAt = entry.UpdatedAt + 1
		}
		data, _ := json.Marshal(branch)
		atomic, err := m.atomicRecords()
		if err != nil {
			return err
		}
		swapped, err := atomic.CompareAndSwap(ctx, id, entry.UpdatedAt, stores.StoredMemoryEntry{Content: string(data), UpdatedAt: branch.UpdatedAt})
		if err != nil {
			return err
		}
		if !swapped {
			return &ConflictError{"branch revision conflict"}
		}
		return nil
	}
	data, _ := json.Marshal(branch)
	_, err := m.records.Save(ctx, stores.StoredMemoryEntry{ID: id, Content: string(data), Level: stores.MemoryLevelSession, Source: branchSource, Tags: []string{"conversation", "branch"}, CreatedAt: branch.CreatedAt, UpdatedAt: branch.UpdatedAt, Metadata: scopeMetadata(scope, "branch")})
	if err != nil {
		if existing, getErr := m.records.Get(ctx, id); getErr == nil && existing != nil {
			return &ConflictError{"branch already exists"}
		}
	}
	return err
}

func (m *Manager) atomicRecords() (stores.AtomicMemoryStore, error) {
	atomic, ok := m.records.(stores.AtomicMemoryStore)
	if !ok {
		return nil, errors.New("conversation branching requires an AtomicMemoryStore")
	}
	return atomic, nil
}
func (m *Manager) requireCheckpoint(ctx context.Context, scope intelligence.Scope, id string) (*Checkpoint, error) {
	checkpoint, err := m.GetCheckpoint(ctx, scope, id)
	if err != nil {
		return nil, err
	}
	if checkpoint == nil {
		return nil, errors.New("checkpoint not found")
	}
	return checkpoint, nil
}
func (m *Manager) restore(ctx context.Context, sessionID string, messages []stores.Message, replace bool) error {
	count, err := m.contexts.GetMessageCount(ctx, sessionID)
	if err != nil {
		return err
	}
	if count > 0 && !replace {
		return &ConflictError{"session is not empty"}
	}
	if replace {
		_ = m.contexts.DestroySession(ctx, sessionID)
	}
	if err := m.contexts.CreateSession(ctx, sessionID, &stores.SessionMetadata{CreatedAt: m.opts.Clock().UnixMilli()}); err != nil {
		return err
	}
	if len(messages) > 0 {
		return m.contexts.AppendBatch(ctx, sessionID, cloneMessages(messages), 100)
	}
	return nil
}
func (m *Manager) authorize(ctx context.Context, req AuthorizationRequest) error {
	if m.opts.Authorize == nil {
		return nil
	}
	ok, err := m.opts.Authorize(ctx, req)
	if err != nil {
		return err
	}
	if !ok {
		return errors.New("conversation action not authorized")
	}
	return nil
}

func ValidateHistory(messages []stores.Message) error {
	pending := map[string]bool{}
	for index, message := range messages {
		switch message.Role {
		case "assistant":
			for _, call := range message.ToolCalls {
				if call.ID != "" {
					if pending[call.ID] {
						return errors.New("duplicate tool call id")
					}
					pending[call.ID] = true
				}
			}
		case "tool":
			if message.ToolCallID == "" || !pending[message.ToolCallID] {
				return fmt.Errorf("orphan tool result at index %d", index)
			}
			delete(pending, message.ToolCallID)
		case "user", "system":
			if len(pending) > 0 {
				return errors.New("unresolved tool calls")
			}
		default:
			return errors.New("invalid message role")
		}
	}
	if len(pending) > 0 {
		return errors.New("conversation ends with unresolved tool calls")
	}
	return nil
}
func historyHash(messages []stores.Message, summary *string) string {
	data, _ := canonicaljson.Marshal(struct {
		Messages []stores.Message `json:"messages"`
		Summary  *string          `json:"summary"`
	}{messages, summary})
	return digest(data)
}
func exportChecksum(bundle Export) string {
	data, _ := canonicaljson.Marshal(struct {
		SchemaVersion int                `json:"schemaVersion"`
		Scope         intelligence.Scope `json:"scope"`
		Checkpoint    Checkpoint         `json:"checkpoint"`
	}{bundle.SchemaVersion, bundle.Scope, bundle.Checkpoint})
	return digest(data)
}
func scopeMetadata(scope intelligence.Scope, kind string) map[string]interface{} {
	privacy := "tenant"
	if scope.SubjectID != "" {
		privacy = "private"
	}
	return map[string]interface{}{"schemaVersion": ExportVersion, "tenantId": scope.TenantID, "namespace": defaultNamespace(scope.Namespace), "subjectId": scope.SubjectID, "privacy": privacy, "kind": "artifact", "recordType": kind}
}
func matchesScope(entry stores.StoredMemoryEntry, scope intelligence.Scope) bool {
	return fmt.Sprint(entry.Metadata["tenantId"]) == scope.TenantID && defaultNamespace(fmt.Sprint(entry.Metadata["namespace"])) == defaultNamespace(scope.Namespace) && (fmt.Sprint(entry.Metadata["privacy"]) != "private" || fmt.Sprint(entry.Metadata["subjectId"]) == scope.SubjectID)
}
func branchRecordID(scope intelligence.Scope, id string) string {
	return "branch:" + digest([]byte(scope.TenantID+"\x00"+defaultNamespace(scope.Namespace)+"\x00"+scope.SubjectID+"\x00"+id))
}
func newID() string {
	value := make([]byte, 16)
	_, _ = rand.Read(value)
	return hex.EncodeToString(value)
}
func digest(value []byte) string { sum := sha256.Sum256(value); return hex.EncodeToString(sum[:]) }
func defaultNamespace(value string) string {
	if value == "" {
		return "default"
	}
	return value
}
func contains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}
func cloneMessages(messages []stores.Message) []stores.Message {
	data, _ := json.Marshal(messages)
	var result []stores.Message
	_ = json.Unmarshal(data, &result)
	return result
}
