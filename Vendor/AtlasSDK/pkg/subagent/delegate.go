// Package subagent provides delegation tools for subagent execution
package subagent

import (
	"context"
	"sync"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/tools"
)

// DelegateToolOptions configures the delegate tool
type DelegateToolOptions struct {
	// Runner is the SubAgentRunner to use for execution
	Runner *SubAgentRunner
	// DefaultAgentType is used if not specified in tool call
	DefaultAgentType SubAgentType
	// DefaultMaxTurns is used if not specified
	DefaultMaxTurns int
}

// CreateDelegateTool creates a tool that allows agents to spawn subagents
func CreateDelegateTool(opts DelegateToolOptions) tools.Tool {
	defaultType := opts.DefaultAgentType
	if defaultType == "" {
		defaultType = SubAgentTypeGeneral
	}
	defaultMaxTurns := opts.DefaultMaxTurns
	if defaultMaxTurns == 0 {
		defaultMaxTurns = 10
	}

	return tools.Tool{
		Name:        "delegate",
		Description: "Delegate a task to a specialized subagent. Use this to spawn subagents for parallel or specialized work.",
		InputSchema: map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"agent_name": map[string]interface{}{
					"type":        "string",
					"description": "Name for the subagent instance",
				},
				"task": map[string]interface{}{
					"type":        "string",
					"description": "The task to delegate to the subagent",
				},
				"agent_type": map[string]interface{}{
					"type":        "string",
					"enum":        []string{"explore", "general", "plan"},
					"description": "Type of subagent to spawn",
				},
				"max_turns": map[string]interface{}{
					"type":        "number",
					"description": "Maximum number of turns for the subagent",
				},
				"context": map[string]interface{}{
					"type":        "object",
					"description": "Optional context to pass to the subagent",
				},
			},
			"required": []string{"agent_name", "task"},
		},
		Handler: func(ctx context.Context, args map[string]interface{}, toolCtx tools.Context) (interface{}, error) {
			agentName, _ := args["agent_name"].(string)
			task, _ := args["task"].(string)
			agentTypeStr, _ := args["agent_type"].(string)
			maxTurns, _ := args["max_turns"].(float64)
			contextData, _ := args["context"].(map[string]interface{})

			if agentName == "" || task == "" {
				return map[string]interface{}{
					"success": false,
					"error":   "agent_name and task are required",
				}, nil
			}

			agentType := SubAgentType(agentTypeStr)
			if agentType == "" {
				agentType = defaultType
			}
			turns := int(maxTurns)
			if turns == 0 {
				turns = defaultMaxTurns
			}

			// Check if agent is already registered
			agent, _ := opts.Runner.GetAgent(agentName)
			if agent == nil {
				// Create temporary agent config
				agent = &SubAgentConfig{
					Name:     agentName,
					Type:     agentType,
					MaxTurns: turns,
				}
			}

			result, err := opts.Runner.Execute(ctx, agent, SubAgentExecuteOptions{
				Prompt:  task,
				Context: contextData,
			})

			if err != nil {
				return map[string]interface{}{
					"success":   false,
					"agentName": agentName,
					"error":     err.Error(),
				}, nil
			}

			if result.Success {
				return map[string]interface{}{
					"success":   true,
					"agentName": result.AgentName,
					"output":    result.Output,
					"turns":     result.Turns,
				}, nil
			}

			return map[string]interface{}{
				"success":   false,
				"agentName": result.AgentName,
				"error":     result.Error,
				"turns":     result.Turns,
			}, nil
		},
	}
}

// CreateParallelDelegateTool creates a tool that runs multiple subagents in parallel
func CreateParallelDelegateTool(opts DelegateToolOptions) tools.Tool {
	defaultType := opts.DefaultAgentType
	if defaultType == "" {
		defaultType = SubAgentTypeGeneral
	}
	defaultMaxTurns := opts.DefaultMaxTurns
	if defaultMaxTurns == 0 {
		defaultMaxTurns = 10
	}

	return tools.Tool{
		Name:        "delegate_parallel",
		Description: "Delegate tasks to multiple subagents in parallel. Use for concurrent execution of independent tasks.",
		InputSchema: map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"agents": map[string]interface{}{
					"type": "array",
					"items": map[string]interface{}{
						"type": "object",
						"properties": map[string]interface{}{
							"agent_name": map[string]interface{}{"type": "string"},
							"task":       map[string]interface{}{"type": "string"},
							"agent_type": map[string]interface{}{
								"type": "string",
								"enum": []string{"explore", "general", "plan"},
							},
							"max_turns": map[string]interface{}{"type": "number"},
						},
						"required": []string{"agent_name", "task"},
					},
					"description": "Array of agent configurations and tasks",
				},
				"context": map[string]interface{}{
					"type":        "object",
					"description": "Shared context to pass to all subagents",
				},
			},
			"required": []string{"agents"},
		},
		Handler: func(ctx context.Context, args map[string]interface{}, toolCtx tools.Context) (interface{}, error) {
			agentsInput, _ := args["agents"].([]interface{})
			contextData, _ := args["context"].(map[string]interface{})

			if len(agentsInput) == 0 {
				return map[string]interface{}{
					"success": false,
					"error":   "at least one agent is required",
				}, nil
			}

			agents := make([]*SubAgentConfig, len(agentsInput))
			prompts := make([]string, len(agentsInput))
			for i, a := range agentsInput {
				agentMap, ok := a.(map[string]interface{})
				if !ok {
					continue
				}
				name, _ := agentMap["agent_name"].(string)
				task, _ := agentMap["task"].(string)
				agentTypeStr, _ := agentMap["agent_type"].(string)
				maxTurns, _ := agentMap["max_turns"].(float64)

				agentType := SubAgentType(agentTypeStr)
				if agentType == "" {
					agentType = defaultType
				}
				turns := int(maxTurns)
				if turns == 0 {
					turns = defaultMaxTurns
				}

				agents[i] = &SubAgentConfig{
					Name:     name,
					Type:     agentType,
					MaxTurns: turns,
				}
				prompts[i] = task
			}

			// Execute each agent with its own prompt concurrently. Each goroutine
			// writes only to its own index in the pre-sized slice, so there is no
			// shared-slice data race and result ordering is preserved (results[i]
			// corresponds to agents[i]). We keep the delegate's per-agent error
			// contract: failures are embedded in the agent's own result map and the
			// overall call still reports success (unlike Runner.ExecuteParallel,
			// which both shares a single prompt and early-returns on first error).
			results := make([]map[string]interface{}, len(agents))
			var wg sync.WaitGroup
			for i := range agents {
				wg.Add(1)
				go func(idx int) {
					defer wg.Done()
					agent := agents[idx]
					result, err := opts.Runner.Execute(ctx, agent, SubAgentExecuteOptions{
						Prompt:  prompts[idx],
						Context: contextData,
					})
					if err != nil {
						results[idx] = map[string]interface{}{
							"agentName": agent.Name,
							"success":   false,
							"error":     err.Error(),
						}
					} else {
						results[idx] = map[string]interface{}{
							"agentName": result.AgentName,
							"output":    result.Output,
							"success":   result.Success,
							"error":     result.Error,
							"turns":     result.Turns,
						}
					}
				}(i)
			}
			wg.Wait()

			return map[string]interface{}{
				"success": true,
				"results": results,
			}, nil
		},
	}
}
