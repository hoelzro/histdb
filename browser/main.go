//go:build libsqlite3

package main

import (
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/table"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/mattn/go-sqlite3"

	"golang.org/x/exp/slices"
)

var baseStyle = lipgloss.NewStyle()

var toggleWorkingDirectoryKey = key.NewBinding(
	key.WithKeys("f2"),
	key.WithHelp("f2", "Toggle working directory column"),
)

var toggleTimestampKey = key.NewBinding(
	key.WithKeys("f3"),
	key.WithHelp("f3", "Toggle timestamp column"),
)

type model struct {
	db    *sql.DB
	input textinput.Model
	table table.Model

	showTimestamp        bool
	showWorkingDirectory bool
}

func (m model) Init() tea.Cmd {
	return textinput.Blink
}

func (m model) getRowsFromQuery(sql string, args ...any) ([]table.Column, []table.Row, error) {
	rows, err := m.db.Query(sql, args...)
	if err != nil {
		return nil, nil, err
	}

	tableRows := make([]table.Row, 0)

	columns, err := rows.Columns()
	if err != nil {
		return nil, nil, err
	}

	tableColumns := make([]table.Column, len(columns))
	currentRow := table.Row(make([]string, len(columns)))
	scanPointers := make([]any, len(columns))

	for i, columnName := range columns {
		tableColumns[i] = table.Column{
			Title: columnName,
			Width: 20, // XXX improve me
		}
		scanPointers[i] = &currentRow[i]
	}

	// XXX always the last column? or always the entry column?
	tableColumns[len(tableColumns)-1].Width = 100

	for rows.Next() {
		err := rows.Scan(scanPointers...)
		if err != nil {
			return nil, nil, err
		}
		tableRows = append(tableRows, slices.Clone(currentRow))
	}

	if err := rows.Err(); err != nil {
		return nil, nil, err
	}

	return tableColumns, tableRows, err
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c":
			return m, tea.Quit
		}

		// XXX merge these two (put ctrl+c into a keymap)
		switch {
		case key.Matches(msg, toggleWorkingDirectoryKey):
			m.showWorkingDirectory = !m.showWorkingDirectory
		case key.Matches(msg, toggleTimestampKey):
			m.showTimestamp = !m.showTimestamp
		}
	}

	var tableCmd tea.Cmd
	var inputCmd tea.Cmd

	m.table, tableCmd = m.table.Update(msg)
	m.input, inputCmd = m.input.Update(msg)

	selectClauseColumns := make([]string, 0)

	if m.showTimestamp {
		selectClauseColumns = append(selectClauseColumns, "timestamp")
	}
	if m.showWorkingDirectory {
		selectClauseColumns = append(selectClauseColumns, "cwd")
	}

	selectClauseColumns = append(selectClauseColumns, "entry")

	selectClause := strings.Join(selectClauseColumns, ", ")

	var columns []table.Column
	var rows []table.Row
	var err error
	query := m.input.Value()
	if query == "" {
		columns, rows, err = m.getRowsFromQuery(fmt.Sprintf("SELECT %s FROM h WHERE timestamp IS NOT NULL ORDER BY timestamp DESC LIMIT 5", selectClause))
	} else {
		columns, rows, err = m.getRowsFromQuery(fmt.Sprintf("SELECT %s FROM h WHERE timestamp IS NOT NULL AND entry MATCH ? ORDER BY timestamp DESC LIMIT 5", selectClause), query)
	}
	if err != nil {
		panic(err)
	}

	// if the set of visible columns has changed, it won't be consistent with the current
	// rows and we may get an index out of range panic - so clear the rows before setting
	// up the columns
	m.table.SetRows(nil) // XXX should we only do this if the column set changed?

	m.table.SetColumns(columns)
	m.table.SetRows(rows)

	return m, tea.Batch(tableCmd, inputCmd)
}

func (m model) View() string {
	return m.input.View() + "\n" + baseStyle.Render(m.table.View()) + "\n"
}

// XXX highlight matching parts of entry in table rows
// XXX hotkey to toggle various columns
// XXX hotkey to toggle local vs global history
// XXX hotkey to convert query to SQL
// XXX load today's DB too

// XXX create a dummy application that live-filters table rows against a query from a textbox
func main() {
	sql.Register("sqlite3-histdb-extensions", &sqlite3.SQLiteDriver{
		Extensions: []string{
			"/home/rob/projects/sqlite-lua-vtable/lua-vtable.so",
		},
	})

	// XXX probably want to do the whole roll-up and ATTACH thing too?
	db, err := sql.Open("sqlite3-histdb-extensions", "/home/rob/.cache/histdb.db")
	if err != nil {
		panic(err)
	}
	defer db.Close()

	databaseDir := "/home/rob/.zsh_history.d"
	todayDatabaseBasename := time.Now().Format(time.DateOnly) + ".db"

	_, err = db.Exec(fmt.Sprintf("ATTACH DATABASE '%s/%s' AS today_db", databaseDir, todayDatabaseBasename))
	if err != nil {
		panic(err)
	}

	_, err = db.Exec("SELECT lua_create_module_from_file('/home/rob/projects/histdb-redux/histdb.lua')")
	if err != nil {
		panic(err)
	}

	_, err = db.Exec("CREATE TEMPORARY VIEW history AS SELECT rowid, * FROM history_before_today")
	if err != nil {
		panic(err)
	}

	columns := []table.Column{
		{Title: "timestamp", Width: 20},
		{Title: "entry", Width: 100}, // XXX flex column, I assume
	}

	input := textinput.New()
	input.Focus()

	t := table.New(
		table.WithColumns(columns),
		table.WithHeight(5),
	)
	m := model{
		db:    db,
		input: input,
		table: t,

		showTimestamp: true,
	}
	if _, err := tea.NewProgram(m).Run(); err != nil {
		panic(err)
	}
}
