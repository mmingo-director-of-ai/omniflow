package types

import "testing"

func TestStructuredErrors(t *testing.T) {
	t.Parallel()
	provider := NewProviderError("provider failed", "openai", 500)
	tool := NewToolError("tool failed", "search", map[string]interface{}{"q": "atlas"})
	mcp := NewMCPServerError("mcp failed", "server", "stdio")
	talent := NewTalentError("talent failed", "hunt")

	if provider.Error() != "provider failed" || provider.Code != "PROVIDER_ERROR" || provider.Provider != "openai" {
		t.Fatal("provider error mismatch")
	}
	if tool.Code != "TOOL_ERROR" || tool.Tool != "search" || mcp.Code != "MCP_SERVER_ERROR" || talent.Code != "TALENT_ERROR" {
		t.Fatal("structured error metadata mismatch")
	}
}
