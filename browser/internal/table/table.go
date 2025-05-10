package table

import (
	"regexp"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/evertras/bubble-table/table"
)

// XXX I'd prefer avoiding type aliases if I can
type (
	RowStyleFuncInput = table.RowStyleFuncInput
	Column            = table.Column
	Row               = table.Row
)

type Table struct {
	inner table.Model
	v     viewport.Model
}

func (t *Table) Init() tea.Cmd {
	// XXX what's the proper order here?
	return tea.Batch(
		t.inner.Init(),
		t.v.Init(),
	)
}

func (t *Table) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	// XXX pass messages down?
	return t, nil
}

func trimTableView(tableView string) string {
	re := regexp.MustCompile(`^[ \t]*\n*`)
	return re.ReplaceAllLiteralString(tableView, "")
}

func (t *Table) View() string {
	headerView := t.inner.WithRows([]table.Row{}).View()
	t.v.SetContent(trimTableView(t.inner.WithHeaderVisibility(false).View()))
	return headerView + "\n" + t.v.View()
}

// XXX don't even expose this
func (t *Table) Focused(focused bool) *Table {
	return &Table{
		inner: t.inner.Focused(focused),
		v:     t.v,
	}
}

func (t *Table) WithFooterVisibility(visible bool) *Table {
	return &Table{
		inner: t.inner.WithFooterVisibility(visible),
		v:     t.v,
	}
}

// XXX don't even expose this
func (t *Table) WithMultiline(multiline bool) *Table {
	return &Table{
		inner: t.inner.WithMultiline(multiline),
		v:     t.v,
	}
}

func (t *Table) HeaderStyle(style lipgloss.Style) *Table {
	return &Table{
		inner: t.inner.HeaderStyle(style),
		v:     t.v,
	}
}

// XXX once I get things compiling, fix the API
func (t *Table) WithBaseStyle(style lipgloss.Style) *Table {
	return &Table{
		inner: t.inner.WithBaseStyle(style),
		v:     t.v,
	}
}

func (t *Table) WithRowStyleFunc(f func(in table.RowStyleFuncInput) lipgloss.Style) *Table {
	return &Table{
		inner: t.inner.WithRowStyleFunc(f),
		v:     t.v,
	}
}

func (t *Table) WithRows(rows []table.Row) *Table {
	return &Table{
		inner: t.inner.WithRows(rows),
		v:     t.v,
	}
}

func (t *Table) WithTargetWidth(width int) *Table {
	return &Table{
		inner: t.inner.WithTargetWidth(width),
		v:     viewport.New(width, t.v.Height),
	}
}

func (t *Table) WithTargetHeight(height int) *Table {
	return &Table{
		inner: t.inner,
		v:     viewport.New(t.v.Width, height-4), // XXX - 2 for the header and padding - can I avoid hard-coding this?
	}
}

// XXX return a Table rather than a *Table?
func New(columns []table.Column) *Table {
	t := table.New(columns).
		Border(table.Border{
			// XXX these values feel super-duper magical and I would like to figure
			//     out if there's a better way, but this'll work for now
			RightJunction: " ",
			BottomRight:   " ",
			InnerDivider:  " ",
		}) // don't show any borders, but space out cells

	return &Table{
		inner: t,
		v:     viewport.New(80, 25),
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
