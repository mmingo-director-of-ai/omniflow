package bootstrap

import (
	"context"
	"fmt"
	"strings"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/agent"
)

// EvalTask is one tool-use task in the reliability eval.
type EvalTask struct {
	ID         string
	Prompt     string
	Tools      []agent.ToolSchema
	ExpectTool string // "" => expect a final answer (no call)
	ExpectArgs func(map[string]interface{}) bool
}

// EvalTaskResult is the per-task outcome.
type EvalTaskResult struct {
	ID              string
	ProducedCall    bool
	SchemaValid     bool
	MatchedExpected bool
}

// EvalReport aggregates results for one model/config.
type EvalReport struct {
	Label           string
	Total           int
	SchemaValidRate float64
	TaskMatchRate   float64
	Results         []EvalTaskResult
}

// EvalMatrixEntry is one row of an eval matrix.
type EvalMatrixEntry struct {
	Label  string
	Make   func() (provider agent.Provider, model string, onTask func(string))
	Config Config
}

// RunEval runs the task set through bootstrap(provider, model) and reports rates.
func RunEval(label string, provider agent.Provider, model string, tasks []EvalTask, config Config, onTask func(string)) EvalReport {
	results := make([]EvalTaskResult, 0, len(tasks))
	for _, t := range tasks {
		if onTask != nil {
			onTask(t.ID)
		}
		bp := Bootstrap(provider, model, config)
		producedCall, schemaValid, matched := false, false, false

		res, err := bp.Generate(context.Background(), []agent.Message{{Role: "user", Content: t.Prompt}}, t.Tools)
		if err == nil {
			calls := res.ToolCalls
			producedCall = len(calls) > 0
			if producedCall {
				schemaValid = validateCalls(calls, t.Tools, true, 0.82).ok
			}
			if t.ExpectTool != "" {
				for _, c := range calls {
					if c.Name == t.ExpectTool && (t.ExpectArgs == nil || t.ExpectArgs(c.Arguments)) {
						matched = true
					}
				}
			} else {
				matched = !producedCall
			}
		}
		results = append(results, EvalTaskResult{ID: t.ID, ProducedCall: producedCall, SchemaValid: schemaValid, MatchedExpected: matched})
	}

	total := len(tasks)
	denom := total
	if denom == 0 {
		denom = 1
	}
	valid, match := 0, 0
	for _, r := range results {
		if r.SchemaValid {
			valid++
		}
		if r.MatchedExpected {
			match++
		}
	}
	return EvalReport{
		Label:           label,
		Total:           total,
		SchemaValidRate: float64(valid) / float64(denom),
		TaskMatchRate:   float64(match) / float64(denom),
		Results:         results,
	}
}

// RunMatrix runs the same task set across every model/config in the matrix.
func RunMatrix(entries []EvalMatrixEntry, tasks []EvalTask) []EvalReport {
	out := make([]EvalReport, 0, len(entries))
	for _, e := range entries {
		p, model, onTask := e.Make()
		out = append(out, RunEval(e.Label, p, model, tasks, e.Config, onTask))
	}
	return out
}

func pct(n float64) string { return fmt.Sprintf("%d%%", int(n*100+0.5)) }

// FormatReport renders a single report.
func FormatReport(r EvalReport) string {
	valid, match := 0, 0
	for _, x := range r.Results {
		if x.SchemaValid {
			valid++
		}
		if x.MatchedExpected {
			match++
		}
	}
	return strings.Join([]string{
		"Eval: " + r.Label,
		fmt.Sprintf("  schema-valid rate: %s (%d/%d)", pct(r.SchemaValidRate), valid, r.Total),
		fmt.Sprintf("  task-match rate:   %s (%d/%d)", pct(r.TaskMatchRate), match, r.Total),
	}, "\n")
}

// FormatMatrix renders a matrix of reports.
func FormatMatrix(reports []EvalReport) string {
	lines := []string{"Eval matrix:"}
	for _, r := range reports {
		lines = append(lines, fmt.Sprintf("  %-32s schema-valid %4s   task-match %4s", r.Label, pct(r.SchemaValidRate), pct(r.TaskMatchRate)))
	}
	return strings.Join(lines, "\n")
}
