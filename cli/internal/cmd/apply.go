package cmd

import (
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/BinaryBourbon/fountain/cli/internal/api"
	"github.com/BinaryBourbon/fountain/cli/internal/manifest"
	"github.com/BinaryBourbon/fountain/cli/internal/output"
	"github.com/BinaryBourbon/fountain/cli/internal/secrets"
	"github.com/BinaryBourbon/fountain/cli/internal/substitution"
	"github.com/spf13/cobra"
)

func init() {
	applyCmd := &cobra.Command{
		Use:   "apply",
		Short: "Apply resource definitions from a YAML file or directory",
		RunE:  runApply,
	}
	applyCmd.Flags().StringP("file", "f", "", "path to YAML file or directory")
	applyCmd.Flags().StringSlice("var", nil, "extra variable for ${VAR} substitution (KEY=VAL, repeatable)")
	rootCmd.AddCommand(applyCmd)
}

func runApply(cmd *cobra.Command, args []string) error {
	path, _ := cmd.Flags().GetString("file")
	if path == "" && len(args) > 0 {
		path = args[0]
	}
	if path == "" {
		Fatal("usage: fountain apply -f <path-to-yaml> [--var KEY=VAL ...]")
	}

	varFlags, _ := cmd.Flags().GetStringSlice("var")
	applyVars := buildApplyVars(varFlags)

	docs, err := manifest.Read(path)
	if err != nil {
		Fatal(err.Error())
	}

	envs, vaults, agents, unknown := groupDocs(docs)
	if len(unknown) > 0 {
		names := make([]string, len(unknown))
		for i, d := range unknown {
			names[i] = d.Kind
		}
		Fatalf("unsupported kinds in %s: %s", path, strings.Join(names, ", "))
	}

	envs, vaults = expandApplySecrets(envs, vaults, applyVars)

	c := activeClient()
	envIDByName := map[string]string{}
	anyFailed := false

	for _, d := range envs {
		if envID, ok := applyEnvironment(c, d); ok {
			envIDByName[d.Name()] = envID
		} else {
			anyFailed = true
		}
	}

	for _, d := range vaults {
		if !applyVault(c, d) {
			anyFailed = true
		}
	}

	for _, d := range agents {
		if !applyAgent(c, d, envIDByName) {
			anyFailed = true
		}
	}

	if anyFailed {
		os.Exit(1)
	}
	return nil
}

// ── grouping ───────────────────────────────────────────────────────────

func groupDocs(docs []*manifest.Doc) (envs, vaults, agents, unknown []*manifest.Doc) {
	for _, d := range docs {
		switch d.Kind {
		case "Environment":
			envs = append(envs, d)
		case "Vault":
			vaults = append(vaults, d)
		case "Agent":
			agents = append(agents, d)
		default:
			unknown = append(unknown, d)
		}
	}
	return
}

// ── apply-time secret resolution ───────────────────────────────────────

func buildApplyVars(varFlags []string) map[string]string {
	out := map[string]string{}
	for _, kv := range os.Environ() {
		if eq := strings.IndexByte(kv, '='); eq > 0 {
			out[kv[:eq]] = kv[eq+1:]
		}
	}
	for _, kv := range varFlags {
		eq := strings.IndexByte(kv, '=')
		if eq <= 0 {
			Fatalf("--var must be KEY=VALUE, got: %q", kv)
		}
		out[kv[:eq]] = kv[eq+1:]
	}
	return out
}

// expandApplySecrets runs the two-phase resolution (substitution then
// external refs) across both env and vault doc lists, collecting all
// failures across both before exiting. Returns the same docs with
// `spec.secrets` rewritten in place.
func expandApplySecrets(envs, vaults []*manifest.Doc, vars map[string]string) ([]*manifest.Doc, []*manifest.Doc) {
	all := append([]*manifest.Doc{}, envs...)
	all = append(all, vaults...)

	substErrors := map[string][]string{}
	for _, d := range all {
		if err := substituteDocSecrets(d, vars); err != nil {
			if me, ok := err.(*substitution.MissingVarsError); ok {
				substErrors[d.Name()] = me.Missing
			}
		}
	}
	if len(substErrors) > 0 {
		Fatal(formatMissingVars(substErrors))
	}

	resolverErrors := map[string][]resolverFailure{}
	for _, d := range all {
		if fails := resolveDocExternalRefs(d, secrets.Default); len(fails) > 0 {
			resolverErrors[d.Name()] = fails
		}
	}
	if len(resolverErrors) > 0 {
		Fatal(formatResolverFailures(resolverErrors))
	}

	return envs, vaults
}

func substituteDocSecrets(d *manifest.Doc, vars map[string]string) error {
	if d.Spec == nil {
		return nil
	}
	raw, ok := d.Spec["secrets"]
	if !ok {
		return nil
	}
	subbed, err := substitution.Apply(raw, vars)
	if err != nil {
		return err
	}
	d.Spec["secrets"] = subbed
	return nil
}

type resolverFailure struct {
	Key   string
	Ref   string
	Mod   secrets.Resolver
	Err   error
	Empty bool
}

func resolveDocExternalRefs(d *manifest.Doc, resolvers []secrets.Resolver) []resolverFailure {
	if d.Spec == nil {
		return nil
	}
	raw, ok := d.Spec["secrets"]
	if !ok {
		return nil
	}
	secMap, ok := raw.(map[string]any)
	if !ok {
		return nil
	}
	var fails []resolverFailure
	resolved := make(map[string]any, len(secMap))

	keys := sortedKeys(secMap)
	for _, k := range keys {
		v := secMap[k]
		s, isStr := v.(string)
		if !isStr {
			resolved[k] = v
			continue
		}
		mod := secrets.ForValue(s, resolvers)
		if mod == nil {
			resolved[k] = v
			continue
		}
		plaintext, err := mod.Read(s)
		if err != nil {
			fails = append(fails, resolverFailure{Key: k, Ref: s, Mod: mod, Err: err})
			continue
		}
		if plaintext == "" {
			// An empty value back from an external CLI nearly always means
			// "secret not found" — surface as a failure rather than silently
			// writing "" and letting the API 422 us later.
			fails = append(fails, resolverFailure{Key: k, Ref: s, Mod: mod, Empty: true})
			continue
		}
		resolved[k] = plaintext
	}
	d.Spec["secrets"] = resolved
	return fails
}

func formatMissingVars(perDoc map[string][]string) string {
	var b strings.Builder
	b.WriteString("apply-time substitution failed — set these in the env or pass --var KEY=VAL:\n")
	for _, name := range sortedStringKeys(perDoc) {
		fmt.Fprintf(&b, "  %s: %s\n", name, strings.Join(perDoc[name], ", "))
	}
	return strings.TrimRight(b.String(), "\n")
}

func formatResolverFailures(perDoc map[string][]resolverFailure) string {
	var b strings.Builder
	b.WriteString("apply-time secret resolution failed:\n")
	for _, name := range sortedStringKeys(perDoc) {
		fmt.Fprintf(&b, "  %s:\n", name)
		for _, f := range perDoc[name] {
			msg := ""
			if f.Empty {
				msg = "resolver returned an empty value (secret missing or wrong env/path?)"
			} else {
				msg = f.Mod.FormatError(f.Err)
			}
			fmt.Fprintf(&b, "    %s (%s): %s\n", f.Key, f.Ref, msg)
		}
	}
	return strings.TrimRight(b.String(), "\n")
}

func sortedStringKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func sortedKeys(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// ── reconciliation ─────────────────────────────────────────────────────

func applyEnvironment(c *api.Client, d *manifest.Doc) (string, bool) {
	name := requireName(d)
	body, secretsMap := buildBody(d, name)

	existing := fetchByName(c, "/environments", name)
	var env map[string]any
	if existing != nil {
		id := output.ToString(existing["id"])
		var resp struct {
			Data map[string]any `json:"data"`
		}
		if err := c.Put("/environments/"+id, body, &resp); err != nil {
			warnf("env  !  %s (update failed): %v", name, err)
			return "", false
		}
		fmt.Printf("env  ~  %s\n", name)
		env = resp.Data
	} else {
		var resp struct {
			Data map[string]any `json:"data"`
		}
		if err := c.Post("/environments", body, &resp); err != nil {
			warnf("env  !  %s (create failed): %v", name, err)
			return "", false
		}
		fmt.Printf("env  +  %s\n", name)
		env = resp.Data
	}

	envID := output.ToString(env["id"])
	if envID == "" {
		warnf("env  !  %s: missing id in response", name)
		return "", false
	}
	upsertSecrets(c, "/environments/"+envID+"/secrets", name, secretsMap)
	return envID, true
}

func applyVault(c *api.Client, d *manifest.Doc) bool {
	name := requireName(d)
	body, secretsMap := buildBody(d, name)

	existing := fetchByName(c, "/vaults", name)
	var v map[string]any
	if existing != nil {
		id := output.ToString(existing["id"])
		var resp struct {
			Data map[string]any `json:"data"`
		}
		if err := c.Put("/vaults/"+id, body, &resp); err != nil {
			warnf("vault  !  %s (update failed): %v", name, err)
			return false
		}
		fmt.Printf("vault  ~  %s\n", name)
		v = resp.Data
	} else {
		var resp struct {
			Data map[string]any `json:"data"`
		}
		if err := c.Post("/vaults", body, &resp); err != nil {
			warnf("vault  !  %s (create failed): %v", name, err)
			return false
		}
		fmt.Printf("vault  +  %s\n", name)
		v = resp.Data
	}

	vaultID := output.ToString(v["id"])
	if vaultID == "" {
		warnf("vault  !  %s: missing id in response", name)
		return false
	}
	upsertSecrets(c, "/vaults/"+vaultID+"/secrets", name, secretsMap)
	return true
}

func applyAgent(c *api.Client, d *manifest.Doc, envIDByName map[string]string) bool {
	name := requireName(d)
	spec := cloneMap(d.Spec)

	if envName, ok := spec["environment"].(string); ok && envName != "" {
		if id, ok := envIDByName[envName]; ok {
			delete(spec, "environment")
			spec["environment_id"] = id
		} else {
			warnf("agent  ?  %s: environment '%s' not in this manifest, skipping reference", name, envName)
			delete(spec, "environment")
		}
	} else {
		delete(spec, "environment")
	}

	body := spec
	body["name"] = name

	existing := fetchByName(c, "/agents", name)
	if existing != nil {
		id := output.ToString(existing["id"])
		if err := c.Put("/agents/"+id, body, nil); err != nil {
			warnf("agent  !  %s (update failed): %v", name, err)
			return false
		}
		fmt.Printf("agent  ~  %s\n", name)
	} else {
		if err := c.Post("/agents", body, nil); err != nil {
			warnf("agent  !  %s (create failed): %v", name, err)
			return false
		}
		fmt.Printf("agent  +  %s\n", name)
	}
	return true
}

// buildBody returns the request body for a resource (spec minus
// `secrets`, with `name` set) and a separate map of secrets to upsert.
//
// Strips ownership fields (user_id, created_by) so a malicious or
// careless manifest can't try to attribute resources to another tenant.
// The server enforces this on its own, but defense-in-depth: don't
// transmit fields the server is just going to drop.
func buildBody(d *manifest.Doc, name string) (map[string]any, map[string]any) {
	body := cloneMap(d.Spec)
	secretsMap, _ := body["secrets"].(map[string]any)
	delete(body, "secrets")
	delete(body, "user_id")
	delete(body, "created_by")
	body["name"] = name
	return body, secretsMap
}

func upsertSecrets(c *api.Client, path, resourceName string, m map[string]any) {
	if len(m) == 0 {
		return
	}
	for _, k := range sortedKeys(m) {
		v := m[k]
		body := map[string]string{
			"key":   k,
			"value": output.ToString(v),
		}
		if err := c.Post(path, body, nil); err != nil {
			warnf("  secret  !  %s/%s: %v", resourceName, k, err)
			continue
		}
		fmt.Printf("  secret  ~  %s/%s\n", resourceName, k)
	}
}

func fetchByName(c *api.Client, collection, name string) map[string]any {
	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get(collection, &resp); err != nil {
		Fatalf("GET %s failed: %v", collection, err)
	}
	for _, row := range resp.Data {
		if output.ToString(row["name"]) == name {
			return row
		}
	}
	return nil
}

func requireName(d *manifest.Doc) string {
	n := d.Name()
	if n == "" {
		Fatalf("resource missing required `metadata.name`: %s/%s", d.APIVersion, d.Kind)
	}
	return n
}

func cloneMap(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	out := make(map[string]any, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

func warnf(format string, a ...any) {
	fmt.Fprintln(os.Stderr, fmt.Sprintf(format, a...))
}
