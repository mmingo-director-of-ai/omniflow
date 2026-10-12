package bootstrap

import (
	"fmt"
	"strings"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/agent"
)

type callCheck struct {
	call        agent.ToolCallData
	ok          bool
	unknownTool bool
	errors      []string
}

type validationOutcome struct {
	ok     bool
	calls  []agent.ToolCallData
	checks []callCheck
}

// validateCalls checks parsed calls against tool schemas, applying fuzzy
// tool-name correction and a required-field presence check.
func validateCalls(calls []agent.ToolCallData, tools []agent.ToolSchema, fuzzy bool, threshold float64) validationOutcome {
	byName := make(map[string]agent.ToolSchema, len(tools))
	for _, t := range tools {
		byName[t.Name] = t
	}

	var checks []callCheck
	var corrected []agent.ToolCallData

	for _, call := range calls {
		tool, found := byName[call.Name]
		name := call.Name
		if !found && fuzzy {
			if best, ok := bestMatch(call.Name, tools, threshold); ok {
				tool, name, found = best, best.Name, true
			}
		}
		if !found {
			checks = append(checks, callCheck{call: call, unknownTool: true, errors: []string{fmt.Sprintf("Unknown tool %q", call.Name)}})
			continue
		}
		errs := missingRequired(call.Arguments, tool.InputSchema)
		fixed := call
		fixed.Name = name
		corrected = append(corrected, fixed)
		checks = append(checks, callCheck{call: fixed, ok: len(errs) == 0, errors: errs})
	}

	ok := len(checks) > 0
	for _, c := range checks {
		if !c.ok {
			ok = false
		}
	}
	return validationOutcome{ok: ok, calls: corrected, checks: checks}
}

func missingRequired(args map[string]interface{}, schema map[string]interface{}) []string {
	if schema == nil {
		return nil
	}
	req, _ := schema["required"].([]interface{})
	var errs []string
	for _, r := range req {
		if key, ok := r.(string); ok {
			if _, present := args[key]; !present {
				errs = append(errs, fmt.Sprintf("missing required field %q", key))
			}
		}
	}
	return errs
}

func bestMatch(name string, tools []agent.ToolSchema, threshold float64) (agent.ToolSchema, bool) {
	var best agent.ToolSchema
	bestScore := 0.0
	for _, t := range tools {
		if s := similarity(name, t.Name); s > bestScore {
			bestScore, best = s, t
		}
	}
	return best, bestScore >= threshold
}

func buildRepairMessage(o validationOutcome, tools []agent.ToolSchema) string {
	names := make([]string, 0, len(tools))
	for _, t := range tools {
		names = append(names, t.Name)
	}
	lines := []string{"Your previous tool call was invalid:"}
	for _, c := range o.checks {
		if c.ok {
			continue
		}
		if c.unknownTool {
			lines = append(lines, fmt.Sprintf("- %q is not a real tool. Valid tools: %s.", c.call.Name, strings.Join(names, ", ")))
		} else {
			lines = append(lines, fmt.Sprintf("- the call to %q had invalid arguments: %s.", c.call.Name, strings.Join(c.errors, "; ")))
		}
	}
	lines = append(lines, "Reply again with ONLY a corrected tool_call block whose arguments match the tool's JSON Schema.")
	return strings.Join(lines, "\n")
}

func similarity(a, b string) float64 {
	a, b = strings.ToLower(a), strings.ToLower(b)
	if a == b {
		return 1
	}
	max := len(a)
	if len(b) > max {
		max = len(b)
	}
	if max == 0 {
		return 1
	}
	return 1 - float64(levenshtein(a, b))/float64(max)
}

func levenshtein(a, b string) int {
	m, n := len(a), len(b)
	if m == 0 {
		return n
	}
	if n == 0 {
		return m
	}
	dp := make([]int, n+1)
	for j := 0; j <= n; j++ {
		dp[j] = j
	}
	for i := 1; i <= m; i++ {
		prev := dp[0]
		dp[0] = i
		for j := 1; j <= n; j++ {
			tmp := dp[j]
			cost := 1
			if a[i-1] == b[j-1] {
				cost = 0
			}
			dp[j] = min3(dp[j]+1, dp[j-1]+1, prev+cost)
			prev = tmp
		}
	}
	return dp[n]
}

func min3(a, b, c int) int {
	if b < a {
		a = b
	}
	if c < a {
		a = c
	}
	return a
}
