package main

import (
	"database/sql"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/evertras/bubble-table/table"
	"github.com/mattn/go-sqlite3"
)

var (
	defaultStyle       = lipgloss.NewStyle().AlignHorizontal(lipgloss.Left)
	headerStyle        = lipgloss.NewStyle().Bold(true)
	highlightStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("#ff87d7")).Bold(true)
	failedCommandStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#ff0000")).Bold(true)
)

var toggleWorkingDirectoryKey = key.NewBinding(
	key.WithKeys("f2"),
	key.WithHelp("f2", "Toggle working directory column"),
)

var toggleTimestampKey = key.NewBinding(
	key.WithKeys("f3"),
	key.WithHelp("f3", "Toggle timestamp column"),
)

var toggleSessionIDKey = key.NewBinding(
	key.WithKeys("f4"),
	key.WithHelp("f4", "Toggle session ID column"),
)

var columnWidths = map[string]int{
	"timestamp":  20, // based on YYYY-MM-DD HH:MM:SS, with a little padding
	"session_id": 11, // this could be 6 based on PIDs on my machine, but bumped to len("session_id")
	"cwd":        70, // based on my history
}

type model struct {
	db    *sql.DB
	input textinput.Model
	table table.Model

	selection string

	showTimestamp        bool
	showWorkingDirectory bool
	showSessionID        bool
}

func (m model) Init() tea.Cmd {
	return m.table.Init()
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

	tableColumns := make([]table.Column, 0, len(columns))

	for _, columnName := range columns {
		if columnName == "exit_status" {
			continue
		}

		columnWidth := columnWidths[columnName]
		if columnWidth == 0 {
			columnWidth = 20
		}

		tableColumns = append(tableColumns, table.NewColumn(columnName, columnName, columnWidth))
	}

	tableColumns[len(tableColumns)-1] = table.NewFlexColumn(tableColumns[len(tableColumns)-1].Key(), tableColumns[len(tableColumns)-1].Title(), 1)

	for rows.Next() {
		// XXX do this once
		rowValues := make([]string, len(columns))
		scanPointers := make([]any, len(columns))
		for i := range rowValues {
			scanPointers[i] = &rowValues[i]
		}

		err := rows.Scan(scanPointers...)
		if err != nil {
			return nil, nil, err
		}

		rowData := make(map[string]any)

		for i, columnName := range columns {
			rowData[columnName] = rowValues[i]
		}
		tableRows = append(tableRows, table.NewRow(rowData))
	}

	if err := rows.Err(); err != nil {
		return nil, nil, err
	}

	return tableColumns, tableRows, err
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var tableCmd tea.Cmd
	var inputCmd tea.Cmd

	columnsChanged := false

	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.table = m.table.WithTargetWidth(msg.Width)
		columnsChanged = true
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c":
			return m, tea.Quit
		case "down":
			m.table, tableCmd = m.table.Update(tea.KeyMsg{Type: tea.KeyDown})
		case "up":
			m.table, tableCmd = m.table.Update(tea.KeyMsg{Type: tea.KeyUp})
		case "enter":
			m.selection = m.table.HighlightedRow().Data["entry"].(string)
			return m, tea.Quit
		}

		// XXX merge these two (put ctrl+c into a keymap)
		switch {
		case key.Matches(msg, toggleWorkingDirectoryKey):
			m.showWorkingDirectory = !m.showWorkingDirectory
			columnsChanged = true
		case key.Matches(msg, toggleTimestampKey):
			m.showTimestamp = !m.showTimestamp
			columnsChanged = true
		case key.Matches(msg, toggleSessionIDKey):
			m.showSessionID = !m.showSessionID
			columnsChanged = true
		}
	}

	previousQuery := m.input.Value()

	if _, isKeyMsg := msg.(tea.KeyMsg); !isKeyMsg {
		m.table, tableCmd = m.table.Update(msg)
	}
	m.input, inputCmd = m.input.Update(msg)

	if query := m.input.Value(); query != previousQuery || m.table.TotalRows() == 0 || columnsChanged {
		selectClauseColumns := make([]string, 0)

		if m.showTimestamp {
			selectClauseColumns = append(selectClauseColumns, "timestamp")
		}
		if m.showSessionID {
			selectClauseColumns = append(selectClauseColumns, "session_id")
		}
		if m.showWorkingDirectory {
			selectClauseColumns = append(selectClauseColumns, "cwd")
		}

		selectClauseColumns = append(selectClauseColumns, "entry")

		selectClause := strings.Join(selectClauseColumns, ", ")

		var columns []table.Column
		var rows []table.Row
		var err error

		if query == "" {
			columns, rows, err = m.getRowsFromQuery(fmt.Sprintf("SELECT %s, COALESCE(exit_status, '') AS exit_status FROM h WHERE timestamp IS NOT NULL ORDER BY timestamp DESC LIMIT 100", selectClause))
		} else {
			columns, rows, err = m.getRowsFromQuery(fmt.Sprintf("SELECT %s, COALESCE(exit_status, '') AS exit_status FROM h WHERE timestamp IS NOT NULL AND entry MATCH ? ORDER BY timestamp DESC LIMIT 100", selectClause), query)
		}
		if err != nil {
			panic(err)
		}

		m.table = m.table.WithColumns(columns)
		m.table = m.table.WithRows(rows)
	}

	return m, tea.Batch(tableCmd, inputCmd)
}

func (m model) View() string {
	return m.input.View() + "\n" + m.table.View() + "\n"
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

	st, err := os.Stat("/home/rob/.cache/histdb.db")
	if err != nil {
		panic(err)
	}

	// if the rollup database is too old, just run histdb to refresh it
	if time.Now().Format(time.DateOnly) != st.ModTime().Format(time.DateOnly) {
		err := exec.Command("histdb", ".schema").Run()
		if err != nil {
			panic(err)
		}
	}

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

	_, err = db.Exec(`
CREATE TABLE IF NOT EXISTS today_db.history (
    hostname,
    session_id, -- shell PID
    timestamp integer not null,
    tz_offset integer,
    history_id, -- $HISTCMD
    cwd,
    entry,
    duration,
    exit_status
);
	`)
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

	lipgloss.SetDefaultRenderer(lipgloss.NewRenderer(os.Stderr))

	input := textinput.New()
	input.Focus()

	t := table.New(nil).
		WithPageSize(20).            // only show the top 20 rows
		Border(table.Border{}).      // don't show any borders
		Focused(true).               // needed to display row highlights
		WithFooterVisibility(false). // don't show the paging widget
		// styling
		HeaderStyle(headerStyle).
		WithBaseStyle(defaultStyle).
		WithRowStyleFunc(func(in table.RowStyleFuncInput) lipgloss.Style {
			if in.IsHighlighted {
				return highlightStyle
			}
			exitStatus := in.Row.Data["exit_status"].(string)
			if exitStatus != "" && exitStatus != "0" && exitStatus != "148" {
				return failedCommandStyle
			}
			return defaultStyle
		})

	m := model{
		db:    db,
		input: input,
		table: t,

		showTimestamp: true,
	}
	resModel, err := tea.NewProgram(m, tea.WithOutput(os.Stderr)).Run()
	if err != nil {
		panic(err)
	}

	m = resModel.(model)
	if m.selection != "" {
		fmt.Println(m.selection)
	}
}
