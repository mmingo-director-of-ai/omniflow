package distill

import (
	"strings"
	"testing"
)

func TestDistillationPublicAPI(t *testing.T) {
	t.Parallel()
	prompt := BuildDistillationPrompt([]ConversationMessage{{Role: "user", Content: "Use PostgreSQL"}}, DistillationOptions{})
	if !strings.Contains(prompt, "USER: Use PostgreSQL") || !strings.Contains(prompt, "up to 10") {
		t.Fatalf("unexpected prompt: %s", prompt)
	}

	response := "```json\n" + `{"learnings":[{"type":"decision","content":"Use PostgreSQL","suggestedLevel":"project","confidence":0.9,"context":"review"}],"summary":"done","topics":["database"],"memoryUpdates":[]}` + "\n```"
	parsed, err := ParseDistillationResponse(response)
	if err != nil || len(parsed.Learnings) != 1 {
		t.Fatalf("parse failed: %#v, %v", parsed, err)
	}
	if _, err := ParseDistillationResponse("not-json"); err == nil {
		t.Fatal("invalid JSON should fail")
	}

	learnings := append(parsed.Learnings,
		DistilledLearning{Type: LearningFact, Content: "Redis is optional", SuggestedLevel: LevelProject, Confidence: 0.4},
		DistilledLearning{Type: LearningPreference, Content: "Concise", SuggestedLevel: LevelUser, Confidence: 1},
	)
	formatted := FormatForMemory(learnings, LevelProject)
	if !strings.Contains(formatted, "## Decisions") || !strings.Contains(formatted, "## Facts") {
		t.Fatalf("unexpected memory format: %s", formatted)
	}
	if FormatForMemory(learnings, LevelEnterprise) != "" {
		t.Fatal("empty level should format as empty")
	}
	if len(FilterByConfidence(learnings, 0.8)) != 2 {
		t.Fatal("confidence filter mismatch")
	}
	if len(FilterByType(learnings, LearningFact, LearningPreference)) != 2 {
		t.Fatal("type filter mismatch")
	}
	if !strings.Contains(GetDistillationSystemPrompt(), "knowledge extraction") {
		t.Fatal("system prompt missing")
	}
}
