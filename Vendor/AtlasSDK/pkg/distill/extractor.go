/**
 * Knowledge distillation for Go SDK
 *
 * Extracts learnings from conversations and formats them for memory storage.
 */
package distill

import (
	"encoding/json"
	"fmt"
	"strings"
)

// LearningType represents the type of distilled learning.
type LearningType string

const (
	LearningDecision   LearningType = "decision"
	LearningPattern    LearningType = "pattern"
	LearningPreference LearningType = "preference"
	LearningFact       LearningType = "fact"
	LearningInsight    LearningType = "insight"
)

// MemoryLevel represents the target memory level.
type MemoryLevel string

const (
	LevelEnterprise MemoryLevel = "enterprise"
	LevelProject    MemoryLevel = "project"
	LevelUser       MemoryLevel = "user"
	LevelSession    MemoryLevel = "session"
)

// DistilledLearning represents a single extracted learning.
type DistilledLearning struct {
	Type           LearningType `json:"type"`
	Content        string       `json:"content"`
	SuggestedLevel MemoryLevel  `json:"suggestedLevel"`
	Confidence     float64      `json:"confidence"`
	Context        string       `json:"context,omitempty"`
}

// DistillationResult contains all extracted learnings.
type DistillationResult struct {
	Learnings     []DistilledLearning `json:"learnings"`
	Summary       string              `json:"summary"`
	Topics        []string            `json:"topics"`
	MemoryUpdates []MemoryUpdate      `json:"memoryUpdates"`
}

// MemoryUpdate represents a formatted memory update.
type MemoryUpdate struct {
	Level   MemoryLevel `json:"level"`
	Content string      `json:"content"`
}

// ConversationMessage represents a message in a conversation.
type ConversationMessage struct {
	Role      string `json:"role"`
	Content   string `json:"content"`
	Timestamp int64  `json:"timestamp,omitempty"`
}

// DistillationOptions configures the distillation process.
type DistillationOptions struct {
	MaxLearnings   int         `json:"maxLearnings"`
	MinConfidence  float64     `json:"minConfidence"`
	IncludeContext bool        `json:"includeContext"`
	TargetLevel    MemoryLevel `json:"targetLevel,omitempty"`
}

// BuildDistillationPrompt creates the prompt for the LLM.
func BuildDistillationPrompt(messages []ConversationMessage, opts DistillationOptions) string {
	if opts.MaxLearnings == 0 {
		opts.MaxLearnings = 10
	}

	var conversationText strings.Builder
	for _, m := range messages {
		conversationText.WriteString(strings.ToUpper(m.Role))
		conversationText.WriteString(": ")
		conversationText.WriteString(m.Content)
		conversationText.WriteString("\n\n")
	}

	return fmt.Sprintf(`Analyze the following conversation and extract learnings that should be remembered.

CONVERSATION:
%s

Extract the following types of learnings:
1. DECISIONS: Important choices or decisions made (e.g., "Use PostgreSQL for the database")
2. PATTERNS: Recurring patterns or conventions discovered (e.g., "APIs follow RESTful conventions")
3. PREFERENCES: User preferences established (e.g., "Prefer TypeScript over JavaScript")
4. FACTS: Important facts or information to remember (e.g., "The API rate limit is 100 requests/minute")
5. INSIGHTS: Key insights or learnings from the conversation

For each learning, suggest a memory level:
- ENTERPRISE: Organization-wide knowledge (affects all projects)
- PROJECT: Project-specific knowledge (affects current project only)
- USER: Personal preferences (user-specific)
- SESSION: Temporary context (only relevant to current session)

Respond in JSON format:
{
  "learnings": [
    {
      "type": "decision|pattern|preference|fact|insight",
      "content": "The learning content",
      "suggestedLevel": "enterprise|project|user|session",
      "confidence": 0.0-1.0,
      "context": "Optional source context"
    }
  ],
  "summary": "Brief summary of the conversation",
  "topics": ["topic1", "topic2"],
  "memoryUpdates": [
    {
      "level": "project",
      "content": "Formatted content ready for memory"
    }
  ]
}

Extract up to %d most important learnings. Focus on actionable, specific information that would be useful in future conversations.`, conversationText.String(), opts.MaxLearnings)
}

// ParseDistillationResponse parses the LLM response into a DistillationResult.
func ParseDistillationResponse(response string) (*DistillationResult, error) {
	// Extract JSON from response (handle markdown code blocks)
	jsonStr := response
	if idx := strings.Index(response, "```"); idx != -1 {
		start := idx + 3
		if strings.HasPrefix(response[start:], "json") {
			start += 4
		}
		end := strings.Index(response[start:], "```")
		if end != -1 {
			jsonStr = response[start : start+end]
		}
	}

	jsonStr = strings.TrimSpace(jsonStr)

	var result DistillationResult
	if err := json.Unmarshal([]byte(jsonStr), &result); err != nil {
		return nil, fmt.Errorf("failed to parse distillation response: %w", err)
	}

	return &result, nil
}

// FormatForMemory formats learnings for a specific memory level.
func FormatForMemory(learnings []DistilledLearning, level MemoryLevel) string {
	var filtered []DistilledLearning
	for _, l := range learnings {
		if l.SuggestedLevel == level {
			filtered = append(filtered, l)
		}
	}

	if len(filtered) == 0 {
		return ""
	}

	sections := map[LearningType][]string{
		LearningDecision:   {},
		LearningPattern:    {},
		LearningPreference: {},
		LearningFact:       {},
		LearningInsight:    {},
	}

	for _, l := range filtered {
		entry := fmt.Sprintf("- %s", l.Content)
		if l.Context != "" {
			entry = fmt.Sprintf("- %s (from: %s)", l.Content, l.Context)
		}
		sections[l.Type] = append(sections[l.Type], entry)
	}

	var parts []string

	if len(sections[LearningDecision]) > 0 {
		parts = append(parts, "## Decisions\n"+strings.Join(sections[LearningDecision], "\n"))
	}
	if len(sections[LearningPattern]) > 0 {
		parts = append(parts, "## Patterns\n"+strings.Join(sections[LearningPattern], "\n"))
	}
	if len(sections[LearningPreference]) > 0 {
		parts = append(parts, "## Preferences\n"+strings.Join(sections[LearningPreference], "\n"))
	}
	if len(sections[LearningFact]) > 0 {
		parts = append(parts, "## Facts\n"+strings.Join(sections[LearningFact], "\n"))
	}
	if len(sections[LearningInsight]) > 0 {
		parts = append(parts, "## Insights\n"+strings.Join(sections[LearningInsight], "\n"))
	}

	return strings.Join(parts, "\n\n")
}

// GetDistillationSystemPrompt returns the system prompt for distillation.
func GetDistillationSystemPrompt() string {
	return `You are a knowledge extraction assistant. Your job is to analyze conversations and extract structured learnings that should be remembered for future interactions.

Focus on:
1. Specific, actionable information
2. Decisions that affect future work
3. Patterns and conventions discovered
4. User preferences and constraints
5. Important facts and context

Avoid extracting:
- Temporary or session-specific context
- Information already well-known
- Trivial details
- Sensitive or personal information

Be concise and specific in your extractions.`
}

// FilterByConfidence filters learnings by minimum confidence.
func FilterByConfidence(learnings []DistilledLearning, minConfidence float64) []DistilledLearning {
	var result []DistilledLearning
	for _, l := range learnings {
		if l.Confidence >= minConfidence {
			result = append(result, l)
		}
	}
	return result
}

// FilterByType filters learnings by type.
func FilterByType(learnings []DistilledLearning, types ...LearningType) []DistilledLearning {
	typeSet := make(map[LearningType]bool)
	for _, t := range types {
		typeSet[t] = true
	}

	var result []DistilledLearning
	for _, l := range learnings {
		if typeSet[l.Type] {
			result = append(result, l)
		}
	}
	return result
}
