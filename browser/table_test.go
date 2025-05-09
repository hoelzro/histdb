package main_test

import (
	"io"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/exp/teatest"

	"hoelz.ro/histdb-browser/internal/table"
)

type testModel struct {
	t *table.Table
}

func (m *testModel) Init() tea.Cmd {
	return m.t.Init()
}

func (m *testModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	return m, tea.Quit
}

func (m *testModel) View() string {
	return m.t.View()
}

// XXX highlighted row should always be visible
// XXX header should always be visible
// XXX filtering rows further should do XYZ wrt. the highlighted row
// XXX all parts of a multi-line highlighted row should be visible
// XXX handle case where the terminal height is less than the number of lines in a multi-line entry
// XXX handle case where the entry is a single line, but it's a loooooong one
// XXX handle case where there are no rows

func TestTable(t *testing.T) {
	headerStyle := lipgloss.NewStyle().Bold(true)
	defaultStyle := lipgloss.NewStyle().AlignHorizontal(lipgloss.Left)
	testWidth := 300
	testHeight := 100

	columns := []table.Column{
		table.NewColumn("id", "id", 5),
		table.NewFlexColumn("entry", "entry", 1),
	}

	entries := []string{
		"one",
		"two",
		"three",
		"four",
		"five",
		"six",
		"seven",
		"eight",
		"nine",
		"ten",
	}
	rows := make([]table.Row, len(entries))

	for i, entry := range entries {
		rows[i] = table.NewRow(map[string]any{
			"id":    i,
			"entry": entry,
		})
	}

	m := &testModel{
		t: table.New(columns).
			Border(table.Border{
				// XXX these values feel super-duper magical and I would like to figure
				//     out if there's a better way, but this'll work for now
				RightJunction: " ",
				BottomRight:   " ",
				InnerDivider:  " ",
			}).                          // don't show any borders, but space out cells
			Focused(true).               // needed to display row highlights
			WithFooterVisibility(false). // don't show the paging widget
			WithMultiline(true).
			// styling
			HeaderStyle(headerStyle).
			WithBaseStyle(defaultStyle).
			WithRowStyleFunc(func(in table.RowStyleFuncInput) lipgloss.Style {
				return defaultStyle
			}).
			WithRows(rows).
			WithTargetWidth(testWidth),
	}

	tm := teatest.NewTestModel(t, m, teatest.WithInitialTermSize(testWidth, testHeight))
	output, err := io.ReadAll(tm.FinalOutput(t, teatest.WithFinalTimeout(time.Second*10)))
	if err != nil {
		t.Fail()
	}

	if !strings.Contains(string(output), "five") {
		t.Log(string(output))
		t.Fail()
	}
}
