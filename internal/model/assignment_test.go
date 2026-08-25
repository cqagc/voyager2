package model

import (
	"path/filepath"
	"testing"

	"github.com/cqagc/voyager2/internal/domain"
)

const assignmentPath = "../../assets/generated/assignment.json"

// TestGeneratedAssignmentSatisfiesContract is the check that was missing when
// the model split was first delegated: it verifies the actual generated
// artifact against domain.AllComponents, rather than trusting that whoever ran
// the splitter used the right names.
func TestGeneratedAssignmentSatisfiesContract(t *testing.T) {
	a, err := Load(filepath.Clean(assignmentPath))
	if err != nil {
		t.Skipf("assignment not generated yet (%v); run tools/model/assign.py --mode export", err)
	}
	if err := a.Verify(); err != nil {
		t.Fatalf("contract violated: %v", err)
	}

	if a.TotalParts == 0 {
		t.Error("total_parts is 0; the splitter produced nothing")
	}

	// Every part must land somewhere: the sum over components (including the
	// excluded helper geometry) has to equal the total the splitter saw.
	sum := 0
	for _, s := range a.Components {
		sum += s.Parts
	}
	if sum != a.TotalParts {
		t.Errorf("parts do not add up: components sum to %d, total_parts is %d", sum, a.TotalParts)
	}

	var distinct, aliased int
	for _, c := range domain.AllComponents {
		node, ok := a.Resolve(c)
		if ok {
			distinct++
		} else {
			aliased++
			t.Logf("%-20s -> %s (模型未区分)", c, node)
		}
	}
	t.Logf("%d/%d components have their own geometry, %d alias to a containing node",
		distinct, len(domain.AllComponents), aliased)
}

func TestVerifyRejectsUnknownComponent(t *testing.T) {
	a := &Assignment{
		TotalParts: 1,
		Components: map[string]ComponentStat{"NotAThing": {Parts: 1, Vertices: 3}},
	}
	if err := a.Verify(); err == nil {
		t.Error("expected an error for a component outside domain.AllComponents")
	}
}

func TestVerifyRejectsEmptyGeometry(t *testing.T) {
	comps := map[string]ComponentStat{}
	for _, c := range domain.AllComponents {
		comps[string(c)] = ComponentStat{Parts: 1, Vertices: 3}
	}
	comps[string(domain.CompRTG2)] = ComponentStat{Parts: 0, Vertices: 0}
	a := &Assignment{TotalParts: 1, Components: comps}
	if err := a.Verify(); err == nil {
		t.Error("expected an error for a component with no geometry")
	}
}

func TestVerifyRejectsDanglingAlias(t *testing.T) {
	comps := map[string]ComponentStat{}
	for _, c := range domain.AllComponents {
		comps[string(c)] = ComponentStat{Parts: 1, Vertices: 3}
	}
	a := &Assignment{
		TotalParts:        1,
		Components:        comps,
		UnresolvedInModel: map[string]string{string(domain.CompInstrumentPLS): "NoSuchNode"},
	}
	if err := a.Verify(); err == nil {
		t.Error("expected an error for an alias pointing at a missing node")
	}
}

// TestVerifyRejectsAliasToExcluded guards the hole the cross-model review found:
// aliasing a real component to the non-spacecraft helper geometry would pass
// every other check while leaving that component with no real geometry.
func TestVerifyRejectsAliasToExcluded(t *testing.T) {
	comps := map[string]ComponentStat{
		"_EXCLUDED": {Parts: 6, Vertices: 24, ConfidenceNote: "glTF 辅助包围盒"},
	}
	for _, c := range domain.AllComponents {
		comps[string(c)] = ComponentStat{Parts: 1, Vertices: 3, ConfidenceNote: "x"}
	}
	a := &Assignment{
		TotalParts:        1,
		Components:        comps,
		UnresolvedInModel: map[string]string{string(domain.CompBus): "_EXCLUDED"},
	}
	if err := a.Verify(); err == nil {
		t.Error("aliasing Bus to _EXCLUDED must be rejected: helper geometry is not spacecraft geometry")
	}
}
