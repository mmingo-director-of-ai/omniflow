package main

import (
	"context"
	"errors"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

type mcpDiscoveryTool struct {
	Name        string `json:"name"`
	Description string `json:"description"`
}

// Only approved, current capability metadata crosses this boundary. Connection
// configuration, credentials, schemas and server response bodies do not.
type mcpDiscovery struct {
	Server    string             `json:"server"`
	Name      string             `json:"name"`
	Error     string             `json:"error,omitempty"`
	ToolCount int                `json:"toolCount"`
	HasMore   bool               `json:"hasMore"`
	Tools     []mcpDiscoveryTool `json:"tools"`
}

func (h *mcpHost) discover(ctx context.Context, query string) []mcpDiscovery {
	// Individual handshakes/catalogs have a 12-second limit. A failed or slow
	// configured server must not consume the whole run's native-answer budget.
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	result := []mcpDiscovery{}
	for _, config := range h.configs {
		if !config.Enabled {
			continue
		}
		item := mcpDiscovery{Server: config.ID, Name: config.Name, Tools: []mcpDiscoveryTool{}}
		var connection *mcpConnection
		err := ctx.Err()
		if err == nil {
			connection, err = h.connect(ctx, config.ID)
		}
		if err != nil {
			item.Error = discoveryError(err)
		} else {
			names := rankedDiscoveryNames(connection, query)
			item.ToolCount = len(names)
			item.HasMore = len(names) > 8
			for _, name := range names[:min(8, len(names))] {
				item.Tools = append(item.Tools, mcpDiscoveryTool{Name: name, Description: utf8Prefix(connection.tools[name].Description, 200)})
			}
		}
		result = append(result, item)
	}
	return result
}

// Ranking changes which approved metadata fits the initial model window. It
// never selects a schema, calls a tool, or expands an approval. The query stays
// in the host; it is not sent to the MCP server or copied into discovery output.
func rankedDiscoveryNames(connection *mcpConnection, query string) []string {
	query = strings.ToLower(utf8Prefix(query, 8000))
	terms := discoveryTerms(query, 32)
	type candidate struct {
		name      string
		nameTerms map[string]bool
		allTerms  map[string]bool
		score     int
	}
	candidates := []candidate{}
	frequency := map[string]int{}
	for name, tool := range connection.tools {
		if !connection.allowed(tool) {
			continue
		}
		nameTerms := discoveryTerms(name, 128)
		allTerms := discoveryTerms(name+" "+tool.Description, 4096)
		for term := range terms {
			if allTerms[term] {
				frequency[term]++
			}
		}
		candidates = append(candidates, candidate{name: name, nameTerms: nameTerms, allTerms: allTerms})
	}
	for index := range candidates {
		item := &candidates[index]
		if discoveryExactName(query, strings.ToLower(item.name)) {
			item.score += 1 << 20
		}
		for term := range terms {
			if !item.allTerms[term] {
				continue
			}
			weight := 1 + len(candidates)/frequency[term]
			if item.nameTerms[term] {
				item.score += 8 * weight
			} else {
				item.score += 2 * weight
			}
		}
	}
	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].score != candidates[j].score {
			return candidates[i].score > candidates[j].score
		}
		return candidates[i].name < candidates[j].name
	})
	names := make([]string, len(candidates))
	for index, item := range candidates {
		names[index] = item.name
	}
	return names
}

func discoveryTerms(text string, maximum int) map[string]bool {
	stop := map[string]bool{}
	for _, term := range strings.Fields("the and for from with this that what which where when how please tell find read search use using show give get list me my our your can could would about does not into then its of on as current user request previous conversation answer tools tool server connection") {
		stop[term] = true
	}
	terms := map[string]bool{}
	for _, term := range strings.FieldsFunc(strings.ToLower(text), func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsNumber(r) }) {
		if utf8.RuneCountInString(term) < 3 || len(term) > 80 || stop[term] {
			continue
		}
		terms[term] = true
		if len(terms) == maximum {
			break
		}
	}
	return terms
}

func discoveryExactName(query, name string) bool {
	if name == "" {
		return false
	}
	nameRune := func(r rune) bool { return unicode.IsLetter(r) || unicode.IsNumber(r) || strings.ContainsRune("_.-", r) }
	for offset := 0; offset < len(query); {
		found := strings.Index(query[offset:], name)
		if found < 0 {
			return false
		}
		start, end := offset+found, offset+found+len(name)
		before, _ := utf8.DecodeLastRuneInString(query[:start])
		after, _ := utf8.DecodeRuneInString(query[end:])
		if (start == 0 || !nameRune(before)) && (end == len(query) || !nameRune(after)) {
			return true
		}
		offset = end
	}
	return false
}

func discoveryError(err error) string {
	if errors.Is(err, context.Canceled) {
		return "mcp_discovery_cancelled"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "mcp_discovery_timeout"
	}
	if safe := safeMCPHTTPError(err); safe != nil {
		return safe.Error()
	}
	// Never forward arbitrary process, protocol or remote error text. It may
	// contain a URL, a response body, or credentials echoed by a remote service.
	switch err.Error() {
	case "mcp_server_not_enabled", "mcp_initialize_failed_check_endpoint_and_credentials",
		"mcp_initialize_failed_check_local_command", "unsupported_mcp_protocol",
		"invalid_mcp_catalog", "mcp_tool_definition_limit_or_duplicate",
		"mcp_catalog_limit_256_tools", "mcp_invalid_pagination", "mcp_catalog_page_limit",
		"mcp_http_status_error":
		return err.Error()
	default:
		return "mcp_discovery_failed"
	}
}
