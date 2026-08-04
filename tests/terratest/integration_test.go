package main

import (
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclparse"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// scenario defines a rendering test case for nomad-pack render
type scenario struct {
	name string
	args []string
}

// splitRenderOutput parses the multi-file output of `nomad-pack render` into a map of filename -> HCL content string.
// `nomad-pack render` prints header markers in the format: `pack-name/file.nomad:\n\n<content>`
func splitRenderOutput(output string) map[string]string {
	files := make(map[string]string)
	lines := strings.Split(output, "\n")

	var currentFile string
	var currentContent []string

	for _, line := range lines {
		if strings.HasSuffix(line, ":") && (strings.Contains(line, "/") || strings.HasSuffix(line, ".nomad:")) {
			if currentFile != "" {
				files[currentFile] = strings.TrimSpace(strings.Join(currentContent, "\n"))
			}
			currentFile = strings.TrimSuffix(strings.TrimSpace(line), ":")
			currentContent = nil
			continue
		}
		if currentFile != "" {
			currentContent = append(currentContent, line)
		}
	}
	if currentFile != "" {
		files[currentFile] = strings.TrimSpace(strings.Join(currentContent, "\n"))
	}
	return files
}

func parseHCL(filename, content string) (*hcl.File, hcl.Diagnostics) {
	parser := hclparse.NewParser()
	return parser.ParseHCL([]byte(content), filename)
}

func runCommand(args ...string) (string, error) {
	cmd := exec.Command("nomad-pack", args...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func TestNomadPackIntegrationScenarios(t *testing.T) {
	t.Parallel()

	repoRoot, err := filepath.Abs("../../")
	require.NoError(t, err, "Failed to determine root pack path")
	packPath := filepath.Join(repoRoot, "packs/openstudio-server")

	scenarios := []scenario{
		{
			name: "default",
			args: []string{"render", packPath},
		},
		{
			name: "vector-disabled",
			args: []string{"render", "--var", "enable_vector_collection=false", packPath},
		},
		{
			name: "custom-images",
			args: []string{
				"render",
				"--var", "web_image=nrel/openstudio-server:3.7.0",
				"--var", "worker_image=nrel/openstudio-server:3.7.0",
				"--var", "rserve_image=nrel/rserve:3.7.0",
				packPath,
			},
		},
		{
			name: "nomad-batch-engine",
			args: []string{
				"render",
				"--var", "batch_engine=nomad_batch",
				"--var", "nomad_batch_datacenter=dc1",
				"--var", "nomad_batch_namespace=default",
				"--var", "nomad_batch_job_name=openstudio-simulation",
				packPath,
			},
		},
		{
			name: "aws-batch-engine",
			args: []string{
				"render",
				"--var", "batch_engine=aws_batch",
				"--var", "aws_region=us-east-1",
				"--var", "aws_batch_job_queue=openstudio-queue",
				"--var", "aws_batch_job_definition=openstudio-worker",
				packPath,
			},
		},
		{
			name: "minimal-dev-var-file",
			args: []string{
				"render",
				"--var-file", filepath.Join(repoRoot, "examples/quickstart/minimal-dev.hcl"),
				packPath,
			},
		},
		{
			name: "production-ha-var-file",
			args: []string{
				"render",
				"--var-file", filepath.Join(repoRoot, "examples/advanced/production-ha.hcl"),
				packPath,
			},
		},
		{
			name: "airgapped-var-file",
			args: []string{
				"render",
				"--var-file", filepath.Join(repoRoot, "examples/advanced/airgapped.hcl"),
				packPath,
			},
		},
		{
			name: "batch-verification-enabled",
			args: []string{
				"render",
				"--var", "enable_batch_verification=true",
				packPath,
			},
		},
		{
			name: "runtime-service-resolution-enabled",
			args: []string{
				"render",
				"--var", "web_worker_runtime_service_resolution_enabled=true",
				packPath,
			},
		},
		{
			name: "stall-watchdog-only-schedule",
			args: []string{
				"render",
				"--var", "enable_queue_sweeper=false",
				"--var", "enable_stall_watchdog=true",
				packPath,
			},
		},
		{
			name: "runtime-discovery-canary-test-enabled",
			args: []string{
				"render",
				"--var", "enable_runtime_discovery_canary_test=true",
				packPath,
			},
		},
	}

	for _, sc := range scenarios {
		sc := sc
		t.Run(sc.name, func(t *testing.T) {
			t.Parallel()

			output, err := runCommand(sc.args...)
			require.NoError(t, err, "nomad-pack render failed for scenario %s: %s", sc.name, output)
			require.NotEmpty(t, output, "Render output should not be empty for scenario %s", sc.name)

			renderedFiles := splitRenderOutput(output)
			require.NotEmpty(t, renderedFiles, "Should have rendered at least one template for scenario %s", sc.name)

			for filename, content := range renderedFiles {
				if strings.TrimSpace(content) == "" {
					continue
				}
				_, diags := parseHCL(filename, content)
				assert.False(t, diags.HasErrors(), "HCL parse errors in %s (%s): %s", filename, sc.name, diags.Error())
			}

			// Scenario-specific assertions
			switch sc.name {
			case "default":
				assert.Contains(t, output, `job "openstudio-server-web"`)
				assert.Contains(t, output, `group "web"`)
				assert.Contains(t, output, `group "web-background"`)
				assert.Contains(t, output, `group "worker"`)
				assert.Contains(t, output, `job "openstudio-server-db"`)
				assert.Contains(t, output, `job "openstudio-server-redis"`)
				assert.Contains(t, output, `job "openstudio-server-rserve"`)
				assert.Contains(t, output, `task "vector"`)
				assert.Contains(t, output, `{{ range $svc := service "openstudio-db" }}`)
				assert.NotContains(t, output, `getent hosts`)
				assert.Contains(t, output, "wait_for_deps_timeout")

			case "vector-disabled":
				assert.NotContains(t, output, `task "vector"`)

			case "custom-images":
				assert.Contains(t, output, "nrel/openstudio-server:3.7.0")
				assert.Contains(t, output, "nrel/rserve:3.7.0")

			case "nomad-batch-engine":
				assert.Contains(t, output, `job "openstudio-server-openstudio-simulation"`)

			case "aws-batch-engine":
				assert.NotContains(t, output, `job "openstudio-server-nomad-batch-worker"`)

			case "batch-verification-enabled":
				assert.Contains(t, output, `job "openstudio-server-batch-verify"`)

			case "runtime-service-resolution-enabled":
				assert.Contains(t, output, "web_runtime_resolve_failed")
				assert.Contains(t, output, "worker_runtime_resolve_failed")

			case "stall-watchdog-only-schedule":
				assert.Contains(t, output, `job "openstudio-server-queue-sweeper"`)
				assert.Contains(t, output, `cron             = "*/15 * * * *"`)
				assert.NotContains(t, output, `job "openstudio-server-stall-watchdog"`)

			case "runtime-discovery-canary-test-enabled":
				assert.Contains(t, output, `task "runtime-discovery-canary"`)
			}
		})
	}
}

func TestQueueSweeperWatchdogCronInvariant(t *testing.T) {
	t.Parallel()

	repoRoot, err := filepath.Abs("../../")
	require.NoError(t, err)
	packPath := filepath.Join(repoRoot, "packs/openstudio-server")

	args := []string{
		"render",
		"--var", "enable_queue_sweeper=true",
		"--var", "enable_stall_watchdog=true",
		"--var", "queue_sweeper_cron=*/2 * * * *",
		"--var", "stall_watchdog_cron=*/15 * * * *",
		packPath,
	}

	output, err := runCommand(args...)
	require.Error(t, err)
	assert.Contains(t, output, "queue_sweeper_cron == stall_watchdog_cron")
}

func TestWorkerStartupDNSResolution(t *testing.T) {
	t.Parallel()

	repoRoot, err := filepath.Abs("../../")
	require.NoError(t, err)
	packPath := filepath.Join(repoRoot, "packs/openstudio-server")

	output, err := runCommand("render", packPath)
	require.NoError(t, err, "nomad-pack render failed: %s", output)

	renderedFiles := splitRenderOutput(output)
	workerSpec, ok := renderedFiles["openstudio-server/worker.nomad"]
	require.True(t, ok, "worker.nomad was not present in render output")
	require.NotEmpty(t, strings.TrimSpace(workerSpec), "worker.nomad render output should not be empty")

	assert.Contains(t, workerSpec, `task "preflight"`)
	assert.Contains(t, workerSpec, `http://$CONSUL_ADDR/v1/health/service/$service?passing=true`)
	assert.Contains(t, workerSpec, `http://$CONSUL_ADDR/v1/catalog/service/$service`)
	assert.Contains(t, workerSpec, `check_service "openstudio-db" "27017"`)
	assert.Contains(t, workerSpec, `check_service "openstudio-redis" "6379"`)
	assert.Contains(t, workerSpec, `check_service "openstudio-rserve" "6311"`)
	assert.Contains(t, workerSpec, `preflight_check service=$service status=pass reason=dns_and_tcp_ok`)
	assert.Contains(t, workerSpec, `preflight_check service=$service status=fail reason=$last_reason`)

	assert.Contains(t, workerSpec, `{{ range $svc := service "openstudio-db" }}{{ $svc.Address }} db`)
	assert.Contains(t, workerSpec, `{{ range $svc := service "openstudio-redis" }}{{ $svc.Address }} queue`)
	assert.Contains(t, workerSpec, `{{ range $svc := service "openstudio-rserve" }}{{ $svc.Address }} rserve`)
	assert.Contains(t, workerSpec, `worker_runtime_service_hosts_applied source=consul_template`)

	assert.NotContains(t, workerSpec, `command -v getent`)
	assert.NotContains(t, workerSpec, `$(getent hosts`)
	assert.NotContains(t, workerSpec, `http://${CONSUL_ADDR}/v1/catalog/service/${service}`)
}

func TestNomadPackPlanScenarios(t *testing.T) {
	t.Parallel()

	// Verify if nomad agent is running locally before attempting plan tests
	checkCmd := exec.Command("nomad", "status")
	if err := checkCmd.Run(); err != nil {
		t.Skip("Nomad agent not running, skipping live nomad-pack plan scenarios")
	}

	repoRoot, err := filepath.Abs("../../")
	require.NoError(t, err)
	packPath := filepath.Join(repoRoot, "packs/openstudio-server")

	planScenarios := []scenario{
		{
			name: "plan-default",
			args: []string{"plan", "--name", "openstudio-server-terratest-plan-default", "--var", "job_name=openstudio-server-terratest-plan-default", packPath},
		},
		{
			name: "plan-minimal-dev",
			args: []string{"plan", "--name", "openstudio-server-terratest-plan-minimal", "--var", "job_name=openstudio-server-terratest-plan-minimal", "--var-file", filepath.Join(repoRoot, "examples/quickstart/minimal-dev.hcl"), packPath},
		},
	}

	for _, sc := range planScenarios {
		sc := sc
		t.Run(sc.name, func(t *testing.T) {
			t.Parallel()

			output, err := runCommand(sc.args...)
			if err != nil {
				if exitErr, ok := err.(*exec.ExitError); ok {
					assert.LessOrEqual(t, exitErr.ExitCode(), 1, "nomad-pack plan exit code for scenario %s: %s", sc.name, output)
				} else {
					t.Fatalf("nomad-pack plan failed for scenario %s: %v", sc.name, err)
				}
			}
			assert.Contains(t, output, "Plan succeeded")
		})
	}
}
