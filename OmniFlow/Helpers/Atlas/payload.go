package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
	"unicode"
	"unicode/utf8"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/security"
)

const maxPayloadBytes = 16 * 1024 * 1024
const maxStoreBytes = 64 * 1024 * 1024
const chunkBytes = 2400

// Payloads never become instructions. Compression is a disk/transport concern;
// the model receives ordinary UTF-8 evidence and opaque, run-scoped references.
type payloadEntry struct {
	Kind       string `json:"kind"`
	ID         string `json:"id"`
	Source     string `json:"source"`
	SHA256     string `json:"sha256"`
	Bytes      int    `json:"bytes"`
	Chunks     int    `json:"chunks"`
	Suspicious bool   `json:"suspicious"`
	Text       bool   `json:"text"`
	Viewed     int    `json:"fullyReadChunks"`
	offsets    []int
	seen       map[int]bool
}

type payloadStore struct {
	persistent bool
	lock       *os.File
	question   string
	directory  string
	entries    map[string]*payloadEntry
	order      []string
	used       int
}

func newPayloadStore(directory string) (*payloadStore, error) {
	if directory == "" {
		var err error
		directory, err = os.MkdirTemp("", "notchlee-atlas-payloads-")
		if err != nil {
			return nil, err
		}
	}
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return nil, errors.New("private_payload_directory_required")
	}
	return &payloadStore{directory: directory, entries: make(map[string]*payloadEntry)}, nil
}

func (s *payloadStore) close() {
	if s.lock != nil {
		_ = s.lock.Close()
		s.lock = nil
	}
	if !s.persistent {
		_ = os.RemoveAll(s.directory)
	}
}

func (s *payloadStore) put(source string, data []byte, isText bool) (*payloadEntry, error) {
	if len(data) > maxPayloadBytes || s.used+len(data) > maxStoreBytes || len(s.entries) >= 128 {
		return nil, errors.New("payload_quota_exceeded")
	}
	if isText && !utf8.Valid(data) {
		return nil, errors.New("invalid_utf8_payload")
	}
	sum := sha256.Sum256(data)
	id := fmt.Sprintf("p%d", len(s.order)+1)
	kind := "binary"
	if isText {
		kind = "text"
	}
	entry := &payloadEntry{Kind: kind, ID: id, Source: source, SHA256: hex.EncodeToString(sum[:]), Bytes: len(data), Text: isText, seen: make(map[int]bool)}
	if isText {
		entry.Suspicious, _ = security.DetectPromptInjection(string(data))
		entry.offsets = []int{0}
		for start := 0; start < len(data); {
			end := min(start+chunkBytes, len(data))
			if end < len(data) {
				// Prefer record/paragraph boundaries; never split a UTF-8 scalar.
				if newline := bytes.LastIndexByte(data[start:end], '\n'); newline >= chunkBytes/2 {
					end = start + newline + 1
				}
				for end > start && !utf8.RuneStart(data[end]) {
					end--
				}
			}
			entry.offsets = append(entry.offsets, end)
			start = end
		}
		entry.Chunks = len(entry.offsets) - 1
	}
	file, err := os.OpenFile(filepath.Join(s.directory, id+".gz"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return nil, err
	}
	compressor := gzip.NewWriter(file)
	_, err = compressor.Write(data)
	closeErr := compressor.Close()
	fileErr := file.Close()
	if err != nil || closeErr != nil || fileErr != nil {
		_ = os.Remove(file.Name())
		return nil, errors.New("payload_write_failed")
	}
	s.entries[id] = entry
	s.order = append(s.order, id)
	s.used += len(data)
	if err := s.persistIndex(); err != nil {
		return nil, err
	}
	return entry, nil
}

func (s *payloadStore) data(id string) ([]byte, *payloadEntry, error) {
	if !validStoredID(id) {
		return nil, nil, errors.New("unknown_payload_reference")
	}
	entry := s.entries[id]
	if entry == nil {
		return nil, nil, errors.New("unknown_payload_reference")
	}
	path := filepath.Join(s.directory, entry.ID+".gz")
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxPayloadBytes+65536 {
		return nil, nil, errors.New("invalid_payload_file")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	defer file.Close()
	r, err := gzip.NewReader(file)
	if err != nil {
		return nil, nil, err
	}
	defer r.Close()
	data, err := io.ReadAll(io.LimitReader(r, int64(maxPayloadBytes+1)))
	sum := sha256.Sum256(data)
	if err != nil || len(data) != entry.Bytes || hex.EncodeToString(sum[:]) != entry.SHA256 {
		return nil, nil, errors.New("payload_integrity_failed")
	}
	return data, entry, nil
}

func jsonText(value interface{}) string { data, _ := json.Marshal(value); return string(data) }

// Coverage concerns bytes delivered, not upstream completeness or model
// comprehension. In particular, reading the last chunk is not reading them all.
func payloadCoverage(result map[string]interface{}, entry *payloadEntry, available bool, start, end int) {
	complete := available && entry.Text && start == 0 && end == entry.Bytes
	allRead := available && entry.Text && entry.Viewed == entry.Chunks
	result["completeText"] = complete
	result["allChunksRead"] = allRead
	coverage := "Payload text is unavailable in this response."
	switch {
	case !entry.Text:
		coverage = "Binary payload metadata only. No decoded text is included."
	case complete:
		coverage = "Complete returned payload text is included in this response; there are no omitted chunks for this payload."
	case allRead:
		coverage = "All chunks of this payload have been delivered across this run. This response contains only the indicated byte range."
	case available:
		coverage = "Partial payload text. Only the indicated byte range is included; read remaining chunks when complete payload coverage is needed."
	}
	if entry.Kind == "schema" {
		coverage = "Schema metadata only; this describes a tool, not a tool execution result. " + coverage
	}
	result["coverage"] = coverage
}

func (s *payloadStore) preview(entry *payloadEntry) string {
	result := map[string]interface{}{"trust": "untrusted_data", "payload": entry}
	available, start, end := false, 0, 0
	if entry.Text {
		data, _, err := s.data(entry.ID)
		if err == nil {
			available = true
			if entry.Chunks > 0 {
				chunk := 0
				if entry.Kind != "schema" && entry.Chunks > 1 && s.question != "" {
					var matched int
					chunk, matched = rankPayloadChunk(data, entry.offsets, s.question)
					result["retrieval"] = map[string]interface{}{"method": "local keyword relevance", "scannedBytes": entry.Bytes, "scannedChunks": entry.Chunks, "matchingChunks": matched, "returnedChunks": 1, "coverage": "All chunks were searched for question keywords. Only the best matching chunk is shown. This does not prove absent facts or full-document understanding."}
				}
				result["chunk"] = chunk
				start, end = entry.offsets[chunk], entry.offsets[chunk+1]
				entry.seen[chunk] = true
				entry.Viewed = len(entry.seen)
			}
			result["startByte"] = start
			result["endByte"] = end
			result["text"] = string(data[start:end])
		}
	}
	payloadCoverage(result, entry, available, start, end)
	return jsonText(result)
}

// Query-aware retrieval is performed by host code, rather than asking a small
// model to infer the entire document from its opening paragraph. Rare matching
// terms outweigh boilerplate repeated throughout a large result. No embeddings,
// models, network calls, or additional dependencies are needed.
func rankPayloadChunk(data []byte, offsets []int, question string) (int, int) {
	stop := map[string]bool{}
	for _, term := range strings.Fields("the and for from with this that what which where when how please tell find read search use using show give me my our your can could would about does not into then its of on as") {
		stop[term] = true
	}
	terms := []string{}
	seen := map[string]bool{}
	for _, term := range strings.FieldsFunc(strings.ToLower(question), func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsNumber(r) }) {
		if utf8.RuneCountInString(term) < 3 || len(term) > 80 || stop[term] || seen[term] {
			continue
		}
		seen[term] = true
		terms = append(terms, term)
		if len(terms) == 32 {
			break
		}
	}
	count := len(offsets) - 1
	hits := make([][]bool, count)
	documents := make([]int, len(terms))
	matched := 0
	for chunk := 0; chunk < count; chunk++ {
		text := strings.ToLower(string(data[offsets[chunk]:offsets[chunk+1]]))
		hits[chunk] = make([]bool, len(terms))
		any := false
		for term, word := range terms {
			if strings.Contains(text, word) {
				hits[chunk][term] = true
				documents[term]++
				any = true
			}
		}
		if any {
			matched++
		}
	}
	best, highest := 0, 0.0
	for chunk, matches := range hits {
		score := 0.0
		for term, hit := range matches {
			if hit {
				score += math.Log(1 + (float64(count-documents[term])+0.5)/(float64(documents[term])+0.5))
			}
		}
		if score > highest {
			best, highest = chunk, score
		}
	}
	return best, matched
}

func (s *payloadStore) execute(ctx context.Context, args map[string]interface{}) (interface{}, error) {
	op, _ := args["operation"].(string)
	if op == "list" {
		entries := make([]*payloadEntry, 0, len(s.order))
		start, err := integerArgument(args, "offset", 0, len(s.order))
		if err != nil {
			return nil, err
		}
		end := min(start+8, len(s.order))
		for _, id := range s.order[start:end] {
			entries = append(entries, s.entries[id])
		}
		return jsonText(map[string]interface{}{"trust": "untrusted_data", "payloads": entries, "nextOffset": end, "total": len(s.order)}), nil
	}
	id, _ := args["id"].(string)
	data, entry, err := s.data(id)
	if err != nil {
		return nil, err
	}
	if !entry.Text {
		return nil, errors.New("binary_payload_has_no_text_chunks")
	}
	if op == "read" {
		chunk, err := integerArgument(args, "offset", 0, max(0, entry.Chunks-1))
		if err != nil || entry.Chunks == 0 {
			return nil, errors.New("invalid_chunk")
		}
		entry.seen[chunk] = true
		entry.Viewed = len(entry.seen)
		start, end := entry.offsets[chunk], entry.offsets[chunk+1]
		result := map[string]interface{}{"trust": "untrusted_data", "payload": entry, "chunk": chunk, "startByte": start, "endByte": end, "text": string(data[start:end]), "nextChunk": chunk + 1, "hasMore": chunk+1 < entry.Chunks}
		payloadCoverage(result, entry, true, start, end)
		return jsonText(result), nil
	}
	if op != "search" {
		return nil, errors.New("unknown_payload_operation")
	}
	query, _ := args["query"].(string)
	if len(query) == 0 || len(query) > 256 {
		return nil, errors.New("search_query_required_max_256_bytes")
	}
	start, err := integerArgument(args, "offset", 0, entry.Bytes)
	if err != nil {
		return nil, err
	}
	// Literal byte search spans chunk boundaries and scans the full remaining
	// source. It does not interpret a query as a regexp, command, or glob path.
	matches := []map[string]interface{}{}
	total, next := 0, entry.Bytes
	for position := start; position <= len(data)-len(query); {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		index := bytes.Index(data[position:], []byte(query))
		if index < 0 {
			break
		}
		position += index
		total++
		if len(matches) < 5 {
			chunk := 0
			for chunk+1 < len(entry.offsets)-1 && entry.offsets[chunk+1] <= position {
				chunk++
			}
			left, right := max(0, position-160), min(len(data), position+len(query)+320)
			for left < position && !utf8.RuneStart(data[left]) {
				left++
			}
			for right < len(data) && !utf8.RuneStart(data[right]) {
				right++
			}
			matches = append(matches, map[string]interface{}{"chunk": chunk, "startByte": position, "excerptStartByte": left, "excerptEndByte": right, "text": string(data[left:right])})
			next = position + len(query)
		}
		position += len(query)
	}
	return jsonText(map[string]interface{}{"trust": "untrusted_data", "payload": entry, "matches": matches, "totalMatchesFromOffset": total, "scannedStartByte": start, "scannedEndByte": entry.Bytes, "nextOffset": next, "hasMore": total > len(matches), "coverage": "Every byte from scannedStartByte through scannedEndByte was searched. fullyReadChunks counts full chunks shown to the model, NOT chunks searched. Matching excerpts are not full-document comprehension."}), nil
}

func integerArgument(args map[string]interface{}, key string, minimum, maximum int) (int, error) {
	value, ok := args[key]
	if !ok || value == nil {
		return minimum, nil
	}
	number, ok := value.(float64)
	if !ok || number < float64(minimum) || number > float64(maximum) || number != float64(int(number)) {
		return 0, errors.New("invalid_offset")
	}
	return int(number), nil
}

// Explicit MIME types select decoding. Never guess that arbitrary text is
// base64, and never let a decompression bomb exceed the expanded byte budget.
func decodeResourceBlob(blob, mime string) ([]byte, bool, error) {
	if len(blob) > maxPayloadBytes*4/3+4 {
		return nil, false, errors.New("encoded_payload_limit")
	}
	data, err := base64.StdEncoding.Strict().DecodeString(blob)
	if err != nil {
		return nil, false, errors.New("invalid_base64")
	}
	if mime == "application/gzip" || mime == "application/x-gzip" {
		r, err := gzip.NewReader(bytes.NewReader(data))
		if err != nil {
			return nil, false, errors.New("invalid_gzip")
		}
		defer r.Close()
		data, err = io.ReadAll(io.LimitReader(r, maxPayloadBytes+1))
		if err != nil || len(data) > maxPayloadBytes {
			return nil, false, errors.New("expanded_payload_limit")
		}
		return data, utf8.Valid(data), nil
	}
	text := strings.HasPrefix(mime, "text/") || mime == "application/json" || mime == "application/xml"
	if len(data) > maxPayloadBytes || (text && !utf8.Valid(data)) {
		return nil, false, errors.New("decoded_payload_invalid")
	}
	return data, text, nil
}
