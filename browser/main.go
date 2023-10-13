//go:build libsqlite3

package main

import (
	"database/sql"

	"github.com/charmbracelet/bubbles/table"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/mattn/go-sqlite3"
)

var baseStyle = lipgloss.NewStyle()

type model struct {
	db    *sql.DB
	input textinput.Model
	table table.Model
}

func (m model) Init() tea.Cmd {
	return textinput.Blink
}

func (m model) getRowsFromQuery(sql string, args ...any) ([]table.Row, error) {
	rows, err := m.db.Query(sql, args...)
	if err != nil {
		return nil, err
	}

	tableRows := make([]table.Row, 0)

	for rows.Next() {
		var timestamp string
		var entry string

		err := rows.Scan(&timestamp, &entry)
		if err != nil {
			return nil, err
		}

		tableRows = append(tableRows, table.Row{timestamp, entry})
	}

	if err := rows.Err(); err != nil {
		return nil, err
	}

	return tableRows, nil
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c":
			return m, tea.Quit
		}
	}

	var tableCmd tea.Cmd
	var inputCmd tea.Cmd

	m.table, tableCmd = m.table.Update(msg)
	m.input, inputCmd = m.input.Update(msg)

	var rows []table.Row
	var err error
	query := m.input.Value()
	if query == "" {
		rows, err = m.getRowsFromQuery("SELECT timestamp, entry FROM h WHERE timestamp IS NOT NULL ORDER BY timestamp DESC LIMIT 5")
	} else {
		rows, err = m.getRowsFromQuery("SELECT timestamp, entry FROM h WHERE timestamp IS NOT NULL AND entry MATCH ? ORDER BY timestamp DESC LIMIT 5", query)
	}
	if err != nil {
		panic(err)
	}

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
	m := model{db, input, t}
	if _, err := tea.NewProgram(m).Run(); err != nil {
		panic(err)
	}
}
