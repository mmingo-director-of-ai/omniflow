// Package intelligence provides host-neutral persistent intelligence contracts.
package intelligence

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
	"sort"
	"strings"
	"time"
	"unicode"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/internal/canonicaljson"
	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/stores"
)

const SchemaVersion = 1

type Scope struct {
	TenantID  string `json:"tenantId"`
	Namespace string `json:"namespace,omitempty"`
	SubjectID string `json:"subjectId,omitempty"`
}

type SaveInput struct {
	ID        string
	Content   string
	Level     stores.MemoryLevel
	Source    string
	Tags      []string
	Embedding []float64
	Kind      string
	Privacy   string
	TTL       time.Duration
	ExpiresAt int64
	LegalHold bool
	Metadata  map[string]interface{}
}

type Query struct {
	Text           string
	Scope          Scope
	Level          stores.MemoryLevel
	Kind           string
	Tags           []string
	Limit          int
	Threshold      float64
	IncludeExpired bool
}

type SearchResult struct {
	Entry         stores.StoredMemoryEntry
	Score         float64
	LexicalScore  float64
	SemanticScore *float64
}

type AuthorizationRequest struct {
	Action string
	Scope  Scope
	Record *stores.StoredMemoryEntry
}

type Options struct {
	Clock     func() time.Time
	Embed     func(context.Context, string) ([]float64, error)
	Authorize func(context.Context, AuthorizationRequest) (bool, error)
}

type Bundle struct {
	SchemaVersion int                        `json:"schemaVersion"`
	ExportedAt    int64                      `json:"exportedAt"`
	Scope         Scope                      `json:"scope"`
	Records       []stores.StoredMemoryEntry `json:"records"`
	Checksum      string                     `json:"checksum"`
}

type PersistentIntelligence struct {
	store stores.MemoryStore
	opts  Options
}

func New(store stores.MemoryStore, opts Options) *PersistentIntelligence {
	if opts.Clock == nil {
		opts.Clock = time.Now
	}
	return &PersistentIntelligence{store: store, opts: opts}
}

func (p *PersistentIntelligence) Save(ctx context.Context, scope Scope, input SaveInput) (string, error) {
	if err := validateScope(scope); err != nil {
		return "", err
	}
	now := p.opts.Clock()
	metadata := cloneMap(input.Metadata)
	metadata["schemaVersion"] = SchemaVersion
	metadata["tenantId"] = scope.TenantID
	metadata["namespace"] = namespace(scope)
	if scope.SubjectID != "" {
		metadata["subjectId"] = scope.SubjectID
	}
	if input.Kind == "" {
		input.Kind = "fact"
	}
	if input.Privacy == "" {
		input.Privacy = "tenant"
	}
	metadata["kind"] = input.Kind
	metadata["privacy"] = input.Privacy
	expiresAt := input.ExpiresAt
	if expiresAt == 0 && input.TTL > 0 {
		expiresAt = now.Add(input.TTL).UnixMilli()
	}
	retention := map[string]interface{}{"legalHold": input.LegalHold}
	if expiresAt != 0 {
		retention["expiresAt"] = expiresAt
	}
	metadata["retention"] = retention

	embedding := input.Embedding
	if len(embedding) == 0 && p.opts.Embed != nil {
		var err error
		embedding, err = p.opts.Embed(ctx, input.Content)
		if err != nil {
			return "", err
		}
	}
	entry := stores.StoredMemoryEntry{
		ID: input.ID, Content: input.Content, Level: input.Level, Source: input.Source,
		Tags: input.Tags, Embedding: embedding, CreatedAt: now.UnixMilli(), UpdatedAt: now.UnixMilli(), Metadata: metadata,
	}
	if entry.ID == "" {
		entry.ID = newID()
	}
	if entry.Level == "" {
		entry.Level = stores.MemoryLevelProject
	}
	if err := p.authorize(ctx, AuthorizationRequest{Action: "write", Scope: scope, Record: &entry}); err != nil {
		return "", err
	}
	return p.store.Save(ctx, entry)
}

func (p *PersistentIntelligence) Retrieve(ctx context.Context, query Query) ([]SearchResult, error) {
	if err := validateScope(query.Scope); err != nil {
		return nil, err
	}
	if err := p.authorize(ctx, AuthorizationRequest{Action: "read", Scope: query.Scope}); err != nil {
		return nil, err
	}
	var queryEmbedding []float64
	var err error
	if p.opts.Embed != nil && query.Text != "" {
		queryEmbedding, err = p.opts.Embed(ctx, query.Text)
		if err != nil {
			return nil, err
		}
	}
	entries, err := p.store.LoadAll(ctx)
	if err != nil {
		return nil, err
	}
	results := make([]SearchResult, 0)
	for _, entry := range entries {
		if !visible(entry, query.Scope) || (query.Level != "" && entry.Level != query.Level) || (query.Kind != "" && stringValue(entry.Metadata["kind"]) != query.Kind) {
			continue
		}
		if !allTags(entry.Tags, query.Tags) || (!query.IncludeExpired && expired(entry, p.opts.Clock().UnixMilli())) {
			continue
		}
		lexical := lexicalSimilarity(query.Text, entry.Content)
		score := lexical
		var semantic *float64
		if len(queryEmbedding) > 0 && len(entry.Embedding) > 0 {
			value := cosine(queryEmbedding, entry.Embedding)
			semantic = &value
			if value > score {
				score = value
			}
		}
		if query.Text != "" && score < query.Threshold {
			continue
		}
		results = append(results, SearchResult{Entry: entry, Score: score, LexicalScore: lexical, SemanticScore: semantic})
	}
	sort.SliceStable(results, func(i, j int) bool {
		if results[i].Score == results[j].Score {
			if results[i].Entry.UpdatedAt == results[j].Entry.UpdatedAt {
				return results[i].Entry.ID < results[j].Entry.ID
			}
			return results[i].Entry.UpdatedAt > results[j].Entry.UpdatedAt
		}
		return results[i].Score > results[j].Score
	})
	limit := query.Limit
	if limit <= 0 {
		limit = 20
	}
	if len(results) > limit {
		results = results[:limit]
	}
	return results, nil
}

func (p *PersistentIntelligence) PurgeExpired(ctx context.Context, scope Scope) (int, error) {
	entries, err := p.store.LoadAll(ctx)
	if err != nil {
		return 0, err
	}
	purged := 0
	for _, entry := range entries {
		if !visible(entry, scope) || !expired(entry, p.opts.Clock().UnixMilli()) || legalHold(entry) {
			continue
		}
		if err := p.authorize(ctx, AuthorizationRequest{Action: "delete", Scope: scope, Record: &entry}); err != nil {
			return purged, err
		}
		if err := p.store.Delete(ctx, entry.ID); err != nil {
			return purged, err
		}
		purged++
	}
	return purged, nil
}

func (p *PersistentIntelligence) Export(ctx context.Context, scope Scope) (Bundle, error) {
	if err := p.authorize(ctx, AuthorizationRequest{Action: "export", Scope: scope}); err != nil {
		return Bundle{}, err
	}
	entries, err := p.store.LoadAll(ctx)
	if err != nil {
		return Bundle{}, err
	}
	filtered := make([]stores.StoredMemoryEntry, 0)
	for _, entry := range entries {
		if visible(entry, scope) {
			filtered = append(filtered, entry)
		}
	}
	sort.Slice(filtered, func(i, j int) bool { return filtered[i].ID < filtered[j].ID })
	bundle := Bundle{SchemaVersion: SchemaVersion, ExportedAt: p.opts.Clock().UnixMilli(), Scope: scope, Records: filtered}
	bundle.Checksum = bundleChecksum(bundle)
	return bundle, nil
}

func (p *PersistentIntelligence) Import(ctx context.Context, scope Scope, bundle Bundle, conflict string) (int, int, error) {
	if bundle.SchemaVersion != SchemaVersion || bundle.Checksum != bundleChecksum(bundle) {
		return 0, 0, errors.New("intelligence bundle checksum or version mismatch")
	}
	if bundle.Scope.TenantID != scope.TenantID {
		return 0, 0, errors.New("cross-tenant intelligence import denied")
	}
	if err := p.authorize(ctx, AuthorizationRequest{Action: "import", Scope: scope}); err != nil {
		return 0, 0, err
	}
	imported, skipped := 0, 0
	for _, entry := range bundle.Records {
		if !visible(entry, scope) {
			return imported, skipped, errors.New("bundle contains a record outside the import scope")
		}
		_, getErr := p.store.Get(ctx, entry.ID)
		if getErr == nil {
			switch conflict {
			case "skip":
				skipped++
				continue
			case "replace":
				if err := p.store.Update(ctx, entry.ID, entry); err != nil {
					return imported, skipped, err
				}
			default:
				return imported, skipped, errors.New("intelligence record already exists")
			}
		} else if _, err := p.store.Save(ctx, entry); err != nil {
			return imported, skipped, err
		}
		imported++
	}
	return imported, skipped, nil
}

func (p *PersistentIntelligence) authorize(ctx context.Context, req AuthorizationRequest) error {
	if p.opts.Authorize == nil {
		return nil
	}
	ok, err := p.opts.Authorize(ctx, req)
	if err != nil {
		return err
	}
	if !ok {
		return errors.New("persistent intelligence action was not authorized")
	}
	return nil
}

func validateScope(scope Scope) error {
	if strings.TrimSpace(scope.TenantID) == "" {
		return errors.New("tenantId is required")
	}
	return nil
}

func namespace(scope Scope) string {
	if scope.Namespace == "" {
		return "default"
	}
	return scope.Namespace
}

func visible(entry stores.StoredMemoryEntry, scope Scope) bool {
	if stringValue(entry.Metadata["tenantId"]) != scope.TenantID || stringValueDefault(entry.Metadata["namespace"], "default") != namespace(scope) {
		return false
	}
	return stringValue(entry.Metadata["privacy"]) != "private" || stringValue(entry.Metadata["subjectId"]) == scope.SubjectID
}

func expired(entry stores.StoredMemoryEntry, now int64) bool {
	retention, _ := entry.Metadata["retention"].(map[string]interface{})
	if retention == nil || boolValue(retention["legalHold"]) {
		return false
	}
	expiresAt := int64(numberValue(retention["expiresAt"]))
	return expiresAt > 0 && expiresAt <= now
}

func legalHold(entry stores.StoredMemoryEntry) bool {
	retention, _ := entry.Metadata["retention"].(map[string]interface{})
	return retention != nil && boolValue(retention["legalHold"])
}

func allTags(entryTags, required []string) bool {
	set := make(map[string]bool, len(entryTags))
	for _, tag := range entryTags {
		set[tag] = true
	}
	for _, tag := range required {
		if !set[tag] {
			return false
		}
	}
	return true
}

func lexicalSimilarity(query, content string) float64 {
	queryTerms := terms(query)
	if len(queryTerms) == 0 {
		return 1
	}
	contentTerms := terms(content)
	matched := 0
	for term := range queryTerms {
		if contentTerms[term] {
			matched++
		}
	}
	return float64(matched) / float64(len(queryTerms))
}

func terms(value string) map[string]bool {
	returnMap := map[string]bool{}
	for _, term := range strings.FieldsFunc(strings.ToLower(value), func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsNumber(r) && r != '_' && r != '-' }) {
		returnMap[term] = true
	}
	return returnMap
}

func cosine(a, b []float64) float64 {
	if len(a) == 0 || len(a) != len(b) {
		return 0
	}
	var dot, aa, bb float64
	for i := range a {
		dot += a[i] * b[i]
		aa += a[i] * a[i]
		bb += b[i] * b[i]
	}
	if aa == 0 || bb == 0 {
		return 0
	}
	return dot / (math.Sqrt(aa) * math.Sqrt(bb))
}

func bundleChecksum(bundle Bundle) string {
	payload := struct {
		SchemaVersion int                        `json:"schemaVersion"`
		ExportedAt    int64                      `json:"exportedAt"`
		Scope         Scope                      `json:"scope"`
		Records       []stores.StoredMemoryEntry `json:"records"`
	}{bundle.SchemaVersion, bundle.ExportedAt, bundle.Scope, bundle.Records}
	data, _ := canonicaljson.Marshal(payload)
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}

func newID() string {
	data := make([]byte, 16)
	_, _ = rand.Read(data)
	return hex.EncodeToString(data)
}

func cloneMap(value map[string]interface{}) map[string]interface{} {
	result := map[string]interface{}{}
	for key, item := range value {
		result[key] = item
	}
	return result
}

func stringValue(value interface{}) string { text, _ := value.(string); return text }
func stringValueDefault(value interface{}, fallback string) string {
	if text := stringValue(value); text != "" {
		return text
	}
	return fallback
}
func numberValue(value interface{}) float64 {
	switch number := value.(type) {
	case float64:
		return number
	case float32:
		return float64(number)
	case int:
		return float64(number)
	case int64:
		return float64(number)
	case int32:
		return float64(number)
	case json.Number:
		result, _ := number.Float64()
		return result
	default:
		return 0
	}
}
func boolValue(value interface{}) bool { result, _ := value.(bool); return result }
