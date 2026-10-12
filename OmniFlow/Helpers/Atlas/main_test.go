package main

import (
	"context"
	"encoding/json"
	"io"
	"strings"
	"testing"
	"time"
)

type client struct {
	encoder *json.Encoder
	decoder *json.Decoder
	done    <-chan error
	cancel  context.CancelFunc
}

func newClient(t *testing.T) *client {
	t.Helper()
	parentIn, childOut := io.Pipe()
	childIn, parentOut := io.Pipe()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	done := make(chan error, 1)
	go func() { done <- serve(ctx, childIn, childOut); childOut.Close() }()
	t.Cleanup(func() { cancel(); parentIn.Close(); childIn.Close(); parentOut.Close(); childOut.Close() })
	c := &client{json.NewEncoder(parentOut), json.NewDecoder(parentIn), done, cancel}
	if ready := c.read(t); ready.Type != "ready" || ready.Version != protocolVersion {
		t.Fatal("missing handshake")
	}
	return c
}

func (c *client) read(t *testing.T) frame {
	t.Helper()
	var f frame
	if err := c.decoder.Decode(&f); err != nil {
		t.Fatal(err)
	}
	return f
}
func (c *client) write(t *testing.T, f frame) {
	t.Helper()
	f.Version = protocolVersion
	f.RequestID = "test-request"
	if err := c.encoder.Encode(f); err != nil {
		t.Fatal(err)
	}
}
func (c *client) start(t *testing.T) {
	c.write(t, frame{Type: "start", Prompt: "What is the local fixture label?", Tools: []toolDefinition{
		{Name: "getMacContext", InputSchemaJSON: `{"type":"object"}`},
		{Name: "inspectLocalFiles", InputSchemaJSON: `{"type":"object"}`},
	}})
}

func TestRealAtlasToolLoop(t *testing.T) {
	c := newClient(t)
	c.start(t)
	f := c.read(t)
	if f.Type != "model" || f.Step != 1 || len(f.Messages) != 1 {
		t.Fatal("initial model call missing")
	}
	c.write(t, frame{Type: "reply", ID: f.ID, ToolCalls: []toolCall{{Name: "inspectLocalFiles", ArgumentsJSON: `{"operation":"read","path":"/local-fixture"}`}}})
	f = c.read(t)
	if f.Type != "tool" || f.Tool != "inspectLocalFiles" {
		t.Fatal("Atlas did not dispatch the tool")
	}
	c.write(t, frame{Type: "reply", ID: f.ID, Content: "private fixture label: persimmon"})
	event := c.read(t)
	if event.Type != "event" || !event.Success || event.Content != "" || event.ArgumentsJSON != "" {
		t.Fatal("content leaked into event")
	}
	f = c.read(t)
	if f.Type != "model" || f.Step != 2 || !strings.Contains(f.Messages[len(f.Messages)-1].Content, "persimmon") {
		t.Fatal("tool evidence did not return to the model")
	}
	c.write(t, frame{Type: "reply", ID: f.ID, Content: "The label is persimmon."})
	f = c.read(t)
	if f.Type != "done" || f.ToolCount != 1 || f.Steps != 2 || f.StopReason != "stop" {
		t.Fatal("incorrect Atlas result")
	}
	if err := <-c.done; err != nil {
		t.Fatal(err)
	}
}

func TestUnknownToolsCannotReachHost(t *testing.T) {
	for _, name := range []string{"web_search", "run_shell_command", "write_file", "unknown"} {
		t.Run(name, func(t *testing.T) {
			c := newClient(t)
			c.start(t)
			f := c.read(t)
			c.write(t, frame{Type: "reply", ID: f.ID, ToolCalls: []toolCall{{Name: name, ArgumentsJSON: `{}`}}})
			if err := <-c.done; err == nil || !strings.Contains(err.Error(), "tool_denied") {
				t.Fatal("unregistered tool was not denied")
			}
		})
	}
}

func TestStepLimitRequiresFinalAnswer(t *testing.T) {
	c := newClient(t)
	c.start(t)
	for step := 1; step <= maxSteps; step++ {
		f := c.read(t)
		if f.Type != "model" || f.Step != step || f.FinalStep != (step == maxSteps) {
			t.Fatal("step budget not enforced")
		}
		if f.FinalStep {
			c.write(t, frame{Type: "reply", ID: f.ID, Content: "Here is the bounded result."})
			break
		}
		c.write(t, frame{Type: "reply", ID: f.ID, ToolCalls: []toolCall{{Name: "getMacContext", ArgumentsJSON: `{"topic":"system"}`}}})
		f = c.read(t)
		c.write(t, frame{Type: "reply", ID: f.ID, Content: "local evidence"})
		_ = c.read(t) // content-free tool event
	}
	result := c.read(t)
	if result.Steps != maxSteps || result.ToolCount != maxSteps-1 {
		t.Fatal("Atlas exceeded its budget")
	}
	if err := <-c.done; err != nil {
		t.Fatal(err)
	}
}

func TestCancelAndMismatchedReply(t *testing.T) {
	for _, cancel := range []bool{false, true} {
		c := newClient(t)
		c.start(t)
		_ = c.read(t)
		if cancel {
			c.cancel()
		} else {
			c.write(t, frame{Type: "reply", ID: "stale-callback", Content: "ignored"})
		}
		select {
		case err := <-c.done:
			if err == nil {
				t.Fatal("invalid run succeeded")
			}
		case <-time.After(time.Second):
			t.Fatal("cancel or protocol failure hung")
		}
	}
}

func TestMalformedAndOversizedInput(t *testing.T) {
	for _, input := range []string{"not json\n", strings.Repeat("x", maxFrameBytes+1)} {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		err := serve(ctx, strings.NewReader(input), io.Discard)
		cancel()
		if err == nil {
			t.Fatal("invalid input accepted")
		}
	}
}
