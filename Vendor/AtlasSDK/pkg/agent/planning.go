/**
 * Planning Module for Autonomous Execution (Go SDK)
 *
 * Features:
 * - Task decomposition
 * - Plan generation from goals
 * - Plan verification
 * - Progress tracking
 */

package agent

import (
	"fmt"
	"strings"
	"sync"
	"time"
)

// PlanStatus represents the status of a plan or step
type PlanStatus string

const (
	PlanStatusPending    PlanStatus = "pending"
	PlanStatusInProgress PlanStatus = "in_progress"
	PlanStatusCompleted  PlanStatus = "completed"
	PlanStatusFailed     PlanStatus = "failed"
	PlanStatusCancelled  PlanStatus = "cancelled"
)

// PlanStep represents a step in an execution plan
type PlanStep struct {
	ID           string      `json:"id"`
	Description  string      `json:"description"`
	Tools        []string    `json:"tools"`
	Dependencies []string    `json:"dependencies"`
	Status       PlanStatus  `json:"status"`
	Result       interface{} `json:"result,omitempty"`
	Error        string      `json:"error,omitempty"`
	StartedAt    *time.Time  `json:"startedAt,omitempty"`
	CompletedAt  *time.Time  `json:"completedAt,omitempty"`
	Retries      int         `json:"retries"`
}

// ExecutionPlan represents a complete execution plan
type ExecutionPlan struct {
	ID          string       `json:"id"`
	Goal        string       `json:"goal"`
	Steps       []PlanStep   `json:"steps"`
	Status      PlanStatus   `json:"status"`
	CreatedAt   time.Time    `json:"createdAt"`
	StartedAt   *time.Time   `json:"startedAt,omitempty"`
	CompletedAt *time.Time   `json:"completedAt,omitempty"`
	Metadata    PlanMetadata `json:"metadata"`
	mu          sync.RWMutex
}

// PlanMetadata contains plan statistics
type PlanMetadata struct {
	TotalSteps        int           `json:"totalSteps"`
	CompletedSteps    int           `json:"completedSteps"`
	FailedSteps       int           `json:"failedSteps"`
	EstimatedTokens   int           `json:"estimatedTokens,omitempty"`
	EstimatedDuration time.Duration `json:"estimatedDuration,omitempty"`
}

// PlanVerification represents verification results
type PlanVerification struct {
	Valid       bool     `json:"valid"`
	Errors      []string `json:"errors"`
	Warnings    []string `json:"warnings"`
	Suggestions []string `json:"suggestions"`
}

// PlanProgress represents progress tracking
type PlanProgress struct {
	PlanID                 string        `json:"planId"`
	CurrentStep            int           `json:"currentStep"`
	TotalSteps             int           `json:"totalSteps"`
	CompletedSteps         int           `json:"completedSteps"`
	FailedSteps            int           `json:"failedSteps"`
	PercentComplete        float64       `json:"percentComplete"`
	EstimatedTimeRemaining time.Duration `json:"estimatedTimeRemaining,omitempty"`
}

// PlanningConfig configures the planner
type PlanningConfig struct {
	MaxSteps      int  `json:"maxSteps"`
	MaxDepth      int  `json:"maxDepth"`
	VerifyPlans   bool `json:"verifyPlans"`
	TrackProgress bool `json:"trackProgress"`
	OnProgress    func(progress PlanProgress)
}

// Planner handles task decomposition and plan management
type Planner struct {
	config      PlanningConfig
	activePlans map[string]*ExecutionPlan
	mu          sync.RWMutex
}

// NewPlanner creates a new planner
func NewPlanner(config PlanningConfig) *Planner {
	if config.MaxSteps == 0 {
		config.MaxSteps = 20
	}
	if config.MaxDepth == 0 {
		config.MaxDepth = 5
	}

	return &Planner{
		config:      config,
		activePlans: make(map[string]*ExecutionPlan),
	}
}

// Plan generates an execution plan from a goal
func (p *Planner) Plan(goal string, availableTools []string) (*ExecutionPlan, error) {
	planID := p.generatePlanID()

	// Decompose goal into steps
	steps := p.decompose(goal, availableTools)

	plan := &ExecutionPlan{
		ID:        planID,
		Goal:      goal,
		Steps:     steps,
		Status:    PlanStatusPending,
		CreatedAt: time.Now(),
		Metadata: PlanMetadata{
			TotalSteps: len(steps),
		},
	}

	// Verify plan if enabled
	if p.config.VerifyPlans {
		verification := p.Verify(plan, availableTools)
		if !verification.Valid {
			return nil, fmt.Errorf("invalid plan: %s", strings.Join(verification.Errors, ", "))
		}
	}

	// Store plan
	p.mu.Lock()
	p.activePlans[planID] = plan
	p.mu.Unlock()

	return plan, nil
}

// decompose breaks down a goal into steps
func (p *Planner) decompose(goal string, availableTools []string) []PlanStep {
	steps := make([]PlanStep, 0)
	goalLower := strings.ToLower(goal)

	// Check for research/investigation tasks
	if strings.Contains(goalLower, "investigate") || strings.Contains(goalLower, "analyze") {
		steps = append(steps, PlanStep{
			ID:           p.generateStepID(),
			Description:  fmt.Sprintf("Gather information about: %s", goal),
			Tools:        p.filterTools(availableTools, []string{"search", "get", "read", "list", "fetch"}),
			Dependencies: []string{},
			Status:       PlanStatusPending,
			Retries:      0,
		})

		steps = append(steps, PlanStep{
			ID:           p.generateStepID(),
			Description:  "Analyze gathered information",
			Tools:        []string{},
			Dependencies: []string{steps[0].ID},
			Status:       PlanStatusPending,
			Retries:      0,
		})
	}

	// Check for creation/building tasks
	if strings.Contains(goalLower, "create") || strings.Contains(goalLower, "build") || strings.Contains(goalLower, "implement") {
		steps = append(steps, PlanStep{
			ID:           p.generateStepID(),
			Description:  "Plan implementation approach",
			Tools:        []string{},
			Dependencies: []string{},
			Status:       PlanStatusPending,
			Retries:      0,
		})

		steps = append(steps, PlanStep{
			ID:           p.generateStepID(),
			Description:  "Implement the solution",
			Tools:        p.filterTools(availableTools, []string{"create", "write", "update", "execute"}),
			Dependencies: []string{steps[0].ID},
			Status:       PlanStatusPending,
			Retries:      0,
		})
	}

	// Check for response/remediation tasks
	if strings.Contains(goalLower, "respond") || strings.Contains(goalLower, "fix") || strings.Contains(goalLower, "remediate") {
		steps = append(steps, PlanStep{
			ID:           p.generateStepID(),
			Description:  "Assess the situation",
			Tools:        p.filterTools(availableTools, []string{"get", "read", "list"}),
			Dependencies: []string{},
			Status:       PlanStatusPending,
			Retries:      0,
		})

		steps = append(steps, PlanStep{
			ID:           p.generateStepID(),
			Description:  "Execute remediation actions",
			Tools:        p.filterTools(availableTools, []string{"update", "delete", "execute", "apply"}),
			Dependencies: []string{steps[0].ID},
			Status:       PlanStatusPending,
			Retries:      0,
		})

		steps = append(steps, PlanStep{
			ID:           p.generateStepID(),
			Description:  "Verify remediation success",
			Tools:        p.filterTools(availableTools, []string{"get", "read", "check", "verify"}),
			Dependencies: []string{steps[1].ID},
			Status:       PlanStatusPending,
			Retries:      0,
		})
	}

	// Default generic plan
	if len(steps) == 0 {
		steps = append(steps, PlanStep{
			ID:           p.generateStepID(),
			Description:  goal,
			Tools:        availableTools,
			Dependencies: []string{},
			Status:       PlanStatusPending,
			Retries:      0,
		})
	}

	return steps
}

// filterTools filters tools by keywords
func (p *Planner) filterTools(availableTools []string, keywords []string) []string {
	if len(keywords) == 0 {
		return availableTools
	}

	filtered := make([]string, 0)
	for _, tool := range availableTools {
		toolLower := strings.ToLower(tool)
		for _, keyword := range keywords {
			if strings.Contains(toolLower, keyword) {
				filtered = append(filtered, tool)
				break
			}
		}
	}
	return filtered
}

// Verify checks if a plan is valid
func (p *Planner) Verify(plan *ExecutionPlan, availableTools []string) PlanVerification {
	errors := make([]string, 0)
	warnings := make([]string, 0)
	suggestions := make([]string, 0)

	// Check for empty plan
	if len(plan.Steps) == 0 {
		errors = append(errors, "Plan has no steps")
	}

	// Check step count
	if len(plan.Steps) > p.config.MaxSteps {
		warnings = append(warnings, fmt.Sprintf("Plan has %d steps, exceeds recommended maximum", len(plan.Steps)))
	}

	// Check for circular dependencies
	visited := make(map[string]bool)
	recStack := make(map[string]bool)

	for _, step := range plan.Steps {
		if p.hasCircularDependency(step, plan.Steps, visited, recStack) {
			errors = append(errors, fmt.Sprintf("Circular dependency detected involving step %s", step.ID))
		}
	}

	// Check for missing dependencies
	stepIDs := make(map[string]bool)
	for _, step := range plan.Steps {
		stepIDs[step.ID] = true
	}

	for _, step := range plan.Steps {
		for _, dep := range step.Dependencies {
			if !stepIDs[dep] {
				errors = append(errors, fmt.Sprintf("Step %s depends on non-existent step %s", step.ID, dep))
			}
		}
	}

	// Check for unavailable tools
	toolSet := make(map[string]bool)
	for _, tool := range availableTools {
		toolSet[tool] = true
	}

	for _, step := range plan.Steps {
		for _, tool := range step.Tools {
			if !toolSet[tool] {
				warnings = append(warnings, fmt.Sprintf("Step %s requires unavailable tool: %s", step.ID, tool))
			}
		}
	}

	// Generate suggestions
	if len(plan.Steps) == 1 {
		suggestions = append(suggestions, "Consider breaking down the goal into smaller steps")
	}

	return PlanVerification{
		Valid:       len(errors) == 0,
		Errors:      errors,
		Warnings:    warnings,
		Suggestions: suggestions,
	}
}

// hasCircularDependency checks for circular dependencies using DFS
func (p *Planner) hasCircularDependency(step PlanStep, allSteps []PlanStep, visited, recStack map[string]bool) bool {
	if recStack[step.ID] {
		return true
	}
	if visited[step.ID] {
		return false
	}

	visited[step.ID] = true
	recStack[step.ID] = true

	for _, depID := range step.Dependencies {
		for _, depStep := range allSteps {
			if depStep.ID == depID {
				if p.hasCircularDependency(depStep, allSteps, visited, recStack) {
					return true
				}
			}
		}
	}

	recStack[step.ID] = false
	return false
}

// GetNextStep returns the next executable step
func (p *Planner) GetNextStep(plan *ExecutionPlan) *PlanStep {
	for i := range plan.Steps {
		step := &plan.Steps[i]
		if step.Status != PlanStatusPending {
			continue
		}

		// Check if all dependencies are completed
		depsComplete := true
		for _, depID := range step.Dependencies {
			depComplete := false
			for _, s := range plan.Steps {
				if s.ID == depID && s.Status == PlanStatusCompleted {
					depComplete = true
					break
				}
			}
			if !depComplete {
				depsComplete = false
				break
			}
		}

		if depsComplete {
			return step
		}
	}

	return nil
}

// GetExecutableSteps returns all steps with satisfied dependencies
func (p *Planner) GetExecutableSteps(plan *ExecutionPlan) []PlanStep {
	executable := make([]PlanStep, 0)

	for i := range plan.Steps {
		step := &plan.Steps[i]
		if step.Status != PlanStatusPending {
			continue
		}

		depsComplete := true
		for _, depID := range step.Dependencies {
			depComplete := false
			for _, s := range plan.Steps {
				if s.ID == depID && s.Status == PlanStatusCompleted {
					depComplete = true
					break
				}
			}
			if !depComplete {
				depsComplete = false
				break
			}
		}

		if depsComplete {
			executable = append(executable, *step)
		}
	}

	return executable
}

// StartStep marks a step as started
func (p *Planner) StartStep(plan *ExecutionPlan, stepID string) {
	plan.mu.Lock()
	defer plan.mu.Unlock()

	for i := range plan.Steps {
		if plan.Steps[i].ID == stepID {
			plan.Steps[i].Status = PlanStatusInProgress
			now := time.Now()
			plan.Steps[i].StartedAt = &now

			if plan.Status == PlanStatusPending {
				plan.Status = PlanStatusInProgress
				plan.StartedAt = &now
			}
			break
		}
	}

	p.updateProgress(plan)
}

// CompleteStep marks a step as completed
func (p *Planner) CompleteStep(plan *ExecutionPlan, stepID string, result interface{}) {
	plan.mu.Lock()
	defer plan.mu.Unlock()

	for i := range plan.Steps {
		if plan.Steps[i].ID == stepID {
			plan.Steps[i].Status = PlanStatusCompleted
			now := time.Now()
			plan.Steps[i].CompletedAt = &now
			plan.Steps[i].Result = result
			plan.Metadata.CompletedSteps++
			break
		}
	}

	p.updateProgress(plan)
	p.checkPlanCompletion(plan)
}

// FailStep marks a step as failed
func (p *Planner) FailStep(plan *ExecutionPlan, stepID string, errMsg string) {
	plan.mu.Lock()
	defer plan.mu.Unlock()

	for i := range plan.Steps {
		if plan.Steps[i].ID == stepID {
			plan.Steps[i].Status = PlanStatusFailed
			plan.Steps[i].Error = errMsg
			plan.Metadata.FailedSteps++
			break
		}
	}

	p.updateProgress(plan)
}

// RetryStep retries a failed step
func (p *Planner) RetryStep(plan *ExecutionPlan, stepID string) bool {
	plan.mu.Lock()
	defer plan.mu.Unlock()

	for i := range plan.Steps {
		if plan.Steps[i].ID == stepID && plan.Steps[i].Status == PlanStatusFailed {
			plan.Steps[i].Status = PlanStatusPending
			plan.Steps[i].Error = ""
			plan.Steps[i].Retries++
			plan.Metadata.FailedSteps--
			return true
		}
	}
	return false
}

// updateProgress updates progress tracking
func (p *Planner) updateProgress(plan *ExecutionPlan) {
	if !p.config.TrackProgress {
		return
	}

	progress := PlanProgress{
		PlanID:          plan.ID,
		TotalSteps:      len(plan.Steps),
		CompletedSteps:  plan.Metadata.CompletedSteps,
		FailedSteps:     plan.Metadata.FailedSteps,
		PercentComplete: float64(plan.Metadata.CompletedSteps) / float64(len(plan.Steps)) * 100,
	}

	// Find current step
	for i, step := range plan.Steps {
		if step.Status == PlanStatusInProgress {
			progress.CurrentStep = i + 1
			break
		}
	}

	// Estimate remaining time
	if plan.StartedAt != nil && plan.Metadata.CompletedSteps > 0 {
		elapsed := time.Since(*plan.StartedAt)
		avgStepTime := elapsed / time.Duration(plan.Metadata.CompletedSteps)
		remainingSteps := len(plan.Steps) - plan.Metadata.CompletedSteps
		progress.EstimatedTimeRemaining = avgStepTime * time.Duration(remainingSteps)
	}

	if p.config.OnProgress != nil {
		p.config.OnProgress(progress)
	}
}

// checkPlanCompletion checks if plan is complete
func (p *Planner) checkPlanCompletion(plan *ExecutionPlan) {
	allComplete := true
	hasFailures := false

	for _, step := range plan.Steps {
		if step.Status != PlanStatusCompleted && step.Status != PlanStatusFailed {
			allComplete = false
		}
		if step.Status == PlanStatusFailed {
			hasFailures = true
		}
	}

	if allComplete {
		plan.Status = PlanStatusFailed
		if !hasFailures {
			plan.Status = PlanStatusCompleted
		}
		now := time.Now()
		plan.CompletedAt = &now
	}
}

// GetPlan retrieves a plan by ID
func (p *Planner) GetPlan(planID string) (*ExecutionPlan, bool) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	plan, ok := p.activePlans[planID]
	return plan, ok
}

// CancelPlan cancels a plan
func (p *Planner) CancelPlan(planID string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()

	plan, ok := p.activePlans[planID]
	if !ok {
		return false
	}

	plan.Status = PlanStatusCancelled
	now := time.Now()
	plan.CompletedAt = &now

	for i := range plan.Steps {
		if plan.Steps[i].Status == PlanStatusPending || plan.Steps[i].Status == PlanStatusInProgress {
			plan.Steps[i].Status = PlanStatusCancelled
		}
	}

	return true
}

// generatePlanID creates a unique plan ID
func (p *Planner) generatePlanID() string {
	return fmt.Sprintf("plan_%d_%s", time.Now().UnixNano(), randomString(9))
}

// generateStepID creates a unique step ID
func (p *Planner) generateStepID() string {
	return fmt.Sprintf("step_%d_%s", time.Now().UnixNano(), randomString(9))
}
