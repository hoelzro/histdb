package table

import (
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/evertras/bubble-table/table"
)

// XXX I'd prefer avoiding type aliases if I can
type (
	Border            = table.Border
	RowStyleFuncInput = table.RowStyleFuncInput
	Column            = table.Column
	Row               = table.Row
)

type Table struct {
	inner table.Model
}

func (t *Table) Init() tea.Cmd {
	return t.inner.Init()
}

func (t *Table) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	return t, nil
}

func (t *Table) View() string {
	return t.inner.View()
}

func (t *Table) Border(border table.Border) *Table {
	return &Table{
		inner: t.inner.Border(border),
	}
}

// XXX don't even expose this
func (t *Table) Focused(focused bool) *Table {
	return &Table{
		inner: t.inner.Focused(focused),
	}
}

func (t *Table) WithFooterVisibility(visible bool) *Table {
	return &Table{
		inner: t.inner.WithFooterVisibility(visible),
	}
}

// XXX don't even expose this
func (t *Table) WithMultiline(multiline bool) *Table {
	return &Table{
		inner: t.inner.WithMultiline(multiline),
	}
}

func (t *Table) HeaderStyle(style lipgloss.Style) *Table {
	return &Table{
		inner: t.inner.HeaderStyle(style),
	}
}

// XXX once I get things compiling, fix the API
func (t *Table) WithBaseStyle(style lipgloss.Style) *Table {
	return &Table{
		inner: t.inner.WithBaseStyle(style),
	}
}

func (t *Table) WithRowStyleFunc(f func(in table.RowStyleFuncInput) lipgloss.Style) *Table {
	return &Table{
		inner: t.inner.WithRowStyleFunc(f),
	}
}

func (t *Table) WithRows(rows []table.Row) *Table {
	return &Table{
		inner: t.inner.WithRows(rows),
	}
}

func (t *Table) WithTargetWidth(width int) *Table {
	return &Table{
		inner: t.inner.WithTargetWidth(width),
	}
}

// XXX return a Table rather than a *Table?
func New(columns []table.Column) *Table {
	return &Table{
		inner: table.New(columns),
	}
}

func NewColumn(key, title string, width int) Column {
	return table.NewColumn(key, title, width)
}

func NewFlexColumn(key, title string, flexFactor int) Column {
	return table.NewFlexColumn(key, title, flexFactor)
}

func NewRow(data table.RowData) Row {
	return table.NewRow(data)
}
