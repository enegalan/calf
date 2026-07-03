package migration

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

const composeProjectLabel = "com.docker.compose.project"
const composeServiceLabel = "com.docker.compose.service"
const composeWorkingDirLabel = "com.docker.compose.project.working_dir"
const composeConfigFilesLabel = "com.docker.compose.project.config_files"

var composeStageSkipDirs = map[string]struct{}{
	".git":         {},
	"node_modules": {},
	"vendor":       {},
	".next":        {},
	"dist":         {},
	"build":        {},
	"__pycache__":  {},
}

type composeProjectGroup struct {
	Name        string
	WorkingDir  string
	ConfigFiles []string
	Containers  []containerInspect
	WasRunning  map[string]bool
}

func groupContainersByComposeProject(inspects []containerInspect, running map[string]bool) ([]composeProjectGroup, []containerInspect) {
	byProject := make(map[string]*composeProjectGroup)
	standalone := make([]containerInspect, 0)

	for _, inspect := range inspects {
		name := strings.TrimPrefix(inspect.Name, "/")
		project := composeProjectName(inspect)
		if project == "" {
			standalone = append(standalone, inspect)
			continue
		}

		group, ok := byProject[project]
		if !ok {
			group = &composeProjectGroup{
				Name:       project,
				WorkingDir: inspect.Config.Labels[composeWorkingDirLabel],
				WasRunning: make(map[string]bool),
			}
			group.ConfigFiles = composeConfigFiles(inspect)
			byProject[project] = group
		}

		if group.WorkingDir == "" {
			group.WorkingDir = inspect.Config.Labels[composeWorkingDirLabel]
		}
		if len(group.ConfigFiles) == 0 {
			group.ConfigFiles = composeConfigFiles(inspect)
		}

		group.Containers = append(group.Containers, inspect)
		group.WasRunning[name] = running[name]
	}

	groups := make([]composeProjectGroup, 0, len(byProject))
	for _, group := range byProject {
		groups = append(groups, *group)
	}

	sort.Slice(groups, func(i, j int) bool {
		return groups[i].Name < groups[j].Name
	})

	return groups, standalone
}

func composeProjectName(inspect containerInspect) string {
	if inspect.Config.Labels == nil {
		return ""
	}

	return inspect.Config.Labels[composeProjectLabel]
}

func composeConfigFiles(inspect containerInspect) []string {
	if inspect.Config.Labels == nil {
		return nil
	}

	raw := strings.TrimSpace(inspect.Config.Labels[composeConfigFilesLabel])
	if raw == "" {
		return nil
	}

	files := make([]string, 0)
	for _, part := range strings.Split(raw, ",") {
		part = strings.TrimSpace(part)
		if part != "" {
			files = append(files, part)
		}
	}

	return files
}

func composeServiceImages(containers []containerInspect) map[string]string {
	images := make(map[string]string, len(containers))

	for _, inspect := range containers {
		if inspect.Config.Labels == nil {
			continue
		}

		service := inspect.Config.Labels[composeServiceLabel]
		if service == "" || inspect.Config.Image == "" {
			continue
		}

		images[service] = inspect.Config.Image
	}

	return images
}

func stageComposeProject(group composeProjectGroup, mountsRoot string) (string, string, error) {
	if group.WorkingDir == "" {
		return "", "", fmt.Errorf("compose project %s has no working dir", group.Name)
	}

	if _, err := os.Stat(group.WorkingDir); err != nil {
		return "", "", fmt.Errorf("compose working dir %s: %w", group.WorkingDir, err)
	}

	destDir := filepath.Join(mountsRoot, "compose", sanitizeFileName(group.Name))
	if err := os.RemoveAll(destDir); err != nil {
		return "", "", err
	}
	if err := os.MkdirAll(destDir, 0o755); err != nil {
		return "", "", err
	}

	if err := copyDir(group.WorkingDir, destDir); err != nil {
		return "", "", err
	}

	composePath, err := resolveComposeFile(group, destDir)
	if err != nil {
		return "", "", err
	}

	serviceImages := composeServiceImages(group.Containers)
	if err := patchComposeForMigration(composePath, serviceImages); err != nil {
		return "", "", err
	}

	if err := patchComposeServiceEnv(composePath, group.Containers); err != nil {
		return "", "", err
	}

	vmDir := VMPath(destDir)
	vmComposePath := VMPath(composePath)
	return vmDir, vmComposePath, nil
}

func resolveComposeFile(group composeProjectGroup, destDir string) (string, error) {
	candidates := make([]string, 0, len(group.ConfigFiles)+4)

	for _, configFile := range group.ConfigFiles {
		rel, err := filepath.Rel(group.WorkingDir, configFile)
		if err == nil && !strings.HasPrefix(rel, "..") {
			candidates = append(candidates, filepath.Join(destDir, rel))
			continue
		}

		if _, err := os.Stat(configFile); err == nil {
			base := filepath.Base(configFile)
			dest := filepath.Join(destDir, base)
			if err := copyFile(configFile, dest); err != nil {
				return "", err
			}
			candidates = append(candidates, dest)
		}
	}

	for _, name := range []string{"docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"} {
		candidates = append(candidates, filepath.Join(destDir, name))
	}

	for _, candidate := range candidates {
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		}
	}

	return "", fmt.Errorf("compose file not found for project %s", group.Name)
}

func patchComposeForMigration(composePath string, serviceImages map[string]string) error {
	if len(serviceImages) == 0 {
		return nil
	}

	data, err := os.ReadFile(composePath)
	if err != nil {
		return err
	}

	var root yaml.Node
	if err := yaml.Unmarshal(data, &root); err != nil {
		return err
	}

	servicesNode := findComposeServicesNode(&root)
	if servicesNode == nil || servicesNode.Kind != yaml.MappingNode {
		return nil
	}

	for index := 0; index < len(servicesNode.Content); index += 2 {
		serviceName := servicesNode.Content[index].Value
		serviceNode := servicesNode.Content[index+1]
		image, ok := serviceImages[serviceName]
		if !ok || image == "" {
			continue
		}

		removeComposeMappingKey(serviceNode, "build")
		setComposeMappingValue(serviceNode, "image", image)
	}

	patched, err := yaml.Marshal(&root)
	if err != nil {
		return err
	}

	return os.WriteFile(composePath, patched, 0o644)
}

func patchComposeServiceEnv(composePath string, containers []containerInspect) error {
	serviceEnv := make(map[string][]string)
	for _, inspect := range containers {
		if inspect.Config.Labels == nil || len(inspect.Config.Env) == 0 {
			continue
		}

		service := inspect.Config.Labels[composeServiceLabel]
		if service == "" {
			continue
		}

		serviceEnv[service] = inspect.Config.Env
	}

	if len(serviceEnv) == 0 {
		return nil
	}

	data, err := os.ReadFile(composePath)
	if err != nil {
		return err
	}

	var root yaml.Node
	if err := yaml.Unmarshal(data, &root); err != nil {
		return err
	}

	servicesNode := findComposeServicesNode(&root)
	if servicesNode == nil || servicesNode.Kind != yaml.MappingNode {
		return nil
	}

	for index := 0; index < len(servicesNode.Content); index += 2 {
		serviceName := servicesNode.Content[index].Value
		env, ok := serviceEnv[serviceName]
		if !ok {
			continue
		}

		setComposeMappingValueList(servicesNode.Content[index+1], "environment", env)
	}

	patched, err := yaml.Marshal(&root)
	if err != nil {
		return err
	}

	return os.WriteFile(composePath, patched, 0o644)
}

func setComposeMappingValueList(serviceNode *yaml.Node, key string, values []string) {
	if serviceNode == nil || serviceNode.Kind != yaml.MappingNode {
		return
	}

	listNode := &yaml.Node{
		Kind: yaml.SequenceNode,
	}

	for _, value := range values {
		listNode.Content = append(listNode.Content, &yaml.Node{
			Kind:  yaml.ScalarNode,
			Tag:   "!!str",
			Value: value,
		})
	}

	for index := 0; index < len(serviceNode.Content); index += 2 {
		if serviceNode.Content[index].Value == key {
			serviceNode.Content[index+1] = listNode
			return
		}
	}

	serviceNode.Content = append(serviceNode.Content,
		&yaml.Node{Kind: yaml.ScalarNode, Value: key},
		listNode,
	)
}

func findComposeServicesNode(root *yaml.Node) *yaml.Node {
	if root == nil {
		return nil
	}

	if root.Kind == yaml.MappingNode {
		for index := 0; index < len(root.Content); index += 2 {
			if root.Content[index].Value == "services" {
				return root.Content[index+1]
			}
		}
	}

	for _, node := range root.Content {
		if found := findComposeServicesNode(node); found != nil {
			return found
		}
	}

	return nil
}

func removeComposeMappingKey(serviceNode *yaml.Node, key string) {
	if serviceNode == nil || serviceNode.Kind != yaml.MappingNode {
		return
	}

	for index := 0; index < len(serviceNode.Content); index += 2 {
		if serviceNode.Content[index].Value != key {
			continue
		}

		serviceNode.Content = append(serviceNode.Content[:index], serviceNode.Content[index+2:]...)
		return
	}
}

func setComposeMappingValue(serviceNode *yaml.Node, key, value string) {
	if serviceNode == nil || serviceNode.Kind != yaml.MappingNode {
		return
	}

	for index := 0; index < len(serviceNode.Content); index += 2 {
		if serviceNode.Content[index].Value == key {
			serviceNode.Content[index+1] = &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: value}
			return
		}
	}

	serviceNode.Content = append(serviceNode.Content,
		&yaml.Node{Kind: yaml.ScalarNode, Value: key},
		&yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: value},
	)
}

func copyDir(source, dest string) error {
	return filepath.Walk(source, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		rel, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}

		if rel != "." {
			parts := strings.Split(rel, string(os.PathSeparator))
			if _, skip := composeStageSkipDirs[parts[0]]; skip {
				if info.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
		}

		target := filepath.Join(dest, rel)
		if info.IsDir() {
			return os.MkdirAll(target, 0o755)
		}

		if !info.Mode().IsRegular() {
			return nil
		}

		return copyFile(path, target)
	})
}

func copyFile(source, dest string) error {
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}

	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer out.Close()

	if _, err := io.Copy(out, in); err != nil {
		return err
	}

	return out.Close()
}

func migrationLabels(inspect containerInspect) [][2]string {
	if len(inspect.Config.Labels) == 0 {
		return nil
	}

	keys := make([]string, 0, len(inspect.Config.Labels))
	for key := range inspect.Config.Labels {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	labels := make([][2]string, 0, len(keys))
	for _, key := range keys {
		value := inspect.Config.Labels[key]
		if value == "" {
			continue
		}
		labels = append(labels, [2]string{key, value})
	}

	return labels
}
