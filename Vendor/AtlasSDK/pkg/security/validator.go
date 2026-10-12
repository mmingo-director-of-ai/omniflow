/**
 * Input Validation & Sanitization (Go SDK)
 *
 * Provides security for tool inputs, prompt injection detection,
 * and argument sanitization.
 */

package security

import (
	"fmt"
	"regexp"
	"strings"
)

// ValidationError represents a validation error
type ValidationError struct {
	Path    string
	Message string
	Type    string // "type", "required", "format", "constraint", "security"
}

// ValidationResult represents the result of validation
type ValidationResult struct {
	Valid     bool
	Errors    []ValidationError
	Warnings  []ValidationWarning
	Sanitized map[string]interface{}
}

// ValidationWarning represents a validation warning
type ValidationWarning struct {
	Path    string
	Message string
	Type    string // "deprecated", "suspicious", "performance"
}

// SchemaDefinition represents a JSON schema for validation
type SchemaDefinition struct {
	Type       string                      `json:"type"`
	Properties map[string]SchemaDefinition `json:"properties,omitempty"`
	Items      *SchemaDefinition           `json:"items,omitempty"`
	Required   []string                    `json:"required,omitempty"`
	Enum       []interface{}               `json:"enum,omitempty"`
	Minimum    *float64                    `json:"minimum,omitempty"`
	Maximum    *float64                    `json:"maximum,omitempty"`
	MinLength  *int                        `json:"minLength,omitempty"`
	MaxLength  *int                        `json:"maxLength,omitempty"`
	Pattern    string                      `json:"pattern,omitempty"`
	Format     string                      `json:"format,omitempty"`
}

// SecurityPatterns contains patterns to detect security issues
var SecurityPatterns = struct {
	PromptInjection  []*regexp.Regexp
	CodeInjection    []*regexp.Regexp
	CommandInjection []*regexp.Regexp
	SQLInjection     []*regexp.Regexp
	PathTraversal    []*regexp.Regexp
}{
	PromptInjection: []*regexp.Regexp{
		regexp.MustCompile(`(?i)ignore\s+(all\s+)?(previous|above)\s+(instructions|prompts|rules)`),
		regexp.MustCompile(`(?i)disregard\s+(all\s+)?(previous|above)`),
		regexp.MustCompile(`(?i)forget\s+(all\s+)?(previous|above)`),
		regexp.MustCompile(`(?i)you\s+are\s+now\s+`),
		regexp.MustCompile(`(?i)pretend\s+(you\s+are|to\s+be)`),
		regexp.MustCompile(`(?i)act\s+as\s+(if\s+you\s+are|a)`),
		regexp.MustCompile(`(?i)jailbreak`),
		regexp.MustCompile(`(?i)DAN\s*:`),
		regexp.MustCompile(`(?i)override\s+(your\s+)?(programming|instructions)`),
	},
	CodeInjection: []*regexp.Regexp{
		regexp.MustCompile(`(?i)<script[\s>]`),
		regexp.MustCompile(`(?i)javascript:`),
		regexp.MustCompile(`(?i)on\w+\s*=`),
		regexp.MustCompile(`(?i)eval\s*\(`),
		regexp.MustCompile(`(?i)Function\s*\(`),
		regexp.MustCompile(`(?i)setTimeout\s*\(`),
		regexp.MustCompile(`(?i)setInterval\s*\(`),
	},
	CommandInjection: []*regexp.Regexp{
		regexp.MustCompile(`(?i);\s*(rm|del|format|shutdown|reboot|halt)`),
		regexp.MustCompile(`(?i)\|\s*(sh|bash|cmd|powershell)`),
		regexp.MustCompile(`\$\([^)]+\)`),
		regexp.MustCompile("`[^`]+`"),
		regexp.MustCompile(`(?i)>\s*/(dev|etc|proc|sys)`),
	},
	SQLInjection: []*regexp.Regexp{
		regexp.MustCompile(`(?i)'\s*(OR|AND)\s+['"]?\d+['"]?\s*=\s*['"]?\d+`),
		regexp.MustCompile(`(?i)UNION\s+(ALL\s+)?SELECT`),
		regexp.MustCompile(`(?i);\s*DROP\s+(TABLE|DATABASE)`),
		regexp.MustCompile(`--\s*$`),
		regexp.MustCompile(`/\*.*\*/`),
	},
	PathTraversal: []*regexp.Regexp{
		regexp.MustCompile(`\.\.[/]`),
		regexp.MustCompile(`\.\.%2[fF]`),
		regexp.MustCompile(`\.\.%5[cC]`),
		regexp.MustCompile(`(?i)%2e%2e[/]`),
	},
}

// InputValidator validates and sanitizes inputs
type InputValidator struct {
	Strict         bool
	MaxDepth       int
	MaxLength      int
	MaxArrayLength int
}

// NewInputValidator creates a new input validator
func NewInputValidator() *InputValidator {
	return &InputValidator{
		Strict:         true,
		MaxDepth:       10,
		MaxLength:      100000,
		MaxArrayLength: 1000,
	}
}

// Validate validates input against a schema
func (v *InputValidator) Validate(input interface{}, schema SchemaDefinition) ValidationResult {
	errors := make([]ValidationError, 0)
	warnings := make([]ValidationWarning, 0)

	v.validateSchema(input, schema, "", &errors, 0)
	v.checkSecurity(input, "", &errors, &warnings)

	var sanitized map[string]interface{}
	if len(errors) == 0 {
		sanitized = v.sanitize(input)
	}

	return ValidationResult{
		Valid:     len(errors) == 0,
		Errors:    errors,
		Warnings:  warnings,
		Sanitized: sanitized,
	}
}

// validateSchema validates input against a JSON schema
func (v *InputValidator) validateSchema(value interface{}, schema SchemaDefinition, path string, errors *[]ValidationError, depth int) {
	if depth > v.MaxDepth {
		*errors = append(*errors, ValidationError{
			Path:    path,
			Message: fmt.Sprintf("Maximum depth exceeded: %d > %d", depth, v.MaxDepth),
			Type:    "constraint",
		})
		return
	}

	// Type validation
	if !v.checkType(value, schema.Type) {
		*errors = append(*errors, ValidationError{
			Path:    path,
			Message: fmt.Sprintf("Expected %s, got %T", schema.Type, value),
			Type:    "type",
		})
		return
	}

	// String validation
	if str, ok := value.(string); ok && schema.Type == "string" {
		if schema.MinLength != nil && len(str) < *schema.MinLength {
			*errors = append(*errors, ValidationError{
				Path:    path,
				Message: fmt.Sprintf("String length %d is less than minimum %d", len(str), *schema.MinLength),
				Type:    "constraint",
			})
		}
		if schema.MaxLength != nil && len(str) > *schema.MaxLength {
			*errors = append(*errors, ValidationError{
				Path:    path,
				Message: fmt.Sprintf("String length %d exceeds maximum %d", len(str), *schema.MaxLength),
				Type:    "constraint",
			})
		}
		if schema.Pattern != "" {
			matched, err := regexp.MatchString(schema.Pattern, str)
			if err != nil || !matched {
				*errors = append(*errors, ValidationError{
					Path:    path,
					Message: fmt.Sprintf("String does not match pattern: %s", schema.Pattern),
					Type:    "format",
				})
			}
		}
	}

	// Number validation
	if num, ok := value.(float64); ok && schema.Type == "number" {
		if schema.Minimum != nil && num < *schema.Minimum {
			*errors = append(*errors, ValidationError{
				Path:    path,
				Message: fmt.Sprintf("Value %v is less than minimum %v", num, *schema.Minimum),
				Type:    "constraint",
			})
		}
		if schema.Maximum != nil && num > *schema.Maximum {
			*errors = append(*errors, ValidationError{
				Path:    path,
				Message: fmt.Sprintf("Value %v exceeds maximum %v", num, *schema.Maximum),
				Type:    "constraint",
			})
		}
	}

	// Object validation
	if obj, ok := value.(map[string]interface{}); ok && schema.Type == "object" {
		// Check required properties
		for _, prop := range schema.Required {
			if _, exists := obj[prop]; !exists {
				*errors = append(*errors, ValidationError{
					Path:    fmt.Sprintf("%s.%s", path, prop),
					Message: fmt.Sprintf("Required property missing: %s", prop),
					Type:    "required",
				})
			}
		}

		// Validate properties
		for key, propSchema := range schema.Properties {
			if val, exists := obj[key]; exists {
				v.validateSchema(val, propSchema, fmt.Sprintf("%s.%s", path, key), errors, depth+1)
			}
		}
	}

	// Array validation
	if arr, ok := value.([]interface{}); ok && schema.Type == "array" {
		if len(arr) > v.MaxArrayLength {
			*errors = append(*errors, ValidationError{
				Path:    path,
				Message: fmt.Sprintf("Array length %d exceeds maximum %d", len(arr), v.MaxArrayLength),
				Type:    "constraint",
			})
		}

		if schema.Items != nil {
			for i, item := range arr {
				v.validateSchema(item, *schema.Items, fmt.Sprintf("%s[%d]", path, i), errors, depth+1)
			}
		}
	}
}

// checkType verifies if value matches the expected type
func (v *InputValidator) checkType(value interface{}, expectedType string) bool {
	switch expectedType {
	case "string":
		_, ok := value.(string)
		return ok
	case "number":
		_, ok := value.(float64)
		return ok
	case "integer":
		num, ok := value.(float64)
		return ok && float64(int(num)) == num
	case "boolean":
		_, ok := value.(bool)
		return ok
	case "object":
		_, ok := value.(map[string]interface{})
		return ok
	case "array":
		_, ok := value.([]interface{})
		return ok
	case "null":
		return value == nil
	default:
		return true
	}
}

// checkSecurity scans for security issues
func (v *InputValidator) checkSecurity(value interface{}, path string, errors *[]ValidationError, warnings *[]ValidationWarning) {
	if str, ok := value.(string); ok {
		// Check length
		if len(str) > v.MaxLength {
			*errors = append(*errors, ValidationError{
				Path:    path,
				Message: fmt.Sprintf("String length %d exceeds maximum %d", len(str), v.MaxLength),
				Type:    "constraint",
			})
		}

		// Check for prompt injection
		for _, pattern := range SecurityPatterns.PromptInjection {
			if pattern.MatchString(str) {
				*errors = append(*errors, ValidationError{
					Path:    path,
					Message: fmt.Sprintf("Potential prompt injection detected: %s", pattern.String()),
					Type:    "security",
				})
			}
		}

		// Check for command injection
		for _, pattern := range SecurityPatterns.CommandInjection {
			if pattern.MatchString(str) {
				*errors = append(*errors, ValidationError{
					Path:    path,
					Message: fmt.Sprintf("Potential command injection detected: %s", pattern.String()),
					Type:    "security",
				})
			}
		}

		// Check for path traversal
		for _, pattern := range SecurityPatterns.PathTraversal {
			if pattern.MatchString(str) {
				*errors = append(*errors, ValidationError{
					Path:    path,
					Message: fmt.Sprintf("Potential path traversal detected: %s", pattern.String()),
					Type:    "security",
				})
			}
		}
	}

	// Recurse into objects and arrays
	if obj, ok := value.(map[string]interface{}); ok {
		for key, val := range obj {
			v.checkSecurity(val, fmt.Sprintf("%s.%s", path, key), errors, warnings)
		}
	}

	if arr, ok := value.([]interface{}); ok {
		for i, val := range arr {
			v.checkSecurity(val, fmt.Sprintf("%s[%d]", path, i), errors, warnings)
		}
	}
}

// sanitize removes dangerous content from input
func (v *InputValidator) sanitize(value interface{}) map[string]interface{} {
	if obj, ok := value.(map[string]interface{}); ok {
		result := make(map[string]interface{})
		for key, val := range obj {
			// Sanitize key
			cleanKey := regexp.MustCompile(`[^\w-]`).ReplaceAllString(key, "")
			if cleanKey != "" {
				result[cleanKey] = v.sanitizeValue(val)
			}
		}
		return result
	}
	return nil
}

// sanitizeValue sanitizes a single value
func (v *InputValidator) sanitizeValue(value interface{}) interface{} {
	switch val := value.(type) {
	case string:
		// Remove null bytes and trim
		sanitized := strings.ReplaceAll(val, "\x00", "")
		if len(sanitized) > v.MaxLength {
			sanitized = sanitized[:v.MaxLength]
		}
		return sanitized
	case map[string]interface{}:
		result := make(map[string]interface{})
		for key, item := range val {
			cleanKey := regexp.MustCompile(`[^\w-]`).ReplaceAllString(key, "")
			if cleanKey != "" {
				// Recurse so nested values are sanitized too. The loop variable was
				// previously named `v`, shadowing the receiver and silently dropping
				// recursion; using `item` keeps the receiver `v` visible.
				result[cleanKey] = v.sanitizeValue(item)
			}
		}
		return result
	case []interface{}:
		if len(val) > v.MaxArrayLength {
			val = val[:v.MaxArrayLength]
		}
		result := make([]interface{}, len(val))
		for i, item := range val {
			result[i] = v.sanitizeValue(item)
		}
		return result
	default:
		return value
	}
}

// DetectPromptInjection checks for prompt injection patterns
func DetectPromptInjection(text string) (bool, []string) {
	patterns := make([]string, 0)

	for _, pattern := range SecurityPatterns.PromptInjection {
		if pattern.MatchString(text) {
			patterns = append(patterns, pattern.String())
		}
	}

	return len(patterns) > 0, patterns
}

// SanitizeForDisplay sanitizes text for safe display
func SanitizeForDisplay(text string, maxLength int) string {
	// Remove control characters
	sanitized := regexp.MustCompile(`[\x00-\x1F\x7F]`).ReplaceAllString(text, "")

	// Truncate
	if len(sanitized) > maxLength {
		sanitized = sanitized[:maxLength] + "..."
	}

	return sanitized
}
