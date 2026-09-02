package tailscale

import (
	"errors"
	"strings"
	"testing"
)

func TestParseVersion(t *testing.T) {
	tests := []struct {
		name            string
		output          string
		requireUpstream bool
		current         string
		latest          string
		wantErr         bool
	}{
		{
			name:            "current and upstream",
			output:          `{"majorMinorPatch":"1.94.2","upstream":"1.102.3"}`,
			requireUpstream: true,
			current:         "1.94.2",
			latest:          "1.102.3",
		},
		{
			name:    "current only",
			output:  `{"majorMinorPatch":"1.102.3"}`,
			current: "1.102.3",
		},
		{
			name:            "warning before json",
			output:          "warning from platform integration\n{\"majorMinorPatch\":\"1.94.2\",\"upstream\":\"1.102.3\"}",
			requireUpstream: true,
			current:         "1.94.2",
			latest:          "1.102.3",
		},
		{
			name:    "invalid json",
			output:  "not json",
			wantErr: true,
		},
		{
			name:    "missing current",
			output:  `{"upstream":"1.102.3"}`,
			wantErr: true,
		},
		{
			name:            "missing required upstream",
			output:          `{"majorMinorPatch":"1.94.2"}`,
			requireUpstream: true,
			wantErr:         true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			version, err := parseVersion([]byte(tt.output), tt.requireUpstream)
			if tt.wantErr {
				if err == nil {
					t.Fatal("parseVersion() error = nil, want error")
				}
				return
			}
			if err != nil {
				t.Fatalf("parseVersion() error = %v", err)
			}
			if version.Current != tt.current || version.Latest != tt.latest {
				t.Fatalf("parseVersion() = %+v, want current=%q latest=%q", version, tt.current, tt.latest)
			}
		})
	}
}

func TestCommandErrorLimitsOutput(t *testing.T) {
	err := commandError("update tailscale", []byte(strings.Repeat("x", 4096)), errors.New("failed"))
	if len(err.Error()) > 2100 {
		t.Fatalf("commandError() returned an unexpectedly long error: %d bytes", len(err.Error()))
	}
}
